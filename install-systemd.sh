#!/usr/bin/env bash
# =====================================================================
# install-systemd.sh - Enable the Hermes cloud backup timer (user unit)
# =====================================================================
set -Eeuo pipefail
umask 077

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SRC_DIR}/lib/common.sh"
source "${SRC_DIR}/lib/state.sh"

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
STORED_HERMES_BIN="$(state_get "HERMES_BIN" "")"

HERMES_RESOLVED=""

if [ -n "${HERMES_BIN:-}" ]; then
    if [ ! -x "${HERMES_BIN}" ]; then
        echo -e "${C_RED}ERROR: Explicit HERMES_BIN environment variable ('${HERMES_BIN}') is not executable.${C_RESET}" >&2
        exit 1
    fi
    HERMES_RESOLVED="${HERMES_BIN}"
elif [ -n "${STORED_HERMES_BIN}" ] && [ -x "${STORED_HERMES_BIN}" ]; then
    HERMES_RESOLVED="${STORED_HERMES_BIN}"
elif command -v hermes &>/dev/null; then
    HERMES_RESOLVED="$(command -v hermes)"
fi

if [ -z "${HERMES_RESOLVED}" ]; then
    echo -e "${C_RED}ERROR: 'hermes' executable not found in PATH or HERMES_BIN environment variable.${C_RESET}" >&2
    echo "Please ensure Hermes is installed or set HERMES_BIN=/path/to/hermes before running installer." >&2
    exit 1
fi

HERMES_DIR="$(dirname "${HERMES_RESOLVED}")"
EXPLICIT_PATH="${HERMES_DIR}:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"

if [ -n "${HERMES_HOME:-}" ] && [ -n "${STORED_HERMES_HOME}" ] && [ "${HERMES_HOME}" != "${STORED_HERMES_HOME}" ]; then
    echo -e "${C_RED}ERROR: HERMES_HOME environment variable ('${HERMES_HOME}') differs from stored state ('${STORED_HERMES_HOME}').${C_RESET}" >&2
    echo "Normal setup/install will not silently change Hermes home." >&2
    exit 1
fi

EFFECTIVE_XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
EFFECTIVE_HERMES_HOME="${HERMES_HOME:-${STORED_HERMES_HOME:-$HOME/.hermes}}"

for checked_path in "${SRC_DIR}" "${HERMES_RESOLVED}" "${EFFECTIVE_XDG_CONFIG}" "${EFFECTIVE_HERMES_HOME}"; do
    if [[ "${checked_path}" == *$'\n'* || "${checked_path}" == *$'\r'* ]]; then
        echo -e "${C_RED}ERROR: Path contains invalid newline characters.${C_RESET}" >&2
        exit 1
    fi
done

state_set_many "HERMES_HOME" "${EFFECTIVE_HERMES_HOME}" "HERMES_BIN" "${HERMES_RESOLVED}"

# ---------------------------------------------------------------------
# RENDER AND INSTALL UNITS
# ---------------------------------------------------------------------
mkdir -p "${UNIT_DIR}"

escape_sed() {
    local val="$1"
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    val="${val//%/%%}"
    printf '%s\n' "${val}" | sed -e 's/[\/&]/\\&/g'
}

REPO_DIR_ESC="$(escape_sed "${SRC_DIR}")"
HERMES_BIN_ESC="$(escape_sed "${HERMES_RESOLVED}")"
PATH_ESC="$(escape_sed "${EXPLICIT_PATH}")"
XDG_CONFIG_ESC="$(escape_sed "${EFFECTIVE_XDG_CONFIG}")"
HERMES_HOME_ESC="$(escape_sed "${EFFECTIVE_HERMES_HOME}")"

rendered_svc="$(sed -e "s/@REPO_DIR@/${REPO_DIR_ESC}/g" \
    -e "s/@HERMES_BIN@/${HERMES_BIN_ESC}/g" \
    -e "s/@HERMES_HOME@/${HERMES_HOME_ESC}/g" \
    -e "s/@PATH@/${PATH_ESC}/g" \
    -e "s/@XDG_CONFIG_HOME@/${XDG_CONFIG_ESC}/g" \
    "${SRC_DIR}/systemd/${SERVICE}")"
atomic_write_file "${UNIT_DIR}/${SERVICE}" "${rendered_svc}" 0644

rendered_timer="$(sed -e "s/@REPO_DIR@/${REPO_DIR_ESC}/g" "${SRC_DIR}/systemd/${TIMER}")"
atomic_write_file "${UNIT_DIR}/${TIMER}" "${rendered_timer}" 0644

echo -e "  ${BADGE_OK} Installed service: ${UNIT_DIR}/${SERVICE}"
echo -e "  ${BADGE_OK} Installed timer:   ${UNIT_DIR}/${TIMER}"

# Verify secret-like values are NOT present in generated unit file
if grep -Eqi 'password2?|recovery|refresh_token|access_token|client_secret' "${UNIT_DIR}/${SERVICE}"; then
    echo -e "${C_RED}ERROR: Secret-like values detected in rendered service unit!${C_RESET}" >&2
    rm -f "${UNIT_DIR}/${SERVICE}" "${UNIT_DIR}/${TIMER}" 2>/dev/null || true
    exit 1
fi

if command -v systemd-analyze &>/dev/null; then
    if systemd-analyze --user verify "${UNIT_DIR}/${SERVICE}" "${UNIT_DIR}/${TIMER}" &>/dev/null; then
        :
    elif systemd-analyze verify "${UNIT_DIR}/${SERVICE}" "${UNIT_DIR}/${TIMER}" &>/dev/null; then
        :
    else
        echo -e "${C_RED}ERROR: Rendered systemd unit failed verification.${C_RESET}" >&2
        rm -f "${UNIT_DIR}/${SERVICE}" "${UNIT_DIR}/${TIMER}" 2>/dev/null || true
        exit 1
    fi
fi

# ---------------------------------------------------------------------
# DAEMON RELOAD AND ACTIVATE
# ---------------------------------------------------------------------
systemctl --user daemon-reload
systemctl --user enable --now "${TIMER}"

IS_ENABLED="$(systemctl --user is-enabled "${TIMER}" 2>/dev/null || echo "no")"
IS_ACTIVE="$(systemctl --user is-active "${TIMER}" 2>/dev/null || echo "no")"

echo ""
echo -e "${C_BOLD}=== Systemd Timer Status ===${C_RESET}"
echo -e "Timer enabled : ${C_GREEN}${IS_ENABLED}${C_RESET}"
echo -e "Timer active  : ${C_GREEN}${IS_ACTIVE}${C_RESET}"

if [ "${IS_ENABLED}" = "enabled" ] && [ "${IS_ACTIVE}" = "active" ]; then
    echo "Next trigger  :"
    systemctl --user list-timers "${TIMER}" --no-pager || true
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
