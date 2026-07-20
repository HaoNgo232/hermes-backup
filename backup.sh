#!/usr/bin/env bash
# =====================================================================
# Hermes Backup Script
# Tự động tạo bản backup bằng 'hermes backup' và đẩy lên Google Drive
# Lần đầu chạy sẽ tự cài Systemd Timer backup mỗi 4 tiếng
# Dọn dẹp bản cũ theo chiến lược GFS (Grandfather-Father-Son)
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
# CẤU HÌNH
# ---------------------------------------------------------------------
REMOTE="${BACKUP_REMOTE:-gdrive-hermes:HermesBackups}"

# Định dạng ngày giờ thuần Việt: DD-MM-YYYY_HHhMMpSSs (VD: 20-07-2026_14h47p55s)
TIMESTAMP="$(date +%d-%m-%Y_%Hh%Mp%Ss)"
ZIP_NAME="hermes-backup-${TIMESTAMP}.zip"

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

# ---------------------------------------------------------------------
# TỰ ĐỘNG CÀI SYSTEMD TIMER (chỉ lần đầu)
# ---------------------------------------------------------------------
install_timer_if_needed() {
    if systemctl --user is-active hermes-cloud-backup.timer &>/dev/null; then
        return 0
    fi
    log "Phát hiện Timer chưa cài. Đang tự động cài Systemd Timer backup mỗi 4 tiếng..."
    local unit_dir="$HOME/.config/systemd/user"
    mkdir -p "${unit_dir}"
    cp "${SCRIPT_DIR}/systemd/hermes-cloud-backup.service" "${unit_dir}/"
    cp "${SCRIPT_DIR}/systemd/hermes-cloud-backup.timer" "${unit_dir}/"
    chmod 644 "${unit_dir}/hermes-cloud-backup.service" "${unit_dir}/hermes-cloud-backup.timer"
    systemctl --user daemon-reload
    systemctl --user enable --now hermes-cloud-backup.timer
    log "Timer đã được cài đặt và kích hoạt! Backup sẽ tự chạy mỗi 4 tiếng."
}

# ---------------------------------------------------------------------
# DỌN DẸP GFS (Grandfather-Father-Son)
# Giữ: tất cả ≤2 ngày | 1/ngày ≤7 ngày | 1/tuần ≤4 tuần | 1/tháng ≤3 tháng
# ---------------------------------------------------------------------
cleanup_gfs() {
    log "Đang dọn dẹp bản backup cũ theo chiến lược GFS..."
    local now_epoch
    now_epoch=$(date +%s)

    local -A daily_seen=()
    local -A weekly_seen=()
    local -A monthly_seen=()
    local kept=0
    local deleted=0

    while IFS=';' read -r timestamp filename; do
        [ -z "${filename}" ] && continue

        local file_epoch
        file_epoch=$(date -d "${timestamp}" +%s 2>/dev/null) || continue
        local age_days=$(( (now_epoch - file_epoch) / 86400 ))

        if [ "${age_days}" -le 2 ]; then
            # Tầng 1: Giữ TẤT CẢ bản trong 2 ngày gần nhất
            kept=$((kept + 1))

        elif [ "${age_days}" -le 7 ]; then
            # Tầng 2: Giữ 1 bản/ngày cho ngày 3-7
            local day_key
            day_key=$(date -d "${timestamp}" +%Y-%m-%d)
            if [ -z "${daily_seen[${day_key}]:-}" ]; then
                daily_seen["${day_key}"]=1
                kept=$((kept + 1))
            else
                log "  Xóa (daily): ${filename}"
                rclone deletefile "${REMOTE}${filename}" 2>/dev/null || true
                deleted=$((deleted + 1))
            fi

        elif [ "${age_days}" -le 28 ]; then
            # Tầng 3: Giữ 1 bản/tuần cho tuần 2-4
            local week_key
            week_key=$(date -d "${timestamp}" +%G-W%V)
            if [ -z "${weekly_seen[${week_key}]:-}" ]; then
                weekly_seen["${week_key}"]=1
                kept=$((kept + 1))
            else
                log "  Xóa (weekly): ${filename}"
                rclone deletefile "${REMOTE}${filename}" 2>/dev/null || true
                deleted=$((deleted + 1))
            fi

        elif [ "${age_days}" -le 90 ]; then
            # Tầng 4: Giữ 1 bản/tháng cho tháng 2-3
            local month_key
            month_key=$(date -d "${timestamp}" +%Y-%m)
            if [ -z "${monthly_seen[${month_key}]:-}" ]; then
                monthly_seen["${month_key}"]=1
                kept=$((kept + 1))
            else
                log "  Xóa (monthly): ${filename}"
                rclone deletefile "${REMOTE}${filename}" 2>/dev/null || true
                deleted=$((deleted + 1))
            fi

        else
            # Quá 90 ngày: xóa
            log "  Xóa (>90 ngày): ${filename}"
            rclone deletefile "${REMOTE}${filename}" 2>/dev/null || true
            deleted=$((deleted + 1))
        fi
    done < <(rclone lsf "${REMOTE}" --format "tp" --files-only 2>/dev/null \
        | grep -E ';hermes-backup-.*\.zip$' | sort -r)

    log "GFS hoàn tất: giữ ${kept} bản, xóa ${deleted} bản."
}

# =====================================================================
# CHẠY CHÍNH
# =====================================================================

# Bước 0: Cài timer tự động nếu chưa có
install_timer_if_needed

# Bước 1: Tạo bản backup
log "Bắt đầu backup Hermes..."
hermes backup -o "${TMP_ZIP}"

if [ ! -f "${TMP_ZIP}" ]; then
    log "LỖI: Không tìm thấy file backup tại ${TMP_ZIP}"
    exit 1
fi

# Bước 2: Upload lên Google Drive
log "Đang đẩy file ${ZIP_NAME} lên Google Drive (${REMOTE})..."
rclone copyto "${TMP_ZIP}" "${REMOTE}${ZIP_NAME}"
log "Backup thành công! File: ${REMOTE}${ZIP_NAME}"

# Bước 3: Dọn dẹp bản cũ theo GFS
cleanup_gfs
