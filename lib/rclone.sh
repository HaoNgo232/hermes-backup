#!/usr/bin/env bash
# =====================================================================
# lib/rclone.sh - Generic Rclone Operations Wrapper
# =====================================================================
set -Eeuo pipefail

if [ "${HERMES_RCLONE_SH_LOADED:-false}" = "true" ]; then
    return 0
fi
HERMES_RCLONE_SH_LOADED=true

RCLONE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${RCLONE_LIB_DIR}/common.sh" ]; then
    source "${RCLONE_LIB_DIR}/common.sh"
fi

rclone_require() {
    require_command rclone
}

# Redact potentially sensitive tokens/passwords from output logs
rclone_sanitize_output() {
    local text="$1"
    printf '%s\n' "${text}" | sed -E \
        -e 's/([Pp]assword2?|[Tt]oken|[Aa]ccess_[Tt]oken|[Rr]efresh_[Tt]oken|[Cc]lient_[Ss]ecret)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\1 = [REDACTED]/g' \
        -e 's/"(password2?|token|access_token|refresh_token|client_secret)"[[:space:]]*:[[:space:]]*"[^"]*"/"\1": "[REDACTED]"/Ig' \
        -e 's/([Aa]uthorization:[[:space:]]*)?[Bb]earer[[:space:]]+[A-Za-z0-9._~+\/=-]+/Authorization: Bearer [REDACTED]/g'
}

rclone_normalize_remote() {
    local remote="$1"
    case "${remote}" in
        *:) echo "${remote}" ;;
        */) echo "${remote}" ;;
        *)  echo "${remote}/" ;;
    esac
}

rclone_get_remote_name() {
    local remote="$1"
    local name="${remote%%:*}"
    if [ "${name}" != "${remote}" ]; then
        echo "${name}"
    else
        echo ""
    fi
}

rclone_parse_remote_and_path() {
    local input_str="$1"
    local name
    name="$(rclone_get_remote_name "${input_str}")"

    if [ -n "${name}" ]; then
        local remote_part="${name}:"
        local path_part="${input_str#*:}"
        path_part="${path_part#/}"
        echo "${remote_part}|${path_part}"
    else
        echo "|${input_str}"
    fi
}

rclone_normalize_base_endpoint() {
    local remote="$1"
    local path="${2:-}"

    local name
    name="$(rclone_get_remote_name "${remote}")"
    if [ -n "${name}" ]; then
        if [ -n "${path}" ]; then
            path="${path#/}"
            path="${path%/}"
            echo "${name}:${path}"
        else
            echo "${name}:"
        fi
    else
        echo "${remote}"
    fi
}

rclone_compose_endpoint() {
    local remote="$1"
    local path="${2:-}"

    if [ -z "${remote}" ]; then
        echo ""
        return
    fi

    local parsed
    parsed="$(rclone_parse_remote_and_path "${remote}")"
    local base_remote_part="${parsed%%|*}"
    local embedded_path="${parsed#*|}"

    local effective_remote="${base_remote_part}"
    [ -z "${effective_remote}" ] && effective_remote="${remote}"

    local effective_path="${path}"
    if [ -z "${effective_path}" ]; then
        effective_path="${embedded_path}"
    elif [ -n "${embedded_path}" ] && [ "${effective_path}" != "${embedded_path}" ]; then
        if [[ "${effective_path}" == "${embedded_path}"* ]]; then
            :
        else
            effective_path="${embedded_path%/}/${effective_path#/}"
        fi
    fi

    effective_remote="$(rclone_normalize_remote "${effective_remote}")"

    if [ -n "${effective_path}" ]; then
        effective_path="${effective_path#/}"
        case "${effective_path}" in
            */) ;;
            *)  effective_path="${effective_path}/" ;;
        esac
        echo "${effective_remote}${effective_path}"
    else
        echo "${effective_remote}"
    fi
}

rclone_has_remote() {
    local remote_name="$1"
    rclone_require
    remote_name="${remote_name%%:*}"
    rclone listremotes 2>/dev/null | grep -Fxq -- "${remote_name}:"
}

rclone_check_remote_root() {
    local remote_name="$1"
    rclone_require
    remote_name="${remote_name%%:*}"

    local out
    if out="$(rclone lsf "${remote_name}:" --max-depth 1 2>&1)"; then
        return 0
    else
        log_error "Cannot connect to rclone remote '${remote_name}:'."
        log_error "rclone output: $(rclone_sanitize_output "${out}")"
        return 1
    fi
}

rclone_check_reachability() {
    local remote_str="$1"
    local path_str="${2:-}"

    local full_endpoint
    full_endpoint="$(rclone_compose_endpoint "${remote_str}" "${path_str}")"

    local remote_name
    remote_name="$(rclone_get_remote_name "${full_endpoint}")"

    if [ -z "${remote_name}" ]; then
        log_error "Invalid remote string: '${remote_str}'"
        return 1
    fi

    if ! rclone_has_remote "${remote_name}"; then
        log_error "rclone remote '${remote_name}:' is not configured."
        return 1
    fi

    if ! rclone_check_remote_root "${remote_name}"; then
        return 1
    fi

    # Subfolder target may not exist yet on fresh setup, so root reachability is sufficient.
    echo "EXISTS"
    return 0
}

rclone_check_writable_probe() {
    local endpoint="$1"
    rclone_require

    endpoint="${endpoint%/}/"

    local probe_file
    probe_file="$(mktemp "${TMPDIR:-/tmp}/hermes-probe-XXXXXX")"
    chmod 0600 "${probe_file}" 2>/dev/null || true
    printf '%s\n' "hermes-probe-test" > "${probe_file}"

    local probe_name
    probe_name="hermes-probe-$(date +%s%N).tmp"
    local target_probe="${endpoint}${probe_name}"

    local success=false
    if rclone copyto "${probe_file}" "${target_probe}" &>/dev/null; then
        if rclone deletefile "${target_probe}" &>/dev/null; then
            success=true
        else
            log_error "Writable probe uploaded successfully but remote probe cleanup failed."
            success=false
        fi
    fi

    rm -f "${probe_file}" 2>/dev/null || true

    if [ "${success}" = true ]; then
        return 0
    else
        log_error "Writable probe failed for endpoint '${endpoint}'."
        return 1
    fi
}

rclone_copy_file() {
    local src_file="$1"
    local dest_remote_path="$2"
    rclone_require

    local out
    if ! out="$(rclone copyto "${src_file}" "${dest_remote_path}" 2>&1)"; then
        log_error "rclone copyto failed from '${src_file}' to '${dest_remote_path}'."
        log_error "rclone output: $(rclone_sanitize_output "${out}")"
        return 1
    fi
    return 0
}

rclone_fetch_file() {
    local src_remote_path="$1"
    local dest_local_file="$2"
    rclone_require

    local out
    if ! out="$(rclone copyto "${src_remote_path}" "${dest_local_file}" 2>&1)"; then
        log_error "rclone copyto download failed for '${src_remote_path}'."
        log_error "rclone output: $(rclone_sanitize_output "${out}")"
        return 1
    fi
    return 0
}

rclone_verify_object() {
    local remote_file_path="$1"
    rclone_require

    local out
    if ! out="$(rclone lsf "${remote_file_path}" --format "s" --files-only 2>&1)"; then
        log_error "Unable to verify remote object '${remote_file_path}'."
        log_error "rclone output: $(rclone_sanitize_output "${out}")"
        return 1
    fi

    local size_out
    size_out="$(printf '%s' "${out}" | tr -d '[:space:]')"

    if [[ "${size_out}" =~ ^[0-9]+$ ]] && [ "${size_out}" -gt 0 ]; then
        return 0
    fi

    log_error "Object verification failed: '${remote_file_path}' has invalid or 0 size (size='${size_out}')."
    return 1
}

# Clean list backups: Returns error if rclone lsf fails, so callers don't falsely report empty folder
rclone_list_backups() {
    local remote_path="$1"
    rclone_require

    local raw_lsf
    if ! raw_lsf="$(rclone lsf "${remote_path}" --format "tps" --files-only 2>&1)"; then
        log_error "Failed to list remote backups at '${remote_path}'."
        log_error "rclone output: $(rclone_sanitize_output "${raw_lsf}")"
        return 1
    fi

    echo "${raw_lsf}" | grep -E '^[0-9T:Z. -]+;hermes-backup-.*\.(tar\.xz|zip);[0-9]+$' | sort || true
}

# Delete file specifically with deletefile (no recursive delete fallback)
rclone_delete_remote_file() {
    local remote_file_path="$1"
    rclone_require
    local out
    if ! out="$(rclone deletefile "${remote_file_path}" 2>&1)"; then
        log_error "rclone deletefile failed for '${remote_file_path}'."
        log_error "rclone output: $(rclone_sanitize_output "${out}")"
        return 1
    fi
}
