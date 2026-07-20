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
# CONFIGURATION & PREFLIGHT
# ---------------------------------------------------------------------
REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

case "${REMOTE}" in
    *:) ;;
    */) ;;
    *) REMOTE="${REMOTE}/" ;;
esac

log_step "[1/3] Preflight checks & backup resolution..."

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        log_error "Missing required command: '${cmd}'"
        log_error "Please install '${cmd}' and try again."
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
    log_error "'hermes' binary not found. Set HERMES_BIN=/path/to/hermes or add it to PATH."
    exit 1
fi
log_info "Using Hermes binary: ${HERMES_RESOLVED}"

# Workspace setup
WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/hermes-restore-XXXXXX")"
cleanup() {
    if [ -n "${WORKSPACE}" ] && [ -d "${WORKSPACE}" ]; then
        rm -rf "${WORKSPACE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Target file resolution
TARGET_FILE="${1:-}"

if [ -z "${TARGET_FILE}" ]; then
    log_info "Querying Google Drive (${REMOTE}) for the latest backup..."
    
    list_output=""
    if ! list_output="$(rclone lsf "${REMOTE}" --format "tp" --files-only 2>&1)"; then
        log_error "Failed to query remote '${REMOTE}'."
        log_error "rclone output: ${list_output}"
        exit 1
    fi

    TARGET_FILE="$(echo "${list_output}" | grep -E ';hermes-backup-.*\.(tar\.xz|zip)$' | sort | tail -n1 | cut -d';' -f2- || true)"
    
    if [ -z "${TARGET_FILE}" ]; then
        log_error "No backup files matching 'hermes-backup-*' were found on Google Drive (${REMOTE})."
        exit 1
    fi
    log_success "Latest backup identified: ${TARGET_FILE}"
else
    log_info "Target backup specified manually: ${TARGET_FILE}"
fi

# ---------------------------------------------------------------------
# DOWNLOAD & VERIFICATION
# ---------------------------------------------------------------------
log_step "[2/3] Downloading & preparing backup files..."
TMP_FILE="${WORKSPACE}/${TARGET_FILE}"
TMP_DIR="${WORKSPACE}/extract"
TMP_ZIP="${WORKSPACE}/import_target.zip"

log_info "Downloading backup '${TARGET_FILE}' from ${REMOTE}${TARGET_FILE}..."
if ! rclone copyto "${REMOTE}${TARGET_FILE}" "${TMP_FILE}"; then
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
    log_info "Using .zip archive directly for restore."
    IMPORT_TARGET="${TMP_FILE}"
fi

# ---------------------------------------------------------------------
# RESTORE IMPORT
# ---------------------------------------------------------------------
log_step "[3/3] Restoring database with 'hermes import'..."
log_warn "Starting destructive restore operation with '${HERMES_RESOLVED} import --force'..."

if "${HERMES_RESOLVED}" import --force "${IMPORT_TARGET}"; then
    log_success "Restore completed successfully from backup '${TARGET_FILE}'!"
else
    log_error "Hermes import command failed."
    exit 1
fi
