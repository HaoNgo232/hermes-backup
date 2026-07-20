#!/usr/bin/env bash
# =====================================================================
# Hermes Restore Script (Supports .tar.xz super-compressed backups & .zip)
# Automatically downloads and restores the latest backup from Google Drive
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/restore.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_FILE}"
}

REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

# Ensure REMOTE ends with / when it contains a folder path
case "${REMOTE}" in
    *:) ;;
    */) ;;
    *) REMOTE="${REMOTE}/" ;;
esac

TARGET_FILE="${1:-}"

if [ -z "${TARGET_FILE}" ]; then
    log "Finding the latest backup on Google Drive (${REMOTE})..."
    TARGET_FILE="$(rclone lsf "${REMOTE}" --format "tp" --files-only 2>/dev/null | grep -E ';hermes-backup-.*\.(tar\.xz|zip)$' | sort | tail -n1 | cut -d';' -f2-)"
    
    if [ -z "${TARGET_FILE}" ]; then
        log "ERROR: No backup was found on Google Drive."
        exit 1
    fi
fi

TMP_FILE="/tmp/${TARGET_FILE}"
TMP_DIR="/tmp/hermes_restore_dir_$$"
TMP_ZIP="/tmp/hermes_restore_import_$$.zip"

cleanup() {
    rm -rf "${TMP_FILE}" "${TMP_DIR}" "${TMP_ZIP}" 2>/dev/null || true
}
trap cleanup EXIT

log "Downloading backup '${TARGET_FILE}' from Google Drive..."
rclone copyto "${REMOTE}${TARGET_FILE}" "${TMP_FILE}"

if [ ! -f "${TMP_FILE}" ]; then
    log "ERROR: Failed to download backup file ${TARGET_FILE}"
    exit 1
fi

log "Download complete. Preparing files for 'hermes import'..."

if [[ "${TARGET_FILE}" == *.tar.xz ]]; then
    log "Decompressing .tar.xz archive..."
    mkdir -p "${TMP_DIR}"
    tar -xf "${TMP_FILE}" -C "${TMP_DIR}"
    (cd "${TMP_DIR}" && zip -r -q "${TMP_ZIP}" .)
    IMPORT_TARGET="${TMP_ZIP}"
else
    IMPORT_TARGET="${TMP_FILE}"
fi

log "Restoring data with 'hermes import'..."
hermes import --force "${IMPORT_TARGET}"

log "Restore completed successfully from backup '${TARGET_FILE}'."
