#!/usr/bin/env bash
# =====================================================================
# tests/test_restore_behavior.sh - Full Mocked Restore Integration Tests
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

source "${TEST_DIR}/test_helpers.sh"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-restore-beh-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running Restore Behavioral Tests ==="

MOCK_BIN="${TEST_TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"

# Mock hermes binary
cat <<'EOF' > "${MOCK_BIN}/hermes"
#!/usr/bin/env bash
if [ "${1:-}" = "import" ] && [ "${2:-}" = "--force" ]; then
    echo "hermes import --force $3" >> "${MOCK_CALL_LOG}"
    exit 0
elif [ "${1:-}" = "--version" ]; then
    echo "hermes v1.0.0-mock"
    exit 0
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/hermes"

# Mock unzip binary
cat <<'EOF' > "${MOCK_BIN}/unzip"
#!/usr/bin/env bash
echo "unzip $*" >> "${MOCK_CALL_LOG}"
exit 0
EOF
chmod +x "${MOCK_BIN}/unzip"

# Mock zip binary
cat <<'EOF' > "${MOCK_BIN}/zip"
#!/usr/bin/env bash
echo "zip $*" >> "${MOCK_CALL_LOG}"
exit 0
EOF
chmod +x "${MOCK_BIN}/zip"

# Mock tar binary
cat <<'EOF' > "${MOCK_BIN}/tar"
#!/usr/bin/env bash
echo "tar $*" >> "${MOCK_CALL_LOG}"
if [ "${1:-}" = "-tf" ]; then
    if [ "${MOCK_TAR_UNSAFE:-false}" = "true" ]; then
        echo "../../outside_file.txt"
    else
        echo "safe_file.txt"
    fi
    exit 0
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/tar"

# Mock xz binary
cat <<'EOF' > "${MOCK_BIN}/xz"
#!/usr/bin/env bash
echo "xz $*" >> "${MOCK_CALL_LOG}"
exit 0
EOF
chmod +x "${MOCK_BIN}/xz"

# Mock rclone binary
cat <<'EOF' > "${MOCK_BIN}/rclone"
#!/usr/bin/env bash
cmd="${1:-}"
shift || true

case "${cmd}" in
    listremotes)
        echo "rclone listremotes" >> "${MOCK_CALL_LOG}"
        if [ "${MOCK_HAS_CRYPT:-false}" = "true" ]; then
            echo "gdrive-hermes:"
            echo "hermes-backup-crypt:"
        else
            echo "gdrive-hermes:"
        fi
        ;;
    lsf)
        echo "rclone lsf $*" >> "${MOCK_CALL_LOG}"
        if [ "${MOCK_RCLONE_LSF_FAIL:-false}" = "true" ]; then
            echo "Error 500: Server error" >&2
            exit 1
        fi
        target="${1:-}"
        if [ "${MOCK_CRYPT_INVALID:-false}" = "true" ] && [[ "${target}" == *"crypt"* ]]; then
            echo "Error 404: Crypt invalid" >&2
            exit 1
        fi
        echo "2026-07-20T10:00:00Z;hermes-backup-20-07-2026_14h00p00s.zip;1024"
        ;;
    copyto)
        echo "rclone copyto $1 -> $2" >> "${MOCK_CALL_LOG}"
        if [ "${MOCK_RCLONE_COPY_FAIL:-false}" = "true" ]; then
            echo "Error: Download failed" >&2
            exit 1
        fi
        dest="$2"
        mkdir -p "$(dirname "${dest}")"
        echo "mock-backup-zip-binary-data" > "${dest}"
        ;;
    config)
        sub="${1:-}"
        if [ "${sub}" = "show" ]; then
            if [ "${MOCK_CRYPT_INVALID:-false}" = "true" ]; then
                echo "type = invalid"
            else
                cat <<'CONF'
type = crypt
remote = gdrive-hermes:HermesBackupsEncrypted
filename_encryption = standard
directory_name_encryption = true
password = MOCK
password2 = MOCK
CONF
            fi
        fi
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "${MOCK_BIN}/rclone"

# Scenario A: Plaintext restore
test_plaintext_restore() {
    local tdir="${TEST_TMP_DIR}/rest_a"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
EOF
    chmod 0600 "${tdir}/cfg/hermes-backup/state.env"

    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_HAS_CRYPT="false" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/restore.sh" "hermes-backup-20-07-2026_14h00p00s.zip"

    grep -q "rclone copyto gdrive-hermes:HermesBackups/hermes-backup-20-07-2026_14h00p00s.zip ->" "${call_log}"
}
assert_succeeds "Scenario A: Plaintext restore uses base destination" test_plaintext_restore

# Scenario B: Encrypted restore
test_encrypted_restore() {
    local tdir="${TEST_TMP_DIR}/rest_b"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted
CRYPT_REMOTE=hermes-backup-crypt:
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
EOF
    chmod 0600 "${tdir}/cfg/hermes-backup/state.env"

    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_HAS_CRYPT="true" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/restore.sh" "hermes-backup-20-07-2026_14h00p00s.zip"

    grep -q "rclone copyto hermes-backup-crypt:hermes-backup-20-07-2026_14h00p00s.zip ->" "${call_log}"
}
assert_succeeds "Scenario B: Encrypted restore uses crypt source" test_encrypted_restore

# Scenario C: Missing/invalid crypt remote
test_invalid_crypt_restore() {
    local tdir="${TEST_TMP_DIR}/rest_c"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted
CRYPT_REMOTE=hermes-backup-crypt:
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
EOF
    chmod 0600 "${tdir}/cfg/hermes-backup/state.env"
    local initial_hash
    initial_hash="$(sha256sum "${tdir}/cfg/hermes-backup/state.env" | cut -d' ' -f1)"

    local rc=0
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_HAS_CRYPT="false" \
        MOCK_CRYPT_INVALID="true" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/restore.sh" "hermes-backup-20-07-2026_14h00p00s.zip" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
    if grep -q "rclone copyto" "${call_log}" || grep -q "hermes import" "${call_log}"; then
        exit 1
    fi
    final_hash="$(sha256sum "${tdir}/cfg/hermes-backup/state.env" | cut -d' ' -f1)"
    [ "${initial_hash}" = "${final_hash}" ]
}
assert_succeeds "Scenario C: Missing/invalid crypt remote aborts restore and leaves state unchanged" test_invalid_crypt_restore

# Scenario D: Invalid filename
test_invalid_filename_restore_scenario() {
    local tdir="${TEST_TMP_DIR}/rest_d"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    local rc=0
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/restore.sh" "invalid-backup.sh" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
    if grep -q "rclone" "${call_log}" || grep -q "hermes" "${call_log}"; then
        exit 1
    fi
}
assert_succeeds "Scenario D: Invalid filename rejected early" test_invalid_filename_restore_scenario

# Scenario E: Successful restore
test_successful_restore_scenario() {
    local tdir="${TEST_TMP_DIR}/rest_e"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
EOF
    chmod 0600 "${tdir}/cfg/hermes-backup/state.env"
    local initial_hash
    initial_hash="$(sha256sum "${tdir}/cfg/hermes-backup/state.env" | cut -d' ' -f1)"

    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/restore.sh" "hermes-backup-20-07-2026_14h00p00s.zip"

    grep -q "hermes import --force" "${call_log}"
    final_hash="$(sha256sum "${tdir}/cfg/hermes-backup/state.env" | cut -d' ' -f1)"
    [ "${initial_hash}" = "${final_hash}" ]
}
assert_succeeds "Scenario E: Successful restore executes hermes import --force and preserves state" test_successful_restore_scenario

# Scenario F: Tar archive path traversal validation
test_tar_path_traversal_scenario() {
    local tdir="${TEST_TMP_DIR}/rest_f"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
CRYPT_REMOTE=
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
EOF
    chmod 0600 "${tdir}/cfg/hermes-backup/state.env"

    local rc=0
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_TAR_UNSAFE="true" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/restore.sh" "hermes-backup-20-07-2026_14h00p00s.tar.xz" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
    if grep -q "hermes import" "${call_log}"; then
        exit 1
    fi
}
assert_succeeds "Scenario F: Unsafe tar archive member path rejected" test_tar_path_traversal_scenario

echo -e "\033[0;32mALL RESTORE INTEGRATION TESTS PASSED!\033[0m"
