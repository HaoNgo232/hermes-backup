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

rclone_has_remote() {
    local remote_name="$1"
    rclone_require
    rclone listremotes 2>/dev/null | grep -q "^${remote_name}:$"
}

rclone_check_remote_root() {
    local remote_name="$1"
    rclone_require
    local out
    if out="$(rclone lsf "${remote_name}:" --max-depth 1 2>&1)"; then
        return 0
    else
        log_error "Cannot connect to rclone remote '${remote_name}:'."
        log_error "rclone output: ${out}"
        return 1
    fi
}

rclone_check_path_reachable() {
    local full_remote_path="$1"
    rclone_require
    rclone lsf "${full_remote_path}" --max-depth 0 &>/dev/null
}

rclone_copy_file() {
    local src_file="$1"
    local dest_remote_path="$2"
    rclone_require

    if ! rclone copyto "${src_file}" "${dest_remote_path}"; then
        log_error "rclone copyto failed from '${src_file}' to '${dest_remote_path}'."
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

    local size
    size="$(rclone size "${remote_file_path}" --json 2>/dev/null | grep -o '"bytes":[0-9]*' | cut -d: -f2 || echo 0)"
    if [ "${size:-0}" -gt 0 ]; then
        return 0
    fi

    # Alternative check using lsf
    if rclone lsf "${remote_file_path}" --max-depth 0 &>/dev/null; then
        return 0
    fi

    return 1
}

rclone_list_backups() {
    local remote_path="$1"
    rclone_require
    rclone lsf "${remote_path}" --format "tps" --files-only 2>/dev/null | grep -E ';hermes-backup-.*\.(tar\.xz|zip);' | sort || true
}

rclone_delete_remote_file() {
    local remote_file_path="$1"
    rclone_require
    rclone deletefile "${remote_file_path}" 2>/dev/null || rclone delete "${remote_file_path}" 2>/dev/null
}
