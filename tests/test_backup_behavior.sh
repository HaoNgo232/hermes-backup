#!/usr/bin/env bash
# =====================================================================
# tests/test_backup_behavior.sh - Mocked Behavioral Tests for Backup
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

echo "=== Running Backup Behavioral Tests ==="

MOCK_BIN="${TEST_TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"

# Create mock hermes binary
cat <<'EOF' > "${MOCK_BIN}/hermes"
#!/usr/bin/env bash
if [ "${1:-}" = "export" ]; then
    echo "mock-backup-archive-content"
    exit 0
elif [ "${1:-}" = "--version" ]; then
    echo "hermes v1.0.0-mock"
    exit 0
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/hermes"

# Create mock rclone binary
cat <<'EOF' > "${MOCK_BIN}/rclone"
#!/usr/bin/env bash
cmd="${1:-}"
shift || true

case "${cmd}" in
    listremotes)
        if [ "${MOCK_HAS_CRYPT:-false}" = "true" ]; then
            echo "gdrive-hermes:"
            echo "hermes-backup-crypt:"
        else
            echo "gdrive-hermes:"
        fi
        ;;
    lsf)
        if [ "${MOCK_RCLONE_LSF_FAIL:-false}" = "true" ]; then
            echo "Error 500: Server error" >&2
            exit 1
        fi
        echo "2026-07-20T10:00:00Z;hermes-backup-01-01-2026_10h00p00s.zip;1024"
        ;;
    copyto)
        echo "copyto:$1->$2" >> "${MOCK_CALL_LOG}"
        if [ "${MOCK_RCLONE_COPY_FAIL:-false}" = "true" ]; then
            exit 1
        fi
        ;;
    deletefile)
        echo "deletefile:$1" >> "${MOCK_CALL_LOG}"
        ;;
    config)
        sub="${1:-}"
        if [ "${sub}" = "show" ]; then
            cat <<'CONF'
type = crypt
remote = gdrive-hermes:HermesBackupsEncrypted
filename_encryption = standard
directory_name_encryption = true
password = MOCK
password2 = MOCK
CONF
        fi
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "${MOCK_BIN}/rclone"

# Test 1: Plaintext backup uploads to base destination
test_plaintext_backup() {
    local tdir="${TEST_TMP_DIR}/pt_backup"
    mkdir -p "${tdir}/cfg"
    export MOCK_CALL_LOG="${tdir}/call.log"
    touch "${MOCK_CALL_LOG}"

    env \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        MOCK_CALL_LOG="${MOCK_CALL_LOG}" \
        MOCK_HAS_CRYPT="false" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/rclone.sh"
            source "${REPO_DIR}/lib/encryption.sh"

            state_set_many \
                "ENCRYPTION_ENABLED" "false" \
                "ENCRYPTION_MODE" "none" \
                "BASE_REMOTE" "gdrive-hermes:" \
                "BASE_PATH" "HermesBackups"

            dest="$(encryption_get_active_destination)"
            if [ "${dest}" != "gdrive-hermes:HermesBackups/" ]; then
                echo "Unexpected destination: ${dest}" >&2
                exit 1
            fi
        '
}
assert_succeeds "Plaintext backup resolves base destination" test_plaintext_backup

# Test 2: Encrypted backup resolves crypt destination
test_encrypted_backup() {
    local tdir="${TEST_TMP_DIR}/enc_backup"
    mkdir -p "${tdir}/cfg/hermes-backup"

    cat <<'EOF' > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted
CRYPT_REMOTE=hermes-backup-crypt:
CRYPT_PATH=
RECOVERY_NOTICE_STATE=shown
ENCRYPTION_SETUP_COMPLETED_AT=
EOF
    chmod 0600 "${tdir}/cfg/hermes-backup/state.env"

    export MOCK_CALL_LOG="${tdir}/call.log"
    touch "${MOCK_CALL_LOG}"

    env \
        PATH="${MOCK_BIN}:${PATH}" \
        HERMES_BIN="${MOCK_BIN}/hermes" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        REPO_DIR="${REPO_DIR}" \
        MOCK_CALL_LOG="${MOCK_CALL_LOG}" \
        MOCK_HAS_CRYPT="true" \
        bash -Eeuo pipefail -c '
            source "${REPO_DIR}/lib/common.sh"
            source "${REPO_DIR}/lib/state.sh"
            source "${REPO_DIR}/lib/rclone.sh"
            source "${REPO_DIR}/lib/encryption.sh"

            state_load
            dest="$(encryption_get_active_destination)"
            if [ "${dest}" != "hermes-backup-crypt:" ]; then
                echo "Unexpected crypt destination: ${dest}" >&2
                exit 1
            fi
        '
}
assert_succeeds "Encrypted backup resolves crypt destination" test_encrypted_backup

echo -e "\033[0;32mALL BACKUP BEHAVIORAL TESTS PASSED!\033[0m"
