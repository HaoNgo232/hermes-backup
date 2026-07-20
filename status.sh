#!/usr/bin/env bash
# =====================================================================
# status.sh - Hermes Backup Diagnostic & Status Tool
# ---------------------------------------------------------------------
# Read-only health check for Hermes backup installation, systemd timer,
# remote connectivity, and latest backup state.
# =====================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

case "${REMOTE}" in
    *:) ;;
    */) ;;
    *) REMOTE="${REMOTE}/" ;;
esac

echo "====================================================================="
echo "                  HERMES BACKUP SYSTEM STATUS                        "
echo "====================================================================="

# 1. Environment & Paths
echo "[1] Environment & Configuration:"
echo "  Repository Path  : ${SCRIPT_DIR}"
echo "  Backup Script    : ${SCRIPT_DIR}/backup.sh"
echo "  Restore Script   : ${SCRIPT_DIR}/restore.sh"

HERMES_RESOLVED=""
if [ -n "${HERMES_BIN:-}" ] && [ -x "${HERMES_BIN}" ]; then
    HERMES_RESOLVED="${HERMES_BIN}"
elif command -v hermes &>/dev/null; then
    HERMES_RESOLVED="$(command -v hermes)"
fi

if [ -n "${HERMES_RESOLVED}" ]; then
    HERMES_VER="$("${HERMES_RESOLVED}" --version 2>/dev/null || echo "version unknown")"
    echo "  Hermes Binary    : ${HERMES_RESOLVED} (${HERMES_VER})"
else
    echo "  Hermes Binary    : NOT FOUND (hermes command not in PATH)"
fi

echo "  Backup Remote    : ${REMOTE}"

# Check rclone remote reachability
REMOTE_REACHABLE="no"
if command -v rclone &>/dev/null; then
    if rclone lsf "${REMOTE}" --max-depth 0 &>/dev/null; then
        REMOTE_REACHABLE="yes"
    elif rclone listremotes 2>/dev/null | grep -q "^${REMOTE%%:*}:"; then
        REMOTE_REACHABLE="yes (remote exists, target folder will be created on upload)"
    else
        REMOTE_REACHABLE="no (remote '${REMOTE%%:*}' not configured in rclone)"
    fi
else
    REMOTE_REACHABLE="no (rclone command missing)"
fi
echo "  Remote Reachable : ${REMOTE_REACHABLE}"

# 2. Systemd Timer & Service Status
echo ""
echo "[2] Systemd Timer & Service Status:"
SERVICE_UNIT="${HOME}/.config/systemd/user/hermes-cloud-backup.service"
TIMER_UNIT="${HOME}/.config/systemd/user/hermes-cloud-backup.timer"

if [ -f "${SERVICE_UNIT}" ] && [ -f "${TIMER_UNIT}" ]; then
    echo "  Unit Files       : Installed (${SERVICE_UNIT})"
else
    echo "  Unit Files       : NOT INSTALLED"
fi

if command -v systemctl &>/dev/null; then
    TIMER_ENABLED="$(systemctl --user is-enabled hermes-cloud-backup.timer 2>/dev/null || echo "not-installed")"
    TIMER_ACTIVE="$(systemctl --user is-active hermes-cloud-backup.timer 2>/dev/null || echo "inactive")"
    echo "  Timer Enabled    : ${TIMER_ENABLED}"
    echo "  Timer Active     : ${TIMER_ACTIVE}"

    if [ "${TIMER_ENABLED}" = "enabled" ]; then
        echo ""
        echo "  Next Scheduled Runs:"
        systemctl --user list-timers hermes-cloud-backup.timer --no-pager 2>/dev/null | sed 's/^/    /' || true
    fi

    SERVICE_STATUS="$(systemctl --user is-failed hermes-cloud-backup.service 2>/dev/null || echo "unknown")"
    if [ "${SERVICE_STATUS}" = "failed" ]; then
        echo "  Last Service Run : FAILED"
    elif [ "${SERVICE_STATUS}" = "active" ]; then
        echo "  Last Service Run : RUNNING"
    else
        echo "  Last Service Run : OK / Idle"
    fi
else
    echo "  Systemctl        : Systemd not available in current environment"
fi

# 3. User Linger Status
echo ""
echo "[3] User Linger Status:"
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
echo "  Linger Enabled   : ${LINGER_STATUS}"
if [ "${LINGER_STATUS}" = "disabled" ]; then
    echo "  (Note: Enable linger to allow timer execution after logout/reboot: 'sudo loginctl enable-linger $USER')"
fi

# 4. Latest Backup on Remote
echo ""
echo "[4] Latest Backup on Remote:"
if [ "${REMOTE_REACHABLE}" != "no" ] && command -v rclone &>/dev/null; then
    LATEST_BACKUP="$(rclone lsf "${REMOTE}" --format "tps" --files-only 2>/dev/null | grep -E ';hermes-backup-.*\.(tar\.xz|zip);' | sort | tail -n1 || true)"
    if [ -n "${LATEST_BACKUP}" ]; then
        IFS=';' read -r b_time b_name b_size <<< "${LATEST_BACKUP}"
        echo "  Filename         : ${b_name}"
        echo "  Timestamp        : ${b_time}"
        echo "  Size             : ${b_size} bytes"
    else
        echo "  No backups found on remote '${REMOTE}'."
    fi
else
    echo "  Cannot query remote backups (remote not reachable)."
fi

# 5. Suggested Actions & Debugging
echo ""
echo "====================================================================="
echo "                        RECOMMENDED ACTIONS                          "
echo "====================================================================="

if [ -z "${HERMES_RESOLVED}" ]; then
    echo "* Install Hermes or add it to PATH / set HERMES_BIN=/path/to/hermes"
fi

if [[ "${REMOTE_REACHABLE}" == no* ]]; then
    echo "* Configure rclone remote by running: rclone config"
fi

if [ ! -f "${TIMER_UNIT}" ] || [ "${TIMER_ENABLED:-}" != "enabled" ]; then
    echo "* Install and enable systemd timer by running: ./install-systemd.sh"
fi

echo ""
echo "Useful Commands for Troubleshooting:"
echo "  Manual backup run  : ./backup.sh"
echo "  Test systemd service: systemctl --user start hermes-cloud-backup.service"
echo "  View service logs  : journalctl --user -u hermes-cloud-backup.service -n 100 --no-pager"
echo "  Check timer list   : systemctl --user list-timers hermes-cloud-backup.timer"
echo "====================================================================="
