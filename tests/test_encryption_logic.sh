#!/usr/bin/env bash
# =====================================================================
# tests/test_encryption_logic.sh - Encryption & Secret Generation Tests
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

source "${TEST_DIR}/test_helpers.sh"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-enc-test-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running Encryption Logic Tests ==="

# Test 1: Secret generator produces exactly 32 alphanumeric characters under set -o pipefail
test_secret_pipefail() {
    env REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        set -o pipefail
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/encryption.sh"
        sec="$(encryption_generate_secret)"
        if [ "${#sec}" -ne 32 ]; then
            exit 1
        fi
    '
}
assert_succeeds "Secret generator works cleanly under set -o pipefail" test_secret_pipefail

# Test 2: Target string composition normalization (gdrive-hermes: + HermesBackupsEncrypted)
test_target_norm() {
    env REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/rclone.sh"
        norm="$(rclone_normalize_base_endpoint "gdrive-hermes:" "HermesBackupsEncrypted")"
        [ "${norm}" = "gdrive-hermes:HermesBackupsEncrypted" ]
    '
}
assert_succeeds "Base target normalization produces no extra slash" test_target_norm

# Test 3: Endpoint composition with path in remote string
test_composed_endpoint() {
    env REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/rclone.sh"
        comp="$(rclone_compose_endpoint "gdrive-hermes:HermesBackups" "HermesBackups")"
        [ "${comp}" = "gdrive-hermes:HermesBackups/" ]
    '
}
assert_succeeds "BACKUP_REMOTE endpoint composition avoids path duplication" test_composed_endpoint

# Test 4: atomic_write_file with empty string does not hang
test_atomic_empty() {
    local empty_test_file="${TEST_TMP_DIR}/empty.txt"
    env REPO_DIR="${REPO_DIR}" TEST_FILE="${empty_test_file}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        atomic_write_file "${TEST_FILE}" "" 0600
        sz="$(stat -c%s "${TEST_FILE}")"
        [ "${sz}" -eq 0 ]
    '
}
assert_succeeds "atomic_write_file handles empty string content without hanging" test_atomic_empty

# Test 5: Secret leak check in state file
test_state_secret_check() {
    local tdir="${TEST_TMP_DIR}/sec_check"
    env XDG_CONFIG_HOME="${tdir}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/state.sh"
        state_load
        if grep -i "password\|salt" "${APP_STATE_FILE}" 2>/dev/null; then
            exit 1
        fi
    '
}
assert_succeeds "state.env contains no secret keys or passwords" test_state_secret_check

echo -e "\033[0;32mALL ENCRYPTION LOGIC TESTS PASSED!\033[0m"
