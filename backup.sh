#!/usr/bin/env bash
# =====================================================================
# Hermes Backup Script
# Tự động tạo bản backup bằng 'hermes backup' và đẩy lên Google Drive
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/backup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "${LOG_FILE}"
}

# ---------------------------------------------------------------------
# CẤU HÌNH ĐỊA CHỈ LƯU TRỮ VÀ TÊN FILE BACKUP
# ---------------------------------------------------------------------
REMOTE="gdrive-hermes:HermesBackups"
MAX_BACKUPS="${MAX_BACKUPS:-24}"

# Định dạng ngày giờ thuần Việt: DD-MM-YYYY_HHhMMpSSs (VD: 20-07-2026_14h47p55s)
TIMESTAMP="$(date +%d-%m-%Y_%Hh%Mp%Ss)"
# Quy tắc đặt tên file zip backup
ZIP_NAME="hermes-backup-${TIMESTAMP}.zip"

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

TMP_ZIP="/tmp/${ZIP_NAME}"

cleanup() {
    rm -f "${TMP_ZIP}" 2>/dev/null || true
}
trap cleanup EXIT

log "Bắt đầu backup Hermes..."

# 1. Tạo bản backup bằng lệnh hermes backup
hermes backup -o "${TMP_ZIP}"

if [ ! -f "${TMP_ZIP}" ]; then
    log "LỖI: Không tìm thấy file backup tại ${TMP_ZIP}"
    exit 1
fi

# 2. Upload file zip lên Google Drive qua rclone
log "Đang đẩy file ${ZIP_NAME} lên Google Drive (${REMOTE})..."
rclone copyto "${TMP_ZIP}" "${REMOTE}${ZIP_NAME}"

log "Backup thành công! File đã được lưu tại ${REMOTE}${ZIP_NAME}"

# 3. Dọn dẹp bản backup cũ trên Google Drive (chỉ giữ lại MAX_BACKUPS bản mới nhất)
log "Đang dọn dẹp các bản backup cũ trên Google Drive (chỉ giữ ${MAX_BACKUPS} bản mới nhất)..."
rclone lsf "${REMOTE}" --format "tp" --files-only 2>/dev/null | grep -E ';hermes-backup-.*\.zip$' | sort | head -n -"${MAX_BACKUPS}" | cut -d';' -f2- | while read -r old_file; do
    if [ -n "${old_file}" ]; then
        log "Đang xóa bản backup cũ: ${old_file}"
        rclone deletefile "${REMOTE}${old_file}" || true
    fi
done
