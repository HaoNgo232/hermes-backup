#!/usr/bin/env bash
# =====================================================================
# Hermes Restore Script
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
    TARGET_FILE="$(rclone lsf "${REMOTE}" --format "tp" --files-only 2>/dev/null | grep -E ';hermes-backup-.*\.zip$' | sort | tail -n1 | cut -d';' -f2-)"
    
    if [ -z "${TARGET_FILE}" ]; then
        log "ERROR: No backup was found on Google Drive."
        exit 1
    fi
fi

TMP_ZIP="/tmp/${TARGET_FILE}"

cleanup() {
    rm -f "${TMP_ZIP}" 2>/dev/null || true
}
trap cleanup EXIT

log "Downloading backup '${TARGET_FILE}' from Google Drive..."
rclone copyto "${REMOTE}${TARGET_FILE}" "${TMP_ZIP}"

if [ ! -f "${TMP_ZIP}" ]; then
    log "ERROR: Failed to download backup file ${TARGET_FILE}"
    exit 1
fi

log "Download complete. Restoring data with 'hermes import'..."
hermes import --force "${TMP_ZIP}"

log "Restore completed successfully from backup '${TARGET_FILE}'."
