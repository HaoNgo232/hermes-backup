#!/usr/bin/env bash
# =====================================================================
# tests/run_tests.sh - Master Test Suite Runner
# =====================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "======================================================================"
echo "                   RUNNING HERMES TEST SUITE"
echo "======================================================================"

TEST_FILES=(
    "${ROOT}/tests/test_state.sh"
    "${ROOT}/tests/test_encryption_logic.sh"
    "${ROOT}/tests/test_idempotency.sh"
    "${ROOT}/tests/test_integrity_manifest.sh"
    "${ROOT}/tests/test_secret_leaks.sh"
    "${ROOT}/tests/test_systemd_render.sh"
    "${ROOT}/tests/test_backup_behavior.sh"
    "${ROOT}/tests/test_restore_behavior.sh"
    "${ROOT}/tests/test_hermes_resolution.sh"
)

FAILED=0
for test_file in "${TEST_FILES[@]}"; do
    test_name="$(basename "${test_file}")"
    echo ""
    echo "==> Executing ${test_name}..."
    
    # Run each test script in a clean, isolated subshell environment
    if bash "${test_file}"; then
        echo -e "\033[0;32m✔ ${test_name} SUCCESS\033[0m"
    else
        echo -e "\033[0;31m✖ ${test_name} FAILED\033[0m"
        FAILED=1
    fi
done

echo ""
echo "======================================================================"
if [ "${FAILED}" -eq 0 ]; then
    echo -e "\033[0;32mALL TEST SUITES PASSED SUCCESSFULLY!\033[0m"
    exit 0
else
    echo -e "\033[0;31mONE OR MORE TEST SUITES FAILED!\033[0m"
    exit 1
fi
