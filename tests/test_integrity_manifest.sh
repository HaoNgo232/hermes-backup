#!/usr/bin/env bash
# =====================================================================
# tests/test_integrity_manifest.sh - SHA-256 Integrity Manifest Tests
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

source "${TEST_DIR}/test_helpers.sh"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-manifest-test-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Running SHA-256 Integrity Manifest Tests ==="

MOCK_BIN="${TEST_TMP_DIR}/bin"
mkdir -p "${MOCK_BIN}"

# Mock hermes binary
cat <<'EOF' > "${MOCK_BIN}/hermes"
#!/usr/bin/env bash
if [ "${1:-}" = "backup" ]; then
    out_file="$3"
    mkdir -p "$(dirname "${out_file}")"
    echo "dummy-hermes-export-data-content" > "${out_file}"
    exit 0
elif [ "${1:-}" = "import" ]; then
    echo "hermes $*" >> "${MOCK_CALL_LOG}"
    exit 0
elif [ "${1:-}" = "--version" ]; then
    echo "hermes v1.0.0-mock"
    exit 0
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/hermes"

# Mock zip binary
cat <<'EOF' > "${MOCK_BIN}/zip"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${MOCK_BIN}/zip"

# Mock unzip binary
cat <<'EOF' > "${MOCK_BIN}/unzip"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${MOCK_BIN}/unzip"

# Mock tar binary
cat <<'EOF' > "${MOCK_BIN}/tar"
#!/usr/bin/env bash
if [ "${1:-}" = "-tf" ]; then
    echo "safe_file.txt"
    exit 0
fi
exit 0
EOF
chmod +x "${MOCK_BIN}/tar"

# Mock rclone binary with file system backstore for accurate SHA-256 test
cat <<'EOF' > "${MOCK_BIN}/rclone"
#!/usr/bin/env bash
cmd="${1:-}"
shift || true

REMOTE_STORAGE="${MOCK_REMOTE_STORAGE:-/tmp/mock-remote-store}"
mkdir -p "${REMOTE_STORAGE}"

case "${cmd}" in
    listremotes)
        echo "gdrive-hermes:"
        ;;
    lsf)
        target="${1:-}"
        target_name="$(basename "${target}")"
        if [ -f "${REMOTE_STORAGE}/${target_name}" ]; then
            size="$(stat -c%s "${REMOTE_STORAGE}/${target_name}" 2>/dev/null || echo 100)"
            echo "${size}"
        else
            echo "2026-07-20T10:00:00Z;hermes-backup-20-07-2026_14h00p00s.zip;1024"
        fi
        ;;
    copyto)
        args=("$@")
        dest="${args[${#args[@]}-1]}"
        src="${args[${#args[@]}-2]}"
        src_name="$(basename "${src}")"
        dest_name="$(basename "${dest}")"
        if [ -f "${src}" ]; then
            cp -f "${src}" "${REMOTE_STORAGE}/${dest_name}"
        elif [ -f "${REMOTE_STORAGE}/${src_name}" ]; then
            cp -f "${REMOTE_STORAGE}/${src_name}" "${dest}"
        else
            echo "Error 404: File not found" >&2
            exit 1
        fi
        ;;
    deletefile)
        target="$1"
        target_name="$(basename "${target}")"
        rm -f "${REMOTE_STORAGE}/${target_name}" 2>/dev/null || true
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "${MOCK_BIN}/rclone"

# Scenario A: Backup generates and uploads valid .sha256 manifest
test_manifest_backup_generation() {
    local tdir="${TEST_TMP_DIR}/man_a"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs" "${tdir}/remote"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
ENABLE_SUPER_COMPRESSION=false
HERMES_BIN=${MOCK_BIN}/hermes
EOF

    env HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        BACKUP_LOG_DIR="${tdir}/logs" \
        BACKUP_LOCK_FILE="${tdir}/backup.lock" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_REMOTE_STORAGE="${tdir}/remote" \
        PATH="${MOCK_BIN}:${PATH}" \
        bash "${REPO_DIR}/backup.sh" >/dev/null

    local backup_file manifest_file
    backup_file="$(find "${tdir}/remote" -name "hermes-backup-*.zip" | head -n1)"
    manifest_file="$(find "${tdir}/remote" -name "hermes-backup-*.zip.sha256" | head -n1)"

    if [ ! -f "${backup_file}" ] || [ ! -f "${manifest_file}" ]; then
        return 1
    fi

    local expected_hash actual_hash
    expected_hash="$(awk '{print $1}' "${manifest_file}")"
    actual_hash="$(sha256sum "${backup_file}" | awk '{print $1}')"

    [ "${expected_hash}" = "${actual_hash}" ]
}
assert_succeeds "Manifest generation and upload during backup" test_manifest_backup_generation

# Scenario B: Restore with valid manifest verifies hash and calls hermes import
test_restore_valid_manifest() {
    local tdir="${TEST_TMP_DIR}/man_b"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs" "${tdir}/remote"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
ENABLE_SUPER_COMPRESSION=false
HERMES_BIN=${MOCK_BIN}/hermes
EOF

    local target_name="hermes-backup-20-07-2026_14h00p00s.zip"
    echo "valid-backup-archive-content" > "${tdir}/remote/${target_name}"
    (cd "${tdir}/remote" && sha256sum "${target_name}") > "${tdir}/remote/${target_name}.sha256"

    env HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_REMOTE_STORAGE="${tdir}/remote" \
        PATH="${MOCK_BIN}:${PATH}" \
        bash "${REPO_DIR}/restore.sh" "${target_name}" >/dev/null

    grep -q "hermes import --force" "${call_log}"
}
assert_succeeds "Restore with valid SHA-256 manifest succeeds" test_restore_valid_manifest

# Scenario C: Restore with checksum mismatch fails closed
test_restore_checksum_mismatch() {
    local tdir="${TEST_TMP_DIR}/man_c"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs" "${tdir}/remote"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
ENABLE_SUPER_COMPRESSION=false
HERMES_BIN=${MOCK_BIN}/hermes
EOF

    local target_name="hermes-backup-20-07-2026_14h00p00s.zip"
    echo "valid-backup-archive-content" > "${tdir}/remote/${target_name}"
    echo "0000000000000000000000000000000000000000000000000000000000000000  ${target_name}" > "${tdir}/remote/${target_name}.sha256"

    env HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_REMOTE_STORAGE="${tdir}/remote" \
        PATH="${MOCK_BIN}:${PATH}" \
        bash "${REPO_DIR}/restore.sh" "${target_name}"
}
assert_fails "Restore with checksum mismatch fails closed" test_restore_checksum_mismatch

# Scenario D: Restore with malformed manifest fails closed
test_restore_malformed_manifest() {
    local tdir="${TEST_TMP_DIR}/man_d"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs" "${tdir}/remote"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
ENABLE_SUPER_COMPRESSION=false
HERMES_BIN=${MOCK_BIN}/hermes
EOF

    local target_name="hermes-backup-20-07-2026_14h00p00s.zip"
    echo "valid-backup-archive-content" > "${tdir}/remote/${target_name}"
    echo "INVALID_NOT_A_HASH" > "${tdir}/remote/${target_name}.sha256"

    env HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_REMOTE_STORAGE="${tdir}/remote" \
        PATH="${MOCK_BIN}:${PATH}" \
        bash "${REPO_DIR}/restore.sh" "${target_name}"
}
assert_fails "Restore with malformed manifest fails closed" test_restore_malformed_manifest

# Scenario E: Legacy restore without manifest issues warning and succeeds
test_restore_legacy_missing_manifest() {
    local tdir="${TEST_TMP_DIR}/man_e"
    mkdir -p "${tdir}/cfg/hermes-backup" "${tdir}/home" "${tdir}/logs" "${tdir}/remote"
    local call_log="${tdir}/call.log"
    touch "${call_log}"

    cat <<EOF > "${tdir}/cfg/hermes-backup/state.env"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups
ENABLE_SUPER_COMPRESSION=false
HERMES_BIN=${MOCK_BIN}/hermes
EOF

    local target_name="hermes-backup-20-07-2026_14h00p00s.zip"
    echo "legacy-backup-content" > "${tdir}/remote/${target_name}"

    env HOME="${tdir}/home" \
        XDG_CONFIG_HOME="${tdir}/cfg" \
        RESTORE_LOG_DIR="${tdir}/logs" \
        MOCK_CALL_LOG="${call_log}" \
        MOCK_REMOTE_STORAGE="${tdir}/remote" \
        PATH="${MOCK_BIN}:${PATH}" \
        bash "${REPO_DIR}/restore.sh" "${target_name}" >/dev/null

    grep -q "hermes import --force" "${call_log}" && grep -q "Legacy backup detected" "${tdir}/logs/restore.log"
}
assert_succeeds "Legacy restore without manifest logs warning and succeeds" test_restore_legacy_missing_manifest

echo -e "\033[0;32mALL INTEGRITY MANIFEST TESTS PASSED!\033[0m"
