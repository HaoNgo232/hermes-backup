#!/usr/bin/env bash
# =====================================================================
# Hermes Restore Script (Supports .tar.xz super-compressed backups & .zip)
# Automatically downloads and restores the latest backup from Google Drive
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${RESTORE_LOG_DIR:-${SCRIPT_DIR}/logs}"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/restore.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_FILE}"
}

REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

case "${REMOTE}" in
    *:) ;;
    */) ;;
    *) REMOTE="${REMOTE}/" ;;
esac

# ---------------------------------------------------------------------
# PREFLIGHT CHECKS
# ---------------------------------------------------------------------
require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        log "ERROR: Missing required command: '${cmd}'"
        log "Please install '${cmd}' and try again."
        exit 1
    fi
}

require_command rclone
require_command zip
require_command tar
require_command xz
require_command date

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

# ---------------------------------------------------------------------
# WORKSPACE & CLEANUP
# ---------------------------------------------------------------------
WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/hermes-restore-XXXXXX")"
cleanup() {
    if [ -n "${WORKSPACE}" ] && [ -d "${WORKSPACE}" ]; then
        rm -rf "${WORKSPACE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# TARGET FILE RESOLUTION
# ---------------------------------------------------------------------
TARGET_FILE="${1:-}"

if [ -z "${TARGET_FILE}" ]; then
    log "Querying Google Drive (${REMOTE}) for the latest backup..."
    
    list_output=""
    if ! list_output="$(rclone lsf "${REMOTE}" --format "tp" --files-only 2>&1)"; then
        log "ERROR: Failed to query remote '${REMOTE}'."
        log "ERROR: rclone output: ${list_output}"
        exit 1
    fi

    TARGET_FILE="$(echo "${list_output}" | grep -E ';hermes-backup-.*\.(tar\.xz|zip)$' | sort | tail -n1 | cut -d';' -f2- || true)"
    
    if [ -z "${TARGET_FILE}" ]; then
        log "ERROR: No backup files matching 'hermes-backup-*' were found on Google Drive (${REMOTE})."
        exit 1
    fi
    log "Latest backup identified: ${TARGET_FILE}"
fi

# ---------------------------------------------------------------------
# DOWNLOAD & VERIFICATION
# ---------------------------------------------------------------------
TMP_FILE="${WORKSPACE}/${TARGET_FILE}"
TMP_DIR="${WORKSPACE}/extract"
TMP_ZIP="${WORKSPACE}/import_target.zip"

log "Downloading backup '${TARGET_FILE}' from Google Drive (${REMOTE}${TARGET_FILE})..."
if ! rclone copyto "${REMOTE}${TARGET_FILE}" "${TMP_FILE}"; then
    log "ERROR: Download command failed for file ${TARGET_FILE}"
    exit 1
fi

if [ ! -f "${TMP_FILE}" ]; then
    log "ERROR: Downloaded backup file was not found at ${TMP_FILE}"
    exit 1
fi

dl_bytes=$(stat -c%s "${TMP_FILE}" 2>/dev/null || du -b "${TMP_FILE}" | cut -f1)
if [ "${dl_bytes}" -le 0 ]; then
    log "ERROR: Downloaded backup file ${TARGET_FILE} is empty (0 bytes)."
    exit 1
fi

log "Download complete (${dl_bytes} bytes). Preparing files for 'hermes import'..."

# ---------------------------------------------------------------------
# RESTORE IMPORT
# ---------------------------------------------------------------------
if [[ "${TARGET_FILE}" == *.tar.xz ]]; then
    log "Decompressing .tar.xz archive..."
    mkdir -p "${TMP_DIR}"
    tar -xf "${TMP_FILE}" -C "${TMP_DIR}"
    (cd "${TMP_DIR}" && zip -r -q "${TMP_ZIP}" .)
    IMPORT_TARGET="${TMP_ZIP}"
else
    log "Using .zip archive directly for restore."
    IMPORT_TARGET="${TMP_FILE}"
fi

log "WARNING: Starting destructive restore operation with 'hermes import --force'..."
"${HERMES_RESOLVED}" import --force "${IMPORT_TARGET}"

log "Restore completed successfully from backup '${TARGET_FILE}'."
