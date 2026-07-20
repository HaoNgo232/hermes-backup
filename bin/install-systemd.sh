#!/usr/bin/env bash
# =====================================================================
# install-systemd.sh - Enable the Hermes cloud backup timer (user unit)
# ---------------------------------------------------------------------
# Safe: only touches ~/.config/systemd/user, never root, never sudo.
# Idempotent: can be re-run.
# =====================================================================
set -Eeuo pipefail
umask 077

UNIT_DIR="$HOME/.config/systemd/user"
SERVICE="hermes-cloud-backup.service"
TIMER="hermes-cloud-backup.timer"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ "$(id -u)" -eq 0 ] && { echo "Refusing to run as root." >&2; exit 1; }

mkdir -p "${UNIT_DIR}"

for f in "${SERVICE}" "${TIMER}"; do
    if [ ! -f "${SRC_DIR}/systemd/${f}" ]; then
        echo "ERROR: missing ${SRC_DIR}/systemd/${f}" >&2
        exit 1
    fi
    cp "${SRC_DIR}/systemd/${f}" "${UNIT_DIR}/${f}"
    chmod 644 "${UNIT_DIR}/${f}"
    echo "Installed ${UNIT_DIR}/${f}"
done

# On some systems the user manager needs an explicit start
systemctl --user daemon-reload

systemctl --user enable --now "${TIMER}"

echo "--- status ---"
systemctl --user is-enabled "${TIMER}" || true
systemctl --user is-active  "${TIMER}" || true
echo "Done. Check with: systemctl --user list-timers ${TIMER}"
