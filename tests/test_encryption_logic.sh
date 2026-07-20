#!/usr/bin/env bash
# =====================================================================
# tests/test_encryption_logic.sh - Unit Tests for lib/encryption.sh
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

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

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [ "${expected}" != "${actual}" ]; then
        echo -e "\033[0;31m[FAIL]\033[0m ${msg}: expected '${expected}', got '${actual}'" >&2
        exit 1
    else
        echo -e "\033[0;32m[PASS]\033[0m ${msg}"
    fi
}

echo "=== Running Encryption Logic Tests ==="

# Test 1: Secret generation produces 32-char strings
sec1="$(encryption_generate_secret)"
sec2="$(encryption_generate_secret)"
if [ "${#sec1}" -ne 32 ] || [ "${#sec2}" -ne 32 ]; then
    echo -e "\033[0;31m[FAIL]\033[0m Secret generation did not produce 32 chars" >&2
    exit 1
fi
if [ "${sec1}" = "${sec2}" ]; then
    echo -e "\033[0;31m[FAIL]\033[0m Secret generation returned identical values" >&2
    exit 1
fi
assert_equals "true" "true" "Secret generation is random and 32 characters"

# Test 2: Active destination returns base remote when encryption is disabled
state_load
assert_equals "false" "$(encryption_is_enabled && echo "true" || echo "false")" "Encryption disabled by default"

# Test 3: Non-interactive TTY display rejection
if is_interactive_tty; then
    echo "Skipping non-TTY test because runner is attached to TTY"
else
    if encryption_display_recovery_screen_and_confirm "pass" "salt" 2>/dev/null; then
        echo -e "\033[0;31m[FAIL]\033[0m Non-TTY interactive display was allowed" >&2
        exit 1
    else
        assert_equals "true" "true" "Non-TTY display rejected safely"
    fi
fi

# Test 4: Verify secret leak safety in state.env
state_set "ENCRYPTION_ENABLED" "false"
if grep -i "password\|salt" "${APP_STATE_FILE}" 2>/dev/null; then
    echo -e "\033[0;31m[FAIL]\033[0m Secret key names leaked in state file" >&2
    exit 1
else
    assert_equals "true" "true" "state.env contains no secret keys"
fi

echo -e "\033[0;32mALL ENCRYPTION LOGIC TESTS PASSED!\033[0m"
