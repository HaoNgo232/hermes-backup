#!/usr/bin/env bash
# =====================================================================
# lib/hermes.sh - Hermes executable and environment resolution
# =====================================================================
set -Eeuo pipefail

if [ "${HERMES_HERMES_SH_LOADED:-false}" = "true" ]; then
    return 0
fi
HERMES_HERMES_SH_LOADED=true

HERMES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERMES_LIB_DIR}/common.sh"
source "${HERMES_LIB_DIR}/state.sh"

hermes_apply_persisted_environment() {
    state_load

    local stored_home
    stored_home="$(state_get "HERMES_HOME" "")"

    # Explicit non-empty environment value wins. Otherwise use stored state.
    if [ -z "${HERMES_HOME:-}" ] && [ -n "${stored_home}" ]; then
        export HERMES_HOME="${stored_home}"
    fi
}

hermes_resolve_binary() {
    state_load

    local stored_bin
    stored_bin="$(state_get "HERMES_BIN" "")"

    # An explicitly supplied non-empty HERMES_BIN is authoritative.
    # If it is invalid, fail instead of silently falling back.
    if [ -n "${HERMES_BIN:-}" ]; then
        if [ ! -x "${HERMES_BIN}" ]; then
            log_error "Explicit HERMES_BIN '${HERMES_BIN}' is not executable."
            return 1
        fi
        printf '%s\n' "${HERMES_BIN}"
        return 0
    fi

    if [ -n "${stored_bin}" ]; then
        if [ ! -x "${stored_bin}" ]; then
            log_error "Stored HERMES_BIN '${stored_bin}' is not executable."
            log_error "Repair HERMES_BIN in state or run setup with a valid explicit HERMES_BIN."
            return 1
        fi
        printf '%s\n' "${stored_bin}"
        return 0
    fi

    local discovered
    discovered="$(command -v hermes 2>/dev/null || true)"
    if [ -n "${discovered}" ] && [ -x "${discovered}" ]; then
        printf '%s\n' "${discovered}"
        return 0
    fi

    log_error "'hermes' binary not found. Set HERMES_BIN=/path/to/hermes or add it to PATH."
    return 1
}
