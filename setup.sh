#!/usr/bin/env bash
# =====================================================================
# setup.sh - Hermes Backup Setup & Onboarding Assistant
# ---------------------------------------------------------------------
# Non-destructive onboarding helper that validates system dependencies,
# verifies rclone remote configuration, installs systemd backup timers,
# and outputs system health status.
# =====================================================================
set -Eeuo pipefail

if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_RED="\033[0;31m"
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[0;33m"
    C_CYAN="\033[0;36m"
    BADGE_OK="\033[0;32m[ OK ]\033[0m"
    BADGE_ERR="\033[0;31m[ FAIL ]\033[0m"
    BADGE_WARN="\033[0;33m[ WARN ]\033[0m"
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    BADGE_OK="[ OK ]"
    BADGE_ERR="[ FAIL ]"
    BADGE_WARN="[ WARN ]"
fi

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${BADGE_ERR} ${C_RED}Refusing to run as root. Run as regular user.${C_RESET}" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}                    HERMES BACKUP SETUP                              ${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"

# ---------------------------------------------------------------------
# [1/4] CHECK REQUIRED TOOLS
# ---------------------------------------------------------------------
echo -e "${C_BOLD}[1/4] Checking required tools...${C_RESET}"

check_cmd() {
    local cmd="$1"
    if command -v "${cmd}" &>/dev/null; then
        echo -e "  ${BADGE_OK} ${cmd}"
    else
        echo -e "  ${BADGE_ERR} ${C_RED}Missing command '${cmd}'${C_RESET}" >&2
        return 1
    fi
}

MISSING=0
check_cmd rclone || MISSING=1
check_cmd systemctl || MISSING=1
check_cmd unzip || MISSING=1
check_cmd zip || MISSING=1
check_cmd tar || MISSING=1
check_cmd xz || MISSING=1
check_cmd flock || MISSING=1

# Hermes executable check
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
# [2/4] CHECK BACKUP REMOTE
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[2/4] Checking backup remote configuration...${C_RESET}"
REMOTE_NAME="${REMOTE%%:*}"

if [ -n "${REMOTE_NAME}" ] && [ "${REMOTE_NAME}" != "${REMOTE}" ]; then
    if rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
        echo -e "  ${BADGE_OK} rclone remote '${REMOTE_NAME}:' is configured."
    else
        echo "" >&2
        echo -e "${C_RED}${C_BOLD}ERROR: rclone remote '${REMOTE_NAME}:' is not configured.${C_RESET}" >&2
        echo "" >&2
        echo "Please configure rclone by running:" >&2
        echo -e "  ${C_CYAN}rclone config${C_RESET}" >&2
        echo "" >&2
        echo "Create a Google Drive remote named:" >&2
        echo -e "  ${C_CYAN}${REMOTE_NAME}${C_RESET}" >&2
        echo "" >&2
        echo "For detailed rclone config instructions, see README.md." >&2
        echo "After configuring rclone, re-run:" >&2
        echo -e "  ${C_CYAN}./setup.sh${C_RESET}" >&2
        exit 1
    fi
else
    echo -e "  ${BADGE_OK} Remote path specified directly: ${REMOTE}"
fi

# ---------------------------------------------------------------------
# [3/4] INSTALL AUTOMATIC BACKUP TIMER
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[3/4] Installing automatic backup timer...${C_RESET}"
if [ -x "${SRC_DIR}/install-systemd.sh" ]; then
    "${SRC_DIR}/install-systemd.sh"
else
    echo -e "${BADGE_ERR} ${C_RED}'${SRC_DIR}/install-systemd.sh' not found or not executable.${C_RESET}" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# [4/4] CHECK SYSTEM HEALTH
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[4/4] Running system health status check...${C_RESET}"
if [ -x "${SRC_DIR}/status.sh" ]; then
    "${SRC_DIR}/status.sh"
else
    echo -e "${BADGE_WARN} '${SRC_DIR}/status.sh' not found or not executable."
fi

echo ""
echo -e "${C_GREEN}${C_BOLD}=====================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}                        SETUP COMPLETE                               ${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}=====================================================================${C_RESET}"
echo "Automatic backup timer is installed and active."
echo ""
echo "Useful commands:"
echo -e "  Check system health:  ${C_CYAN}./status.sh${C_RESET}"
echo -e "  Run a backup now:     ${C_CYAN}./backup.sh${C_RESET}"
echo -e "  Restore latest:       ${C_CYAN}./restore.sh${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}=====================================================================${C_RESET}"
