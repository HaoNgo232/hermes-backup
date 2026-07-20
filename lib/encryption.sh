#!/usr/bin/env bash
# =====================================================================
# lib/encryption.sh - Rclone Crypt Integration & Encryption Logic
# =====================================================================
set -Eeuo pipefail

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

    # Verify crypt remote connectivity/reachability
    if ! rclone_check_path_reachable "${crypt_remote}"; then
        # Try checking if root of crypt remote works or target directory will be created
        if ! rclone lsf "${crypt_remote}" --max-depth 1 &>/dev/null; then
            log_error "Crypt remote '${crypt_remote}' is unreachable or invalid."
            return 1
        fi
    fi

    return 0
}

encryption_generate_secret() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32
    else
        head -c 64 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32
    fi
}

encryption_create_crypt_remote() {
    local base_remote="$1"
    local crypt_remote_name="${2:-${DEFAULT_CRYPT_REMOTE_NAME}}"
    local crypt_folder="${3:-${DEFAULT_CRYPT_FOLDER}}"

    # Standardize base remote
    local base_remote_name
    base_remote_name="$(rclone_get_remote_name "${base_remote}")"

    if [ -z "${base_remote_name}" ]; then
        log_error "Base remote '${base_remote}' is invalid."
        return 1
    fi

    # Verify base remote reachability
    if ! rclone_check_remote_root "${base_remote_name}"; then
        log_error "Base remote '${base_remote_name}:' is unreachable. Cannot setup encryption."
        return 1
    fi

    # Check for existing conflicting remote name
    if rclone_has_remote "${crypt_remote_name}"; then
        if encryption_is_crypt_remote "${crypt_remote_name}"; then
            log_warn "Crypt remote '${crypt_remote_name}:' already exists in rclone configuration."
            return 0
        else
            log_error "A non-crypt rclone remote named '${crypt_remote_name}:' already exists."
            return 1
        fi
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

    local base_target_path="${base_remote_name}:${crypt_folder}"

    # Create crypt remote via rclone config create
    rclone config create "${crypt_remote_name}" crypt \
        remote "${base_target_path}" \
        filename_encryption standard \
        directory_name_encryption true \
        password "${obs_password}" \
        password2 "${obs_salt}" &>/dev/null

    # Validate crypt remote creation succeeded
    if ! rclone_has_remote "${crypt_remote_name}" || ! encryption_is_crypt_remote "${crypt_remote_name}"; then
        log_error "Failed to create rclone crypt remote '${crypt_remote_name}:'."
        return 1
    fi

    # Expose generated secrets safely to caller via global variables in memory only
    GEN_CRYPT_PASSWORD="${plain_password}"
    GEN_CRYPT_SALT="${plain_salt}"
    GEN_CRYPT_REMOTE="${crypt_remote_name}:"
    GEN_BASE_PATH="${crypt_folder}"

    return 0
}

encryption_display_recovery_screen_and_confirm() {
    local pass="$1"
    local salt="$2"

    if ! is_interactive_tty; then
        echo -e "${C_RED}ERROR: Encryption setup must be run interactively attached to a TTY.${C_RESET}" >&2
        echo "Non-interactive setups cannot safely display recovery material." >&2
        return 1
    fi

    echo ""
    echo "======================================================================"
    echo "IMPORTANT: ENCRYPTED BACKUP RECOVERY MATERIAL"
    echo "======================================================================"
    echo ""
    echo "Your cloud backups will be encrypted before upload."
    echo ""
    echo "Save BOTH values below in a password manager, encrypted offline note,"
    echo "or another secure location independent from:"
    echo ""
    echo "  - this VPS/computer"
    echo "  - this Hermes installation"
    echo "  - this rclone configuration"
    echo "  - this cloud-storage account and backup folder"
    echo ""
    echo "If you lose both this machine/rclone configuration and these values,"
    echo "encrypted backups cannot be restored."
    echo ""
    echo "Recovery password:"
    echo "  ${pass}"
    echo ""
    echo "Recovery salt:"
    echo "  ${salt}"
    echo ""
    echo "Do NOT save these values in the same Google Drive folder that stores"
    echo "the encrypted backups."
    echo ""
    echo "Type SAVED to confirm that you saved the recovery material:"
    echo "======================================================================"
    read -r user_confirm

    if [ "${user_confirm}" = "SAVED" ]; then
        return 0
    else
        echo ""
        echo -e "${C_RED}Confirmation failed (input was not 'SAVED'). Encryption setup not completed.${C_RESET}" >&2
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

        echo "${reminder_msg}"
        if [ -n "${LOG_FILE:-}" ]; then
            echo "${reminder_msg}" >> "${LOG_FILE}"
        fi

        # Atomically mark notice state as shown
        state_set "RECOVERY_NOTICE_STATE" "shown"
    fi
}

encryption_get_active_destination() {
    state_load
    if encryption_is_enabled; then
        local crypt_remote
        crypt_remote="$(state_get "CRYPT_REMOTE")"

        if [ -z "${crypt_remote}" ] || ! encryption_validate_crypt_remote "${crypt_remote}"; then
            log_error "[ERR] Encryption is enabled, but the configured crypt remote is unavailable."
            log_error "[ERR] Backup was not uploaded to prevent an accidental plaintext cloud upload."
            log_info "[INFO] Restore the rclone configuration or repair the crypt remote using the saved recovery material."
            exit 1
        fi
        echo "${crypt_remote}"
    else
        local base_remote
        base_remote="$(state_get "BASE_REMOTE" "${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}")"
        echo "$(rclone_normalize_remote "${base_remote}")"
    fi
}

encryption_get_active_source() {
    encryption_get_active_destination
}
