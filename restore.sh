#!/usr/bin/env bash
# =====================================================================
# Hermes Restore Script (Supports .tar.xz & .zip Archives + Encryption)
# =====================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LOG_FILE="${RESTORE_LOG_DIR:-${SCRIPT_DIR}/logs}/restore.log"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/hermes.sh"
source "${SCRIPT_DIR}/lib/rclone.sh"
source "${SCRIPT_DIR}/lib/encryption.sh"

TARGET_FILE="${1:-}"

if [ -n "${TARGET_FILE}" ]; then
    # Strict regex validation for backup filename parameter
    if ! [[ "${TARGET_FILE}" =~ ^hermes-backup-[A-Za-z0-9_.-]+\.(tar\.xz|zip)$ ]]; then
        log_error "Invalid backup filename '${TARGET_FILE}'."
        log_error "Expected a hermes-backup-*.tar.xz or hermes-backup-*.zip archive filename."
        exit 1
    fi
    log_info "Target backup specified manually: ${TARGET_FILE}"
fi

rotate_log_file
log_step "[1/3] Preflight checks & backup resolution..."

require_command rclone
require_command zip
require_command tar
require_command date
require_command sha256sum

hermes_apply_persisted_environment

if ! HERMES_RESOLVED="$(hermes_resolve_binary)"; then
    exit 1
fi
log_info "Using Hermes binary: ${HERMES_RESOLVED}"

SOURCE="$(encryption_get_active_source)"
log_info "Resolved active restore source: ${SOURCE}"

WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/hermes-restore-XXXXXX")"
cleanup() {
    if [ -n "${WORKSPACE}" ] && [ -d "${WORKSPACE}" ]; then
        rm -rf "${WORKSPACE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ -z "${TARGET_FILE}" ]; then
    log_info "Querying active source (${SOURCE}) for the latest backup..."

    raw_list="$(rclone_list_backups "${SOURCE}")"
    latest_entry="$(echo "${raw_list}" | tail -n1 || true)"

    if [ -n "${latest_entry}" ]; then
        IFS=';' read -r _t_str TARGET_FILE _s_bytes <<< "${latest_entry}"
    fi

    if [ -z "${TARGET_FILE:-}" ]; then
        log_error "No backup files matching 'hermes-backup-*' were found on active source (${SOURCE})."
        exit 1
    fi
    log_success "Latest backup identified: ${TARGET_FILE}"
fi

# ---------------------------------------------------------------------
# DOWNLOAD & DECRYPTION
# ---------------------------------------------------------------------
log_step "[2/3] Downloading & preparing backup files..."
TMP_FILE="${WORKSPACE}/${TARGET_FILE}"
TMP_DIR="${WORKSPACE}/extract"
TMP_ZIP="${WORKSPACE}/import_target.zip"

log_info "Downloading backup '${TARGET_FILE}' from ${SOURCE}${TARGET_FILE}..."
if ! rclone_fetch_file "${SOURCE}${TARGET_FILE}" "${TMP_FILE}"; then
    log_error "Download command failed for file ${TARGET_FILE}"
    exit 1
fi

if [ ! -f "${TMP_FILE}" ]; then
    log_error "Downloaded backup file was not found at ${TMP_FILE}"
    exit 1
fi

dl_bytes=$(stat -c%s "${TMP_FILE}" 2>/dev/null || du -b "${TMP_FILE}" | cut -f1)
if [ "${dl_bytes}" -le 0 ]; then
    log_error "Downloaded backup file ${TARGET_FILE} is empty (0 bytes)."
    exit 1
fi

log_success "Download complete ($(format_bytes "${dl_bytes}"))."

TMP_MANIFEST="${WORKSPACE}/${TARGET_FILE}.sha256"
log_step "Verifying archive integrity manifest..."
if rclone_fetch_file "${SOURCE}${TARGET_FILE}.sha256" "${TMP_MANIFEST}" 2>/dev/null && [ -f "${TMP_MANIFEST}" ]; then
    log_info "Integrity manifest '${TARGET_FILE}.sha256' downloaded successfully."
    expected_hash="$(awk '{print $1}' "${TMP_MANIFEST}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || echo "")"
    if ! [[ "${expected_hash}" =~ ^[a-f0-9]{64}$ ]]; then
        log_error "Malformed integrity manifest '${TARGET_FILE}.sha256': expected a 64-character SHA-256 hash."
        exit 1
    fi
    actual_hash="$(sha256sum "${TMP_FILE}" | awk '{print $1}' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [ "${actual_hash}" != "${expected_hash}" ]; then
        log_error "INTEGRITY ERROR: SHA-256 checksum mismatch for '${TARGET_FILE}'!"
        log_error "Expected SHA-256 : ${expected_hash}"
        log_error "Computed SHA-256 : ${actual_hash}"
        log_error "Restore aborted to prevent restoring corrupt or tampered backup data."
        exit 1
    fi
    log_success "SHA-256 integrity manifest verified successfully."
else
    log_warn "Legacy backup detected: No integrity manifest ('${TARGET_FILE}.sha256') found on remote source."
    log_warn "Proceeding with restore using basic file size validation."
fi

validate_tar_member_paths() {
    local archive="$1"
    local listing=""
    local member=""
    local normalized=""

    if ! listing="$(tar -tf "${archive}")"; then
        log_error "Unable to inspect archive members."
        return 1
    fi

    while IFS= read -r member || [ -n "${member}" ]; do
        normalized="${member#./}"

        if [ -z "${normalized}" ]; then
            continue
        fi

        if [[ "${normalized}" == /* ]] ||
           [[ "${normalized}" == ".." ]] ||
           [[ "${normalized}" == ../* ]] ||
           [[ "${normalized}" == */../* ]] ||
           [[ "${normalized}" == */.. ]]; then
            log_error "Unsafe archive member path detected."
            return 1
        fi
    done <<< "${listing}"

    return 0
}

if [[ "${TARGET_FILE}" == *.tar.xz ]]; then
    require_command xz
    log_info "Decompressing .tar.xz archive..."
    if ! validate_tar_member_paths "${TMP_FILE}"; then
        log_error "Archive path validation failed for '${TARGET_FILE}'."
        exit 1
    fi
    mkdir -p "${TMP_DIR}"
    tar -xf "${TMP_FILE}" -C "${TMP_DIR}"
    (cd "${TMP_DIR}" && zip -r -q "${TMP_ZIP}" .)
    IMPORT_TARGET="${TMP_ZIP}"
else
    IMPORT_TARGET="${TMP_FILE}"
fi

# ---------------------------------------------------------------------
# HERMES IMPORT EXECUTION
# ---------------------------------------------------------------------
log_step "[3/3] Importing backup into Hermes state..."
log_info "Executing: ${HERMES_RESOLVED} import --force ${IMPORT_TARGET}"
"${HERMES_RESOLVED}" import --force "${IMPORT_TARGET}"

log_success "Hermes backup restore completed successfully!"
