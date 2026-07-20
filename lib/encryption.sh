#!/usr/bin/env bash
# =====================================================================
# lib/encryption.sh - Rclone Crypt Integration & Encryption Logic
# =====================================================================
set -Eeuo pipefail

if [ "${HERMES_ENCRYPTION_SH_LOADED:-false}" = "true" ]; then
    return 0
fi
HERMES_ENCRYPTION_SH_LOADED=true

ENC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${ENC_LIB_DIR}/common.sh" ]; then
    source "${ENC_LIB_DIR}/common.sh"
fi
if [ -f "${ENC_LIB_DIR}/state.sh" ]; then
    source "${ENC_LIB_DIR}/state.sh"
fi
if [ -f "${ENC_LIB_DIR}/rclone.sh" ]; then
    source "${ENC_LIB_DIR}/rclone.sh"
fi

DEFAULT_CRYPT_REMOTE_NAME="hermes-backup-crypt"
DEFAULT_CRYPT_FOLDER="HermesBackupsEncrypted"

encryption_is_enabled() {
    local enabled
    enabled="$(state_get "ENCRYPTION_ENABLED" "false")"
    [ "${enabled}" = "true" ]
}

encryption_is_crypt_remote() {
    local remote_name="$1"
    remote_name="${remote_name%%:*}"
    if [ -z "${remote_name}" ]; then
        return 1
    fi
    rclone config show "${remote_name}" 2>/dev/null | grep -i -q "type = crypt"
}

encryption_validate_crypt_remote() {
    local crypt_remote="$1"
    local expected_base_target="${2:-}"

    local remote_name="${crypt_remote%%:*}"
    if [ -z "${remote_name}" ]; then
        log_error "Crypt remote string '${crypt_remote}' is invalid."
        return 1
    fi

    if ! rclone_has_remote "${remote_name}"; then
        log_error "Crypt remote '${remote_name}:' does not exist in rclone configuration."
        return 1
    fi

    if ! encryption_is_crypt_remote "${remote_name}"; then
        log_error "Remote '${remote_name}:' is not of type 'crypt'."
        return 1
    fi

    local show_config
    show_config="$(rclone config show "${remote_name}" 2>/dev/null || echo "")"

    # Validate crypt parameters per spec Section 7.2
    if ! echo "${show_config}" | grep -i -q "filename_encryption = standard"; then
        log_error "Crypt remote '${remote_name}:' does not have 'filename_encryption = standard'."
        return 1
    fi

    if ! echo "${show_config}" | grep -i -q "directory_name_encryption = true"; then
        log_error "Crypt remote '${remote_name}:' does not have 'directory_name_encryption = true'."
        return 1
    fi

    # Validate target remote mapping if expected base target is specified
    if [ -n "${expected_base_target}" ]; then
        local configured_target
        configured_target="$(echo "${show_config}" | grep -i "^remote =" | cut -d'=' -f2- || echo "")"
        configured_target="$(state_trim "${configured_target}")"
        local expected_norm
        expected_norm="${expected_base_target%/}"
        local configured_norm
        configured_norm="${configured_target%/}"

        if [ "${configured_norm}" != "${expected_norm}" ]; then
            log_error "Crypt remote '${remote_name}:' points to '${configured_target}' but state expects '${expected_base_target}'."
            return 1
        fi
    fi

    # Verify reachability probe
    if ! rclone lsf "${remote_name}:" --max-depth 1 &>/dev/null; then
        log_error "Crypt remote '${remote_name}:' is unreachable or failed authorization."
        return 1
    fi

    return 0
}

# Reliable 32-character random secret generator (No SIGPIPE under set -o pipefail)
encryption_generate_secret() {
    local raw=""
    if command -v openssl &>/dev/null; then
        raw="$(openssl rand -hex 32 2>/dev/null || true)"
    else
        raw="$(head -c 128 /dev/urandom 2>/dev/null | tr -dc 'a-zA-Z0-9' || true)"
    fi

    if [ "${#raw}" -ge 32 ]; then
        echo "${raw:0:32}"
    else
        local sec="${raw}"
        while [ "${#sec}" -lt 32 ]; do
            sec+=$(head -c 64 /dev/urandom 2>/dev/null | tr -dc 'a-zA-Z0-9' || true)
        done
        echo "${sec:0:32}"
    fi
}

encryption_create_crypt_remote() {
    local base_remote="$1"
    local crypt_remote_name="${2:-${DEFAULT_CRYPT_REMOTE_NAME}}"
    local crypt_folder="${3:-${DEFAULT_CRYPT_FOLDER}}"

    local base_remote_name
    base_remote_name="$(rclone_get_remote_name "${base_remote}")"

    if [ -z "${base_remote_name}" ]; then
        log_error "Base remote '${base_remote}' is invalid."
        return 1
    fi

    # Check base remote connectivity
    if ! rclone_check_remote_root "${base_remote_name}"; then
        log_error "Base remote '${base_remote_name}:' is unreachable. Cannot setup encryption."
        return 1
    fi

    local base_target_endpoint="${base_remote_name}:${crypt_folder}"

    # Writable probe on base remote per spec Section 7.3
    if ! rclone_check_writable_probe "${base_remote_name}:${crypt_folder}/"; then
        log_error "Base remote target '${base_target_endpoint}' is not writable."
        return 1
    fi

    # Check for existing crypt remote (Idempotency matrix Section 8.1)
    if rclone_has_remote "${crypt_remote_name}"; then
        if encryption_is_enabled; then
            local current_crypt
            current_crypt="$(state_get "CRYPT_REMOTE")"
            if [ "${current_crypt%%:*}" = "${crypt_remote_name}" ]; then
                log_warn "Crypt remote '${crypt_remote_name}:' already configured for application state."
                # shellcheck disable=SC2034
                GEN_CRYPT_PASSWORD=""
                # shellcheck disable=SC2034
                GEN_CRYPT_SALT=""
                # shellcheck disable=SC2034
                GEN_CRYPT_REMOTE="${crypt_remote_name}:"
                # shellcheck disable=SC2034
                GEN_BASE_PATH="${crypt_folder}"
                return 0
            fi
        fi

        # Orphan crypt remote exists but app state does not (must fail closed per spec Section 8.1)
        log_error "[ERR] rclone remote '${crypt_remote_name}:' already exists, but application state is not configured for encryption."
        log_error "[ERR] Setup will not overwrite or adopt an existing unlinked crypt remote automatically."
        log_info "[INFO] Please remove or rename '${crypt_remote_name}:' in rclone.conf or repair state.env manually."
        return 1
    fi

    # Generate random recovery material
    local plain_password
    local plain_salt
    plain_password="$(encryption_generate_secret)"
    plain_salt="$(encryption_generate_secret)"

    local obs_password
    local obs_salt
    obs_password="$(rclone obscure "${plain_password}")"
    obs_salt="$(rclone obscure "${plain_salt}")"

    # Create crypt remote via rclone config create
    rclone config create "${crypt_remote_name}" crypt \
        remote "${base_target_endpoint}" \
        filename_encryption standard \
        directory_name_encryption true \
        password "${obs_password}" \
        password2 "${obs_salt}" &>/dev/null

    # Validate resulting remote
    if ! encryption_validate_crypt_remote "${crypt_remote_name}:" "${base_target_endpoint}"; then
        log_error "Failed to validate newly created rclone crypt remote '${crypt_remote_name}:'."
        return 1
    fi

    # shellcheck disable=SC2034
    GEN_CRYPT_PASSWORD="${plain_password}"
    # shellcheck disable=SC2034
    GEN_CRYPT_SALT="${plain_salt}"
    # shellcheck disable=SC2034
    GEN_CRYPT_REMOTE="${crypt_remote_name}:"
    # shellcheck disable=SC2034
    GEN_BASE_PATH="${crypt_folder}"

    return 0
}

encryption_display_recovery_screen_and_confirm() {
    local pass="$1"
    local salt="$2"

    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        log_error "Encryption setup requires an interactive terminal attached to /dev/tty."
        return 1
    fi

    local user_confirm=""

    exec 3<>/dev/tty || {
        log_error "Unable to open controlling terminal (/dev/tty)."
        return 1
    }

    {
        printf '\n'
        printf '%s\n' "======================================================================"
        printf '%s\n' "IMPORTANT: ENCRYPTED BACKUP RECOVERY MATERIAL"
        printf '%s\n' "======================================================================"
        printf '\n'
        printf '%s\n' "Your cloud backups will be encrypted before upload."
        printf '\n'
        printf '%s\n' "Save BOTH values below in a password manager, encrypted offline note,"
        printf '%s\n' "or another secure location independent from:"
        printf '\n'
        printf '%s\n' "  - this VPS/computer"
        printf '%s\n' "  - this Hermes installation"
        printf '%s\n' "  - this rclone configuration"
        printf '%s\n' "  - this cloud-storage account and backup folder"
        printf '\n'
        printf '%s\n' "If you lose both this machine/rclone configuration and these values,"
        printf '%s\n' "encrypted backups cannot be restored."
        printf '\n'
        printf '%s\n' "Recovery password:"
        printf '  %s\n' "${pass}"
        printf '\n'
        printf '%s\n' "Recovery salt:"
        printf '  %s\n' "${salt}"
        printf '\n'
        printf '%s\n' "Do NOT save these values in the same Google Drive folder that stores"
        printf '%s\n' "the encrypted backups."
        printf '\n'
        printf '%s\n' "Type SAVED to confirm that you saved the recovery material:"
        printf '%s\n' "======================================================================"
    } >&3

    IFS= read -r user_confirm <&3
    exec 3>&- 3<&- || true

    if [ "${user_confirm}" = "SAVED" ]; then
        return 0
    else
        echo "Confirmation failed (input was not 'SAVED'). Encryption setup not completed." >&2
        return 1
    fi
}

encryption_show_first_backup_reminder_if_needed() {
    if ! encryption_is_enabled; then
        return 0
    fi

    local notice_state
    notice_state="$(state_get "RECOVERY_NOTICE_STATE" "shown")"

    if [ "${notice_state}" = "pending" ]; then
        local reminder_msg="======================================================================
IMPORTANT: ENCRYPTED BACKUP RECOVERY REMINDER
======================================================================

Cloud backup encryption is enabled.

Your backup data is encrypted before it is uploaded. The cloud provider
cannot read the archive without the encryption recovery material.

Save the recovery password and recovery salt in a password manager,
encrypted offline storage, or another secure location independent from:

  - this VPS/computer
  - this Hermes installation
  - this rclone configuration
  - this cloud-storage account

Do NOT store recovery material in the same Google Drive folder or
alongside the encrypted backups.

If this machine and its rclone configuration are lost, encrypted backups
cannot be restored without the saved recovery material.

This reminder is shown only once.
======================================================================"

        log_raw "${reminder_msg}"
        state_set "RECOVERY_NOTICE_STATE" "shown"
    fi
}

encryption_get_active_endpoint() {
    local op="${1:-backup}"
    state_load

    if encryption_is_enabled; then
        local crypt_remote
        crypt_remote="$(state_get "CRYPT_REMOTE")"
        local crypt_path
        crypt_path="$(state_get "CRYPT_PATH" "")"
        local base_remote
        base_remote="$(state_get "BASE_REMOTE")"
        local base_path
        base_path="$(state_get "BASE_PATH" "${DEFAULT_CRYPT_FOLDER}")"

        local expected_base_target
        expected_base_target="$(rclone_normalize_base_endpoint "${base_remote}" "${base_path}")"

        if [ -z "${crypt_remote}" ] || ! encryption_validate_crypt_remote "${crypt_remote}" "${expected_base_target}"; then
            if [ "${op}" = "restore" ]; then
                log_error "[ERR] Encrypted backup restore cannot continue because the configured crypt remote is unavailable."
                log_info "[INFO] Restore the rclone configuration or recreate the crypt remote using the saved recovery password and recovery salt."
            else
                log_error "[ERR] Encryption is enabled, but the configured crypt remote is unavailable."
                log_error "[ERR] Backup was not uploaded to prevent an accidental plaintext cloud upload."
                log_info "[INFO] Restore the rclone configuration or repair the crypt remote using the saved recovery material."
            fi
            exit 1
        fi
        log_info "Encryption mode: ENABLED (rclone crypt)"
        log_info "Validated crypt remote endpoint: ${crypt_remote}${crypt_path}"
        rclone_compose_endpoint "${crypt_remote}" "${crypt_path}"
    else
        local base_remote
        base_remote="$(state_get "BASE_REMOTE" "${BACKUP_REMOTE:-gdrive-hermes:}")"
        local base_path
        base_path="$(state_get "BASE_PATH" "HermesBackups")"
        log_info "Encryption mode: DISABLED (Plaintext cloud upload)"
        rclone_compose_endpoint "${base_remote}" "${base_path}"
    fi
}

encryption_get_active_destination() {
    encryption_get_active_endpoint "backup"
}

encryption_get_active_source() {
    encryption_get_active_endpoint "restore"
}
