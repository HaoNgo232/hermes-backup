#!/usr/bin/env bash
# =====================================================================
# setup.sh - Hermes Backup Setup & Onboarding Assistant
# ---------------------------------------------------------------------
# Non-destructive onboarding helper that validates system dependencies,
# verifies rclone remote configuration, installs systemd backup timers,
# and outputs system health status.
# =====================================================================
set -Eeuo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: Refusing to run as root. Run as regular user." >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

echo "====================================================================="
echo "                    HERMES BACKUP SETUP                              "
echo "====================================================================="

# ---------------------------------------------------------------------
# [1/4] CHECK REQUIRED TOOLS
# ---------------------------------------------------------------------
echo "[1/4] Checking required tools..."

check_cmd() {
    local cmd="$1"
    if command -v "${cmd}" &>/dev/null; then
        echo "  OK: ${cmd}"
    else
        echo "  ERROR: Missing command '${cmd}'" >&2
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
    echo "  OK: Hermes binary -> ${HERMES_RESOLVED}"
else
    echo "  ERROR: 'hermes' binary not found. Add it to PATH or set HERMES_BIN=/path/to/hermes" >&2
    MISSING=1
fi

if [ "${MISSING}" -ne 0 ]; then
    echo "" >&2
    echo "ERROR: Missing required dependencies. Please install missing tools and try again." >&2
    echo "On Debian/Ubuntu: sudo apt update && sudo apt install -y rclone unzip zip xz-utils util-linux" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# [2/4] CHECK BACKUP REMOTE
# ---------------------------------------------------------------------
echo ""
echo "[2/4] Checking backup remote configuration..."
REMOTE_NAME="${REMOTE%%:*}"

if [ -n "${REMOTE_NAME}" ] && [ "${REMOTE_NAME}" != "${REMOTE}" ]; then
    if rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
        echo "  OK: rclone remote '${REMOTE_NAME}:' is configured."
    else
        echo "" >&2
        echo "ERROR: rclone remote '${REMOTE_NAME}:' is not configured." >&2
        echo "" >&2
        echo "Please configure rclone by running:" >&2
        echo "  rclone config" >&2
        echo "" >&2
        echo "Create a Google Drive remote named:" >&2
        echo "  ${REMOTE_NAME}" >&2
        echo "" >&2
        echo "For detailed rclone config instructions, see README.md." >&2
        echo "After configuring rclone, re-run:" >&2
        echo "  ./setup.sh" >&2
        exit 1
    fi
else
    echo "  OK: Remote path specified directly: ${REMOTE}"
fi

# ---------------------------------------------------------------------
# [3/4] INSTALL AUTOMATIC BACKUP TIMER
# ---------------------------------------------------------------------
echo ""
echo "[3/4] Installing automatic backup timer..."
if [ -x "${SRC_DIR}/install-systemd.sh" ]; then
    "${SRC_DIR}/install-systemd.sh"
else
    echo "ERROR: '${SRC_DIR}/install-systemd.sh' not found or not executable." >&2
    exit 1
fi

# ---------------------------------------------------------------------
# [4/4] CHECK SYSTEM HEALTH
# ---------------------------------------------------------------------
echo ""
echo "[4/4] Running system health status check..."
if [ -x "${SRC_DIR}/status.sh" ]; then
    "${SRC_DIR}/status.sh"
else
    echo "WARNING: '${SRC_DIR}/status.sh' not found or not executable."
fi

echo ""
echo "====================================================================="
echo "                        SETUP COMPLETE                               "
echo "====================================================================="
echo "Automatic backup timer is installed and active."
echo ""
echo "Useful commands:"
echo "  Check system health:  ./status.sh"
echo "  Run a backup now:     ./backup.sh"
echo "  Restore latest:       ./restore.sh"
echo "====================================================================="
