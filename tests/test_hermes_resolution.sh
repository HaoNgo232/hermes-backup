#!/usr/bin/env bash
# =====================================================================
# tests/test_hermes_resolution.sh - Hermes Resolution Unit Tests
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

source "${TEST_DIR}/test_helpers.sh"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-res-test-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running Hermes Resolution Tests ==="

MOCK_BIN="${TEST_TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"

# Create executable mock hermes
cat <<'EOF' > "${MOCK_BIN}/hermes"
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    echo "hermes v1.0.0-mock"
    exit 0
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/hermes"

# Create non-executable file
touch "${MOCK_BIN}/hermes_non_exec"

# Test 1: Explicit executable HERMES_BIN wins
test_explicit_exec_wins() {
    local tdir="${TEST_TMP_DIR}/t1"
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="/usr/bin:/bin" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/hermes.sh"

            state_set_many "HERMES_BIN" "/stored/nonexistent/hermes"
            res="$(hermes_resolve_binary)"
            [ "${res}" = "'"${MOCK_BIN}/hermes"'" ]
        '
}
assert_succeeds "Explicit executable HERMES_BIN wins" test_explicit_exec_wins

# Test 2: Explicit non-executable HERMES_BIN fails
test_explicit_non_exec_fails() {
    local tdir="${TEST_TMP_DIR}/t2"
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        HERMES_BIN="${MOCK_BIN}/hermes_non_exec" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/hermes.sh"

            hermes_resolve_binary
        '
}
assert_fails "Explicit non-executable HERMES_BIN fails" test_explicit_non_exec_fails

# Test 3: Stored executable HERMES_BIN is used when environment is unset
test_stored_exec_used() {
    local tdir="${TEST_TMP_DIR}/t3"
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="/usr/bin:/bin" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/hermes.sh"

            state_set_many "HERMES_BIN" "'"${MOCK_BIN}/hermes"'"
            res="$(hermes_resolve_binary)"
            [ "${res}" = "'"${MOCK_BIN}/hermes"'" ]
        '
}
assert_succeeds "Stored executable HERMES_BIN is used when env is unset" test_stored_exec_used

# Test 4: Stored non-executable HERMES_BIN fails
test_stored_non_exec_fails() {
    local tdir="${TEST_TMP_DIR}/t4"
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/hermes.sh"

            state_set_many "HERMES_BIN" "'"${MOCK_BIN}/hermes_non_exec"'"
            hermes_resolve_binary
        '
}
assert_fails "Stored non-executable HERMES_BIN fails" test_stored_non_exec_fails

# Test 5: PATH discovery is used when neither explicit nor stored path exists
test_path_discovery() {
    local tdir="${TEST_TMP_DIR}/t5"
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:/usr/bin:/bin" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/hermes.sh"

            res="$(hermes_resolve_binary)"
            [ "${res}" = "'"${MOCK_BIN}/hermes"'" ]
        '
}
assert_succeeds "PATH discovery used when neither explicit nor stored path exists" test_path_discovery

# Test 6: Missing Hermes fails
test_missing_hermes_fails() {
    local tdir="${TEST_TMP_DIR}/t6"
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="/usr/bin:/bin" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/hermes.sh"

            hermes_resolve_binary
        '
}
assert_fails "Missing Hermes fails" test_missing_hermes_fails

# Test 7: Stored HERMES_HOME is exported when environment is unset
test_stored_hermes_home_exported() {
    local tdir="${TEST_TMP_DIR}/t7"
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="/usr/bin:/bin" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/hermes.sh"

            state_set_many "HERMES_HOME" "/custom/stored/hermes_home"
            hermes_apply_persisted_environment
            [ "${HERMES_HOME:-}" = "/custom/stored/hermes_home" ]
        '
}
assert_succeeds "Stored HERMES_HOME is exported when environment is unset" test_stored_hermes_home_exported

# Test 8: Explicit HERMES_HOME is preserved
test_explicit_hermes_home_preserved() {
    local tdir="${TEST_TMP_DIR}/t8"
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        HERMES_HOME="/explicit/hermes_home" \
        PATH="/usr/bin:/bin" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/hermes.sh"

            state_set_many "HERMES_HOME" "/custom/stored/hermes_home"
            hermes_apply_persisted_environment
            [ "${HERMES_HOME}" = "/explicit/hermes_home" ]
        '
}
assert_succeeds "Explicit HERMES_HOME is preserved" test_explicit_hermes_home_preserved

# Test 9: backup.sh, restore.sh and status.sh use stored HERMES_BIN without an explicit env var
test_scripts_use_stored_hermes_bin() {
    local tdir="${TEST_TMP_DIR}/t9"
    mkdir -p "${tdir}/home" "${tdir}/cfg/hermes-backup" "${tdir}/bin"

    # Copy mock hermes binary to a non-PATH location
    cp "${MOCK_BIN}/hermes" "${tdir}/bin/stored_hermes"
    chmod +x "${tdir}/bin/stored_hermes"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
HERMES_HOME=/custom/hermes
HERMES_BIN=${tdir}/bin/stored_hermes
EOF
    chmod 0600 "${tdir}/cfg/hermes-backup/state.env"

    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="/usr/bin:/bin" \
        REPO_DIR="${REPO_DIR}" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/hermes.sh"

            hermes_apply_persisted_environment
            resolved="$(hermes_resolve_binary)"
            [ "${resolved}" = "'"${tdir}/bin/stored_hermes"'" ]
            [ "${HERMES_HOME}" = "/custom/hermes" ]
        '
}
assert_succeeds "backup.sh, restore.sh, and status.sh use stored HERMES_BIN and HERMES_HOME" test_scripts_use_stored_hermes_bin

echo -e "\033[0;32mALL HERMES RESOLUTION TESTS PASSED!\033[0m"
