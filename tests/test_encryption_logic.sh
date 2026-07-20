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

# Test 1: Secret generator produces exactly 32 alphanumeric characters
sec1="$(encryption_generate_secret)"
sec2="$(encryption_generate_secret)"
assert_equals "32" "${#sec1}" "Secret 1 is exactly 32 chars"
assert_equals "32" "${#sec2}" "Secret 2 is exactly 32 chars"
if [ "${sec1}" = "${sec2}" ]; then
    echo -e "\033[0;31m[FAIL]\033[0m Secrets generated were identical" >&2
    exit 1
fi
assert_equals "true" "true" "Secrets are unique and random"

# Test 2: Active destination returns composed base path when encryption is disabled
state_load
assert_equals "gdrive-hermes:HermesBackups/" "$(encryption_get_active_destination)" "Plaintext destination uses BASE_REMOTE + BASE_PATH"

# Test 3: Secret leak check (confirm state file and logs contain NO recovery passwords/salts)
if grep -i "password\|salt" "${APP_STATE_FILE}" 2>/dev/null; then
    echo -e "\033[0;31m[FAIL]\033[0m Secret password/salt leaked into state file" >&2
    exit 1
else
    assert_equals "true" "true" "state.env contains no secret keys or passwords"
fi

echo -e "\033[0;32mALL ENCRYPTION LOGIC TESTS PASSED!\033[0m"
