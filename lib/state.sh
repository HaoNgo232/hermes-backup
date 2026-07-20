#!/usr/bin/env bash
# =====================================================================
# lib/state.sh - Persistent Application State Manager
# =====================================================================
set -Eeuo pipefail

if [ "${HERMES_STATE_SH_LOADED:-false}" = "true" ]; then
    return 0
fi
HERMES_STATE_SH_LOADED=true

STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${STATE_LIB_DIR}/common.sh" ]; then
    source "${STATE_LIB_DIR}/common.sh"
fi

STATE_SCHEMA_VERSION_DEFAULT="1"
declare -A APP_STATE=()
STATE_LOADED=false

state_ensure_dir() {
    mkdir -p "${APP_CONFIG_DIR}"
    chmod 0700 "${APP_CONFIG_DIR}"
    verify_permissions "${APP_CONFIG_DIR}" "700"
}

state_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

state_key_is_allowed() {
    case "$1" in
        STATE_SCHEMA_VERSION|\
        ENCRYPTION_ENABLED|\
        ENCRYPTION_MODE|\
        BASE_REMOTE|\
        BASE_PATH|\
        CRYPT_REMOTE|\
        CRYPT_PATH|\
        RECOVERY_NOTICE_STATE|\
        ENCRYPTION_SETUP_COMPLETED_AT|\
        HERMES_HOME|\
        HERMES_BIN)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

state_value_is_safe() {
    local value="$1"
    [[ "${value}" != *$'\n'* && "${value}" != *$'\r'* ]]
}

state_validate_assignment() {
    local key="$1"
    local value="$2"

    if ! state_key_is_allowed "${key}"; then
        log_error "Refusing to set unknown state key '${key}'."
        return 1
    fi

    if ! state_value_is_safe "${value}"; then
        log_error "Refusing unsafe value for state key '${key}'."
        return 1
    fi
}

state_init_defaults() {
    local default_backup_remote="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"
    local parsed_remote="gdrive-hermes:"
    local parsed_path="HermesBackups"

    if command -v rclone_parse_remote_and_path &>/dev/null; then
        local parsed
        parsed="$(rclone_parse_remote_and_path "${default_backup_remote}")"
        parsed_remote="${parsed%%|*}"
        parsed_path="${parsed#*|}"
    else
        parsed_remote="${default_backup_remote%%:*}"
        if [ "${parsed_remote}" != "${default_backup_remote}" ]; then
            parsed_remote="${parsed_remote}:"
            parsed_path="${default_backup_remote#*:}"
        else
            parsed_remote="gdrive-hermes:"
            parsed_path="HermesBackups"
        fi
    fi

    [ -z "${parsed_remote}" ] && parsed_remote="gdrive-hermes:"
    [ -z "${parsed_path}" ] && parsed_path="HermesBackups"

    APP_STATE["STATE_SCHEMA_VERSION"]="${STATE_SCHEMA_VERSION_DEFAULT}"
    APP_STATE["ENCRYPTION_ENABLED"]="false"
    APP_STATE["ENCRYPTION_MODE"]="none"
    APP_STATE["BASE_REMOTE"]="${parsed_remote}"
    APP_STATE["BASE_PATH"]="${parsed_path%/}"
    APP_STATE["CRYPT_REMOTE"]=""
    APP_STATE["CRYPT_PATH"]=""
    APP_STATE["RECOVERY_NOTICE_STATE"]="shown"
    APP_STATE["ENCRYPTION_SETUP_COMPLETED_AT"]=""
    APP_STATE["HERMES_HOME"]=""
    APP_STATE["HERMES_BIN"]=""
}

state_load() {
    state_ensure_dir
    state_init_defaults

    if [ -f "${APP_STATE_FILE}" ]; then
        chmod 0600 "${APP_STATE_FILE}"
        verify_permissions "${APP_STATE_FILE}" "600"

        local line_count=0
        declare -A seen_keys=()

        while IFS= read -r line || [ -n "${line}" ]; do
            [[ -z "${line}" ]] && continue
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue

            if [[ "${line}" != *=* ]]; then
                log_error "Invalid state file: line without '='."
                exit 1
            fi

            local key="${line%%=*}"
            local value="${line#*=}"
            key="$(state_trim "${key}")"

            if ! [[ "${key}" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
                log_error "Invalid state key syntax '${key}'."
                exit 1
            fi

            if ! state_key_is_allowed "${key}"; then
                log_error "Invalid state file: Unknown key '${key}'."
                exit 1
            fi

            if ! state_value_is_safe "${value}"; then
                log_error "Invalid state file: Key '${key}' contains unsafe newline or carriage return characters."
                exit 1
            fi

            if [[ -v "seen_keys[${key}]" ]]; then
                log_error "Invalid state file: Duplicate key '${key}'."
                exit 1
            fi
            seen_keys["${key}"]=1

            APP_STATE["${key}"]="${value}"
            line_count=$((line_count + 1))
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
        return 1
    fi

    if ! is_boolean "${enc_enabled}"; then
        log_error "Invalid state file: ENCRYPTION_ENABLED must be 'true' or 'false' (got '${enc_enabled}')."
        return 1
    fi

    if [[ "${enc_mode}" != "none" && "${enc_mode}" != "rclone-crypt" ]]; then
        log_error "Invalid state file: ENCRYPTION_MODE must be 'none' or 'rclone-crypt' (got '${enc_mode}')."
        return 1
    fi

    if [[ "${notice_state}" != "pending" && "${notice_state}" != "shown" ]]; then
        log_error "Invalid state file: RECOVERY_NOTICE_STATE must be 'pending' or 'shown' (got '${notice_state}')."
        return 1
    fi

    if [ "${enc_enabled}" = "true" ]; then
        if [ "${enc_mode}" != "rclone-crypt" ]; then
            log_error "[ERR] Encryption state is inconsistent: ENCRYPTION_ENABLED is true but ENCRYPTION_MODE is '${enc_mode}'."
            log_error "[ERR] Operation aborted to avoid accidental plaintext upload."
            return 1
        fi
        if [ -z "${crypt_remote}" ]; then
            log_error "[ERR] Encryption state is inconsistent: CRYPT_REMOTE is missing."
            log_error "[ERR] Backup was not started to avoid an accidental plaintext upload."
            return 1
        fi
        if [ -z "${base_remote}" ]; then
            log_error "[ERR] Encryption state is inconsistent: BASE_REMOTE is missing."
            return 1
        fi
    else
        if [ "${enc_mode}" != "none" ]; then
            log_error "[ERR] Invalid state file: ENCRYPTION_ENABLED is false but ENCRYPTION_MODE is '${enc_mode}'."
            return 1
        fi
        if [ -n "${crypt_remote}" ]; then
            log_error "[ERR] Invalid state file: ENCRYPTION_ENABLED is false but CRYPT_REMOTE is set to '${crypt_remote}'."
            return 1
        fi
    fi
    return 0
}

state_get() {
    local key="$1"
    local default_val="${2:-}"
    if [ "${STATE_LOADED}" = false ]; then
        state_load
    fi
    if [[ -v "APP_STATE[${key}]" ]]; then
        printf '%s\n' "${APP_STATE[${key}]}"
    else
        printf '%s\n' "${default_val}"
    fi
}

state_set() {
    local key="$1"
    local val="$2"
    state_validate_assignment "${key}" "${val}" || return 1

    if [ "${STATE_LOADED}" = false ]; then
        state_load
    fi

    local old_set=false
    local old_val=""
    if [[ -v "APP_STATE[${key}]" ]]; then
        old_set=true
        old_val="${APP_STATE[${key}]}"
    fi

    APP_STATE["${key}"]="${val}"

    if ! state_save; then
        if [ "${old_set}" = true ]; then
            APP_STATE["${key}"]="${old_val}"
        else
            unset "APP_STATE[${key}]"
        fi
        return 1
    fi
}

state_set_many() {
    if [ "${STATE_LOADED}" = false ]; then
        state_load
    fi

    if [ $(( $# % 2 )) -ne 0 ]; then
        log_error "state_set_many requires key/value pairs."
        return 1
    fi

    local -a keys=()
    local -a vals=()
    while [ $# -gt 1 ]; do
        local k="$1"
        local v="$2"
        state_validate_assignment "${k}" "${v}" || return 1
        keys+=("${k}")
        vals+=("${v}")
        shift 2
    done

    declare -A old_state=()
    for k in "${!APP_STATE[@]}"; do
        old_state["${k}"]="${APP_STATE[${k}]}"
    done

    for idx in "${!keys[@]}"; do
        APP_STATE["${keys[$idx]}"]="${vals[$idx]}"
    done

    if ! state_save; then
        APP_STATE=()
        for k in "${!old_state[@]}"; do
            APP_STATE["${k}"]="${old_state[${k}]}"
        done
        return 1
    fi
}

state_save() {
    state_ensure_dir
    state_validate || return 1

    local buffer="# hermes-backup state file - DO NOT EDIT MANUALLY"$'\n'
    local k

    while IFS= read -r k; do
        [ -z "${k}" ] && continue
        buffer+="${k}=${APP_STATE[${k}]}"$'\n'
    done < <(printf '%s\n' "${!APP_STATE[@]}" | LC_ALL=C sort)

    atomic_write_file "${APP_STATE_FILE}" "${buffer}" 0600
}
