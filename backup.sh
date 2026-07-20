#!/usr/bin/env bash
# =====================================================================
# Hermes Backup Script (Super Compression tar.xz + Optional Encryption)
# =====================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_FILE="${BACKUP_LOG_DIR:-${SCRIPT_DIR}/logs}/backup.log"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/hermes.sh"
source "${SCRIPT_DIR}/lib/rclone.sh"
source "${SCRIPT_DIR}/lib/encryption.sh"

rotate_log_file

# Lock file setup
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
    DEFAULT_LOCK="${XDG_RUNTIME_DIR}/hermes-backup.lock"
else
    DEFAULT_LOCK="${TMPDIR:-/tmp}/hermes-backup-${UID:-$(id -u)}.lock"
fi
LOCK_FILE="${BACKUP_LOCK_FILE:-${DEFAULT_LOCK}}"

acquire_backup_lock "${LOCK_FILE}"

# Temporary workspace
WORKSPACE=""
cleanup() {
    if [ -n "${WORKSPACE}" ] && [ -d "${WORKSPACE}" ]; then
        rm -rf "${WORKSPACE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# PREFLIGHT & ENCRYPTION DESTINATION RESOLUTION
# ---------------------------------------------------------------------
preflight_backup() {
    require_command rclone
    require_command unzip
    require_command tar
    require_command xz
    require_command date
    require_command du
    require_command flock

    # Resolve Hermes binary
    hermes_apply_persisted_environment

    if ! HERMES_RESOLVED="$(hermes_resolve_binary)"; then
        exit 1
    fi
    log_info "Using Hermes binary: ${HERMES_RESOLVED}"

    # Resolve active destination (Plaintext vs Encrypted)
    DESTINATION="$(encryption_get_active_destination)"
    log_info "Resolved active backup destination: ${DESTINATION}"
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

# ---------------------------------------------------------------------
# GFS CLEANUP (Grandfather-Father-Son)
# Keep: all ≤2 days | 1/day ≤7 days | 1/week ≤4 weeks | 1/month ≤3 months
# ---------------------------------------------------------------------
cleanup_gfs() {
    local target_dest="$1"
    log_info "Scanning destination (${target_dest}) for GFS retention cleanup..."
    local now_epoch
    now_epoch="$(date +%s)"

    local raw_list
    if ! raw_list="$(rclone_list_backups "${target_dest}")"; then
        log_error "GFS cleanup aborted due to listing failure."
        exit 1
    fi

    if [ -z "${raw_list}" ]; then
        log_info "No previous backups found for GFS evaluation."
        return 0
    fi

    declare -A daily_map=()
    declare -A weekly_map=()
    declare -A monthly_map=()
    local -a to_delete=()

    while IFS=; read -r line || [ -n "${line}" ]; do
        [ -z "${line}" ] && continue

        local file_time_str="" file_name="" _file_size=""
        IFS=';' read -r file_time_str file_name _file_size <<< "${line}"

        if [ -z "${file_time_str}" ] || [ -z "${file_name}" ]; then
            continue
        fi

        local file_epoch
        file_epoch="$(date -d "${file_time_str}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${file_time_str%%.*}" +%s 2>/dev/null || echo 0)"

        if [ "${file_epoch}" -eq 0 ]; then
            continue
        fi

        local age_days=$(( (now_epoch - file_epoch) / 86400 ))

        # Tier 1: <= 2 days -> Keep ALL
        if [ "${age_days}" -le 2 ]; then
            continue
        fi

        # Tier 2: 3 to 7 days -> Keep 1 per day (latest of day)
        if [ "${age_days}" -le 7 ]; then
            local day_key
            day_key="$(date -d "@${file_epoch}" +%Y-%m-%d 2>/dev/null || echo "")"
            if [ -n "${day_key}" ]; then
                if [ -n "${daily_map[${day_key}]:-}" ]; then
                    to_delete+=("${daily_map[${day_key}]}")
                fi
                daily_map["${day_key}"]="${file_name}"
            fi
            continue
        fi

        # Tier 3: 8 to 28 days -> Keep 1 per week (latest of ISO week %G-%V)
        if [ "${age_days}" -le 28 ]; then
            local week_key
            week_key="$(date -d "@${file_epoch}" +%G-%V 2>/dev/null || echo "")"
            if [ -n "${week_key}" ]; then
                if [ -n "${weekly_map[${week_key}]:-}" ]; then
                    to_delete+=("${weekly_map[${week_key}]}")
                fi
                weekly_map["${week_key}"]="${file_name}"
            fi
            continue
        fi

        # Tier 4: 29 to 90 days -> Keep 1 per month (latest of month)
        if [ "${age_days}" -le 90 ]; then
            local month_key
            month_key="$(date -d "@${file_epoch}" +%Y-%m 2>/dev/null || echo "")"
            if [ -n "${month_key}" ]; then
                if [ -n "${monthly_map[${month_key}]:-}" ]; then
                    to_delete+=("${monthly_map[${month_key}]}")
                fi
                monthly_map["${month_key}"]="${file_name}"
            fi
            continue
        fi

        # Tier 5: > 90 days -> Delete
        to_delete+=("${file_name}")

    done <<< "${raw_list}"

    if [ "${#to_delete[@]}" -eq 0 ]; then
        log_info "GFS retention check completed. No old backups require deletion."
        return 0
    fi

    log_info "GFS retention: Pruning ${#to_delete[@]} old archive(s)..."
    for old_file in "${to_delete[@]}"; do
        log_info "Deleting old archive: ${old_file}"
        rclone_delete_remote_file "${target_dest}${old_file}"
    done
    log_success "GFS retention pruning finished."
}

# ---------------------------------------------------------------------
# MAIN BACKUP EXECUTION
# ---------------------------------------------------------------------
log_step "Starting Hermes Backup Workflow..."
check_timer_warning
preflight_backup

encryption_show_first_backup_reminder_if_needed

TIMESTAMP="$(date +%d-%m-%Y_%Hh%Mp%Ss)"
ARCHIVE_NAME="hermes-backup-${TIMESTAMP}.tar.xz"

WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/hermes-backup-XXXXXX")"
TMP_ZIP="${WORKSPACE}/hermes-raw-backup.zip"
TMP_EXTRACT="${WORKSPACE}/extract"
TMP_XZ="${WORKSPACE}/${ARCHIVE_NAME}"

log_step "[1/4] Generating raw Hermes export..."
local_backup_out=""
if ! local_backup_out="$("${HERMES_RESOLVED}" backup -o "${TMP_ZIP}" 2>&1)"; then
    log_error "Hermes backup command failed:"
    log_error "${local_backup_out}"
    exit 1
fi

if [ ! -f "${TMP_ZIP}" ]; then
    log_error "Hermes backup failed: file ${TMP_ZIP} was not created."
    exit 1
fi

raw_zip_bytes=$(stat -c%s "${TMP_ZIP}" 2>/dev/null || du -b "${TMP_ZIP}" | cut -f1)
log_success "Raw ZIP archive created successfully (${raw_zip_bytes} bytes)."

log_step "[2/4] Decompressing and super-compressing to .tar.xz (-9e)..."
mkdir -p "${TMP_EXTRACT}"
unzip -q "${TMP_ZIP}" -d "${TMP_EXTRACT}"
(cd "${TMP_EXTRACT}" && tar -cf - . | xz -9e -c > "${TMP_XZ}")

if [ ! -f "${TMP_XZ}" ]; then
    log_error "Compression failed: ${TMP_XZ} was not created."
    exit 1
fi

xz_bytes=$(stat -c%s "${TMP_XZ}" 2>/dev/null || du -b "${TMP_XZ}" | cut -f1)
log_success "Super-compressed .tar.xz archive created successfully (${xz_bytes} bytes)."

log_step "[3/4] Uploading archive to destination (${DESTINATION})..."
TARGET_REMOTE_FILE="${DESTINATION}${ARCHIVE_NAME}"
rclone_copy_file "${TMP_XZ}" "${TARGET_REMOTE_FILE}"

log_step "Verifying remote upload integrity..."
if ! rclone_verify_object "${TARGET_REMOTE_FILE}"; then
    log_error "Remote verification failed: '${TARGET_REMOTE_FILE}' missing or zero size on remote."
    exit 1
fi
log_success "Remote file upload verified."

log_step "[4/4] Executing GFS retention cleanup..."
cleanup_gfs "${DESTINATION}"

log_success "Hermes backup completed successfully!"
