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

export XDG_CONFIG_HOME="${TEST_TMP_DIR}"

source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/state.sh"
source "${REPO_DIR}/lib/rclone.sh"
source "${REPO_DIR}/lib/encryption.sh"

echo "=== Running Idempotency & Fail-Closed Tests ==="

# Test 1: Fail closed when encryption is enabled but CRYPT_REMOTE does not exist
test_missing_crypt_remote() {
    local tmp_conf="$(mktemp -d "${TEST_TMP_DIR}/fc1-XXXXXX")"
    export XDG_CONFIG_HOME="${tmp_conf}"
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
}
assert_fails "Missing crypt remote fails closed on backup" test_missing_crypt_remote

# Test 2: Encrypted restore fails closed when crypt remote does not exist
test_missing_crypt_restore() {
    local tmp_conf="$(mktemp -d "${TEST_TMP_DIR}/fc2-XXXXXX")"
    export XDG_CONFIG_HOME="${tmp_conf}"
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
}
assert_fails "Missing crypt remote fails closed on restore" test_missing_crypt_restore

# Test 3: Path traversal target filename in restore.sh rejected
test_path_traversal_restore() {
    bash "${REPO_DIR}/restore.sh" "../../etc/passwd"
}
assert_fails "Path traversal filename in restore.sh rejected" test_path_traversal_restore

# Test 4: Invalid filename regex in restore.sh rejected
test_invalid_filename_restore() {
    bash "${REPO_DIR}/restore.sh" "malicious-backup.sh"
}
assert_fails "Non-archive filename regex in restore.sh rejected" test_invalid_filename_restore

# Test 5: Missing state file with existing crypt remote fails closed
test_missing_state_with_crypt() {
    local tmp_conf="$(mktemp -d "${TEST_TMP_DIR}/missingstate-XXXXXX")"
    export XDG_CONFIG_HOME="${tmp_conf}"
    export RCLONE_CONFIG="${tmp_conf}/rclone/rclone.conf"
    mkdir -p "${tmp_conf}/rclone"

    cat <<EOF > "${RCLONE_CONFIG}"
[hermes-backup-crypt]
type = crypt
remote = gdrive-hermes:HermesBackupsEncrypted
filename_encryption = standard
directory_name_encryption = true
EOF

    HERMES_COMMON_SH_LOADED=false source "${REPO_DIR}/lib/common.sh"
    HERMES_STATE_SH_LOADED=false source "${REPO_DIR}/lib/state.sh"
    HERMES_RCLONE_SH_LOADED=false source "${REPO_DIR}/lib/rclone.sh"
    HERMES_ENCRYPTION_SH_LOADED=false source "${REPO_DIR}/lib/encryption.sh"

    # Loading missing state when crypt remote exists MUST fail closed
    state_load
}
assert_fails "Missing state.env with existing crypt remote fails closed" test_missing_state_with_crypt

# Test 6: Reminder notice transition pending -> shown
reminder_dir="$(mktemp -d "${TEST_TMP_DIR}/rem-XXXXXX")"
export XDG_CONFIG_HOME="${reminder_dir}"
HERMES_COMMON_SH_LOADED=false source "${REPO_DIR}/lib/common.sh"
HERMES_STATE_SH_LOADED=false source "${REPO_DIR}/lib/state.sh"
HERMES_RCLONE_SH_LOADED=false source "${REPO_DIR}/lib/rclone.sh"
HERMES_ENCRYPTION_SH_LOADED=false source "${REPO_DIR}/lib/encryption.sh"

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
assert_equals "shown" "$(state_get "RECOVERY_NOTICE_STATE")" "Reminder state transitions pending -> shown"

# Test 7: Rerunning reminder check when already shown does not repeat
encryption_show_first_backup_reminder_if_needed &>/dev/null
assert_equals "shown" "$(state_get "RECOVERY_NOTICE_STATE")" "Reminder state remains shown"

echo -e "\033[0;32mALL IDEMPOTENCY & FAIL-CLOSED TESTS PASSED!\033[0m"
