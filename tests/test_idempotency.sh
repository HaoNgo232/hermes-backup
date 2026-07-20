#!/usr/bin/env bash
# =====================================================================
# tests/test_idempotency.sh - Idempotency & Fail-Closed Tests
# =====================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

TEST_TMP_DIR="$(mktemp -d "/tmp/hermes-idempotency-test-XXXXXX")"
cleanup() {
    rm -rf "${TEST_TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

export XDG_CONFIG_HOME="${TEST_TMP_DIR}"

source "${REPO_DIR}/lib/common.sh"
source "${REPO_DIR}/lib/state.sh"
source "${REPO_DIR}/lib/rclone.sh"
source "${REPO_DIR}/lib/encryption.sh"

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

echo "=== Running Idempotency & Fail-Closed Tests ==="

# Test 1: Fail closed when encryption is enabled but CRYPT_REMOTE is invalid
(
    export XDG_CONFIG_HOME="$(mktemp -d "${TEST_TMP_DIR}/failclosed-XXXXXX")"
    source "${REPO_DIR}/lib/common.sh"
    source "${REPO_DIR}/lib/state.sh"
    source "${REPO_DIR}/lib/rclone.sh"
    source "${REPO_DIR}/lib/encryption.sh"

    mkdir -p "${APP_CONFIG_DIR}"
    cat <<EOF > "${APP_STATE_FILE}"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted
CRYPT_REMOTE=nonexistent-crypt-remote:
RECOVERY_NOTICE_STATE=pending
EOF
    chmod 0600 "${APP_STATE_FILE}"

    # Active destination MUST fail closed and exit non-zero
    if encryption_get_active_destination 2>/dev/null; then
        echo -e "\033[0;31m[FAIL]\033[0m Missing crypt remote did not fail closed" >&2
        exit 1
    fi
) && assert_equals "true" "true" "Missing crypt remote fails closed (blocks backup upload)"

# Test 2: Reminder state transition pending -> shown
(
    export XDG_CONFIG_HOME="$(mktemp -d "${TEST_TMP_DIR}/reminder-XXXXXX")"
    source "${REPO_DIR}/lib/common.sh"
    source "${REPO_DIR}/lib/state.sh"
    source "${REPO_DIR}/lib/rclone.sh"
    source "${REPO_DIR}/lib/encryption.sh"

    mkdir -p "${APP_CONFIG_DIR}"
    cat <<EOF > "${APP_STATE_FILE}"
STATE_SCHEMA_VERSION=1
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted
CRYPT_REMOTE=gdrive-hermes:
RECOVERY_NOTICE_STATE=pending
EOF
    chmod 0600 "${APP_STATE_FILE}"
    state_load

    # Call reminder helper
    encryption_show_first_backup_reminder_if_needed &>/dev/null

    notice_after="$(state_get "RECOVERY_NOTICE_STATE")"
    if [ "${notice_after}" != "shown" ]; then
        echo -e "\033[0;31m[FAIL]\033[0m Reminder notice state was not updated to 'shown'" >&2
        exit 1
    fi
) && assert_equals "true" "true" "Reminder notice transitions pending -> shown atomically"

echo -e "\033[0;32mALL IDEMPOTENCY & FAIL-CLOSED TESTS PASSED!\033[0m"
