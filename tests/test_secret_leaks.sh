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

# Check script dependency
if ! command -v script &>/dev/null; then
    echo "[FAIL] Required command 'script' (util-linux) is not available." >&2
    exit 1
fi

# Test 1: state.env contains no secret keys (password, salt, oauth tokens)
test_state_secret_free() {
    local tdir="${TEST_TMP_DIR}/state_clean"
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            state_load
            state_save
        ' &>/dev/null

    local state_file="${tdir}/cfg/hermes-backup/state.env"
    if grep -Ei '^(PASSWORD|PASSWORD2|SALT|SECRET|TOKEN|RECOVERY_PASSWORD|RECOVERY_SALT)=' "${state_file}" 2>/dev/null; then
        return 1
    fi
    return 0
}
assert_succeeds "state.env contains no sensitive keys or secrets" test_state_secret_free

# Test 2: rclone_sanitize_output redacts tokens, JSON secrets, and Bearer tokens via env var
test_rclone_redaction() {
    local raw_secrets=$'password = secret_pass_111\npassword2 = secret_pass_222\ntoken = secret_token_333\naccess_token = secret_access_444\nrefresh_token = secret_refresh_555\nclient_secret = secret_client_666\nAuthorization: Bearer secret_bearer_777\n{"access_token":"secret_json_888"}\n{"refresh_token":"secret_json_999"}\n{"client_secret":"secret_json_aaa"}'

    local sanitized
    sanitized="$(RAW_SECRETS="${raw_secrets}" REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        source "${REPO_DIR}/lib/rclone.sh"
        rclone_sanitize_output "${RAW_SECRETS}"
    ')"

    if grep -q "secret_pass_111" <<< "${sanitized}" || \
       grep -q "secret_pass_222" <<< "${sanitized}" || \
       grep -q "secret_token_333" <<< "${sanitized}" || \
       grep -q "secret_access_444" <<< "${sanitized}" || \
       grep -q "secret_refresh_555" <<< "${sanitized}" || \
       grep -q "secret_client_666" <<< "${sanitized}" || \
       grep -q "secret_bearer_777" <<< "${sanitized}" || \
       grep -q "secret_json_888" <<< "${sanitized}" || \
       grep -q "secret_json_999" <<< "${sanitized}" || \
       grep -q "secret_json_aaa" <<< "${sanitized}"; then
        echo "Sanitizer failed to redact secrets." >&2
        return 1
    fi
    return 0
}
assert_succeeds "rclone_sanitize_output redacts all secret patterns passed safely via env var" test_rclone_redaction

# Test 3: is_interactive_tty requires fd 0, fd 1, AND fd 2 to be TTYs
test_tty_redirection_check() {
    local is_tty
    is_tty="$(REPO_DIR="${REPO_DIR}" bash -Eeuo pipefail -c '
        source "${REPO_DIR}/lib/common.sh"
        if is_interactive_tty; then echo true; else echo false; fi
    ' 2>/dev/null)"

    assert_equals "false" "${is_tty}" "is_interactive_tty returns false when stderr is redirected"
}
test_tty_redirection_check

# Test 4: PTY recovery screen output test (Exact SAVED confirmation)
test_pty_recovery_display_saved() {
    local pty_dir="${TEST_TMP_DIR}/pty_saved"
    mkdir -p "${pty_dir}/cfg" "${pty_dir}/log"

    local p1="RECOVERY_PASSWORD_MARKER_123"
    local s1="RECOVERY_SALT_MARKER_456"

    local script_rc=0
    printf "SAVED\n" | env \
        HOME="${pty_dir}/home" \
        XDG_CONFIG_HOME="${pty_dir}/cfg" \
        PASS_VAL="${p1}" \
        SALT_VAL="${s1}" \
        LOG_VAL="${pty_dir}/log/app.log" \
        OUT_LOG="${pty_dir}/stdout.log" \
        ERR_LOG="${pty_dir}/stderr.log" \
        REPO_DIR="${REPO_DIR}" \
        script -q -e -c '
            bash -Eeuo pipefail -c '\''
                source "${REPO_DIR}/lib/common.sh"
                source "${REPO_DIR}/lib/state.sh"
                source "${REPO_DIR}/lib/rclone.sh"
                source "${REPO_DIR}/lib/encryption.sh"
                export LOG_FILE="${LOG_VAL}"
                encryption_display_recovery_screen_and_confirm "${PASS_VAL}" "${SALT_VAL}" > "${OUT_LOG}" 2> "${ERR_LOG}"
            '\''
        ' "${pty_dir}/transcript.txt" &>/dev/null || script_rc=$?

    [ "${script_rc}" -eq 0 ]
    grep -q "${p1}" "${pty_dir}/transcript.txt"
    grep -q "${s1}" "${pty_dir}/transcript.txt"

    if grep -q "${p1}" "${pty_dir}/stdout.log" || \
       grep -q "${s1}" "${pty_dir}/stdout.log" || \
       grep -q "${p1}" "${pty_dir}/stderr.log" || \
       grep -q "${s1}" "${pty_dir}/stderr.log"; then
        exit 1
    fi

    if [ -f "${pty_dir}/cfg/hermes-backup/state.env" ]; then
        if grep -q "${p1}" "${pty_dir}/cfg/hermes-backup/state.env" || \
           grep -q "${s1}" "${pty_dir}/cfg/hermes-backup/state.env"; then
            exit 1
        fi
    fi

    if [ -f "${pty_dir}/log/app.log" ]; then
        if grep -q "${p1}" "${pty_dir}/log/app.log" || \
           grep -q "${s1}" "${pty_dir}/log/app.log"; then
            exit 1
        fi
    fi
}
assert_succeeds "PTY recovery display displays secrets ONLY on PTY transcript and exits 0 on SAVED" test_pty_recovery_display_saved

# Test 5: PTY recovery screen output test (Wrong confirmation)
test_pty_recovery_display_wrong_confirm() {
    local pty_dir="${TEST_TMP_DIR}/pty_wrong"
    mkdir -p "${pty_dir}/cfg" "${pty_dir}/log"

    local p1="RECOVERY_PASSWORD_MARKER_123"
    local s1="RECOVERY_SALT_MARKER_456"

    local script_rc=0
    printf "WRONG_INPUT\n" | env \
        HOME="${pty_dir}/home" \
        XDG_CONFIG_HOME="${pty_dir}/cfg" \
        PASS_VAL="${p1}" \
        SALT_VAL="${s1}" \
        LOG_VAL="${pty_dir}/log/app.log" \
        OUT_LOG="${pty_dir}/stdout.log" \
        ERR_LOG="${pty_dir}/stderr.log" \
        REPO_DIR="${REPO_DIR}" \
        script -q -e -c '
            bash -Eeuo pipefail -c '\''
                source "${REPO_DIR}/lib/common.sh"
                source "${REPO_DIR}/lib/state.sh"
                source "${REPO_DIR}/lib/rclone.sh"
                source "${REPO_DIR}/lib/encryption.sh"
                export LOG_FILE="${LOG_VAL}"
                encryption_display_recovery_screen_and_confirm "${PASS_VAL}" "${SALT_VAL}" > "${OUT_LOG}" 2> "${ERR_LOG}"
            '\''
        ' "${pty_dir}/transcript.txt" &>/dev/null || script_rc=$?

    [ "${script_rc}" -ne 0 ]

    # Verify no encrypted state was written
    if [ -f "${pty_dir}/cfg/hermes-backup/state.env" ]; then
        st="$(grep "^ENCRYPTION_ENABLED=" "${pty_dir}/cfg/hermes-backup/state.env" | cut -d'=' -f2 || echo "false")"
        [ "${st}" != "true" ]
    fi
}
assert_succeeds "PTY recovery display fails non-zero on wrong confirmation without persisting encrypted state" test_pty_recovery_display_wrong_confirm

# Test 6: Global scan of generated test outputs for leaked marker secrets
test_global_marker_leak_scan() {
    local leaked
    leaked="$(grep -RInE 'RECOVERY_PASSWORD_MARKER_123|RECOVERY_SALT_MARKER_456' "${TEST_TMP_DIR}" 2>/dev/null | grep -v 'transcript.txt' || true)"
    if [ -n "${leaked}" ]; then
        echo "Leaked marker secret found in generated outputs:" >&2
        echo "${leaked}" >&2
        return 1
    fi
    return 0
}
assert_succeeds "Global leak scan verifies no marker secrets leaked to state/logs/captures" test_global_marker_leak_scan

echo -e "\033[0;32mALL SECRET LEAK TESTS PASSED!\033[0m"
