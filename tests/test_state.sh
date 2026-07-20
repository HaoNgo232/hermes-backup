#!/usr/bin/env bash
# =====================================================================
# tests/test_state.sh - Comprehensive State Management Unit Tests
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

export XDG_CONFIG_HOME="${TEST_TMP_DIR}"

source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/state.sh"

echo "=== Running State Unit Tests ==="

# Test 1: Missing state file initializes defaults safely
state_load
assert_equals "false" "$(state_get "ENCRYPTION_ENABLED")" "Default ENCRYPTION_ENABLED is false"
assert_equals "none" "$(state_get "ENCRYPTION_MODE")" "Default ENCRYPTION_MODE is none"

# Test 2: State save and permissions check (0700 dir, 0600 file)
state_set "ENCRYPTION_ENABLED" "false"
assert_file_mode "${APP_CONFIG_DIR}" "700" "Config dir permissions 0700"
assert_file_mode "${APP_STATE_FILE}" "600" "State file permissions 0600"

# Test 3: Invalid ENCRYPTION_ENABLED string rejected
bad_dir1="$(mktemp -d "${TEST_TMP_DIR}/bad1-XXXXXX")"
test_invalid_bool() {
    export XDG_CONFIG_HOME="${bad_dir1}"
    mkdir -p "${bad_dir1}/hermes-backup"
    echo "ENCRYPTION_ENABLED=not_a_bool" > "${bad_dir1}/hermes-backup/state.env"
    source "${REPO_DIR}/lib/common.sh"
    source "${REPO_DIR}/lib/state.sh"
    state_load
}
assert_fails "Invalid ENCRYPTION_ENABLED string rejected" test_invalid_bool

# Test 4: Invalid ENCRYPTION_MODE string rejected
bad_dir2="$(mktemp -d "${TEST_TMP_DIR}/bad2-XXXXXX")"
test_invalid_mode() {
    export XDG_CONFIG_HOME="${bad_dir2}"
    mkdir -p "${bad_dir2}/hermes-backup"
    echo "ENCRYPTION_ENABLED=true" > "${bad_dir2}/hermes-backup/state.env"
    echo "ENCRYPTION_MODE=custom-crypto" >> "${bad_dir2}/hermes-backup/state.env"
    source "${REPO_DIR}/lib/common.sh"
    source "${REPO_DIR}/lib/state.sh"
    state_load
}
assert_fails "Invalid ENCRYPTION_MODE rejected" test_invalid_mode

# Test 5: Inconsistent state (ENCRYPTION_ENABLED=true without CRYPT_REMOTE) fails closed
bad_dir3="$(mktemp -d "${TEST_TMP_DIR}/bad3-XXXXXX")"
test_inconsistent_crypt() {
    export XDG_CONFIG_HOME="${bad_dir3}"
    mkdir -p "${bad_dir3}/hermes-backup"
    echo "STATE_SCHEMA_VERSION=1" > "${bad_dir3}/hermes-backup/state.env"
    echo "ENCRYPTION_ENABLED=true" >> "${bad_dir3}/hermes-backup/state.env"
    echo "ENCRYPTION_MODE=rclone-crypt" >> "${bad_dir3}/hermes-backup/state.env"
    echo "CRYPT_REMOTE=" >> "${bad_dir3}/hermes-backup/state.env"
    source "${REPO_DIR}/lib/common.sh"
    source "${REPO_DIR}/lib/state.sh"
    state_load
}
assert_fails "Inconsistent state without CRYPT_REMOTE fails closed" test_inconsistent_crypt

# Test 6: Inconsistent state (ENCRYPTION_ENABLED=false with CRYPT_REMOTE set) fails closed
bad_dir4="$(mktemp -d "${TEST_TMP_DIR}/bad4-XXXXXX")"
test_disabled_with_crypt() {
    export XDG_CONFIG_HOME="${bad_dir4}"
    mkdir -p "${bad_dir4}/hermes-backup"
    echo "STATE_SCHEMA_VERSION=1" > "${bad_dir4}/hermes-backup/state.env"
    echo "ENCRYPTION_ENABLED=false" >> "${bad_dir4}/hermes-backup/state.env"
    echo "ENCRYPTION_MODE=none" >> "${bad_dir4}/hermes-backup/state.env"
    echo "CRYPT_REMOTE=some-crypt-remote:" >> "${bad_dir4}/hermes-backup/state.env"
    source "${REPO_DIR}/lib/common.sh"
    source "${REPO_DIR}/lib/state.sh"
    state_load
}
assert_fails "ENCRYPTION_ENABLED=false with CRYPT_REMOTE set fails closed" test_disabled_with_crypt

# Test 7: Atomic batch update via state_set_many
batch_dir="$(mktemp -d "${TEST_TMP_DIR}/batch-XXXXXX")"
export XDG_CONFIG_HOME="${batch_dir}"
source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/state.sh"
state_load
state_set_many \
    "ENCRYPTION_ENABLED" "true" \
    "ENCRYPTION_MODE" "rclone-crypt" \
    "BASE_REMOTE" "gdrive-hermes:" \
    "BASE_PATH" "HermesBackupsEncrypted" \
    "CRYPT_REMOTE" "hermes-backup-crypt:" \
    "CRYPT_PATH" "" \
    "RECOVERY_NOTICE_STATE" "pending"
assert_equals "true" "$(state_get "ENCRYPTION_ENABLED")" "state_set_many updated ENCRYPTION_ENABLED"
assert_equals "hermes-backup-crypt:" "$(state_get "CRYPT_REMOTE")" "state_set_many updated CRYPT_REMOTE"

echo -e "\033[0;32mALL STATE UNIT TESTS PASSED!\033[0m"
