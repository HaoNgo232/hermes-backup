#!/usr/bin/env bash
# =====================================================================
# lib/rclone.sh - Generic Rclone Operations Wrapper
# =====================================================================
set -Eeuo pipefail

RCLONE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${RCLONE_LIB_DIR}/common.sh" ]; then
    source "${RCLONE_LIB_DIR}/common.sh"
fi

rclone_require() {
    require_command rclone
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

rclone_compose_endpoint() {
    local remote="$1"
    local path="${2:-}"

    if [ -z "${remote}" ]; then
        echo ""
        return
    fi

    local norm_remote
    norm_remote="$(rclone_normalize_remote "${remote}")"

    if [ -n "${path}" ]; then
        # strip leading slash
        path="${path#/}"
        # ensure trailing slash if it's a directory path
        case "${path}" in
            */) ;;
            *)  path="${path}/" ;;
        esac
        echo "${norm_remote}${path}"
    else
        echo "${norm_remote}"
    fi
}

rclone_has_remote() {
    local remote_name="$1"
    rclone_require
    remote_name="${remote_name%%:*}"
    rclone listremotes 2>/dev/null | grep -q "^${remote_name}:$"
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
        log_error "rclone output: ${out}"
        return 1
    fi
}

# Detailed reachability probe distinguishing root connectivity vs target folder existence
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

    # Step 1: Probe root connectivity
    if ! rclone_check_remote_root "${remote_name}"; then
        return 1
    fi

    # Step 2: Check target folder
    if rclone lsf "${full_endpoint}" --max-depth 0 &>/dev/null; then
        echo "EXISTS"
        return 0
    else
        echo "CREATED_ON_UPLOAD"
        return 0
    fi
}

# Writable probe for setup preflight check
rclone_check_writable_probe() {
    local endpoint="$1"
    rclone_require

    local probe_file
    probe_file="$(mktemp /tmp/hermes-probe-XXXXXX)"
    echo "hermes-probe-test" > "${probe_file}"

    local probe_name="hermes-probe-$(date +%s%N).tmp"
    local target_probe="${endpoint}${probe_name}"

    local success=false
    if rclone copyto "${probe_file}" "${target_probe}" &>/dev/null; then
        rclone deletefile "${target_probe}" &>/dev/null || rclone delete "${target_probe}" &>/dev/null || true
        success=true
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
        log_error "rclone output: ${out}"
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
        log_error "rclone output: ${out}"
        return 1
    fi
    return 0
}

rclone_verify_object() {
    local remote_file_path="$1"
    rclone_require

    local size_out
    size_out="$(rclone lsf "${remote_file_path}" --format "s" --files-only 2>/dev/null || echo "0")"
    size_out="$(echo "${size_out}" | tr -d '[:space:]')"

    if [[ "${size_out}" =~ ^[0-9]+$ ]] && [ "${size_out}" -gt 0 ]; then
        return 0
    fi

    log_error "Object verification failed: '${remote_file_path}' has invalid or 0 size (size='${size_out}')."
    return 1
}

# Lists backups in format: ModTime;Path;Size
rclone_list_backups() {
    local remote_path="$1"
    rclone_require
    rclone lsf "${remote_path}" --format "tps" --files-only 2>/dev/null | grep -E '^[0-9T:Z. -]+;hermes-backup-.*\.(tar\.xz|zip);[0-9]+$' | sort || true
}

rclone_delete_remote_file() {
    local remote_file_path="$1"
    rclone_require
    rclone deletefile "${remote_file_path}" 2>/dev/null || rclone delete "${remote_file_path}" 2>/dev/null
}
