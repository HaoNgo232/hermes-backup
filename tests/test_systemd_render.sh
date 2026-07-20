#!/usr/bin/env bash
# =====================================================================
# tests/test_systemd_render.sh - Systemd Rendering & Installation Tests
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

echo "=== Running Systemd Render & Installation Tests ==="

MOCK_BIN="${TEST_TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"

# Mock id
cat <<'EOF' > "${MOCK_BIN}/id"
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
    echo "1000"
    exit 0
fi
exec /usr/bin/id "$@"
EOF
chmod +x "${MOCK_BIN}/id"

# Mock hermes
cat <<'EOF' > "${MOCK_BIN}/hermes"
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    echo "hermes v1.0.0-mock"
    exit 0
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/hermes"

# Mock loginctl
cat <<'EOF' > "${MOCK_BIN}/loginctl"
#!/usr/bin/env bash
echo "Linger=yes"
exit 0
EOF
chmod +x "${MOCK_BIN}/loginctl"

# Mock systemctl
cat <<'EOF' > "${MOCK_BIN}/systemctl"
#!/usr/bin/env bash
echo "systemctl $*" >> "${MOCK_CALL_LOG}"
cmd="${1:-}"
if [ "${cmd}" = "--user" ]; then
    sub="${2:-}"
    if [ "${sub}" = "status" ] || [ "${sub}" = "show-environment" ]; then
        exit 0
    elif [ "${sub}" = "daemon-reload" ]; then
        if [ "${MOCK_RELOAD_FAIL:-false}" = "true" ]; then
            exit 1
        fi
        exit 0
    elif [ "${sub}" = "enable" ]; then
        if [ "${MOCK_ENABLE_FAIL:-false}" = "true" ]; then
            exit 1
        fi
        exit 0
    elif [ "${sub}" = "is-enabled" ]; then
        echo "enabled"
        exit 0
    elif [ "${sub}" = "is-active" ]; then
        echo "active"
        exit 0
    elif [ "${sub}" = "list-timers" ]; then
        echo "Next scheduled run"
        exit 0
    fi
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/systemctl"

# Mock systemd-analyze
cat <<'EOF' > "${MOCK_BIN}/systemd-analyze"
#!/usr/bin/env bash
echo "systemd-analyze $*" >> "${MOCK_CALL_LOG}"
if [ "${MOCK_ANALYZE_FAIL:-false}" = "true" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/systemd-analyze"

# Test 1: Full installation with special characters in paths
test_special_char_rendering() {
    # Directory with special chars: space, %, &, ', ", $, [, ]
    local special_dir="${TEST_TMP_DIR}/repo space % & ' \$ [ ]"
    mkdir -p "${special_dir}"
    cp -r "${REPO_DIR}/." "${special_dir}/"

    local custom_home="${TEST_TMP_DIR}/hhome % & ' \$"
    local custom_bin="${special_dir}/bin/hermes_bin % &"
    mkdir -p "${custom_home}" "$(dirname "${custom_bin}")"
    cp "${MOCK_BIN}/hermes" "${custom_bin}"
    chmod +x "${custom_bin}"

    local user_home="${TEST_TMP_DIR}/user_home"
    local config_dir="${user_home}/.config"
    mkdir -p "${config_dir}/systemd/user" "${config_dir}/hermes-backup"

    cat <<EOF > "${config_dir}/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
HERMES_HOME=${custom_home}
HERMES_BIN=${custom_bin}
EOF
    chmod 0600 "${config_dir}/hermes-backup/state.env"

    local call_log="${TEST_TMP_DIR}/call1.log"
    touch "${call_log}"

    env \
        HOME="${user_home}" \
        XDG_CONFIG_HOME="${config_dir}" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_HOME="${custom_home}" \
        HERMES_BIN="${custom_bin}" \
        MOCK_CALL_LOG="${call_log}" \
        bash "${special_dir}/install-systemd.sh"

    local rendered_svc_file="${config_dir}/systemd/user/hermes-cloud-backup.service"
    local rendered_tmr_file="${config_dir}/systemd/user/hermes-cloud-backup.timer"

    [ -f "${rendered_svc_file}" ]
    [ -f "${rendered_tmr_file}" ]

    if grep -R -E '@[A-Z0-9_]+@' "${config_dir}/systemd/user/"; then
        exit 1
    fi

    grep -q "WorkingDirectory=\"${special_dir}\"" "${rendered_svc_file}"
    grep -q "ExecStart=\"${special_dir}/backup.sh\"" "${rendered_svc_file}"
    grep -q "Environment=\"HERMES_HOME=${custom_home}\"" "${rendered_svc_file}"
    grep -q "Environment=\"HERMES_BIN=${custom_bin}\"" "${rendered_svc_file}"

    # Check % escaped as %%
    grep -q "%%" "${rendered_svc_file}"

    # Verify no secrets present
    if grep -Eqi 'password2?|recovery|refresh_token|access_token|client_secret' "${rendered_svc_file}"; then
        exit 1
    fi

    grep -q "systemd-analyze" "${call_log}"
    grep -q "systemctl --user daemon-reload" "${call_log}"
    grep -q "systemctl --user enable --now hermes-cloud-backup.timer" "${call_log}"
}
assert_succeeds "Full systemd rendering handles special-character paths and installs units" test_special_char_rendering

# Scenario A: systemd-analyze verification fails
test_analyze_fail_scenario() {
    local tdir="${TEST_TMP_DIR}/scen_a"
    mkdir -p "${tdir}/repo" "${tdir}/home/.config/systemd/user" "${tdir}/home/.config/hermes-backup"
    cp -r "${REPO_DIR}/." "${tdir}/repo/"

    cat <<EOF > "${tdir}/home/.config/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
HERMES_HOME=${tdir}/home/.hermes
HERMES_BIN=${MOCK_BIN}/hermes
EOF
    chmod 0600 "${tdir}/home/.config/hermes-backup/state.env"

    local call_log="${tdir}/call.log"
    touch "${call_log}"

    local rc=0
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/home/.config" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_ANALYZE_FAIL="true" \
        bash "${tdir}/repo/install-systemd.sh" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
    [ ! -f "${tdir}/home/.config/systemd/user/hermes-cloud-backup.service" ]
    if grep -q "systemctl --user enable" "${call_log}"; then
        exit 1
    fi
}
assert_succeeds "Scenario A: systemd-analyze verification failure aborts installation and leaves no final units" test_analyze_fail_scenario

# Scenario B: systemctl enable fails
test_enable_fail_scenario() {
    local tdir="${TEST_TMP_DIR}/scen_b"
    mkdir -p "${tdir}/repo" "${tdir}/home/.config/systemd/user" "${tdir}/home/.config/hermes-backup"
    cp -r "${REPO_DIR}/." "${tdir}/repo/"

    # Create pre-existing unit files to test rollback
    echo "old_service_content" > "${tdir}/home/.config/systemd/user/hermes-cloud-backup.service"
    echo "old_timer_content" > "${tdir}/home/.config/systemd/user/hermes-cloud-backup.timer"

    cat <<EOF > "${tdir}/home/.config/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
HERMES_HOME=${tdir}/home/.hermes
HERMES_BIN=${MOCK_BIN}/hermes
EOF
    chmod 0600 "${tdir}/home/.config/hermes-backup/state.env"

    local call_log="${tdir}/call.log"
    touch "${call_log}"

    local rc=0
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/home/.config" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_ENABLE_FAIL="true" \
        bash "${tdir}/repo/install-systemd.sh" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
    [ "$(cat "${tdir}/home/.config/systemd/user/hermes-cloud-backup.service")" = "old_service_content" ]
    [ "$(cat "${tdir}/home/.config/systemd/user/hermes-cloud-backup.timer")" = "old_timer_content" ]
    grep -q "systemctl --user daemon-reload" "${call_log}"
}
assert_succeeds "Scenario B: systemctl enable failure rolls back unit files and runs daemon-reload cleanup" test_enable_fail_scenario

# Scenario C: Stored HERMES_BIN is used when no explicit HERMES_BIN exists
test_stored_hermes_bin_used() {
    local tdir="${TEST_TMP_DIR}/scen_c"
    mkdir -p "${tdir}/repo" "${tdir}/home/.config/systemd/user" "${tdir}/home/.config/hermes-backup"
    cp -r "${REPO_DIR}/." "${tdir}/repo/"

    cat <<EOF > "${tdir}/home/.config/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
HERMES_HOME=${tdir}/home/.hermes
HERMES_BIN=${MOCK_BIN}/hermes
EOF
    chmod 0600 "${tdir}/home/.config/hermes-backup/state.env"

    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/home/.config" \
        PATH="${MOCK_BIN}:${PATH}" \
        MOCK_CALL_LOG="${tdir}/call.log" \
        bash "${tdir}/repo/install-systemd.sh"

    grep -q "Environment=\"HERMES_BIN=${MOCK_BIN}/hermes\"" "${tdir}/home/.config/systemd/user/hermes-cloud-backup.service"
}
assert_succeeds "Scenario C: Stored HERMES_BIN is used when no explicit HERMES_BIN exists" test_stored_hermes_bin_used

# Scenario D: Explicit valid HERMES_BIN overrides stored HERMES_BIN
test_explicit_hermes_bin_overrides() {
    local tdir="${TEST_TMP_DIR}/scen_d"
    mkdir -p "${tdir}/repo" "${tdir}/home/.config/systemd/user" "${tdir}/home/.config/hermes-backup" "${tdir}/new_bin"
    cp -r "${REPO_DIR}/." "${tdir}/repo/"

    cp "${MOCK_BIN}/hermes" "${tdir}/new_bin/hermes_new"
    chmod +x "${tdir}/new_bin/hermes_new"

    cat <<EOF > "${tdir}/home/.config/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
HERMES_HOME=${tdir}/home/.hermes
HERMES_BIN=${MOCK_BIN}/hermes
EOF
    chmod 0600 "${tdir}/home/.config/hermes-backup/state.env"

    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/home/.config" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${tdir}/new_bin/hermes_new" \
        MOCK_CALL_LOG="${tdir}/call.log" \
        bash "${tdir}/repo/install-systemd.sh"

    grep -q "Environment=\"HERMES_BIN=${tdir}/new_bin/hermes_new\"" "${tdir}/home/.config/systemd/user/hermes-cloud-backup.service"
    grep -q "HERMES_BIN=${tdir}/new_bin/hermes_new" "${tdir}/home/.config/hermes-backup/state.env"
}
assert_succeeds "Scenario D: Explicit valid HERMES_BIN overrides stored HERMES_BIN" test_explicit_hermes_bin_overrides

# Scenario E: Explicit invalid HERMES_BIN fails and does not silently fall back
test_explicit_invalid_hermes_bin_fails() {
    local tdir="${TEST_TMP_DIR}/scen_e"
    mkdir -p "${tdir}/repo" "${tdir}/home/.config/systemd/user" "${tdir}/home/.config/hermes-backup"
    cp -r "${REPO_DIR}/." "${tdir}/repo/"

    cat <<EOF > "${tdir}/home/.config/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
HERMES_HOME=${tdir}/home/.hermes
HERMES_BIN=${MOCK_BIN}/hermes
EOF
    chmod 0600 "${tdir}/home/.config/hermes-backup/state.env"

    local rc=0
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/home/.config" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="/nonexistent/path/hermes" \
        bash "${tdir}/repo/install-systemd.sh" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
}
assert_succeeds "Scenario E: Explicit invalid HERMES_BIN fails without silent fallback" test_explicit_invalid_hermes_bin_fails

# Scenario F: Stored invalid HERMES_BIN fails clearly
test_stored_invalid_hermes_bin_fails() {
    local tdir="${TEST_TMP_DIR}/scen_f"
    mkdir -p "${tdir}/repo" "${tdir}/home/.config/systemd/user" "${tdir}/home/.config/hermes-backup"
    cp -r "${REPO_DIR}/." "${tdir}/repo/"

    cat <<EOF > "${tdir}/home/.config/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
HERMES_HOME=${tdir}/home/.hermes
HERMES_BIN=/nonexistent/path/hermes
EOF
    chmod 0600 "${tdir}/home/.config/hermes-backup/state.env"

    local rc=0
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/home/.config" \
        PATH="${MOCK_BIN}:${PATH}" \
        bash "${tdir}/repo/install-systemd.sh" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
}
assert_succeeds "Scenario F: Stored invalid HERMES_BIN fails clearly" test_stored_invalid_hermes_bin_fails

echo -e "\033[0;32mALL SYSTEMD RENDER & INSTALLATION TESTS PASSED!\033[0m"
