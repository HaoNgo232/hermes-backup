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

# ---------------------------------------------------------------------
# LOGGING & COLOR FORMATTING UTILITY
# ---------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_RED="\033[0;31m"
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[0;33m"
    C_BLUE="\033[0;34m"
    C_CYAN="\033[0;36m"
    ICON_OK="✔"
    ICON_ERR="✖"
    ICON_WARN="⚠"
    ICON_INFO="ℹ"
    ICON_STEP="➜"
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    ICON_OK="[OK]"
    ICON_ERR="[ERR]"
    ICON_WARN="[WARN]"
    ICON_INFO="[INFO]"
    ICON_STEP="[STEP]"
fi

strip_ansi() {
    sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g'
}

log_raw() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${timestamp} - $*"
    if [ -n "${LOG_FILE:-}" ]; then
        echo -e "${timestamp} - $*" | strip_ansi >> "${LOG_FILE}"
    fi
}

rotate_log_file() {
    local max_lines="${MAX_LOG_LINES:-5000}"
    local keep_lines="${KEEP_LOG_LINES:-2000}"
    if [ -f "${LOG_FILE:-}" ]; then
        local current_lines
        current_lines=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
        if [ "${current_lines}" -gt "${max_lines}" ]; then
            local tmp_log="${LOG_FILE}.tmp"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [INFO] Log file exceeded ${max_lines} lines (${current_lines} lines). Truncating to last ${keep_lines} lines." > "${tmp_log}"
            tail -n "${keep_lines}" "${LOG_FILE}" >> "${tmp_log}"
            mv "${tmp_log}" "${LOG_FILE}"
        fi
    fi
}

log_info() {
    log_raw "${C_BLUE}${ICON_INFO}${C_RESET} $*"
}

log_success() {
    log_raw "${C_GREEN}${ICON_OK}${C_RESET} ${C_GREEN}$*${C_RESET}"
}

log_warn() {
    log_raw "${C_YELLOW}${ICON_WARN}${C_RESET} ${C_YELLOW}$*${C_RESET}"
}

log_error() {
    log_raw "${C_RED}${ICON_ERR}${C_RESET} ${C_RED}$*${C_RESET}"
}

log_step() {
    log_raw "${C_CYAN}${C_BOLD}${ICON_STEP} $*${C_RESET}"
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
        log_error "Missing required command: '${cmd}'"
        log_error "Please install '${cmd}' and try again."
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
        log_error "'hermes' binary not found. Set HERMES_BIN=/path/to/hermes or add it to PATH."
        exit 1
    fi
    log_info "Using Hermes binary: ${HERMES_RESOLVED}"

    # Verify rclone remote config exists
    local remote_config_name
    remote_config_name="${REMOTE%%:*}"
    if [ -n "${remote_config_name}" ] && [ "${remote_config_name}" != "${REMOTE}" ]; then
        if ! rclone listremotes 2>/dev/null | grep -q "^${remote_config_name}:"; then
            log_error "rclone remote '${remote_config_name}:' is not configured."
            log_error "Run 'rclone config' to setup the remote '${remote_config_name}'."
            exit 1
        fi
    fi

    log_success "Preflight checks passed."
}

check_timer_warning() {
    if command -v systemctl &>/dev/null; then
        if systemctl --user status &>/dev/null; then
            if ! systemctl --user is-enabled hermes-cloud-backup.timer &>/dev/null; then
                log_warn "Systemd backup timer is not enabled."
                log_warn "Run './setup.sh' to setup automatic backups."
            fi
        fi
    fi
}

acquire_lock() {
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        log_info "Another backup is already running; skipping this run."
        exit 0
    fi
}

# ---------------------------------------------------------------------
# GFS CLEANUP (Grandfather-Father-Son)
# Keep: all ≤2 days | 1/day ≤7 days | 1/week ≤4 weeks | 1/month ≤3 months
# ---------------------------------------------------------------------
cleanup_gfs() {
    log_info "Scanning remote for GFS retention cleanup..."
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
        log_error "GFS listing failed; no deletion was attempted."
        log_error "rclone output: ${list_output}"
        return 1
    fi

    local filtered_list
    filtered_list="$(echo "${list_output}" | grep -E ';hermes-backup-.*\.(tar\.xz|zip)$' | sort -r || true)"

    if [ -z "${filtered_list}" ]; then
        log_info "GFS cleanup: No existing backup files found on remote."
        return 0
    fi

    while IFS=';' read -r timestamp filename; do
        [ -z "${filename}" ] && continue

        local file_epoch
        file_epoch=$(date -d "${timestamp}" +%s 2>/dev/null) || continue
        local age_days=$(( (now_epoch - file_epoch) / 86400 ))

        if [ "${age_days}" -le 2 ]; then
            kept=$((kept + 1))

        elif [ "${age_days}" -le 7 ]; then
            local day_key
            day_key=$(date -d "${timestamp}" +%Y-%m-%d)
            if [ -z "${daily_seen[${day_key}]:-}" ]; then
                daily_seen["${day_key}"]=1
                kept=$((kept + 1))
            else
                log_info "Deleting (daily): ${filename}"
                if rclone deletefile "${REMOTE}${filename}"; then
                    deleted=$((deleted + 1))
                else
                    log_error "Failed to delete remote file: ${filename}"
                    cleanup_had_errors=true
                fi
            fi

        elif [ "${age_days}" -le 28 ]; then
            local week_key
            week_key=$(date -d "${timestamp}" +%G-W%V)
            if [ -z "${weekly_seen[${week_key}]:-}" ]; then
                weekly_seen["${week_key}"]=1
                kept=$((kept + 1))
            else
                log_info "Deleting (weekly): ${filename}"
                if rclone deletefile "${REMOTE}${filename}"; then
                    deleted=$((deleted + 1))
                else
                    log_error "Failed to delete remote file: ${filename}"
                    cleanup_had_errors=true
                fi
            fi

        elif [ "${age_days}" -le 90 ]; then
            local month_key
            month_key=$(date -d "${timestamp}" +%Y-%m)
            if [ -z "${monthly_seen[${month_key}]:-}" ]; then
                monthly_seen["${month_key}"]=1
                kept=$((kept + 1))
            else
                log_info "Deleting (monthly): ${filename}"
                if rclone deletefile "${REMOTE}${filename}"; then
                    deleted=$((deleted + 1))
                else
                    log_error "Failed to delete remote file: ${filename}"
                    cleanup_had_errors=true
                fi
            fi

        else
            log_info "Deleting (>90 days): ${filename}"
            if rclone deletefile "${REMOTE}${filename}"; then
                deleted=$((deleted + 1))
            else
                log_error "Failed to delete remote file: ${filename}"
                cleanup_had_errors=true
            fi
        fi
    done <<< "${filtered_list}"

    if [ "${cleanup_had_errors}" = true ]; then
        log_warn "GFS cleanup finished with errors: kept ${kept} backups, deleted ${deleted} backups."
        return 1
    else
        log_success "GFS cleanup complete: kept ${kept} backups, deleted ${deleted} backups."
        return 0
    fi
}

# =====================================================================
# MAIN EXECUTION
# =====================================================================
rotate_log_file
log_step "[1/4] Preflight checks & acquiring lock..."
preflight_backup
acquire_lock
check_timer_warning

WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/hermes-backup-XXXXXX")"
TMP_ORIG="${WORKSPACE}/orig.zip"
TMP_DIR="${WORKSPACE}/extract"
TMP_XZ="${WORKSPACE}/${ARCHIVE_NAME}"

# Step 2: Snapshot & Compression
log_step "[2/4] Creating Hermes backup & super-compressing..."
log_info "Running '${HERMES_RESOLVED} backup'..."
hermes_out="$("${HERMES_RESOLVED}" backup -o "${TMP_ORIG}" 2>&1)" || {
    log_error "Hermes backup failed with output:"
    log_error "${hermes_out}"
    exit 1
}

# Filter out confusing 'Restore with:' line emitted by hermes binary
echo "${hermes_out}" | grep -v -i "Restore with:" | while IFS= read -r line; do
    [ -n "${line}" ] && log_info "${line}"
done

if [ ! -f "${TMP_ORIG}" ]; then
    log_error "Hermes backup output file was not created at ${TMP_ORIG}"
    exit 1
fi

log_info "Super-compressing to .tar.xz (level 9)..."
mkdir -p "${TMP_DIR}"
unzip -q -o "${TMP_ORIG}" -d "${TMP_DIR}"
tar -cf - -C "${TMP_DIR}" . | xz -9e -c > "${TMP_XZ}"

orig_size=$(du -h "${TMP_ORIG}" | cut -f1)
xz_size=$(du -h "${TMP_XZ}" | cut -f1)
local_bytes=$(stat -c%s "${TMP_XZ}" 2>/dev/null || du -b "${TMP_XZ}" | cut -f1)
log_success "Super-compression complete: ${orig_size} -> ${xz_size} (${local_bytes} bytes)"

# Step 3: Upload & Verification
log_step "[3/4] Uploading to Google Drive & verifying..."
log_info "Uploading ${ARCHIVE_NAME} to ${REMOTE}..."
if ! rclone copyto "${TMP_XZ}" "${REMOTE}${ARCHIVE_NAME}"; then
    log_error "Upload command failed for ${ARCHIVE_NAME}"
    exit 1
fi

log_info "Verifying remote file size..."
remote_bytes="$(rclone lsf "${REMOTE}${ARCHIVE_NAME}" --format "s" 2>/dev/null | tr -d '[:space:]' || true)"

if [ -z "${remote_bytes}" ] || ! [[ "${remote_bytes}" =~ ^[0-9]+$ ]] || [ "${remote_bytes}" -le 0 ]; then
    log_error "Upload completed but remote verification failed for ${REMOTE}${ARCHIVE_NAME} (remote size: '${remote_bytes}')"
    exit 1
fi

log_success "Upload verified on remote: ${REMOTE}${ARCHIVE_NAME} (${remote_bytes} bytes)"

# Step 4: GFS Retention Cleanup
log_step "[4/4] Running GFS retention cleanup..."
cleanup_status=0
cleanup_gfs || cleanup_status=$?

if [ ${cleanup_status} -eq 0 ]; then
    log_success "Backup completed successfully!"
    exit 0
else
    log_warn "Upload succeeded, but GFS cleanup encountered errors."
    exit 1
fi
