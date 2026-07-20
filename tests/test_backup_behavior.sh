#!/usr/bin/env bash
# =====================================================================
# tests/test_backup_behavior.sh - Full Mocked Integration Tests for Backup
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

source "${TEST_DIR}/test_helpers.sh"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-backup-beh-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running Full Mocked Backup Integration Tests ==="

MOCK_BIN="${TEST_TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"

# Mock hermes binary
cat <<'EOF' > "${MOCK_BIN}/hermes"
#!/usr/bin/env bash
if [ "${1:-}" = "backup" ] && [ "${2:-}" = "-o" ]; then
    echo "hermes backup -o $3" >> "${MOCK_CALL_LOG}"
    mkdir -p "$(dirname "$3")"
    echo "mock-zip-content" > "$3"
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
out_dir=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-d" ]; then
        out_dir="$2"
        shift 2
    else
        shift
    fi
done
if [ -n "${out_dir}" ]; then
    mkdir -p "${out_dir}"
    echo "mock-unzipped-file" > "${out_dir}/mock.txt"
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/unzip"

# Mock tar binary
cat <<'EOF' > "${MOCK_BIN}/tar"
#!/usr/bin/env bash
echo "tar $*" >> "${MOCK_CALL_LOG}"
echo "mock-tar-stream"
exit 0
EOF
chmod +x "${MOCK_BIN}/tar"

# Mock xz binary
cat <<'EOF' > "${MOCK_BIN}/xz"
#!/usr/bin/env bash
echo "xz $*" >> "${MOCK_CALL_LOG}"
echo "mock-xz-compressed-stream"
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
        shift || true
        fmt=""
        while [ $# -gt 0 ]; do
            if [ "$1" = "--format" ]; then
                fmt="$2"
                shift 2
            else
                shift
            fi
        done
        if [ "${fmt}" = "s" ]; then
            if [ "${MOCK_VERIFY_FAIL:-false}" = "true" ]; then
                echo "0"
            else
                echo "12345"
            fi
        elif [ "${fmt}" = "tps" ]; then
            if [ "${MOCK_LIST_FAIL:-false}" = "true" ]; then
                echo "Error 500: Listing failed" >&2
                exit 1
            fi
            if [ "${MOCK_WITH_GFS_FIXTURES:-false}" = "true" ]; then
                echo "2026-07-20T10:00:00Z;hermes-backup-01-01-2026_10h00p00s.tar.xz;1024"
            fi
        else
            if [ "${MOCK_CRYPT_INVALID:-false}" = "true" ] && [[ "${target}" == *"crypt"* ]]; then
                echo "Error 404: Crypt invalid" >&2
                exit 1
            fi
            echo "2026-07-20T10:00:00Z;hermes-backup-01-01-2026_10h00p00s.tar.xz;1024"
        fi
        ;;
    copyto)
        echo "rclone copyto $1 -> $2" >> "${MOCK_CALL_LOG}"
        if [ "${MOCK_RCLONE_COPY_FAIL:-false}" = "true" ]; then
            echo "Error: Upload failed" >&2
            exit 1
        fi
        ;;
    deletefile)
        echo "rclone deletefile $1" >> "${MOCK_CALL_LOG}"
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

# Scenario A: Plaintext success
test_plaintext_backup_scenario() {
    local tdir="${TEST_TMP_DIR}/scen_a"
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
        BACKUP_LOG_DIR="${tdir}/logs" \
        BACKUP_LOCK_FILE="${tdir}/backup.lock" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_HAS_CRYPT="false" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/backup.sh"

    # Assertions
    grep -q "hermes backup -o" "${call_log}"
    grep -q "rclone copyto .* -> gdrive-hermes:HermesBackups/hermes-backup-" "${call_log}"
    grep -q "rclone lsf gdrive-hermes:HermesBackups/hermes-backup-.* --format s --files-only" "${call_log}"
    if grep -q "hermes-backup-crypt:" "${call_log}"; then
        exit 1
    fi
}
assert_succeeds "Scenario A: Plaintext backup succeeds" test_plaintext_backup_scenario

# Scenario B: Encrypted success
test_encrypted_backup_scenario() {
    local tdir="${TEST_TMP_DIR}/scen_b"
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
        BACKUP_LOG_DIR="${tdir}/logs" \
        BACKUP_LOCK_FILE="${tdir}/backup.lock" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_HAS_CRYPT="true" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/backup.sh"

    # Assertions
    grep -q "rclone copyto .* -> hermes-backup-crypt:hermes-backup-" "${call_log}"
    if grep -q "rclone copyto .* -> gdrive-hermes:" "${call_log}"; then
        exit 1
    fi
}
assert_succeeds "Scenario B: Encrypted backup succeeds" test_encrypted_backup_scenario

# Scenario C: Crypt remote unavailable
test_crypt_unavailable_assert() {
    local tdir="${TEST_TMP_DIR}/scen_c_assert"
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

    local rc=0
    env \
        HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        BACKUP_LOG_DIR="${tdir}/logs" \
        BACKUP_LOCK_FILE="${tdir}/backup.lock" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_HAS_CRYPT="false" \
        MOCK_CRYPT_INVALID="true" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/backup.sh" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
    if grep -q "hermes backup -o" "${call_log}" || \
       grep -q "rclone copyto" "${call_log}" || \
       grep -q "rclone deletefile" "${call_log}"; then
        exit 1
    fi
}
assert_succeeds "Scenario C: Crypt remote unavailable aborts backup early" test_crypt_unavailable_assert

# Scenario D: Upload failure
test_upload_failure_scenario() {
    local tdir="${TEST_TMP_DIR}/scen_d"
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
        BACKUP_LOG_DIR="${tdir}/logs" \
        BACKUP_LOCK_FILE="${tdir}/backup.lock" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_RCLONE_COPY_FAIL="true" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/backup.sh" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
    if grep -q "format s --files-only" "${call_log}" || \
       grep -q "rclone deletefile" "${call_log}"; then
        exit 1
    fi
}
assert_succeeds "Scenario D: Upload failure aborts workflow" test_upload_failure_scenario

# Scenario E: Verification failure
test_verification_failure_scenario() {
    local tdir="${TEST_TMP_DIR}/scen_e"
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
        BACKUP_LOG_DIR="${tdir}/logs" \
        BACKUP_LOCK_FILE="${tdir}/backup.lock" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_VERIFY_FAIL="true" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/backup.sh" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
    grep -q "rclone copyto" "${call_log}"
    if grep -q "rclone deletefile" "${call_log}"; then
        exit 1
    fi
}
assert_succeeds "Scenario E: Verification failure aborts retention" test_verification_failure_scenario

# Scenario F: Listing failure during retention
test_listing_failure_retention_scenario() {
    local tdir="${TEST_TMP_DIR}/scen_f"
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
        BACKUP_LOG_DIR="${tdir}/logs" \
        BACKUP_LOCK_FILE="${tdir}/backup.lock" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_LIST_FAIL="true" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/backup.sh" &>/dev/null || rc=$?

    [ "${rc}" -ne 0 ]
    grep -q "rclone copyto" "${call_log}"
    if grep -q "rclone deletefile" "${call_log}"; then
        exit 1
    fi
}
assert_succeeds "Scenario F: Listing failure during retention causes backup failure" test_listing_failure_retention_scenario

# Scenario G: Super compression enabled produces .tar.xz
test_super_compression_enabled_scenario() {
    local tdir="${TEST_TMP_DIR}/scen_g"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
ENABLE_SUPER_COMPRESSION=true
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
        BACKUP_LOG_DIR="${tdir}/logs" \
        BACKUP_LOCK_FILE="${tdir}/backup.lock" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_HAS_CRYPT="false" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/backup.sh"

    grep -q "xz -9e" "${call_log}"
    grep -q "rclone copyto .* -> gdrive-hermes:HermesBackups/hermes-backup-.*\.tar\.xz" "${call_log}"
}
assert_succeeds "Scenario G: Super compression enabled produces .tar.xz" test_super_compression_enabled_scenario

# Scenario H: Super compression disabled produces .zip directly without calling xz
test_super_compression_disabled_scenario() {
    local tdir="${TEST_TMP_DIR}/scen_h"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
ENABLE_SUPER_COMPRESSION=false
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
        BACKUP_LOG_DIR="${tdir}/logs" \
        BACKUP_LOCK_FILE="${tdir}/backup.lock" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_HAS_CRYPT="false" \
        REPO_DIR="${REPO_DIR}" \
        bash "${REPO_DIR}/backup.sh"

    if grep -q "xz" "${call_log}"; then
        echo "xz was called unexpectedly when super compression disabled" >&2
        exit 1
    fi
    grep -q "rclone copyto .* -> gdrive-hermes:HermesBackups/hermes-backup-.*\.zip" "${call_log}"
}
assert_succeeds "Scenario H: Super compression disabled produces .zip directly" test_super_compression_disabled_scenario

echo -e "\033[0;32mALL BACKUP INTEGRATION TESTS PASSED!\033[0m"
