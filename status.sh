#!/usr/bin/env bash
# =====================================================================
# status.sh - Hermes Backup Diagnostic & Status Tool
# =====================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/hermes.sh"
source "${SCRIPT_DIR}/lib/rclone.sh"
source "${SCRIPT_DIR}/lib/encryption.sh"

CHECK_ONLY=false
if [ "${1:-}" = "--check" ] || [ "${1:-}" = "-c" ]; then
    CHECK_ONLY=true
fi

HEALTH_OK=true

if [ "${CHECK_ONLY}" = false ]; then
    echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}                  HERMES BACKUP SYSTEM STATUS                        ${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
    echo -e "${C_CYAN}ℹ Checking system status & remote connectivity...${C_RESET}\n"
fi

# ---------------------------------------------------------------------
# STAGE 1: ENVIRONMENT & CONFIGURATION
# ---------------------------------------------------------------------
hermes_apply_persisted_environment

HERMES_RESOLVED=""
if resolved_bin="$(hermes_resolve_binary 2>/dev/null)"; then
    HERMES_RESOLVED="${resolved_bin}"
else
    HEALTH_OK=false
fi

if [ "${CHECK_ONLY}" = false ]; then
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
    echo ""
fi

# ---------------------------------------------------------------------
# STAGE 2: ENCRYPTION STATUS & CLOUD CONNECTIVITY
# ---------------------------------------------------------------------
RCLONE_OK=false
REMOTE_REACHABLE_TEXT="no"
IS_REACHABLE_RAW=false
ENCRYPTION_STATUS_OK=true
ENC_MODE_TEXT="DISABLED"
ENC_REASON_TEXT=""
ACTIVE_ENDPOINT=""

if command -v rclone &>/dev/null; then
    RCLONE_OK=true
    if encryption_is_enabled; then
        CRYPT_REMOTE_CUR="$(state_get "CRYPT_REMOTE")"
        BASE_REMOTE_CUR="$(state_get "BASE_REMOTE")"
        BASE_PATH_CUR="$(state_get "BASE_PATH" "HermesBackupsEncrypted")"
        EXPECTED_BASE="$(rclone_normalize_base_endpoint "${BASE_REMOTE_CUR}" "${BASE_PATH_CUR}")"

        if encryption_validate_crypt_remote "${CRYPT_REMOTE_CUR}" "${EXPECTED_BASE}"; then
            ENC_MODE_TEXT="ENABLED"
            ACTIVE_REMOTE="${CRYPT_REMOTE_CUR}"
            ACTIVE_PATH="$(state_get "CRYPT_PATH" "")"
        else
            ENC_MODE_TEXT="ERROR"
            ENCRYPTION_STATUS_OK=false
            HEALTH_OK=false
            ENC_REASON_TEXT="configured crypt remote '${CRYPT_REMOTE_CUR}' is unavailable, invalid, or inconsistent."
            ACTIVE_REMOTE="${CRYPT_REMOTE_CUR}"
            ACTIVE_PATH=""
        fi
    else
        ENC_MODE_TEXT="DISABLED"
        BASE_REMOTE_CUR="$(state_get "BASE_REMOTE" "${BACKUP_REMOTE:-gdrive-hermes:}")"
        BASE_PATH_CUR="$(state_get "BASE_PATH" "HermesBackups")"
        ACTIVE_REMOTE="${BASE_REMOTE_CUR}"
        ACTIVE_PATH="${BASE_PATH_CUR}"
    fi

    ACTIVE_ENDPOINT="$(rclone_compose_endpoint "${ACTIVE_REMOTE}" "${ACTIVE_PATH}")"

    if [ "${ENCRYPTION_STATUS_OK}" = true ]; then
        reach_status="$(rclone_check_reachability "${ACTIVE_REMOTE}" "${ACTIVE_PATH}" 2>/dev/null || echo "FAILED")"
        if [ "${reach_status}" = "EXISTS" ]; then
            REMOTE_REACHABLE_TEXT="${BADGE_OK} yes"
            IS_REACHABLE_RAW=true
        elif [ "${reach_status}" = "CREATED_ON_UPLOAD" ]; then
            REMOTE_REACHABLE_TEXT="${BADGE_OK} yes (remote reachable; target folder created on upload)"
            IS_REACHABLE_RAW=true
        else
            REMOTE_REACHABLE_TEXT="${BADGE_ERR} no (cannot connect to remote '${ACTIVE_REMOTE}')"
            IS_REACHABLE_RAW=false
            HEALTH_OK=false
        fi
    else
        REMOTE_REACHABLE_TEXT="${BADGE_ERR} no (${ENC_REASON_TEXT})"
        IS_REACHABLE_RAW=false
        HEALTH_OK=false
    fi
else
    RCLONE_OK=false
    HEALTH_OK=false
    REMOTE_REACHABLE_TEXT="${BADGE_ERR} no (rclone command missing)"
    IS_REACHABLE_RAW=false
    if encryption_is_enabled; then
        ENC_MODE_TEXT="ERROR"
        ENCRYPTION_STATUS_OK=false
        ENC_REASON_TEXT="rclone command is missing; crypt remote cannot be validated."
        ACTIVE_ENDPOINT="$(state_get "CRYPT_REMOTE")"
    else
        ENC_MODE_TEXT="DISABLED"
        ACTIVE_ENDPOINT="$(rclone_compose_endpoint "$(state_get "BASE_REMOTE" "gdrive-hermes:")" "$(state_get "BASE_PATH" "HermesBackups")")"
    fi
fi

if [ "${CHECK_ONLY}" = false ]; then
    echo -e "${C_BOLD}[2] Encryption Status:${C_RESET}"
    if [ "${ENC_MODE_TEXT}" = "ENABLED" ]; then
        echo "  Encryption Mode  : ENABLED"
        echo "  Backend          : rclone crypt"
        echo "  Crypt Remote     : ${ACTIVE_ENDPOINT}"
        echo "  Data Security    : Client-side encrypted content & filenames"
        echo "  Recovery Notice  : $(state_get "RECOVERY_NOTICE_STATE" "shown")"
    elif [ "${ENC_MODE_TEXT}" = "DISABLED" ]; then
        echo "  Encryption Mode  : DISABLED"
        echo "  Cloud Destination: ${ACTIVE_ENDPOINT}"
    else
        echo -e "  Encryption Mode  : ${C_RED}ERROR${C_RESET}"
        echo -e "  Reason           : ${C_RED}${ENC_REASON_TEXT}${C_RESET}"
        echo "  Action           : Restore rclone configuration or repair crypt remote with saved recovery material."
    fi
    echo -e "  Remote Reachable : ${REMOTE_REACHABLE_TEXT}"
    echo ""
fi

# ---------------------------------------------------------------------
# STAGE 3: SYSTEMD TIMER & SERVICE STATUS
# ---------------------------------------------------------------------
SERVICE_UNIT="${HOME}/.config/systemd/user/hermes-cloud-backup.service"
TIMER_UNIT="${HOME}/.config/systemd/user/hermes-cloud-backup.timer"

UNITS_EXIST=false
if [ -f "${SERVICE_UNIT}" ] && [ -f "${TIMER_UNIT}" ]; then
    UNITS_EXIST=true
else
    HEALTH_OK=false
fi

SYSTEMD_OK=false
TIMER_ENABLED_RAW=false
TIMER_ACTIVE_RAW=false
TIMER_ENABLED_TEXT="not-installed"
TIMER_ACTIVE_TEXT="inactive"

if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null; then
    SYSTEMD_OK=true
    TIMER_ENABLED_TEXT="$(systemctl --user is-enabled hermes-cloud-backup.timer 2>/dev/null || echo "not-installed")"
    TIMER_ACTIVE_TEXT="$(systemctl --user is-active hermes-cloud-backup.timer 2>/dev/null || echo "inactive")"

    [ "${TIMER_ENABLED_TEXT}" = "enabled" ] && TIMER_ENABLED_RAW=true
    [ "${TIMER_ACTIVE_TEXT}" = "active" ] && TIMER_ACTIVE_RAW=true
else
    HEALTH_OK=false
fi

if [ "${TIMER_ENABLED_RAW}" = false ] || [ "${TIMER_ACTIVE_RAW}" = false ]; then
    HEALTH_OK=false
fi

if [ "${CHECK_ONLY}" = false ]; then
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
        if [ "${LINGER_STATUS}" = "enabled" ]; then
            echo -e "  User Linger      : ${BADGE_OK} enabled"
        elif [ "${LINGER_STATUS}" = "disabled" ]; then
            echo -e "  User Linger      : ${BADGE_WARN} disabled (timer will not run after logout)"
        fi
    fi
    echo ""
fi

# ---------------------------------------------------------------------
# STAGE 4: LATEST CLOUD BACKUP
# ---------------------------------------------------------------------
LATEST_BACKUP=""
LATEST_LIST_OK=true
if [ "${IS_REACHABLE_RAW}" = true ] && [ "${RCLONE_OK}" = true ] && [ "${ENCRYPTION_STATUS_OK}" = true ]; then
    if latest_list="$(rclone_list_backups "${ACTIVE_ENDPOINT}")"; then
        LATEST_BACKUP="$(echo "${latest_list}" | tail -n1 || true)"
    else
        LATEST_LIST_OK=false
        HEALTH_OK=false
    fi
else
    HEALTH_OK=false
fi

if [ "${CHECK_ONLY}" = true ]; then
    if [ "${HEALTH_OK}" = true ]; then
        echo -e "${C_GREEN}${C_BOLD}OVERALL STATUS: HEALTHY${C_RESET}"
        exit 0
    else
        echo -e "${C_RED}${C_BOLD}OVERALL STATUS: ACTION REQUIRED${C_RESET}"
        exit 1
    fi
fi

echo -e "${C_BOLD}[4] Latest Cloud Backup:${C_RESET}"
if [ -n "${LATEST_BACKUP}" ]; then
    IFS=';' read -r b_time b_file b_size <<< "${LATEST_BACKUP}"
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
