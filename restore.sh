#!/usr/bin/env bash
# =====================================================================
# Hermes Restore Script
# Tự động tải bản backup mới nhất từ Google Drive và khôi phục
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/restore.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_FILE}"
}

# Đọc cấu hình nếu có
REMOTE="gdrive-hermes:HermesBackups"
if [ -f "${SCRIPT_DIR}/config/backup.env" ]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config/backup.env"
    REMOTE="${BACKUP_REMOTE:-${CRYPT_REMOTE:-${PLAINTEXT_REMOTE:-gdrive-hermes:HermesBackups}}}"
fi

# Chắc chắn REMOTE kết thúc bằng / nếu có folder
case "${REMOTE}" in
    *:) ;;
    */) ;;
    *) REMOTE="${REMOTE}/" ;;
esac

TARGET_FILE="${1:-}"

if [ -z "${TARGET_FILE}" ]; then
    log "Đang tìm bản backup mới nhất trên Google Drive (${REMOTE})..."
    TARGET_FILE="$(rclone lsf "${REMOTE}" --format "tp" --files-only 2>/dev/null | grep -E ';hermes-backup-.*\.zip$' | sort | tail -n1 | cut -d';' -f2-)"
    
    if [ -z "${TARGET_FILE}" ]; then
        log "LỖI: Không tìm thấy bản backup nào trên Google Drive!"
        exit 1
    fi
fi

TMP_ZIP="/tmp/${TARGET_FILE}"

cleanup() {
    rm -f "${TMP_ZIP}" 2>/dev/null || true
}
trap cleanup EXIT

log "Đang tải bản backup '${TARGET_FILE}' từ Google Drive..."
rclone copyto "${REMOTE}${TARGET_FILE}" "${TMP_ZIP}"

if [ ! -f "${TMP_ZIP}" ]; then
    log "LỖI: Tải thất bại file backup ${TARGET_FILE}"
    exit 1
fi

log "Đã tải xong. Đang khôi phục dữ liệu bằng 'hermes import'..."
hermes import --force "${TMP_ZIP}"

log "Khôi phục thành công từ bản backup '${TARGET_FILE}'!"
