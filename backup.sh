#!/usr/bin/env bash
# =====================================================================
# Hermes Backup Script
# Automatically creates a backup with 'hermes backup' and uploads it to
# Google Drive. The first run installs a Systemd Timer every four hours.
# Old backups are removed according to GFS (Grandfather-Father-Son).
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/backup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_FILE}"
}

# ---------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------
REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

# Timestamp format: DD-MM-YYYY_HHhMMpSSs (example: 20-07-2026_14h47p55s)
TIMESTAMP="$(date +%d-%m-%Y_%Hh%Mp%Ss)"
ZIP_NAME="hermes-backup-${TIMESTAMP}.zip"

case "${REMOTE}" in
    *:) ;;
    */) ;;
    *) REMOTE="${REMOTE}/" ;;
esac

TMP_ZIP="/tmp/${ZIP_NAME}"

cleanup() {
    rm -f "${TMP_ZIP}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# AUTOMATICALLY INSTALL SYSTEMD TIMER (first run only)
# ---------------------------------------------------------------------
install_timer_if_needed() {
    if systemctl --user is-active hermes-cloud-backup.timer &>/dev/null; then
        return 0
    fi
    log "Timer is not installed. Automatically installing the Systemd Timer for backups every four hours..."
    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "${unit_dir}"
    cp "${SCRIPT_DIR}/systemd/hermes-cloud-backup.service" "${unit_dir}/"
    cp "${SCRIPT_DIR}/systemd/hermes-cloud-backup.timer" "${unit_dir}/"
    chmod 644 "${unit_dir}/hermes-cloud-backup.service" "${unit_dir}/hermes-cloud-backup.timer"
    systemctl --user daemon-reload
    systemctl --user enable --now hermes-cloud-backup.timer
    log "Timer installed and enabled. Backups will run automatically every four hours."
}

# ---------------------------------------------------------------------
# GFS CLEANUP (Grandfather-Father-Son)
# Keep: all ≤2 days | 1/day ≤7 days | 1/week ≤4 weeks | 1/month ≤3 months
# ---------------------------------------------------------------------
cleanup_gfs() {
    log "Cleaning up old backups according to the GFS retention strategy..."
    local now_epoch
    now_epoch=$(date +%s)

    local -A daily_seen=()
    local -A weekly_seen=()
    local -A monthly_seen=()
    local kept=0
    local deleted=0

    while IFS=';' read -r timestamp filename; do
        [ -z "${filename}" ] && continue

        local file_epoch
        file_epoch=$(date -d "${timestamp}" +%s 2>/dev/null) || continue
        local age_days=$(( (now_epoch - file_epoch) / 86400 ))

        if [ "${age_days}" -le 2 ]; then
            # Tier 1: Keep ALL backups from the most recent two days
            kept=$((kept + 1))

        elif [ "${age_days}" -le 7 ]; then
            # Tier 2: Keep one backup per day for days 3-7
            local day_key
            day_key=$(date -d "${timestamp}" +%Y-%m-%d)
            if [ -z "${daily_seen[${day_key}]:-}" ]; then
                daily_seen["${day_key}"]=1
                kept=$((kept + 1))
            else
                log "  Deleting (daily): ${filename}"
                rclone deletefile "${REMOTE}${filename}" 2>/dev/null || true
                deleted=$((deleted + 1))
            fi

        elif [ "${age_days}" -le 28 ]; then
            # Tier 3: Keep one backup per week for weeks 2-4
            local week_key
            week_key=$(date -d "${timestamp}" +%G-W%V)
            if [ -z "${weekly_seen[${week_key}]:-}" ]; then
                weekly_seen["${week_key}"]=1
                kept=$((kept + 1))
            else
                log "  Deleting (weekly): ${filename}"
                rclone deletefile "${REMOTE}${filename}" 2>/dev/null || true
                deleted=$((deleted + 1))
            fi

        elif [ "${age_days}" -le 90 ]; then
            # Tier 4: Keep one backup per month for months 2-3
            local month_key
            month_key=$(date -d "${timestamp}" +%Y-%m)
            if [ -z "${monthly_seen[${month_key}]:-}" ]; then
                monthly_seen["${month_key}"]=1
                kept=$((kept + 1))
            else
                log "  Deleting (monthly): ${filename}"
                rclone deletefile "${REMOTE}${filename}" 2>/dev/null || true
                deleted=$((deleted + 1))
            fi

        else
            # Older than 90 days: delete
            log "  Deleting (>90 days): ${filename}"
            rclone deletefile "${REMOTE}${filename}" 2>/dev/null || true
            deleted=$((deleted + 1))
        fi
    done < <(rclone lsf "${REMOTE}" --format "tp" --files-only 2>/dev/null \
        | grep -E ';hermes-backup-.*\.zip$' | sort -r)

    log "GFS cleanup complete: kept ${kept} backups, deleted ${deleted} backups."
}

# =====================================================================
# MAIN EXECUTION
# =====================================================================

# Step 0: Install the timer automatically if needed
install_timer_if_needed

# Step 1: Create the backup
log "Starting Hermes backup..."
hermes backup -o "${TMP_ZIP}"

if [ ! -f "${TMP_ZIP}" ]; then
    log "ERROR: Backup file was not found at ${TMP_ZIP}"
    exit 1
fi

# Step 2: Upload to Google Drive
log "Uploading ${ZIP_NAME} to Google Drive (${REMOTE})..."
rclone copyto "${TMP_ZIP}" "${REMOTE}${ZIP_NAME}"
log "Backup completed successfully. File: ${REMOTE}${ZIP_NAME}"

# Step 3: Remove old backups according to GFS
cleanup_gfs
