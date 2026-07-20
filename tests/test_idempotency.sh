#!/usr/bin/env bash
# =====================================================================
# tests/test_idempotency.sh - Extended Idempotency & Fail-Closed Tests
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

source "${TEST_DIR}/test_helpers.sh"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-idempotency-test-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running Idempotency & Fail-Closed Tests ==="

# Test 1: Fail closed when encryption is enabled but CRYPT_REMOTE does not exist
test_missing_crypt_remote() {
    local tmp_conf="${TEST_TMP_DIR}/fc1"
    env \
        HOME="${tmp_conf}/home" \
        XDG_CONFIG_HOME="${tmp_conf}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/rclone.sh"
            source "${REPO_DIR}/lib/encryption.sh"

            mkdir -p "${APP_CONFIG_DIR}"
            cat <<EOF > "${APP_STATE_FILE}"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted
CRYPT_REMOTE=nonexistent-crypt-remote:
CRYPT_PATH=
RECOVERY_NOTICE_STATE=pending
EOF
            chmod 0600 "${APP_STATE_FILE}"
            encryption_get_active_destination
        '
}
assert_fails "Missing crypt remote fails closed on backup" test_missing_crypt_remote

# Test 2: Encrypted restore fails closed when crypt remote does not exist
test_missing_crypt_restore() {
    local tmp_conf="${TEST_TMP_DIR}/fc2"
    env \
        HOME="${tmp_conf}/home" \
        XDG_CONFIG_HOME="${tmp_conf}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/rclone.sh"
            source "${REPO_DIR}/lib/encryption.sh"

            mkdir -p "${APP_CONFIG_DIR}"
            cat <<EOF > "${APP_STATE_FILE}"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted
CRYPT_REMOTE=nonexistent-crypt-remote:
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
EOF
            chmod 0600 "${APP_STATE_FILE}"
            encryption_get_active_source
        '
}
assert_fails "Missing crypt remote fails closed on restore" test_missing_crypt_restore

# Test 3: Path traversal target filename in restore.sh rejected
test_path_traversal_restore() {
    local tmp_conf="${TEST_TMP_DIR}/fc3"
    env \
        HOME="${tmp_conf}/home" \
        XDG_CONFIG_HOME="${tmp_conf}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/restore.sh" "../../etc/passwd"
}
assert_fails "Path traversal filename in restore.sh rejected" test_path_traversal_restore

# Test 4: Invalid filename regex in restore.sh rejected
test_invalid_filename_restore() {
    local tmp_conf="${TEST_TMP_DIR}/fc4"
    env \
        HOME="${tmp_conf}/home" \
        XDG_CONFIG_HOME="${tmp_conf}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/restore.sh" "malicious-backup.sh"
}
assert_fails "Non-archive filename regex in restore.sh rejected" test_invalid_filename_restore

# Test 5: Missing state file with existing crypt remote fails closed
test_missing_state_with_crypt() {
    local tmp_conf="${TEST_TMP_DIR}/fc5"
    local rclone_cfg="${tmp_conf}/rclone/rclone.conf"
    mkdir -p "${tmp_conf}/rclone"

    cat <<EOF > "${rclone_cfg}"
[hermes-backup-crypt]
type = crypt
remote = gdrive-hermes:HermesBackupsEncrypted
filename_encryption = standard
directory_name_encryption = true
EOF

    env \
        HOME="${tmp_conf}/home" \
        XDG_CONFIG_HOME="${tmp_conf}/cfg" \
        RCLONE_CONFIG="${rclone_cfg}" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/rclone.sh"
            source "${REPO_DIR}/lib/encryption.sh"

            state_load
        '
}
assert_fails "Missing state.env with existing crypt remote fails closed" test_missing_state_with_crypt

# Test 6: Reminder notice transition pending -> shown
test_reminder_notice_transition() {
    local tmp_conf="${TEST_TMP_DIR}/fc6"
    env \
        HOME="${tmp_conf}/home" \
        XDG_CONFIG_HOME="${tmp_conf}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/rclone.sh"
            source "${REPO_DIR}/lib/encryption.sh"

            mkdir -p "${APP_CONFIG_DIR}"
            cat <<EOF > "${APP_STATE_FILE}"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted
CRYPT_REMOTE=gdrive-hermes:
CRYPT_PATH=
RECOVERY_NOTICE_STATE=pending
EOF
            chmod 0600 "${APP_STATE_FILE}"
            state_load

            encryption_show_first_backup_reminder_if_needed &>/dev/null
            st="$(state_get "RECOVERY_NOTICE_STATE")"
            if [ "${st}" != "shown" ]; then
                exit 1
            fi
        '
}
assert_succeeds "Reminder state transitions pending -> shown" test_reminder_notice_transition

# Test 7: Rerunning reminder check when already shown does not repeat
test_reminder_notice_repeat() {
    local tmp_conf="${TEST_TMP_DIR}/fc7"
    env \
        HOME="${tmp_conf}/home" \
        XDG_CONFIG_HOME="${tmp_conf}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/rclone.sh"
            source "${REPO_DIR}/lib/encryption.sh"

            mkdir -p "${APP_CONFIG_DIR}"
            cat <<EOF > "${APP_STATE_FILE}"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted
CRYPT_REMOTE=gdrive-hermes:
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
EOF
            chmod 0600 "${APP_STATE_FILE}"
            state_load

            encryption_show_first_backup_reminder_if_needed &>/dev/null
            st="$(state_get "RECOVERY_NOTICE_STATE")"
            if [ "${st}" != "shown" ]; then
                exit 1
            fi
        '
}
assert_succeeds "Reminder state remains shown when already shown" test_reminder_notice_repeat

# Test 8: Concurrent execution lock check
test_concurrent_execution_lock() {
    local tmp_conf="${TEST_TMP_DIR}/fc8"
    local lock_file="${tmp_conf}/backup.lock"
    mkdir -p "${tmp_conf}"

    exec 9>"${lock_file}"
    flock -n 9

    env \
        HOME="${tmp_conf}/home" \
        XDG_CONFIG_HOME="${tmp_conf}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            acquire_backup_lock "'"${lock_file}"'"
            exit 1
        ' >/dev/null 2>&1
    local ret=$?
    exec 9>&-
    return "${ret}"
}
assert_succeeds "Concurrent execution lock prevents parallel backups" test_concurrent_execution_lock

echo -e "\033[0;32mALL IDEMPOTENCY & FAIL-CLOSED TESTS PASSED!\033[0m"
