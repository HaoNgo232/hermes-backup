#!/usr/bin/env bash
# =====================================================================
# lib/state.sh - Persistent Application State Manager
# =====================================================================
set -Eeuo pipefail

STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${STATE_LIB_DIR}/common.sh" ]; then
    source "${STATE_LIB_DIR}/common.sh"
fi

STATE_SCHEMA_VERSION_DEFAULT="1"
declare -A APP_STATE=()
STATE_LOADED=false

state_ensure_dir() {
    mkdir -p "${APP_CONFIG_DIR}"
    chmod 0700 "${APP_CONFIG_DIR}" 2>/dev/null || true
    verify_permissions "${APP_CONFIG_DIR}" "700" || true
}

state_init_defaults() {
    APP_STATE["STATE_SCHEMA_VERSION"]="${STATE_SCHEMA_VERSION_DEFAULT}"
    APP_STATE["ENCRYPTION_ENABLED"]="false"
    APP_STATE["ENCRYPTION_MODE"]="none"
    APP_STATE["BASE_REMOTE"]="${BACKUP_REMOTE:-gdrive-hermes:}"
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
        verify_permissions "${APP_STATE_FILE}" "600" || true
        local line_count=0
        while IFS='=' read -r key value || [ -n "${key}" ]; do
            [[ "${key}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key}" ]] && continue
            
            key="$(echo "${key}" | xargs)"
            value="$(echo "${value:-}" | xargs)"
            
            if [ -n "${key}" ]; then
                APP_STATE["${key}"]="${value}"
                line_count=$((line_count + 1))
            fi
        done < "${APP_STATE_FILE}"

        if [ "${line_count}" -eq 0 ]; then
            log_error "State file '${APP_STATE_FILE}' exists but is empty or corrupted."
            exit 1
        fi
    else
        # Spec invariant check: Never assume missing state file means encryption can be safely disabled if crypt remote exists
        if command -v rclone &>/dev/null; then
            if rclone listremotes 2>/dev/null | grep -i -q "^hermes-backup-crypt:"; then
                log_error "[ERR] Application state file '${APP_STATE_FILE}' is missing, but crypt remote 'hermes-backup-crypt:' was found in rclone config."
                log_error "[ERR] Process stopped to prevent an unencrypted plaintext cloud upload."
                log_info "[INFO] Please run ./setup.sh to restore or re-initialize application state."
                exit 1
            fi
        fi
    fi

    STATE_LOADED=true
    state_validate
}

state_validate() {
    local schema_ver="${APP_STATE["STATE_SCHEMA_VERSION"]:-1}"
    local enc_enabled="${APP_STATE["ENCRYPTION_ENABLED"]:-false}"
    local enc_mode="${APP_STATE["ENCRYPTION_MODE"]:-none}"
    local notice_state="${APP_STATE["RECOVERY_NOTICE_STATE"]:-shown}"
    local crypt_remote="${APP_STATE["CRYPT_REMOTE"]:-}"
    local base_remote="${APP_STATE["BASE_REMOTE"]:-}"

    if [ "${schema_ver}" != "1" ]; then
        log_error "Unsupported state schema version '${schema_ver}'."
        exit 1
    fi

    if ! is_boolean "${enc_enabled}"; then
        log_error "Invalid state file: ENCRYPTION_ENABLED must be 'true' or 'false' (got '${enc_enabled}')."
        exit 1
    fi

    if [[ "${enc_mode}" != "none" && "${enc_mode}" != "rclone-crypt" ]]; then
        log_error "Invalid state file: ENCRYPTION_MODE must be 'none' or 'rclone-crypt' (got '${enc_mode}')."
        exit 1
    fi

    if [[ "${notice_state}" != "pending" && "${notice_state}" != "shown" ]]; then
        log_error "Invalid state file: RECOVERY_NOTICE_STATE must be 'pending' or 'shown' (got '${notice_state}')."
        exit 1
    fi

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
        if [ -z "${base_remote}" ]; then
            log_error "[ERR] Encryption state is inconsistent: BASE_REMOTE is missing."
            exit 1
        fi
    else
        if [ "${enc_mode}" != "none" ]; then
            log_error "[ERR] Invalid state file: ENCRYPTION_ENABLED is false but ENCRYPTION_MODE is '${enc_mode}'."
            exit 1
        fi
        if [ -n "${crypt_remote}" ]; then
            log_error "[ERR] Invalid state file: ENCRYPTION_ENABLED is false but CRYPT_REMOTE is set to '${crypt_remote}'."
            exit 1
        fi
    fi
}

state_get() {
    local key="$1"
    local default_val="${2:-}"
    if [ "${STATE_LOADED}" = false ]; then
        state_load
    fi
    echo "${APP_STATE["${key}"]:-${default_val}}"
}

state_set() {
    local key="$1"
    local val="$2"
    if [ "${STATE_LOADED}" = false ]; then
        state_load
    fi
    APP_STATE["${key}"]="${val}"
    state_save
}

state_set_many() {
    if [ "${STATE_LOADED}" = false ]; then
        state_load
    fi
    while [ $# -gt 1 ]; do
        local key="$1"
        local val="$2"
        APP_STATE["${key}"]="${val}"
        shift 2
    done
    state_save
}

state_save() {
    state_ensure_dir
    state_validate

    local buffer="# hermes-backup state file - DO NOT EDIT MANUALLY\n"
    for k in "${!APP_STATE[@]}"; do
        buffer+="${k}=${APP_STATE[$k]}\n"
    done

    local sorted_buffer
    sorted_buffer="$(printf "%b" "${buffer}" | sort)"

    atomic_write_file "${APP_STATE_FILE}" "${sorted_buffer}" 0600
}
