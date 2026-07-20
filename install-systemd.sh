#!/usr/bin/env bash
# =====================================================================
# install-systemd.sh - Enable the Hermes cloud backup timer (user unit)
# ---------------------------------------------------------------------
# Safe: only touches ~/.config/systemd/user, never root, never sudo.
# Idempotent: can be re-run safely.
# =====================================================================
set -Eeuo pipefail
umask 077

if [ "$(id -u)" -eq 0 ]; then
    echo "ERROR: Refusing to run as root. Run as regular user." >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${HOME}/.config/systemd/user"
SERVICE="hermes-cloud-backup.service"
TIMER="hermes-cloud-backup.timer"

# ---------------------------------------------------------------------
# PREFLIGHT CHECKS
# ---------------------------------------------------------------------
if ! command -v systemctl &>/dev/null; then
    echo "ERROR: 'systemctl' command not found. Systemd is required to install the backup timer." >&2
    exit 1
fi

if ! systemctl --user status &>/dev/null && ! systemctl --user show-environment &>/dev/null; then
    echo "ERROR: Cannot connect to systemd user manager ('systemctl --user')." >&2
    echo "Make sure you are logged into an active systemd user session." >&2
    echo "For unattended operation after logout/reboot, enable linger separately." >&2
    exit 1
fi

if [ ! -x "${SRC_DIR}/backup.sh" ]; then
    echo "ERROR: '${SRC_DIR}/backup.sh' is missing or not executable." >&2
    echo "Run 'chmod +x ${SRC_DIR}/backup.sh' first." >&2
    exit 1
fi

if [ ! -f "${SRC_DIR}/systemd/${SERVICE}" ] || [ ! -f "${SRC_DIR}/systemd/${TIMER}" ]; then
    echo "ERROR: Systemd unit templates missing in '${SRC_DIR}/systemd/'." >&2
    exit 1
fi

# Resolve Hermes binary absolute path
HERMES_RESOLVED=""
if [ -n "${HERMES_BIN:-}" ] && [ -x "${HERMES_BIN}" ]; then
    HERMES_RESOLVED="${HERMES_BIN}"
elif command -v hermes &>/dev/null; then
    HERMES_RESOLVED="$(command -v hermes)"
fi

if [ -z "${HERMES_RESOLVED}" ]; then
    echo "ERROR: 'hermes' executable not found in PATH or HERMES_BIN environment variable." >&2
    echo "Please ensure Hermes is installed or set HERMES_BIN=/path/to/hermes before running installer." >&2
    exit 1
fi

HERMES_DIR="$(dirname "${HERMES_RESOLVED}")"
EXPLICIT_PATH="${HERMES_DIR}:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Ensure no newlines in path values before sed replacement
if [[ "${SRC_DIR}" == *$'\n'* ]] || [[ "${HERMES_RESOLVED}" == *$'\n'* ]]; then
    echo "ERROR: Path contains invalid characters (newline)." >&2
    exit 1
fi

# ---------------------------------------------------------------------
# RENDER AND INSTALL UNITS
# ---------------------------------------------------------------------
mkdir -p "${UNIT_DIR}"

# Helper function to escape sed replacement string
escape_sed() {
    printf '%s\n' "$1" | sed -e 's/[\/&]/\\&/g'
}

REPO_DIR_ESC="$(escape_sed "${SRC_DIR}")"
HERMES_BIN_ESC="$(escape_sed "${HERMES_RESOLVED}")"
PATH_ESC="$(escape_sed "${EXPLICIT_PATH}")"

# Render service unit
sed -e "s/@REPO_DIR@/${REPO_DIR_ESC}/g" \
    -e "s/@HERMES_BIN@/${HERMES_BIN_ESC}/g" \
    -e "s/@PATH@/${PATH_ESC}/g" \
    "${SRC_DIR}/systemd/${SERVICE}" > "${UNIT_DIR}/${SERVICE}"
chmod 644 "${UNIT_DIR}/${SERVICE}"

# Render timer unit
sed -e "s/@REPO_DIR@/${REPO_DIR_ESC}/g" \
    "${SRC_DIR}/systemd/${TIMER}" > "${UNIT_DIR}/${TIMER}"
chmod 644 "${UNIT_DIR}/${TIMER}"

echo "Installed service: ${UNIT_DIR}/${SERVICE}"
echo "Installed timer:   ${UNIT_DIR}/${TIMER}"

# ---------------------------------------------------------------------
# DAEMON RELOAD AND ACTIVATE
# ---------------------------------------------------------------------
systemctl --user daemon-reload
systemctl --user enable --now "${TIMER}"

# ---------------------------------------------------------------------
# VERIFICATION & STATUS
# ---------------------------------------------------------------------
IS_ENABLED="$(systemctl --user is-enabled "${TIMER}" 2>/dev/null || echo "no")"
IS_ACTIVE="$(systemctl --user is-active "${TIMER}" 2>/dev/null || echo "no")"

echo ""
echo "=== Systemd Timer Status ==="
echo "Timer enabled : ${IS_ENABLED}"
echo "Timer active  : ${IS_ACTIVE}"

if [ "${IS_ENABLED}" = "enabled" ] && [ "${IS_ACTIVE}" = "active" ]; then
    echo "Next trigger  :"
    systemctl --user list-timers "${TIMER}" --no-pager || true
else
    echo "WARNING: Timer installation finished but timer state is enabled=${IS_ENABLED}, active=${IS_ACTIVE}." >&2
    exit 1
fi

# ---------------------------------------------------------------------
# LINGER DETECTION & WARNING
# ---------------------------------------------------------------------
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
    echo "WARNING: User linger is NOT enabled for user '$USER'."
    echo "Without linger, systemd user timer will not run after logout or system reboot"
    echo "until you log back in."
    echo "To enable unattended operation after reboot/logout, run:"
    echo "  sudo loginctl enable-linger $USER"
fi

echo ""
echo "Installation complete!"
echo "To manually trigger a backup test now, run:"
echo "  systemctl --user start ${SERVICE}"
