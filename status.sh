#!/usr/bin/env bash
# =====================================================================
# status.sh - Hermes Backup Diagnostic & Status Tool
# ---------------------------------------------------------------------
# Read-only health check for Hermes backup installation, systemd timer,
# remote connectivity, and latest backup state.
# Exits with 0 when system is HEALTHY, exits with 1 when ACTION REQUIRED.
# Supports --check for minimal automated output.
# =====================================================================
set -Eeuo pipefail

if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_RED="\033[0;31m"
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[0;33m"
    C_CYAN="\033[0;36m"
    FMT_OK="\033[0;32m[ OK ]\033[0m"
    FMT_ERR="\033[0;31m[ FAIL ]\033[0m"
    FMT_WARN="\033[0;33m[ WARN ]\033[0m"
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    FMT_OK="[ OK ]"
    FMT_ERR="[ FAIL ]"
    FMT_WARN="[ WARN ]"
fi

CHECK_ONLY=false
if [ "${1:-}" = "--check" ] || [ "${1:-}" = "-c" ]; then
    CHECK_ONLY=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

case "${REMOTE}" in
    *:) ;;
    */) ;;
    *) REMOTE="${REMOTE}/" ;;
esac

# ---------------------------------------------------------------------
# RAW DATA COLLECTION & HEALTH EVALUATION
# ---------------------------------------------------------------------
HERMES_RESOLVED=""
if [ -n "${HERMES_BIN:-}" ] && [ -x "${HERMES_BIN}" ]; then
    HERMES_RESOLVED="${HERMES_BIN}"
elif command -v hermes &>/dev/null; then
    HERMES_RESOLVED="$(command -v hermes)"
fi

RCLONE_OK=false
REMOTE_REACHABLE_TEXT="no"
IS_REACHABLE_RAW=false
if command -v rclone &>/dev/null; then
    RCLONE_OK=true
    if rclone lsf "${REMOTE}" --max-depth 0 &>/dev/null; then
        REMOTE_REACHABLE_TEXT="${FMT_OK} yes"
        IS_REACHABLE_RAW=true
    elif rclone listremotes 2>/dev/null | grep -q "^${REMOTE%%:*}:"; then
        REMOTE_REACHABLE_TEXT="${FMT_OK} yes (remote exists, target folder will be created on upload)"
        IS_REACHABLE_RAW=true
    else
        REMOTE_REACHABLE_TEXT="${FMT_ERR} no (remote '${REMOTE%%:*}' not configured in rclone)"
    fi
else
    REMOTE_REACHABLE_TEXT="${FMT_ERR} no (rclone command missing)"
fi

# Pre-fetch latest backup if remote reachable
LATEST_BACKUP=""
if [ "${IS_REACHABLE_RAW}" = true ] && [ "${RCLONE_OK}" = true ]; then
    LATEST_BACKUP="$(rclone lsf "${REMOTE}" --format "tps" --files-only 2>/dev/null | grep -E ';hermes-backup-.*\.(tar\.xz|zip);' | sort | tail -n1 || true)"
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
   [ "${SYSTEMD_OK}" = false ] || [ "${UNITS_EXIST}" = false ] || [ "${TIMER_ENABLED_RAW}" = false ] || [ "${TIMER_ACTIVE_RAW}" = false ]; then
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

# 1. Environment & Paths
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

echo "  Backup Remote    : ${REMOTE}"
echo -e "  Remote Reachable : ${REMOTE_REACHABLE_TEXT}"

# 2. Systemd Timer & Service Status
echo ""
echo -e "${C_BOLD}[2] Systemd Timer & Service Status:${C_RESET}"

if [ "${UNITS_EXIST}" = true ]; then
    echo -e "  Unit Files       : ${FMT_OK} Installed (${SERVICE_UNIT})"
else
    echo -e "  Unit Files       : ${FMT_WARN} NOT INSTALLED"
fi

if [ "${SYSTEMD_OK}" = true ]; then
    if [ "${TIMER_ENABLED_RAW}" = true ]; then
        echo -e "  Timer Enabled    : ${FMT_OK} enabled"
    else
        echo -e "  Timer Enabled    : ${FMT_WARN} ${TIMER_ENABLED_TEXT}"
    fi

    if [ "${TIMER_ACTIVE_RAW}" = true ]; then
        echo -e "  Timer Active     : ${FMT_OK} active"
    else
        echo -e "  Timer Active     : ${FMT_WARN} ${TIMER_ACTIVE_TEXT}"
    fi

    if [ "${TIMER_ENABLED_RAW}" = true ]; then
        echo ""
        echo -e "  ${C_BOLD}Next Scheduled Runs:${C_RESET}"
        systemctl --user list-timers hermes-cloud-backup.timer --no-pager 2>/dev/null | sed 's/^/    /' || true
    fi

    if [ "${SERVICE_STATUS_TEXT}" = "failed" ]; then
        echo -e "  Last Service Run : ${FMT_ERR} FAILED"
    elif [ "${SERVICE_STATUS_TEXT}" = "active" ]; then
        echo -e "  Last Service Run : ${C_CYAN}RUNNING${C_RESET}"
    else
        echo -e "  Last Service Run : ${FMT_OK} OK / Idle"
    fi
else
    echo -e "  Systemctl        : Systemd user session not available"
fi

# 3. User Linger Status
echo ""
echo -e "${C_BOLD}[3] User Linger Status:${C_RESET}"
LINGER_STATUS="unknown"
if command -v loginctl &>/dev/null; then
    if loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
        LINGER_STATUS="${FMT_OK} enabled"
    elif [ -f "/var/lib/systemd/linger/$USER" ]; then
        LINGER_STATUS="${FMT_OK} enabled"
    else
        LINGER_STATUS="${FMT_WARN} disabled"
    fi
fi
echo -e "  Linger Enabled   : ${LINGER_STATUS}"
if [[ "${LINGER_STATUS}" == *disabled* ]]; then
    echo -e "  ${C_YELLOW}(Note: Enable linger to allow timer execution after logout/reboot: 'sudo loginctl enable-linger $USER')${C_RESET}"
fi

# 4. Latest Backup on Remote
echo ""
echo -e "${C_BOLD}[4] Latest Backup on Remote:${C_RESET}"
if [ -n "${LATEST_BACKUP}" ]; then
    IFS=';' read -r b_time b_name b_size <<< "${LATEST_BACKUP}"
    echo "  Filename         : ${b_name}"
    echo "  Timestamp        : ${b_time}"
    echo "  Size             : ${b_size} bytes"
elif [ "${IS_REACHABLE_RAW}" = true ]; then
    echo "  No backups found on remote '${REMOTE}'."
else
    echo "  Cannot query remote backups (remote not reachable)."
fi

# 5. Summary & Recommended Actions
echo ""
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
if [ "${HEALTH_OK}" = true ]; then
    echo -e "${C_GREEN}${C_BOLD}OVERALL STATUS: HEALTHY${C_RESET}"
    echo "Automatic backups are configured and the Google Drive remote is reachable."
else
    echo -e "${C_RED}${C_BOLD}OVERALL STATUS: ACTION REQUIRED${C_RESET}"
    echo "Automatic backups may fail until the issues listed below are resolved."
fi
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"

if [ -z "${HERMES_RESOLVED}" ]; then
    echo -e "${C_RED}* Install Hermes or add it to PATH / set HERMES_BIN=/path/to/hermes${C_RESET}"
fi

if [ "${IS_REACHABLE_RAW}" = false ]; then
    echo -e "${C_RED}* Configure rclone remote by running: rclone config${C_RESET}"
fi

if [ "${UNITS_EXIST}" = false ] || [ "${TIMER_ENABLED_RAW}" = false ]; then
    echo -e "${C_YELLOW}* Install and enable systemd timer by running: ./setup.sh${C_RESET}"
fi

echo ""
echo "Useful Commands for Troubleshooting:"
echo -e "  Manual backup run  : ${C_CYAN}./backup.sh${C_RESET}"
echo -e "  Test systemd service: ${C_CYAN}systemctl --user start hermes-cloud-backup.service${C_RESET}"
echo -e "  View service logs  : ${C_CYAN}journalctl --user -u hermes-cloud-backup.service -n 100 --no-pager${C_RESET}"
echo -e "  Uninstall timer    : ${C_CYAN}./uninstall.sh${C_RESET}"
echo -e "  Check timer list   : ${C_CYAN}systemctl --user list-timers hermes-cloud-backup.timer${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"

if [ "${HEALTH_OK}" = true ]; then
    exit 0
else
    exit 1
fi
