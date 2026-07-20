#!/usr/bin/env bash
# =====================================================================
# tests/test_secret_leaks.sh - Secret Leak Prevention Tests
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

source "${TEST_DIR}/test_helpers.sh"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-secret-test-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running Secret Leak Prevention Tests ==="

# Test 1: state.env contains no secret keys (password, salt, oauth tokens)
test_state_secret_free() {
    export XDG_CONFIG_HOME="${TEST_TMP_DIR}/state_clean"
    bash -c "
        source '${REPO_DIR}/lib/common.sh'
        source '${REPO_DIR}/lib/state.sh'
        state_load
        state_save
    " &>/dev/null
    
    local state_file="${TEST_TMP_DIR}/state_clean/hermes-backup/state.env"
    if grep -Ei '^(PASSWORD|PASSWORD2|SALT|SECRET|TOKEN|RECOVERY_PASSWORD|RECOVERY_SALT)=' "${state_file}" 2>/dev/null; then
        return 1
    fi
    return 0
}
assert_succeeds "state.env contains no sensitive keys or secrets" test_state_secret_free

# Test 2: rclone_sanitize_output redacts tokens, JSON secrets, and Bearer tokens
test_rclone_redaction() {
    local raw_log
    raw_log="$(printf '{"access_token": "secret_abc_123"}\npassword = secret_pass_456\nAuthorization: Bearer secret_bearer_789')"

    local sanitized
    sanitized="$(bash -c "
        source '${REPO_DIR}/lib/common.sh'
        source '${REPO_DIR}/lib/rclone.sh'
        rclone_sanitize_output \"${raw_log}\"
    ")"

    if grep -q "secret_abc_123" <<< "${sanitized}" || \
       grep -q "secret_pass_456" <<< "${sanitized}" || \
       grep -q "secret_bearer_789" <<< "${sanitized}"; then
        echo "Sanitizer failed: ${sanitized}" >&2
        return 1
    fi
    return 0
}
assert_succeeds "rclone_sanitize_output redacts tokens, passwords, JSON, and Bearer headers" test_rclone_redaction

# Test 3: is_interactive_tty requires fd 0, fd 1, AND fd 2 to be TTYs
test_tty_redirection_check() {
    local is_tty
    is_tty="$(bash -c "
        source '${REPO_DIR}/lib/common.sh'
        if is_interactive_tty; then echo true; else echo false; fi
    " 2> /dev/null)"
    
    # Under standard non-tty subshell or stderr redirection, is_interactive_tty MUST be false
    assert_equals "false" "${is_tty}" "is_interactive_tty returns false when stderr is redirected"
}
test_tty_redirection_check

echo -e "\033[0;32mALL SECRET LEAK TESTS PASSED!\033[0m"
