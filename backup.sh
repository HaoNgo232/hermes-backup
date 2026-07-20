#!/usr/bin/env bash
# =====================================================================
# Hermes Backup Script (Super Compression tar.xz)
# Automatically creates a backup with 'hermes backup', super-compresses
# with xz (-9e), and uploads it to Google Drive.
# Old backups are removed according to GFS (Grandfather-Father-Son).
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${BACKUP_LOG_DIR:-${SCRIPT_DIR}/logs}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/backup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_FILE}"
}

# ---------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------
REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

case "${REMOTE}" in
    *:) ;;
    */) ;;
    *) REMOTE="${REMOTE}/" ;;
esac

# Timestamp format: DD-MM-YYYY_HHhMMpSSs (example: 20-07-2026_14h47p55s)
TIMESTAMP="$(date +%d-%m-%Y_%Hh%Mp%Ss)"
ARCHIVE_NAME="hermes-backup-${TIMESTAMP}.tar.xz"

# Lock file setup
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
    DEFAULT_LOCK="${XDG_RUNTIME_DIR}/hermes-backup.lock"
else
    DEFAULT_LOCK="${TMPDIR:-/tmp}/hermes-backup-${UID:-$(id -u)}.lock"
fi
LOCK_FILE="${BACKUP_LOCK_FILE:-${DEFAULT_LOCK}}"

# Isolated temporary workspace
WORKSPACE=""
cleanup() {
    if [ -n "${WORKSPACE}" ] && [ -d "${WORKSPACE}" ]; then
        rm -rf "${WORKSPACE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# PREFLIGHT CHECKS & LOCKING
# ---------------------------------------------------------------------
require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        log "ERROR: Missing required command: '${cmd}'"
        log "Please install '${cmd}' and try again."
        exit 1
    fi
}

preflight_backup() {
    require_command rclone
    require_command unzip
    require_command tar
    require_command xz
    require_command date
    require_command du
    require_command flock

    # Resolve Hermes binary
    HERMES_RESOLVED=""
    if [ -n "${HERMES_BIN:-}" ] && [ -x "${HERMES_BIN}" ]; then
        HERMES_RESOLVED="${HERMES_BIN}"
    elif command -v hermes &>/dev/null; then
        HERMES_RESOLVED="$(command -v hermes)"
    fi

    if [ -z "${HERMES_RESOLVED}" ]; then
        log "ERROR: 'hermes' binary not found. Set HERMES_BIN=/path/to/hermes or add it to PATH."
        exit 1
    fi
    log "Using Hermes binary: ${HERMES_RESOLVED}"

    # Verify rclone remote config exists
    local remote_config_name
    remote_config_name="${REMOTE%%:*}"
    if [ -n "${remote_config_name}" ] && [ "${remote_config_name}" != "${REMOTE}" ]; then
        if ! rclone listremotes 2>/dev/null | grep -q "^${remote_config_name}:"; then
            log "ERROR: rclone remote '${remote_config_name}:' is not configured."
            log "Run 'rclone config' to setup the remote '${remote_config_name}'."
            exit 1
        fi
    fi

    log "Preflight checks passed."
}

check_timer_warning() {
    if command -v systemctl &>/dev/null; then
        if systemctl --user status &>/dev/null; then
            if ! systemctl --user is-enabled hermes-cloud-backup.timer &>/dev/null; then
                log "WARNING: Systemd backup timer is not enabled."
                log "WARNING: Run './install-systemd.sh' to setup automatic backups."
            fi
        fi
    fi
}

# Acquire lock using flock
acquire_lock() {
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        log "Another backup is already running; skipping this run."
        exit 0
    fi
}

# ---------------------------------------------------------------------
# GFS CLEANUP (Grandfather-Father-Son)
# Keep: all ≤2 days | 1/day ≤7 days | 1/week ≤4 weeks | 1/month ≤3 months
# ---------------------------------------------------------------------
cleanup_gfs() {
    log "Starting GFS cleanup..."
    local now_epoch
    now_epoch=$(date +%s)

    local -A daily_seen=()
    local -A weekly_seen=()
    local -A monthly_seen=()
    local kept=0
    local deleted=0
    local cleanup_had_errors=false

    local list_output
    if ! list_output="$(rclone lsf "${REMOTE}" --format "tp" --files-only 2>&1)"; then
        log "ERROR: GFS listing failed; no deletion was attempted."
        log "ERROR: rclone output: ${list_output}"
        return 1
    fi

    local filtered_list
    filtered_list="$(echo "${list_output}" | grep -E ';hermes-backup-.*\.(tar\.xz|zip)$' | sort -r || true)"

    if [ -z "${filtered_list}" ]; then
        log "GFS cleanup: No existing backup files found on remote."
        return 0
    fi

    while IFS=';' read -r timestamp filename; do
        [ -z "${filename}" ] && continue

        local file_epoch
        file_epoch=$(date -d "${timestamp}" +%s 2>/dev/null) || continue
        local age_days=$(( (now_epoch - file_epoch) / 86400 ))

        if [ "${age_days}" -le 2 ]; then
            # Tier 1: Keep ALL backups from the most recent two days (age <= 2 days)
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
                if rclone deletefile "${REMOTE}${filename}"; then
                    deleted=$((deleted + 1))
                else
                    log "ERROR: Failed to delete remote file: ${filename}"
                    cleanup_had_errors=true
                fi
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
                if rclone deletefile "${REMOTE}${filename}"; then
                    deleted=$((deleted + 1))
                else
                    log "ERROR: Failed to delete remote file: ${filename}"
                    cleanup_had_errors=true
                fi
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
                if rclone deletefile "${REMOTE}${filename}"; then
                    deleted=$((deleted + 1))
                else
                    log "ERROR: Failed to delete remote file: ${filename}"
                    cleanup_had_errors=true
                fi
            fi

        else
            # Older than 90 days: delete
            log "  Deleting (>90 days): ${filename}"
            if rclone deletefile "${REMOTE}${filename}"; then
                deleted=$((deleted + 1))
            else
                log "ERROR: Failed to delete remote file: ${filename}"
                cleanup_had_errors=true
            fi
        fi
    done <<< "${filtered_list}"

    if [ "${cleanup_had_errors}" = true ]; then
        log "GFS cleanup finished with errors: kept ${kept} backups, deleted ${deleted} backups."
        return 1
    else
        log "GFS cleanup complete: kept ${kept} backups, deleted ${deleted} backups."
        return 0
    fi
}

# =====================================================================
# MAIN EXECUTION
# =====================================================================
preflight_backup
acquire_lock
check_timer_warning

WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/hermes-backup-XXXXXX")"
TMP_ORIG="${WORKSPACE}/orig.zip"
TMP_DIR="${WORKSPACE}/extract"
TMP_XZ="${WORKSPACE}/${ARCHIVE_NAME}"

# Step 1: Create the base backup with Hermes
log "Starting Hermes backup..."
"${HERMES_RESOLVED}" backup -o "${TMP_ORIG}"

if [ ! -f "${TMP_ORIG}" ]; then
    log "ERROR: Hermes backup output file was not created at ${TMP_ORIG}"
    exit 1
fi

# Step 2: Super-compress with xz -9e
log "Super-compressing backup to .tar.xz (level 9)..."
mkdir -p "${TMP_DIR}"
unzip -q -o "${TMP_ORIG}" -d "${TMP_DIR}"
tar -cf - -C "${TMP_DIR}" . | xz -9e -c > "${TMP_XZ}"

orig_size=$(du -h "${TMP_ORIG}" | cut -f1)
xz_size=$(du -h "${TMP_XZ}" | cut -f1)
local_bytes=$(stat -c%s "${TMP_XZ}" 2>/dev/null || du -b "${TMP_XZ}" | cut -f1)
log "Super-compression complete: ${orig_size} -> ${xz_size} (${local_bytes} bytes)"

# Step 3: Upload to Google Drive
log "Uploading ${ARCHIVE_NAME} to Google Drive (${REMOTE})..."
if ! rclone copyto "${TMP_XZ}" "${REMOTE}${ARCHIVE_NAME}"; then
    log "ERROR: Upload command failed for ${ARCHIVE_NAME}"
    exit 1
fi

# Verification of uploaded object
log "Verifying uploaded file on remote..."
remote_bytes="$(rclone lsf "${REMOTE}${ARCHIVE_NAME}" --format "s" 2>/dev/null | tr -d '[:space:]' || true)"

if [ -z "${remote_bytes}" ] || ! [[ "${remote_bytes}" =~ ^[0-9]+$ ]] || [ "${remote_bytes}" -le 0 ]; then
    log "ERROR: Upload completed but remote verification failed for ${REMOTE}${ARCHIVE_NAME} (remote size: '${remote_bytes}')"
    exit 1
fi

log "Upload verified on remote: ${REMOTE}${ARCHIVE_NAME} (${remote_bytes} bytes)"

# Step 4: GFS Retention Cleanup
cleanup_status=0
cleanup_gfs || cleanup_status=$?

if [ ${cleanup_status} -eq 0 ]; then
    log "Backup completed successfully."
    exit 0
else
    log "Upload succeeded, but GFS cleanup encountered errors."
    exit 1
fi
