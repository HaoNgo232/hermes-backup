#!/usr/bin/env bash
# =====================================================================
# install-systemd.sh - Enable the Hermes cloud backup timer (user unit)
# =====================================================================
set -Eeuo pipefail
umask 077

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/lib/common.sh"
source "${SRC_DIR}/lib/state.sh"
source "${SRC_DIR}/lib/hermes.sh"

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${C_RED}ERROR: Refusing to run as root. Run as regular user.${C_RESET}" >&2
    exit 1
fi

UNIT_DIR="${HOME}/.config/systemd/user"
SERVICE="hermes-cloud-backup.service"
TIMER="hermes-cloud-backup.timer"

# ---------------------------------------------------------------------
# PREFLIGHT CHECKS
# ---------------------------------------------------------------------
if ! command -v systemctl &>/dev/null; then
    echo -e "${C_RED}ERROR: 'systemctl' command not found. Systemd is required to install the backup timer.${C_RESET}" >&2
    exit 1
fi

if ! systemctl --user status &>/dev/null && ! systemctl --user show-environment &>/dev/null; then
    echo -e "${C_RED}ERROR: Cannot connect to systemd user manager ('systemctl --user').${C_RESET}" >&2
    echo "Make sure you are logged into an active systemd user session." >&2
    echo "For unattended operation after logout/reboot, enable linger separately." >&2
    exit 1
fi

if [ ! -x "${SRC_DIR}/backup.sh" ]; then
    echo -e "${C_RED}ERROR: '${SRC_DIR}/backup.sh' is missing or not executable.${C_RESET}" >&2
    echo "Run 'chmod +x ${SRC_DIR}/backup.sh' first." >&2
    exit 1
fi

if [ ! -f "${SRC_DIR}/systemd/${SERVICE}" ] || [ ! -f "${SRC_DIR}/systemd/${TIMER}" ]; then
    echo -e "${C_RED}ERROR: Systemd unit templates missing in '${SRC_DIR}/systemd/'.${C_RESET}" >&2
    exit 1
fi

state_load

STORED_HERMES_HOME="$(state_get "HERMES_HOME" "")"

if [ -n "${HERMES_HOME:-}" ] && [ -n "${STORED_HERMES_HOME}" ] && [ "${HERMES_HOME}" != "${STORED_HERMES_HOME}" ]; then
    echo -e "${C_RED}ERROR: HERMES_HOME environment variable ('${HERMES_HOME}') differs from stored state ('${STORED_HERMES_HOME}').${C_RESET}" >&2
    echo "Normal setup/install will not silently change Hermes home." >&2
    exit 1
fi

hermes_apply_persisted_environment

if ! HERMES_RESOLVED="$(hermes_resolve_binary)"; then
    exit 1
fi

HERMES_DIR="$(dirname "${HERMES_RESOLVED}")"
EXPLICIT_PATH="${HERMES_DIR}:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"

EFFECTIVE_XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
EFFECTIVE_HERMES_HOME="${HERMES_HOME:-${STORED_HERMES_HOME:-$HOME/.hermes}}"

for checked_path in "${SRC_DIR}" "${HERMES_RESOLVED}" "${EFFECTIVE_XDG_CONFIG}" "${EFFECTIVE_HERMES_HOME}"; do
    if [[ "${checked_path}" == *$'\n'* || "${checked_path}" == *$'\r'* ]]; then
        echo -e "${C_RED}ERROR: Path contains invalid newline characters.${C_RESET}" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------
# RENDER HELPERS
# ---------------------------------------------------------------------
systemd_escape_double_quoted() {
    local value="$1"

    if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
        log_error "Cannot render a systemd value containing newline characters."
        return 1
    fi

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//%/%%}"

    printf '%s' "${value}"
}

replace_literal() {
    local input="$1"
    local token="$2"
    local replacement="$3"
    local prefix=""

    REPLY=""

    while [[ "${input}" == *"${token}"* ]]; do
        prefix="${input%%"${token}"*}"
        REPLY+="${prefix}${replacement}"
        input="${input#*"${token}"}"
    done

    REPLY+="${input}"
}

# ---------------------------------------------------------------------
# TRANSACTIONAL STAGING AND INSTALLATION
# ---------------------------------------------------------------------
STAGING_UNIT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hermes-systemd-units-XXXXXX")"
chmod 0700 "${STAGING_UNIT_DIR}"

cleanup_staging() {
    if [ -n "${STAGING_UNIT_DIR:-}" ] && [ -d "${STAGING_UNIT_DIR}" ]; then
        rm -rf "${STAGING_UNIT_DIR}" 2>/dev/null || true
    fi
}
trap cleanup_staging EXIT

REPO_DIR_ESC="$(systemd_escape_double_quoted "${SRC_DIR}")"
HERMES_BIN_ESC="$(systemd_escape_double_quoted "${HERMES_RESOLVED}")"
PATH_ESC="$(systemd_escape_double_quoted "${EXPLICIT_PATH}")"
XDG_CONFIG_ESC="$(systemd_escape_double_quoted "${EFFECTIVE_XDG_CONFIG}")"
HERMES_HOME_ESC="$(systemd_escape_double_quoted "${EFFECTIVE_HERMES_HOME}")"

service_template="$(cat "${SRC_DIR}/systemd/${SERVICE}")"
replace_literal "${service_template}" "@REPO_DIR@" "${REPO_DIR_ESC}"
rendered_svc="${REPLY}"
replace_literal "${rendered_svc}" "@HERMES_BIN@" "${HERMES_BIN_ESC}"
rendered_svc="${REPLY}"
replace_literal "${rendered_svc}" "@HERMES_HOME@" "${HERMES_HOME_ESC}"
rendered_svc="${REPLY}"
replace_literal "${rendered_svc}" "@PATH@" "${PATH_ESC}"
rendered_svc="${REPLY}"
replace_literal "${rendered_svc}" "@XDG_CONFIG_HOME@" "${XDG_CONFIG_ESC}"
rendered_svc="${REPLY}"
rendered_svc+=$'\n'

timer_template="$(cat "${SRC_DIR}/systemd/${TIMER}")"
replace_literal "${timer_template}" "@REPO_DIR@" "${REPO_DIR_ESC}"
rendered_timer="${REPLY}"
replace_literal "${rendered_timer}" "@HERMES_BIN@" "${HERMES_BIN_ESC}"
rendered_timer="${REPLY}"
replace_literal "${rendered_timer}" "@HERMES_HOME@" "${HERMES_HOME_ESC}"
rendered_timer="${REPLY}"
replace_literal "${rendered_timer}" "@PATH@" "${PATH_ESC}"
rendered_timer="${REPLY}"
replace_literal "${rendered_timer}" "@XDG_CONFIG_HOME@" "${XDG_CONFIG_ESC}"
rendered_timer="${REPLY}"
rendered_timer+=$'\n'

atomic_write_file "${STAGING_UNIT_DIR}/${SERVICE}" "${rendered_svc}" 0644
atomic_write_file "${STAGING_UNIT_DIR}/${TIMER}" "${rendered_timer}" 0644

# 1. Check no placeholders remain
if grep -R -E '@[A-Z0-9_]+@' "${STAGING_UNIT_DIR}" &>/dev/null; then
    echo -e "${C_RED}ERROR: Unsubstituted placeholder remains in rendered unit files.${C_RESET}" >&2
    exit 1
fi

# 2. Run secret-like value check on staged service and timer
if grep -Eqi 'password2?|recovery|refresh_token|access_token|client_secret' "${STAGING_UNIT_DIR}/${SERVICE}" "${STAGING_UNIT_DIR}/${TIMER}"; then
    echo -e "${C_RED}ERROR: Secret-like values detected in rendered systemd unit!${C_RESET}" >&2
    exit 1
fi

# 3. If systemd-analyze is installed, verify units
if command -v systemd-analyze &>/dev/null; then
    if SYSTEMD_UNIT_PATH="${STAGING_UNIT_DIR}:${SYSTEMD_UNIT_PATH:-}" systemd-analyze --user verify "${STAGING_UNIT_DIR}/${SERVICE}" "${STAGING_UNIT_DIR}/${TIMER}" &>/dev/null; then
        :
    elif SYSTEMD_UNIT_PATH="${STAGING_UNIT_DIR}:${SYSTEMD_UNIT_PATH:-}" systemd-analyze verify "${STAGING_UNIT_DIR}/${SERVICE}" "${STAGING_UNIT_DIR}/${TIMER}" &>/dev/null; then
        :
    else
        echo -e "${C_RED}ERROR: Rendered systemd unit failed verification.${C_RESET}" >&2
        exit 1
    fi
fi

# 4. Save existing unit content for rollback if needed
BACKUP_SERVICE_EXISTS=false
BACKUP_TIMER_EXISTS=false
SVC_BACKUP_CONTENT=""
TMR_BACKUP_CONTENT=""

if [ -f "${UNIT_DIR}/${SERVICE}" ]; then
    BACKUP_SERVICE_EXISTS=true
    SVC_BACKUP_CONTENT="$(cat "${UNIT_DIR}/${SERVICE}")"
fi
if [ -f "${UNIT_DIR}/${TIMER}" ]; then
    BACKUP_TIMER_EXISTS=true
    TMR_BACKUP_CONTENT="$(cat "${UNIT_DIR}/${TIMER}")"
fi

# Atomically install final unit files
mkdir -p "${UNIT_DIR}"
atomic_write_file "${UNIT_DIR}/${SERVICE}" "${rendered_svc}" 0644
atomic_write_file "${UNIT_DIR}/${TIMER}" "${rendered_timer}" 0644

# Persist HERMES_HOME and HERMES_BIN state
state_set_many "HERMES_HOME" "${EFFECTIVE_HERMES_HOME}" "HERMES_BIN" "${HERMES_RESOLVED}"

echo -e "  ${BADGE_OK} Installed service: ${UNIT_DIR}/${SERVICE}"
echo -e "  ${BADGE_OK} Installed timer:   ${UNIT_DIR}/${TIMER}"

# 5. Daemon reload and activate with rollback on failure
rollback_units() {
    if [ "${BACKUP_SERVICE_EXISTS}" = true ]; then
        atomic_write_file "${UNIT_DIR}/${SERVICE}" "${SVC_BACKUP_CONTENT}" 0644
    else
        rm -f "${UNIT_DIR}/${SERVICE}" 2>/dev/null || true
    fi

    if [ "${BACKUP_TIMER_EXISTS}" = true ]; then
        atomic_write_file "${UNIT_DIR}/${TIMER}" "${TMR_BACKUP_CONTENT}" 0644
    else
        rm -f "${UNIT_DIR}/${TIMER}" 2>/dev/null || true
    fi
    systemctl --user daemon-reload 2>/dev/null || true
}

if ! systemctl --user daemon-reload 2>/dev/null || ! systemctl --user enable --now "${TIMER}" 2>/dev/null; then
    echo -e "${C_RED}ERROR: Failed to reload daemon or enable systemd timer.${C_RESET}" >&2
    rollback_units
    exit 1
fi

IS_ENABLED="$(systemctl --user is-enabled "${TIMER}" 2>/dev/null || echo "no")"
IS_ACTIVE="$(systemctl --user is-active "${TIMER}" 2>/dev/null || echo "no")"

echo ""
echo -e "${C_BOLD}=== Systemd Timer Status ===${C_RESET}"
if [ "${IS_ENABLED}" = "enabled" ]; then
    echo -e "  Timer Enabled : ${BADGE_OK} enabled"
else
    echo -e "  Timer Enabled : ${BADGE_WARN} ${IS_ENABLED}"
fi
if [ "${IS_ACTIVE}" = "active" ]; then
    echo -e "  Timer Active  : ${BADGE_OK} active"
else
    echo -e "  Timer Active  : ${BADGE_WARN} ${IS_ACTIVE}"
fi

if [ "${IS_ENABLED}" = "enabled" ] && [ "${IS_ACTIVE}" = "active" ]; then
    timer_info="$(systemctl --user list-timers "${TIMER}" --no-pager --legend=false 2>/dev/null | grep "${TIMER}" | head -n1 || true)"
    if [ -n "${timer_info}" ]; then
        read -r -a tokens <<< "${timer_info}"
        if [ "${tokens[0]}" = "-" ]; then
            echo -e "  Next Run      : None scheduled"
        else
            last_idx=-1
            for ((i=4; i<${#tokens[@]}-4; i++)); do
                if [[ "${tokens[$i]}" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]]; then
                    last_idx=$i
                    break
                fi
            done
            next_str="${tokens[0]} ${tokens[1]} ${tokens[2]} ${tokens[3]}"
            if [ $last_idx -gt 4 ]; then
                left_str="${tokens[*]:4:$((last_idx-4))}"
            else
                left_str="${tokens[4]:-} ${tokens[5]:-}"
            fi
            echo -e "  Next Run      : ${next_str} (${left_str} left)"
        fi
    else
        systemctl --user list-timers "${TIMER}" --no-pager 2>/dev/null | grep -v -E "timers listed|Pass --all" | sed 's/^/  /' || true
    fi
else
    echo -e "${BADGE_WARN} ${C_YELLOW}Timer installation finished but timer state is enabled=${IS_ENABLED}, active=${IS_ACTIVE}.${C_RESET}" >&2
    exit 1
fi

LINGER_STATUS="unknown"
if command -v loginctl &>/dev/null; then
    if loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
        LINGER_STATUS="enabled"
    elif [ -f "/var/lib/systemd/linger/$USER" ]; then
        LINGER_STATUS="enabled"
    else
        LINGER_STATUS="disabled"
    fi
fi

if [ "${LINGER_STATUS}" = "disabled" ]; then
    echo ""
    echo -e "${C_YELLOW}${C_BOLD}WARNING: User linger is NOT enabled for user '$USER'.${C_RESET}"
    echo "Without linger, systemd user timer will not run after logout or system reboot"
    echo "until you log back in."
    echo "To enable unattended operation after reboot/logout, run:"
    echo -e "  ${C_CYAN}sudo loginctl enable-linger $USER${C_RESET}"
fi

echo ""
echo -e "${C_GREEN}${C_BOLD}Installation complete!${C_RESET}"
echo "To manually trigger a backup test now, run:"
echo -e "  ${C_CYAN}systemctl --user start ${SERVICE}${C_RESET}"
