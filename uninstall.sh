#!/usr/bin/env bash
# =====================================================================
# uninstall.sh - Hermes Backup Uninstaller
# ---------------------------------------------------------------------
# Stops and disables systemd backup timers, removes installed unit files
# from ~/.config/systemd/user/, and reloads the systemd user daemon.
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
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    FMT_OK="[ OK ]"
    FMT_ERR="[ FAIL ]"
fi

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${FMT_ERR} ${C_RED}Refusing to run as root. Run as regular user.${C_RESET}" >&2
    exit 1
fi

UNIT_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${UNIT_DIR}/hermes-cloud-backup.service"
TIMER_FILE="${UNIT_DIR}/hermes-cloud-backup.timer"

echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}                 HERMES BACKUP UNINSTALLER                          ${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"

if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null; then
    echo -e "${C_BOLD}Stopping and disabling systemd timer...${C_RESET}"
    systemctl --user stop hermes-cloud-backup.timer 2>/dev/null || true
    systemctl --user disable hermes-cloud-backup.timer 2>/dev/null || true
fi

REMOVED=0
if [ -f "${SERVICE_FILE}" ]; then
    rm -f "${SERVICE_FILE}"
    echo -e "  ${FMT_OK} Removed service unit: ${SERVICE_FILE}"
    REMOVED=$((REMOVED + 1))
fi

if [ -f "${TIMER_FILE}" ]; then
    rm -f "${TIMER_FILE}"
    echo -e "  ${FMT_OK} Removed timer unit:   ${TIMER_FILE}"
    REMOVED=$((REMOVED + 1))
fi

if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null; then
    systemctl --user daemon-reload 2>/dev/null || true
fi

echo ""
if [ ${REMOVED} -gt 0 ]; then
    echo -e "${C_GREEN}${C_BOLD}✔ Systemd backup timer and service uninstalled successfully!${C_RESET}"
else
    echo -e "${C_YELLOW}No installed systemd units were found at ${UNIT_DIR}.${C_RESET}"
fi
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
