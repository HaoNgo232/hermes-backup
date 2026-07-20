#!/usr/bin/env bash
# =====================================================================
# setup.sh - Hermes Backup Setup & Onboarding Assistant
# =====================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/rclone.sh"
source "${SCRIPT_DIR}/lib/encryption.sh"

RUN_TEST=false
if [ "${#}" -gt 0 ]; then
    if [ "${1}" = "--test" ] || [ "${1}" = "-t" ]; then
        RUN_TEST=true
    else
        echo -e "${C_RED}ERROR: Unknown option '${1}'${C_RESET}" >&2
        echo "Usage:" >&2
        echo "  ./setup.sh         Run standard environment setup & timer installation" >&2
        echo "  ./setup.sh --test  Run setup & execute a live end-to-end backup test" >&2
        exit 1
    fi
fi

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${BADGE_ERR} ${C_RED}Refusing to run as root. Run as regular user.${C_RESET}" >&2
    exit 1
fi

state_load

INPUT_REMOTE="${BACKUP_REMOTE:-gdrive-hermes:}"
parsed_input="$(rclone_parse_remote_and_path "${INPUT_REMOTE}")"
BASE_REMOTE_ONLY="${parsed_input%%|*}"
INPUT_PATH="${parsed_input#*|}"

if [ -z "${BASE_REMOTE_ONLY}" ]; then
    BASE_REMOTE_ONLY="gdrive-hermes:"
fi

# Detect existing state base remote and prevent silent mutation
EXISTING_BASE="$(state_get "BASE_REMOTE" "")"
if [ -n "${EXISTING_BASE}" ] && [ -f "${APP_STATE_FILE}" ]; then
    local_exist_norm="${EXISTING_BASE%%:*}"
    input_norm="${BASE_REMOTE_ONLY%%:*}"
    if [ "${local_exist_norm}" != "${input_norm}" ]; then
        echo -e "${BADGE_ERR} ${C_RED}[ERR] Base remote in state.env is '${EXISTING_BASE}', but BACKUP_REMOTE is '${BASE_REMOTE_ONLY}'.${C_RESET}" >&2
        echo -e "${C_RED}[ERR] Silent mutation prohibited: changing base remote requires manual repair or future maintenance command.${C_RESET}" >&2
        exit 1
    fi
fi

BASE_PATH_ONLY="$(state_get "BASE_PATH" "")"
if [ -z "${BASE_PATH_ONLY}" ]; then
    BASE_PATH_ONLY="${INPUT_PATH}"
    [ -z "${BASE_PATH_ONLY}" ] && BASE_PATH_ONLY="HermesBackups"
fi

TOTAL_STEPS="5"
if [ "${RUN_TEST}" = true ]; then
    TOTAL_STEPS="6"
fi

echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}                    HERMES BACKUP SETUP                              ${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"

# ---------------------------------------------------------------------
# [1/5] CHECK REQUIRED TOOLS
# ---------------------------------------------------------------------
echo -e "${C_BOLD}[1/${TOTAL_STEPS}] Checking required tools...${C_RESET}"

MISSING=0
check_cmd rclone || MISSING=1
check_cmd systemctl || MISSING=1
check_cmd unzip || MISSING=1
check_cmd zip || MISSING=1
check_cmd tar || MISSING=1
check_cmd xz || MISSING=1
check_cmd flock || MISSING=1

HERMES_RESOLVED=""
if [ -n "${HERMES_BIN:-}" ] && [ -x "${HERMES_BIN}" ]; then
    HERMES_RESOLVED="${HERMES_BIN}"
elif command -v hermes &>/dev/null; then
    HERMES_RESOLVED="$(command -v hermes)"
fi

if [ -n "${HERMES_RESOLVED}" ]; then
    echo -e "  ${BADGE_OK} Hermes binary -> ${HERMES_RESOLVED}"
else
    echo -e "  ${BADGE_ERR} ${C_RED}'hermes' binary not found. Add it to PATH or set HERMES_BIN=/path/to/hermes${C_RESET}" >&2
    MISSING=1
fi

if [ "${MISSING}" -ne 0 ]; then
    echo "" >&2
    echo -e "${C_RED}${C_BOLD}ERROR: Missing required dependencies. Please install missing tools and try again.${C_RESET}" >&2
    echo "On Debian/Ubuntu: sudo apt update && sudo apt install -y rclone unzip zip xz-utils util-linux" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# [2/5] CHECK BACKUP REMOTE CONNECTIVITY
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[2/${TOTAL_STEPS}] Checking base cloud remote connectivity...${C_RESET}"

REMOTE_NAME="${BASE_REMOTE_ONLY%%:*}"
if ! rclone_has_remote "${REMOTE_NAME}"; then
    echo "" >&2
    echo -e "${C_RED}${C_BOLD}ERROR: rclone remote '${REMOTE_NAME}:' is not configured.${C_RESET}" >&2
    echo "" >&2
    echo "Please configure rclone by running:" >&2
    echo -e "  ${C_CYAN}rclone config${C_RESET}" >&2
    echo "Create a remote named '${REMOTE_NAME}' and re-run setup." >&2
    exit 1
fi
echo -e "  ${BADGE_OK} rclone base remote '${REMOTE_NAME}:' is configured."

probe_res="$(rclone_check_reachability "${BASE_REMOTE_ONLY}" "${BASE_PATH_ONLY}")"
if [ $? -ne 0 ]; then
    exit 1
fi
echo -e "  ${BADGE_OK} Base remote '${REMOTE_NAME}:' is reachable."

# ---------------------------------------------------------------------
# [3/5] OPTIONAL CLIENT-SIDE ENCRYPTION SETUP
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[3/${TOTAL_STEPS}] Configuring client-side encryption...${C_RESET}"

if encryption_is_enabled; then
    CRYPT_REMOTE_CUR="$(state_get "CRYPT_REMOTE")"
    EXPECTED_BASE="${BASE_REMOTE_ONLY%/:}/${BASE_PATH_ONLY}"
    if encryption_validate_crypt_remote "${CRYPT_REMOTE_CUR}" "${EXPECTED_BASE}"; then
        echo -e "  ${BADGE_OK} Client-side encryption is already configured."
        echo -e "  ${BADGE_OK} Existing crypt remote '${CRYPT_REMOTE_CUR}' was retained."
        echo -e "  ${BADGE_OK} No recovery password or salt was regenerated."
        echo -e "  ${BADGE_OK} Recovery reminder state: $(state_get "RECOVERY_NOTICE_STATE" "shown")"
    else
        echo -e "  ${BADGE_ERR} ${C_RED}Encryption state is enabled, but configured crypt remote '${CRYPT_REMOTE_CUR}' is invalid or missing.${C_RESET}" >&2
        echo "Please repair the rclone configuration or recreate '${CRYPT_REMOTE_CUR}' using your saved recovery material." >&2
        exit 1
    fi
else
    ENABLE_ENC="n"
    if is_interactive_tty; then
        read -p "Enable client-side encryption for cloud backups? [y/N]: " -r ENABLE_ENC_INPUT || ENABLE_ENC_INPUT="n"
        ENABLE_ENC="$(echo "${ENABLE_ENC_INPUT}" | tr '[:upper:]' '[:lower:]')"
    fi

    if [[ "${ENABLE_ENC}" == "y" || "${ENABLE_ENC}" == "yes" ]]; then
        if ! is_interactive_tty; then
            echo -e "${BADGE_ERR} ${C_RED}Encrypted setup must be run interactively attached to a TTY.${C_RESET}" >&2
            exit 1
        fi

        echo -e "  ${C_CYAN}Setting up rclone crypt remote...${C_RESET}"
        if encryption_create_crypt_remote "${BASE_REMOTE_ONLY}"; then
            if [ -z "${GEN_CRYPT_PASSWORD:-}" ] || [ -z "${GEN_CRYPT_SALT:-}" ]; then
                log_error "Crypt remote provisioned but recovery secrets were not generated."
                exit 1
            fi

            if encryption_display_recovery_screen_and_confirm "${GEN_CRYPT_PASSWORD}" "${GEN_CRYPT_SALT}"; then
                state_set_many \
                    "ENCRYPTION_ENABLED" "true" \
                    "ENCRYPTION_MODE" "rclone-crypt" \
                    "BASE_REMOTE" "${BASE_REMOTE_ONLY}" \
                    "BASE_PATH" "${GEN_BASE_PATH}" \
                    "CRYPT_REMOTE" "${GEN_CRYPT_REMOTE}" \
                    "CRYPT_PATH" "" \
                    "RECOVERY_NOTICE_STATE" "pending" \
                    "ENCRYPTION_SETUP_COMPLETED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

                echo -e "  ${BADGE_OK} Client-side encryption configured successfully."
            else
                echo -e "${BADGE_ERR} ${C_RED}Encryption recovery material confirmation failed. Setup aborted.${C_RESET}" >&2
                exit 1
            fi
        else
            echo -e "${BADGE_ERR} ${C_RED}Failed to create crypt remote.${C_RESET}" >&2
            exit 1
        fi
    else
        echo -e "  ${BADGE_OK} Client-side encryption: DISABLED (Plaintext cloud backup mode)"
        state_set_many \
            "ENCRYPTION_ENABLED" "false" \
            "ENCRYPTION_MODE" "none" \
            "BASE_REMOTE" "${BASE_REMOTE_ONLY}" \
            "BASE_PATH" "${BASE_PATH_ONLY}" \
            "CRYPT_REMOTE" "" \
            "CRYPT_PATH" "" \
            "RECOVERY_NOTICE_STATE" "shown"
    fi
fi

# ---------------------------------------------------------------------
# [4/5] INSTALL AUTOMATIC BACKUP TIMER
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[4/${TOTAL_STEPS}] Installing automatic backup timer...${C_RESET}"
if [ -x "${SCRIPT_DIR}/install-systemd.sh" ]; then
    "${SCRIPT_DIR}/install-systemd.sh"
else
    echo -e "${BADGE_ERR} ${C_RED}'${SCRIPT_DIR}/install-systemd.sh' not found or not executable.${C_RESET}" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# [5/5] CHECK SYSTEM HEALTH STATUS
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[5/${TOTAL_STEPS}] Running system health status check...${C_RESET}"
if [ -x "${SCRIPT_DIR}/status.sh" ]; then
    if ! "${SCRIPT_DIR}/status.sh"; then
        echo "" >&2
        echo -e "${C_RED}${C_BOLD}SETUP FAILED: System status health check reported action required.${C_RESET}" >&2
        exit 1
    fi
else
    echo -e "${BADGE_WARN} '${SCRIPT_DIR}/status.sh' not found or not executable."
fi

# ---------------------------------------------------------------------
# [6/6] END-TO-END TEST (ONLY IF --test SPECIFIED)
# ---------------------------------------------------------------------
if [ "${RUN_TEST}" = true ]; then
    echo ""
    echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
    echo -e "${C_BOLD}[6/6] Running Live End-to-End Backup Test...${C_RESET}"
    if [ -x "${SCRIPT_DIR}/backup.sh" ]; then
        "${SCRIPT_DIR}/backup.sh"
    fi
fi

echo ""
echo -e "${C_GREEN}${C_BOLD}SETUP COMPLETE SUCCESSFUL!${C_RESET}"
