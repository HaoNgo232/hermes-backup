#!/usr/bin/env bash
# =====================================================================
# status.sh - Hermes Backup Diagnostic & Status Tool
# =====================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/rclone.sh"
source "${SCRIPT_DIR}/lib/encryption.sh"

CHECK_ONLY=false
if [ "${1:-}" = "--check" ] || [ "${1:-}" = "-c" ]; then
    CHECK_ONLY=true
fi

state_load

HERMES_RESOLVED=""
if [ -n "${HERMES_BIN:-}" ] && [ -x "${HERMES_BIN}" ]; then
    HERMES_RESOLVED="${HERMES_BIN}"
elif command -v hermes &>/dev/null; then
    HERMES_RESOLVED="$(command -v hermes)"
fi

RCLONE_OK=false
REMOTE_REACHABLE_TEXT="no"
IS_REACHABLE_RAW=false

# Evaluate Encryption State & Destination
ENCRYPTION_STATUS_OK=true
ENC_MODE_TEXT="DISABLED"
ENC_REASON_TEXT=""

if encryption_is_enabled; then
    CRYPT_REMOTE_CUR="$(state_get "CRYPT_REMOTE")"
    if encryption_validate_crypt_remote "${CRYPT_REMOTE_CUR}"; then
        ENC_MODE_TEXT="ENABLED"
        ACTIVE_DEST="${CRYPT_REMOTE_CUR}"
    else
        ENC_MODE_TEXT="ERROR"
        ENCRYPTION_STATUS_OK=false
        ENC_REASON_TEXT="configured crypt remote '${CRYPT_REMOTE_CUR}' is unavailable, invalid, or inconsistent."
        ACTIVE_DEST="${CRYPT_REMOTE_CUR}"
    fi
else
    ENC_MODE_TEXT="DISABLED"
    BASE_REMOTE_CUR="$(state_get "BASE_REMOTE" "${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}")"
    ACTIVE_DEST="$(rclone_normalize_remote "${BASE_REMOTE_CUR}")"
fi

if command -v rclone &>/dev/null; then
    RCLONE_OK=true
    if [ "${ENCRYPTION_STATUS_OK}" = true ]; then
        if rclone_check_path_reachable "${ACTIVE_DEST}"; then
            REMOTE_REACHABLE_TEXT="${BADGE_OK} yes"
            IS_REACHABLE_RAW=true
        else
            REMOTE_REACHABLE_TEXT="${BADGE_OK} yes (reachable; target folder created on upload)"
            IS_REACHABLE_RAW=true
        fi
    else
        REMOTE_REACHABLE_TEXT="${BADGE_ERR} no (${ENC_REASON_TEXT})"
        IS_REACHABLE_RAW=false
    fi
else
    REMOTE_REACHABLE_TEXT="${BADGE_ERR} no (rclone command missing)"
    IS_REACHABLE_RAW=false
fi

# Pre-fetch latest backup if reachable
LATEST_BACKUP=""
if [ "${IS_REACHABLE_RAW}" = true ] && [ "${RCLONE_OK}" = true ] && [ "${ENCRYPTION_STATUS_OK}" = true ]; then
    LATEST_BACKUP="$(rclone_list_backups "${ACTIVE_DEST}" | tail -n1 || true)"
fi

# Systemd timer checks
SERVICE_UNIT="${HOME}/.config/systemd/user/hermes-cloud-backup.service"
TIMER_UNIT="${HOME}/.config/systemd/user/hermes-cloud-backup.timer"

UNITS_EXIST=false
if [ -f "${SERVICE_UNIT}" ] && [ -f "${TIMER_UNIT}" ]; then
    UNITS_EXIST=true
fi

SYSTEMD_OK=false
TIMER_ENABLED_RAW=false
TIMER_ACTIVE_RAW=false
TIMER_ENABLED_TEXT="not-installed"
TIMER_ACTIVE_TEXT="inactive"
SERVICE_STATUS_TEXT="unknown"

if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null; then
    SYSTEMD_OK=true
    TIMER_ENABLED_TEXT="$(systemctl --user is-enabled hermes-cloud-backup.timer 2>/dev/null || echo "not-installed")"
    TIMER_ACTIVE_TEXT="$(systemctl --user is-active hermes-cloud-backup.timer 2>/dev/null || echo "inactive")"

    [ "${TIMER_ENABLED_TEXT}" = "enabled" ] && TIMER_ENABLED_RAW=true
    [ "${TIMER_ACTIVE_TEXT}" = "active" ] && TIMER_ACTIVE_RAW=true

    SERVICE_STATUS_TEXT="$(systemctl --user is-failed hermes-cloud-backup.service 2>/dev/null || echo "unknown")"
fi

# Overall Health Evaluation
HEALTH_OK=true
if [ -z "${HERMES_RESOLVED}" ] || [ "${RCLONE_OK}" = false ] || [ "${IS_REACHABLE_RAW}" = false ] || \
   [ "${ENCRYPTION_STATUS_OK}" = false ] || [ "${SYSTEMD_OK}" = false ] || [ "${UNITS_EXIST}" = false ] || \
   [ "${TIMER_ENABLED_RAW}" = false ] || [ "${TIMER_ACTIVE_RAW}" = false ]; then
    HEALTH_OK=false
fi

# ---------------------------------------------------------------------
# OUTPUT FOR --check MODE
# ---------------------------------------------------------------------
if [ "${CHECK_ONLY}" = true ]; then
    if [ "${HEALTH_OK}" = true ]; then
        echo -e "${C_GREEN}${C_BOLD}OVERALL STATUS: HEALTHY${C_RESET}"
        exit 0
    else
        echo -e "${C_RED}${C_BOLD}OVERALL STATUS: ACTION REQUIRED${C_RESET}"
        exit 1
    fi
fi

# ---------------------------------------------------------------------
# FULL RENDER OUTPUT
# ---------------------------------------------------------------------
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}                  HERMES BACKUP SYSTEM STATUS                        ${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
echo -e "${C_CYAN}ℹ Checking system status & remote connectivity...${C_RESET}\n"

# 1. Environment & Config
echo -e "${C_BOLD}[1] Environment & Configuration:${C_RESET}"
echo "  Repository Path  : ${SCRIPT_DIR}"
echo "  Backup Script    : ${SCRIPT_DIR}/backup.sh"
echo "  Restore Script   : ${SCRIPT_DIR}/restore.sh"

if [ -n "${HERMES_RESOLVED}" ]; then
    HERMES_VER="$("${HERMES_RESOLVED}" --version 2>/dev/null || echo "version unknown")"
    echo -e "  Hermes Binary    : ${HERMES_RESOLVED} (${HERMES_VER})"
else
    echo -e "  Hermes Binary    : ${C_RED}NOT FOUND (hermes command not in PATH)${C_RESET}"
fi

# 2. Encryption Status Report
echo ""
echo -e "${C_BOLD}[2] Encryption Status:${C_RESET}"
if [ "${ENC_MODE_TEXT}" = "ENABLED" ]; then
    echo "  Encryption Mode  : ENABLED"
    echo "  Backend          : rclone crypt"
    echo "  Crypt Remote     : ${ACTIVE_DEST}"
    echo "  Data Security    : Client-side encrypted content & filenames"
    echo "  Recovery Notice  : $(state_get "RECOVERY_NOTICE_STATE" "shown")"
elif [ "${ENC_MODE_TEXT}" = "DISABLED" ]; then
    echo "  Encryption Mode  : DISABLED"
    echo "  Cloud Destination: ${ACTIVE_DEST}"
else
    echo -e "  Encryption Mode  : ${C_RED}ERROR${C_RESET}"
    echo -e "  Reason           : ${C_RED}${ENC_REASON_TEXT}${C_RESET}"
    echo "  Action           : Restore rclone configuration or repair crypt remote with saved recovery material."
fi

echo -e "  Remote Reachable : ${REMOTE_REACHABLE_TEXT}"

# 3. Systemd Status
echo ""
echo -e "${C_BOLD}[3] Systemd Timer & Service Status:${C_RESET}"

if [ "${UNITS_EXIST}" = true ]; then
    echo -e "  Unit Files       : ${BADGE_OK} Installed (${SERVICE_UNIT})"
else
    echo -e "  Unit Files       : ${BADGE_WARN} NOT INSTALLED"
fi

if [ "${SYSTEMD_OK}" = true ]; then
    if [ "${TIMER_ENABLED_RAW}" = true ]; then
        echo -e "  Timer Enabled    : ${BADGE_OK} enabled"
    else
        echo -e "  Timer Enabled    : ${BADGE_WARN} ${TIMER_ENABLED_TEXT}"
    fi

    if [ "${TIMER_ACTIVE_RAW}" = true ]; then
        echo -e "  Timer Active     : ${BADGE_OK} active"
    else
        echo -e "  Timer Active     : ${BADGE_WARN} ${TIMER_ACTIVE_TEXT}"
    fi

    if [ "${TIMER_ENABLED_RAW}" = true ]; then
        echo ""
        echo -e "  ${C_BOLD}Next Scheduled Runs:${C_RESET}"
        systemctl --user list-timers hermes-cloud-backup.timer --no-pager 2>/dev/null | sed 's/^/    /' || true
    fi
fi

# 4. Latest Backup Status
echo ""
echo -e "${C_BOLD}[4] Latest Cloud Backup:${C_RESET}"
if [ -n "${LATEST_BACKUP}" ]; then
    b_time="$(echo "${LATEST_BACKUP}" | cut -d';' -f1)"
    b_file="$(echo "${LATEST_BACKUP}" | cut -d';' -f2)"
    b_size="$(echo "${LATEST_BACKUP}" | cut -d';' -f3)"
    echo "  Filename         : ${b_file}"
    echo "  Timestamp        : ${b_time}"
    echo "  Archive Size     : ${b_size} bytes"
else
    echo "  Filename         : None found"
fi

echo ""
if [ "${HEALTH_OK}" = true ]; then
    echo -e "${BADGE_OK} ${C_GREEN}${C_BOLD}Overall System Health: HEALTHY${C_RESET}"
    exit 0
else
    echo -e "${BADGE_ERR} ${C_RED}${C_BOLD}Overall System Health: ACTION REQUIRED${C_RESET}"
    exit 1
fi
