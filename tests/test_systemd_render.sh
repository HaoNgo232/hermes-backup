#!/usr/bin/env bash
# =====================================================================
# tests/test_systemd_render.sh - Systemd Template & Persistence Tests
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

source "${TEST_DIR}/test_helpers.sh"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-sys-test-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running Systemd Render & Persistence Tests ==="

# Test 1: Systemd unit quotes WorkingDirectory and ExecStart
test_systemd_quoting() {
    local svc_file="${REPO_DIR}/systemd/hermes-cloud-backup.service"
    if ! grep -q 'WorkingDirectory="@REPO_DIR@"' "${svc_file}" || \
       ! grep -q 'ExecStart="@REPO_DIR@/backup.sh"' "${svc_file}"; then
        echo "Service file missing double quotes for path variables" >&2
        return 1
    fi
    return 0
}
assert_succeeds "Systemd template uses double quotes for paths" test_systemd_quoting

# Test 2: HERMES_HOME is preserved in state.env across reruns
test_hermes_home_preservation() {
    local config_dir="${TEST_TMP_DIR}/hhome_cfg"
    export XDG_CONFIG_HOME="${config_dir}"
    export HERMES_HOME="/custom/hermes/path"
    export HERMES_BIN="/usr/bin/hermes"

    bash -c "
        source '${REPO_DIR}/lib/common.sh'
        source '${REPO_DIR}/lib/state.sh'
        state_load
        state_set_many 'HERMES_HOME' '${HERMES_HOME}' 'HERMES_BIN' '${HERMES_BIN}'
    " &>/dev/null

    # Run subshell WITHOUT HERMES_HOME env var
    local loaded_hhome
    loaded_hhome="$(bash -c "
        export XDG_CONFIG_HOME='${config_dir}'
        source '${REPO_DIR}/lib/common.sh'
        source '${REPO_DIR}/lib/state.sh'
        state_load
        state_get 'HERMES_HOME'
    ")"

    assert_equals "/custom/hermes/path" "${loaded_hhome}" "HERMES_HOME is preserved in state.env across reruns"
}
test_hermes_home_preservation

echo -e "\033[0;32mALL SYSTEMD RENDER TESTS PASSED!\033[0m"
