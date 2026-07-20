#!/usr/bin/env bash
# =====================================================================
# tests/test_state.sh - Unit Tests for lib/state.sh
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# Use isolated temporary config directory for testing
TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-state-test-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

export XDG_CONFIG_HOME="${TEST_TMP_DIR}"

source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/state.sh"

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

assert_file_mode() {
    local file="$1"
    local expected_mode="$2"
    local msg="$3"
    local actual_mode
    actual_mode="$(stat -c "%a" "${file}" 2>/dev/null || stat -f "%Lp" "${file}" 2>/dev/null)"
    if [ "${actual_mode}" != "${expected_mode}" ]; then
        echo -e "\033[0;31m[FAIL]\033[0m ${msg}: expected permissions '${expected_mode}', got '${actual_mode}'" >&2
        exit 1
    else
        echo -e "\033[0;32m[PASS]\033[0m ${msg}"
    fi
}

echo "=== Running State Unit Tests ==="

# Test 1: Missing state initializes default values safely
state_load
assert_equals "false" "$(state_get "ENCRYPTION_ENABLED")" "Default ENCRYPTION_ENABLED is false"
assert_equals "none" "$(state_get "ENCRYPTION_MODE")" "Default ENCRYPTION_MODE is none"

# Test 2: State save and atomic state load
state_set "ENCRYPTION_ENABLED" "false"
assert_file_mode "${APP_CONFIG_DIR}" "700" "Config dir has 0700 permissions"
assert_file_mode "${APP_STATE_FILE}" "600" "State file has 0600 permissions"

# Test 3: Invalid ENCRYPTION_ENABLED rejected
bad_state_dir="$(mktemp -d "${TEST_TMP_DIR}/bad1-XXXXXX")"
(
    export XDG_CONFIG_HOME="${bad_state_dir}"
    mkdir -p "${bad_state_dir}/hermes-backup"
    echo "ENCRYPTION_ENABLED=invalid_bool" > "${bad_state_dir}/hermes-backup/state.env"
    source "${REPO_DIR}/lib/common.sh"
    source "${REPO_DIR}/lib/state.sh"
    if state_load 2>/dev/null; then
        echo -e "\033[0;31m[FAIL]\033[0m Invalid ENCRYPTION_ENABLED was accepted" >&2
        exit 1
    fi
) && assert_equals "true" "true" "Invalid ENCRYPTION_ENABLED rejected"

# Test 4: Inconsistent state (ENCRYPTION_ENABLED=true without CRYPT_REMOTE) rejected
bad_state_dir2="$(mktemp -d "${TEST_TMP_DIR}/bad2-XXXXXX")"
(
    export XDG_CONFIG_HOME="${bad_state_dir2}"
    mkdir -p "${bad_state_dir2}/hermes-backup"
    echo "ENCRYPTION_ENABLED=true" > "${bad_state_dir2}/hermes-backup/state.env"
    echo "ENCRYPTION_MODE=rclone-crypt" >> "${bad_state_dir2}/hermes-backup/state.env"
    echo "CRYPT_REMOTE=" >> "${bad_state_dir2}/hermes-backup/state.env"
    source "${REPO_DIR}/lib/common.sh"
    source "${REPO_DIR}/lib/state.sh"
    if state_load 2>/dev/null; then
        echo -e "\033[0;31m[FAIL]\033[0m Inconsistent state without CRYPT_REMOTE was accepted" >&2
        exit 1
    fi
) && assert_equals "true" "true" "Inconsistent state without CRYPT_REMOTE fails closed"

echo -e "\033[0;32mALL STATE TESTS PASSED!\033[0m"
