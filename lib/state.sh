#!/usr/bin/env bash
# =====================================================================
# lib/state.sh - Persistent Application State Manager
# =====================================================================
set -Eeuo pipefail

# Depend on lib/common.sh
STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${STATE_LIB_DIR}/common.sh" ]; then
    source "${STATE_LIB_DIR}/common.sh"
fi

STATE_SCHEMA_VERSION_DEFAULT="1"

# Internal memory state map (as standard bash variables with STATE_PREFIX)
declare -A APP_STATE=()

state_ensure_dir() {
    mkdir -p "${APP_CONFIG_DIR}"
    chmod 0700 "${APP_CONFIG_DIR}" 2>/dev/null || true
}

state_init_defaults() {
    APP_STATE["STATE_SCHEMA_VERSION"]="${STATE_SCHEMA_VERSION_DEFAULT}"
    APP_STATE["ENCRYPTION_ENABLED"]="false"
    APP_STATE["ENCRYPTION_MODE"]="none"
    APP_STATE["BASE_REMOTE"]="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"
    APP_STATE["BASE_PATH"]="HermesBackups"
    APP_STATE["CRYPT_REMOTE"]=""
    APP_STATE["CRYPT_PATH"]=""
    APP_STATE["RECOVERY_NOTICE_STATE"]="shown"
    APP_STATE["ENCRYPTION_SETUP_COMPLETED_AT"]=""
}

state_load() {
    state_ensure_dir
    state_init_defaults

    if [ -f "${APP_STATE_FILE}" ]; then
        chmod 0600 "${APP_STATE_FILE}" 2>/dev/null || true
        while IFS='=' read -r key value || [ -n "${key}" ]; do
            # Skip comments and empty lines
            [[ "${key}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key}" ]] && continue
            
            # Trim whitespace
            key="$(echo "${key}" | xargs)"
            value="$(echo "${value:-}" | xargs)"
            
            if [ -n "${key}" ]; then
                APP_STATE["${key}"]="${value}"
            fi
        done < "${APP_STATE_FILE}"
    fi

    state_validate
}

state_validate() {
    local enc_enabled="${APP_STATE["ENCRYPTION_ENABLED"]:-false}"
    local enc_mode="${APP_STATE["ENCRYPTION_MODE"]:-none}"
    local notice_state="${APP_STATE["RECOVERY_NOTICE_STATE"]:-shown}"
    local crypt_remote="${APP_STATE["CRYPT_REMOTE"]:-}"

    # Validate boolean format
    if ! is_boolean "${enc_enabled}"; then
        log_error "Invalid state file: ENCRYPTION_ENABLED must be 'true' or 'false' (got '${enc_enabled}')."
        exit 1
    fi

    # Validate mode
    if [[ "${enc_mode}" != "none" && "${enc_mode}" != "rclone-crypt" ]]; then
        log_error "Invalid state file: ENCRYPTION_MODE must be 'none' or 'rclone-crypt' (got '${enc_mode}')."
        exit 1
    fi

    # Validate notice state
    if [[ "${notice_state}" != "pending" && "${notice_state}" != "shown" ]]; then
        log_error "Invalid state file: RECOVERY_NOTICE_STATE must be 'pending' or 'shown' (got '${notice_state}')."
        exit 1
    fi

    # Check state consistency (fail closed)
    if [ "${enc_enabled}" = "true" ]; then
        if [ "${enc_mode}" != "rclone-crypt" ]; then
            log_error "[ERR] Encryption state is inconsistent: ENCRYPTION_ENABLED is true but ENCRYPTION_MODE is '${enc_mode}'."
            log_error "[ERR] Operation aborted to avoid accidental plaintext upload."
            exit 1
        fi
        if [ -z "${crypt_remote}" ]; then
            log_error "[ERR] Encryption state is inconsistent: CRYPT_REMOTE is missing."
            log_error "[ERR] Backup was not started to avoid an accidental plaintext upload."
            exit 1
        fi
    fi
}

state_get() {
    local key="$1"
    local default_val="${2:-}"
    if [ ${#APP_STATE[@]} -eq 0 ]; then
        state_load
    fi
    echo "${APP_STATE["${key}"]:-${default_val}}"
}

state_set() {
    local key="$1"
    local val="$2"
    if [ ${#APP_STATE[@]} -eq 0 ]; then
        state_load
    fi
    APP_STATE["${key}"]="${val}"
    state_save
}

state_save() {
    state_ensure_dir
    state_validate

    local buffer="# hermes-backup state file - DO NOT EDIT MANUALLY\n"
    for k in "${!APP_STATE[@]}"; do
        buffer+="${k}=${APP_STATE[$k]}\n"
    done

    # Sort keys for clean output
    local sorted_buffer
    sorted_buffer="$(printf "%b" "${buffer}" | sort)"

    atomic_write_file "${APP_STATE_FILE}" "${sorted_buffer}" 0600
}
