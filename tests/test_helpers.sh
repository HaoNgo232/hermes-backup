#!/usr/bin/env bash
# =====================================================================
# tests/test_helpers.sh - Shared Test Assertions & Utilities
# =====================================================================
set -Eeuo pipefail

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

assert_file_mode() {
    local file="$1"
    local expected_mode="$2"
    local msg="$3"
    local actual_mode
    actual_mode="$(stat -c "%a" "${file}" 2>/dev/null || stat -f "%Lp" "${file}" 2>/dev/null)"
    if [ "${actual_mode}" != "${expected_mode}" ]; then
        echo -e "\033[0;31m[FAIL]\033[0m ${msg}: expected permissions '${expected_mode}', got '${actual_mode}'" >&2
        exit 1
    else
        echo -e "\033[0;32m[PASS]\033[0m ${msg}"
    fi
}

assert_succeeds() {
    local msg="$1"
    shift
    local rc=0
    ( "$@" ) &>/dev/null || rc=$?
    if [ "${rc}" -ne 0 ]; then
        echo -e "\033[0;31m[FAIL]\033[0m ${msg} (command failed with code ${rc})" >&2
        exit 1
    else
        echo -e "\033[0;32m[PASS]\033[0m ${msg}"
    fi
}

assert_fails() {
    local msg="$1"
    shift
    local rc=0
    ( "$@" ) &>/dev/null || rc=$?
    if [ "${rc}" -eq 0 ]; then
        echo -e "\033[0;31m[FAIL]\033[0m ${msg} (command unexpectedly succeeded with exit code 0)" >&2
        exit 1
    else
        echo -e "\033[0;32m[PASS]\033[0m ${msg}"
    fi
}
