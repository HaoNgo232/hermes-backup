#!/usr/bin/env bash
# =====================================================================
# setup.sh - Hermes Backup Setup & Onboarding Assistant
# ---------------------------------------------------------------------
# Onboarding helper that validates system dependencies, verifies rclone
# remote connectivity, installs systemd backup timers, and outputs system
# health status. Supports --test flag for end-to-end backup validation.
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

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

case "${REMOTE}" in
    *:) ;;
    */) ;;
    *) REMOTE="${REMOTE}/" ;;
esac

TOTAL_STEPS="4"
if [ "${RUN_TEST}" = true ]; then
    TOTAL_STEPS="5"
fi

echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}                    HERMES BACKUP SETUP                              ${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"

# ---------------------------------------------------------------------
# [1/4] CHECK REQUIRED TOOLS
# ---------------------------------------------------------------------
echo -e "${C_BOLD}[1/${TOTAL_STEPS}] Checking required tools...${C_RESET}"

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
# [2/4] CHECK BACKUP REMOTE CONNECTIVITY
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[2/${TOTAL_STEPS}] Checking backup remote connectivity...${C_RESET}"
REMOTE_NAME="${REMOTE%%:*}"

if [ -n "${REMOTE_NAME}" ] && [ "${REMOTE_NAME}" != "${REMOTE}" ]; then
    if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
        echo "" >&2
        echo -e "${C_RED}${C_BOLD}ERROR: rclone remote '${REMOTE_NAME}:' is not configured.${C_RESET}" >&2
        echo "" >&2
        echo "Please configure rclone by running:" >&2
        echo -e "  ${C_CYAN}rclone config${C_RESET}" >&2
        echo "Create a Google Drive remote named '${REMOTE_NAME}' and re-run setup." >&2
        exit 1
    fi
    echo -e "  ${BADGE_OK} rclone remote '${REMOTE_NAME}:' is configured."
fi

# Real connectivity test
lsf_output=""
if lsf_output="$(rclone lsf "${REMOTE}" --max-depth 0 2>&1)"; then
    echo -e "  ${BADGE_OK} Remote '${REMOTE}' is reachable and responding."
else
    echo "" >&2
    echo -e "${BADGE_ERR} ${C_RED}${C_BOLD}Cannot access rclone remote '${REMOTE}'.${C_RESET}" >&2
    echo "rclone output: ${lsf_output}" >&2
    echo "" >&2
    echo "Possible causes:" >&2
    echo "  - Google login/OAuth token has expired" >&2
    echo "  - Network or DNS is unavailable" >&2
    echo "  - Google Drive permission was revoked" >&2
    echo "" >&2
    echo "Try reconnecting with:" >&2
    echo -e "  ${C_CYAN}rclone config reconnect ${REMOTE_NAME}:${C_RESET}" >&2
    echo "Then re-run setup:" >&2
    echo -e "  ${C_CYAN}./setup.sh${C_RESET}" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# [3/4] INSTALL AUTOMATIC BACKUP TIMER
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[3/${TOTAL_STEPS}] Installing automatic backup timer...${C_RESET}"
if [ -x "${SRC_DIR}/install-systemd.sh" ]; then
    "${SRC_DIR}/install-systemd.sh"
else
    echo -e "${BADGE_ERR} ${C_RED}'${SRC_DIR}/install-systemd.sh' not found or not executable.${C_RESET}" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# [4/4] CHECK SYSTEM HEALTH STATUS
# ---------------------------------------------------------------------
echo ""
echo -e "${C_BOLD}[4/${TOTAL_STEPS}] Running system health status check...${C_RESET}"
if [ -x "${SRC_DIR}/status.sh" ]; then
    if ! "${SRC_DIR}/status.sh"; then
        echo "" >&2
        echo -e "${C_RED}${C_BOLD}SETUP FAILED: System status health check reported action required.${C_RESET}" >&2
        exit 1
    fi
else
    echo -e "${BADGE_WARN} '${SRC_DIR}/status.sh' not found or not executable."
fi

# ---------------------------------------------------------------------
# [5/5] END-TO-END TEST (ONLY IF --test SPECIFIED)
# ---------------------------------------------------------------------
if [ "${RUN_TEST}" = true ]; then
    echo ""
    echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
    echo -e "${C_BOLD}[5/5] Running Live End-to-End Backup Test...${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}=====================================================================${C_RESET}"
    
    TEST_START_EPOCH="$(date +%s)"
    echo -e "Starting systemd backup service..."
    systemctl --user start hermes-cloud-backup.service

    echo -e "Waiting for backup service completion..."
    # Poll until service is inactive
    for (( i=0; i<120; i++ )); do
        if [ "$(systemctl --user is-active hermes-cloud-backup.service 2>/dev/null)" != "active" ]; then
            break
        fi
        sleep 2
    done

    if [ "$(systemctl --user is-failed hermes-cloud-backup.service 2>/dev/null)" = "failed" ]; then
        echo "" >&2
        echo -e "${BADGE_ERR} ${C_RED}${C_BOLD}END-TO-END TEST FAILED: Systemd service execution failed.${C_RESET}" >&2
        echo "Check systemd journal logs:" >&2
        echo -e "  ${C_CYAN}journalctl --user -u hermes-cloud-backup.service -n 100 --no-pager${C_RESET}" >&2
        exit 1
    fi

    # Query latest backup on remote
    echo -e "Verifying new backup archive on remote Google Drive..."
    LATEST="$(rclone lsf "${REMOTE}" --format "tps" --files-only 2>/dev/null | grep -E ';hermes-backup-.*\.(tar\.xz|zip);' | sort | tail -n1 || true)"
    
    if [ -z "${LATEST}" ]; then
        echo "" >&2
        echo -e "${BADGE_ERR} ${C_RED}${C_BOLD}END-TO-END TEST FAILED: No backup files found on remote.${C_RESET}" >&2
        exit 1
    fi

    IFS=';' read -r b_time b_name b_size <<< "${LATEST}"
    b_epoch="$(date -d "${b_time}" +%s 2>/dev/null || echo 0)"

    # Allow 60s tolerance for clock/rounding
    MIN_EXPECTED_EPOCH=$(( TEST_START_EPOCH - 60 ))
    if [ "${b_epoch}" -ge "${MIN_EXPECTED_EPOCH}" ] && [ "${b_size}" -gt 0 ]; then
        echo ""
        echo -e "${C_GREEN}${C_BOLD}=====================================================================${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}                    END-TO-END TEST PASSED                           ${C_RESET}"
        echo -e "${C_GREEN}${C_BOLD}=====================================================================${C_RESET}"
        echo "A fresh backup was successfully created and verified on Google Drive:"
        echo "  Filename  : ${b_name}"
        echo "  Timestamp : ${b_time}"
        echo "  Size      : ${b_size} bytes"
        echo -e "${C_GREEN}${C_BOLD}=====================================================================${C_RESET}"
        exit 0
    else
        echo "" >&2
        echo -e "${BADGE_ERR} ${C_RED}${C_BOLD}END-TO-END TEST FAILED: Latest archive is older than test start or 0 bytes.${C_RESET}" >&2
        echo "  Found file: ${b_name} (time: ${b_time}, size: ${b_size})" >&2
        exit 1
    fi
fi

# Standard setup summary
echo ""
echo -e "${C_GREEN}${C_BOLD}=====================================================================${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}                        SETUP COMPLETE                               ${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}=====================================================================${C_RESET}"
echo "Automatic backup timer is installed and active."
echo "Google Drive remote connectivity verified."
echo ""
echo "Recommended end-to-end backup validation:"
echo -e "  ${C_CYAN}./setup.sh --test${C_RESET}"
echo ""
echo "Useful commands:"
echo -e "  Check system health:  ${C_CYAN}./status.sh${C_RESET}"
echo -e "  Run a backup now:     ${C_CYAN}./backup.sh${C_RESET}"
echo -e "  Restore latest:       ${C_CYAN}./restore.sh${C_RESET}"
echo -e "${C_GREEN}${C_BOLD}=====================================================================${C_RESET}"
