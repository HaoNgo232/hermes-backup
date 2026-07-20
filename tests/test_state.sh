#!/usr/bin/env bash
# =====================================================================
# tests/test_state.sh - State Persistence Unit Tests
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

source "${TEST_DIR}/test_helpers.sh"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-state-test-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running State Unit Tests ==="

# Test 1: Defaults
test_defaults() {
    local tdir="${TEST_TMP_DIR}/def"
    env XDG_CONFIG_HOME="${tdir}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"
        state_load
        [ "$(state_get "ENCRYPTION_ENABLED")" = "false" ]
        [ "$(state_get "ENCRYPTION_MODE")" = "none" ]
    '
}
assert_succeeds "Default state options loaded correctly" test_defaults

# Test 2: File permissions
test_permissions() {
    local tdir="${TEST_TMP_DIR}/perm"
    env XDG_CONFIG_HOME="${tdir}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"
        state_load
        state_save
    '
    assert_file_mode "${TEST_TMP_DIR}/perm/hermes-backup" "700" "Config dir permissions 0700"
    assert_file_mode "${TEST_TMP_DIR}/perm/hermes-backup/state.env" "600" "State file permissions 0600"
}
test_permissions

# Test 3: Validation - Invalid boolean string
test_invalid_boolean() {
    local tdir="${TEST_TMP_DIR}/inv_bool"
    env XDG_CONFIG_HOME="${tdir}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"
        state_set "ENCRYPTION_ENABLED" "invalid_bool"
    '
}
assert_fails "Invalid ENCRYPTION_ENABLED string rejected" test_invalid_boolean

# Test 4: Validation - Invalid mode
test_invalid_mode() {
    local tdir="${TEST_TMP_DIR}/inv_mode"
    env XDG_CONFIG_HOME="${tdir}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"
        state_set_many "ENCRYPTION_ENABLED" "true" "ENCRYPTION_MODE" "invalid_mode"
    '
}
assert_fails "Invalid ENCRYPTION_MODE rejected" test_invalid_mode

# Test 5: Validation - Unknown state key rejected in fresh subshell
test_unknown_key() {
    local tmp_c="${TEST_TMP_DIR}/uk"
    env XDG_CONFIG_HOME="${tmp_c}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"
        mkdir -p "${APP_CONFIG_DIR}"
        echo "UNKNOWN_KEY=123" > "${APP_STATE_FILE}"
        chmod 0600 "${APP_STATE_FILE}"
        state_load
    '
}
assert_fails "Unknown state key rejected" test_unknown_key

# Test 6: Validation - Newline in value rejected in fresh subshell
test_unsafe_newline() {
    local tmp_c="${TEST_TMP_DIR}/nl"
    env XDG_CONFIG_HOME="${tmp_c}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"
        mkdir -p "${APP_CONFIG_DIR}"
        printf "BASE_PATH=Hermes\nBackups\n" > "${APP_STATE_FILE}"
        chmod 0600 "${APP_STATE_FILE}"
        state_load
    '
}
assert_fails "State newline injection rejected" test_unsafe_newline

# Test 7: Fail closed on inconsistent state (ENCRYPTION_ENABLED=true but no CRYPT_REMOTE)
test_inconsistent_state() {
    local tdir="${TEST_TMP_DIR}/inc1"
    env XDG_CONFIG_HOME="${tdir}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"
        state_set_many "ENCRYPTION_ENABLED" "true" "ENCRYPTION_MODE" "rclone-crypt" "CRYPT_REMOTE" ""
    '
}
assert_fails "Inconsistent state without CRYPT_REMOTE fails closed" test_inconsistent_state

# Test 8: Fail closed when ENCRYPTION_ENABLED=false but CRYPT_REMOTE is set
test_inconsistent_false_state() {
    local tdir="${TEST_TMP_DIR}/inc2"
    env XDG_CONFIG_HOME="${tdir}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"
        state_set_many "ENCRYPTION_ENABLED" "false" "ENCRYPTION_MODE" "none" "CRYPT_REMOTE" "my-crypt:"
    '
}
assert_fails "ENCRYPTION_ENABLED=false with CRYPT_REMOTE set fails closed" test_inconsistent_false_state

# Test 9: state_set_many transactionality in fresh subshell
test_state_set_many_batch() {
    local batch_dir="${TEST_TMP_DIR}/batch"
    env XDG_CONFIG_HOME="${batch_dir}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"

        state_set_many \
            "ENCRYPTION_ENABLED" "true" \
            "ENCRYPTION_MODE" "rclone-crypt" \
            "BASE_REMOTE" "gdrive-hermes:" \
            "BASE_PATH" "HermesBackupsEncrypted" \
            "CRYPT_REMOTE" "hermes-backup-crypt:" \
            "CRYPT_PATH" "" \
            "RECOVERY_NOTICE_STATE" "pending"

        [ "$(state_get "ENCRYPTION_ENABLED")" = "true" ]
        [ "$(state_get "CRYPT_REMOTE")" = "hermes-backup-crypt:" ]
    '
}
assert_succeeds "state_set_many updated state successfully in isolated process" test_state_set_many_batch

echo -e "\033[0;32mALL STATE UNIT TESTS PASSED!\033[0m"
