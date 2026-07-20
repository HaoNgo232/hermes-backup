#!/usr/bin/env bash
# =====================================================================
# lib/common.sh - Shared Generic Utilities
# =====================================================================
set -Eeuo pipefail

if [ "${HERMES_COMMON_SH_LOADED:-false}" = "true" ]; then
    return 0
fi
HERMES_COMMON_SH_LOADED=true

COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${COMMON_LIB_DIR}/.." && pwd)"

# Application config and state paths
APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hermes-backup"
# shellcheck disable=SC2034
APP_STATE_FILE="${APP_CONFIG_DIR}/state.env"

# shellcheck disable=SC2034
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_FILE:-}"

# Terminal color and formatting
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
    BADGE_OK="\033[0;32m[ OK ]\033[0m"
    BADGE_ERR="\033[0;31m[ FAIL ]\033[0m"
    # shellcheck disable=SC2034
    BADGE_WARN="\033[0;33m[ WARN ]\033[0m"
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
    BADGE_OK="[ OK ]"
    BADGE_ERR="[ FAIL ]"
    # shellcheck disable=SC2034
    BADGE_WARN="[ WARN ]"
fi

strip_ansi() {
    sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g'
}

# ALL log output MUST go to stderr (>&2) to preserve clean stdout for function returns
log_raw() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${timestamp} - $*" >&2
    if [ -n "${LOG_FILE:-}" ]; then
        local log_dir
        log_dir="$(dirname "${LOG_FILE}")"
        mkdir -p "${log_dir}"
        chmod 0700 "${log_dir}" 2>/dev/null || true
        echo -e "${timestamp} - $*" | strip_ansi >> "${LOG_FILE}"
    fi
}

rotate_log_file() {
    local max_lines="${MAX_LOG_LINES:-5000}"
    local keep_lines="${KEEP_LOG_LINES:-2000}"
    if [ -n "${LOG_FILE:-}" ] && [ -f "${LOG_FILE}" ]; then
        local current_lines
        current_lines=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
        if [ "${current_lines}" -gt "${max_lines}" ]; then
            local tmp_log="${LOG_FILE}.tmp"
            echo "$(date '+%Y-%m-%d %H:%M:%S') - [INFO] Log file exceeded ${max_lines} lines (${current_lines} lines). Truncating to last ${keep_lines} lines." > "${tmp_log}"
            tail -n "${keep_lines}" "${LOG_FILE}" >> "${tmp_log}"
            atomic_write_file "${LOG_FILE}" "$(cat "${tmp_log}")" 0600
            rm -f "${tmp_log}" 2>/dev/null || true
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

verify_permissions() {
    local target="$1"
    local expected="$2"
    expected="${expected#0}"
    local actual
    actual="$(stat -c "%a" "${target}" 2>/dev/null || stat -f "%Lp" "${target}" 2>/dev/null || echo "")"
    actual="${actual#0}"
    if [ "${actual}" != "${expected}" ]; then
        log_error "Permission enforcement failed on '${target}': expected permissions ${expected}, got '${actual}'."
        return 1
    fi
    return 0
}

# Enforce 0700 permissions on config directory (Fail-closed: NO || true)
mkdir -p "${APP_CONFIG_DIR}"
chmod 0700 "${APP_CONFIG_DIR}"
verify_permissions "${APP_CONFIG_DIR}" "700"

is_interactive_tty() {
    [ -t 0 ] && [ -t 1 ] && [ -t 2 ]
}

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        log_error "Missing required command: '${cmd}'"
        log_error "Please install '${cmd}' and try again."
        exit 1
    fi
}

check_cmd() {
    local cmd="$1"
    if command -v "${cmd}" &>/dev/null; then
        echo -e "  ${BADGE_OK} ${cmd}" >&2
        return 0
    else
        echo -e "  ${BADGE_ERR} ${C_RED}Missing command '${cmd}'${C_RESET}" >&2
        return 1
    fi
}

atomic_write_file() {
    local target_file="$1"
    local mode="${3:-0600}"

    local parent_dir
    parent_dir="$(dirname "${target_file}")"
    mkdir -p "${parent_dir}"
    chmod 0700 "${parent_dir}"

    local tmp_file
    tmp_file="$(mktemp "${parent_dir}/tmp.XXXXXX")"

    if [ $# -ge 2 ]; then
        printf "%s" "${2:-}" > "${tmp_file}"
    else
        cat > "${tmp_file}"
    fi

    chmod "${mode}" "${tmp_file}"
    verify_permissions "${tmp_file}" "${mode}"
    mv -f "${tmp_file}" "${target_file}"
    verify_permissions "${target_file}" "${mode}"
}

is_boolean() {
    local val="$1"
    [[ "${val}" == "true" || "${val}" == "false" ]]
}

acquire_backup_lock() {
    local lock_file="$1"
    local lock_dir
    lock_dir="$(dirname "${lock_file}")"
    mkdir -p "${lock_dir}"

    exec 9>"${lock_file}"
    if ! flock -n 9; then
        log_info "Another backup process is running; skipping execution."
        exit 0
    fi
}
