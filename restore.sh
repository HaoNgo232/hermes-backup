#!/usr/bin/env bash
# =====================================================================
# Hermes Restore Script (Supports .tar.xz & .zip Archives + Encryption)
# =====================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/rclone.sh"
source "${SCRIPT_DIR}/lib/encryption.sh"

rotate_log_file
log_step "[1/3] Preflight checks & backup resolution..."

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
    log_error "'hermes' binary not found. Set HERMES_BIN=/path/to/hermes or add it to PATH."
    exit 1
fi
log_info "Using Hermes binary: ${HERMES_RESOLVED}"

# Resolve active source (Plaintext vs Crypt Remote)
SOURCE="$(encryption_get_active_source)"
log_info "Resolved active restore source: ${SOURCE}"

# Workspace setup
WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/hermes-restore-XXXXXX")"
cleanup() {
    if [ -n "${WORKSPACE}" ] && [ -d "${WORKSPACE}" ]; then
        rm -rf "${WORKSPACE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

TARGET_FILE="${1:-}"

if [ -z "${TARGET_FILE}" ]; then
    log_info "Querying active source (${SOURCE}) for the latest backup..."

    list_output="$(rclone_list_backups "${SOURCE}")"
    TARGET_FILE="$(echo "${list_output}" | grep -E ';hermes-backup-.*\.(tar\.xz|zip)$' | sort | tail -n1 | cut -d';' -f2- || true)"

    if [ -z "${TARGET_FILE}" ]; then
        log_error "No backup files matching 'hermes-backup-*' were found on active source (${SOURCE})."
        exit 1
    fi
    log_success "Latest backup identified: ${TARGET_FILE}"
else
    log_info "Target backup specified manually: ${TARGET_FILE}"
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

log_success "Download complete (${dl_bytes} bytes)."

if [[ "${TARGET_FILE}" == *.tar.xz ]]; then
    log_info "Decompressing .tar.xz archive..."
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
