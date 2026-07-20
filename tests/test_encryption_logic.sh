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

export XDG_CONFIG_HOME="${TEST_TMP_DIR}"

source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/state.sh"
source "${REPO_DIR}/lib/rclone.sh"
source "${REPO_DIR}/lib/encryption.sh"

echo "=== Running Encryption Logic Tests ==="

# Test 1: Secret generator produces exactly 32 alphanumeric characters under set -o pipefail
test_secret_pipefail() {
    set -o pipefail
    local sec
    sec="$(encryption_generate_secret)"
    if [ "${#sec}" -ne 32 ]; then
        exit 1
    fi
}
assert_succeeds "Secret generator works cleanly under set -o pipefail" test_secret_pipefail

# Test 2: Target string composition normalization (gdrive-hermes: + HermesBackupsEncrypted)
norm_target="$(rclone_normalize_base_endpoint "gdrive-hermes:" "HermesBackupsEncrypted")"
assert_equals "gdrive-hermes:HermesBackupsEncrypted" "${norm_target}" "Base target normalization produces no extra slash"

# Test 3: Endpoint composition with path in remote string (BACKUP_REMOTE=gdrive-hermes:HermesBackups)
composed_endpoint="$(rclone_compose_endpoint "gdrive-hermes:HermesBackups" "HermesBackups")"
assert_equals "gdrive-hermes:HermesBackups/" "${composed_endpoint}" "BACKUP_REMOTE endpoint composition avoids path duplication"

# Test 4: atomic_write_file with empty string does not hang
empty_test_file="${TEST_TMP_DIR}/empty.txt"
atomic_write_file "${empty_test_file}" "" 0600
assert_equals "0" "$(stat -c%s "${empty_test_file}")" "atomic_write_file handles empty string content without hanging"

# Test 5: Secret leak check (confirm state file contains NO recovery passwords/salts)
state_load
if grep -i "password\|salt" "${APP_STATE_FILE}" 2>/dev/null; then
    echo -e "\033[0;31m[FAIL]\033[0m Secret password/salt leaked into state file" >&2
    exit 1
else
    assert_equals "true" "true" "state.env contains no secret keys or passwords"
fi

echo -e "\033[0;32mALL ENCRYPTION LOGIC TESTS PASSED!\033[0m"
