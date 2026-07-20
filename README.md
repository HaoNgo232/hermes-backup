# Hermes Backup sang Google Drive (Đơn giản)

Tự động backup dữ liệu Hermes Agent lên Google Drive định kỳ hàng giờ.

---

## 0. Cài đặt & Kết nối Google Drive (Chỉ làm 1 lần đầu)

### B1: Cài đặt công cụ cần thiết (rclone & shellcheck)
```bash
sudo apt update && sudo apt install -y rclone shellcheck
```

### B2: Cấu hình kết nối Google Drive
Chạy lệnh `rclone config` và chọn các phím bấm theo thứ tự sau:

1. `n` *(New remote)* -> Nhập tên: **`gdrive-hermes`**
2. Chọn loại storage: nhập **`drive`** *(Google Drive)*
3. `client_id` & `client_secret`: Bấm **Enter** (để trống)
4. `scope`: Bấm **Enter** (mặc định `drive.file`)
5. `service_account_file`: Bấm **Enter** (để trống)
6. `Edit advanced config?`: chọn **`n`**
7. `Use auto config?`: chọn **`y`** *(Trình duyệt tự mở, đăng nhập Google và bấm **Cho phép**)*
8. `Shared Drive?`: chọn **`n`**
9. `Keep this "gdrive-hermes" remote?`: chọn **`y`**
10. `q` *(Thoát config)*

---

## 1. Backup thủ công

Chạy 1 lệnh duy nhất để sao lưu ngay lập tức:

```bash
./backup.sh
```

*(Script sẽ tự tạo bản backup bằng `hermes backup`, đẩy lên Google Drive và tự động giữ lại **24 bản mới nhất**)*

---

## 2. Bật Backup định kỳ (Systemd Timer)

Bật tính năng tự động chạy backup **mỗi 1 tiếng 1 lần (hourly)**:

```bash
bin/install-systemd.sh
```

Kiểm tra trạng thái timer:
```bash
systemctl --user list-timers hermes-cloud-backup.timer
```

---

## 3. Khôi phục dữ liệu (Restore)

Khi cần phục hồi dữ liệu Hermes trên máy hiện tại hoặc máy mới:

1. **Tải bản backup từ Google Drive về máy**:
   ```bash
   # Xem danh sách bản backup trên Drive
   rclone lsf gdrive-hermes:HermesBackups

   # Tải bản mới nhất về máy (thay tên file tương ứng)
   rclone copyto gdrive-hermes:HermesBackups/hermes-backup-YYYYMMDD_HHMMSS.zip ./backup.zip
   ```

2. **Dùng lệnh chuẩn của Hermes để import**:
   ```bash
   hermes import ./backup.zip
   ```

---

## Xem nhật ký (Logs)

```bash
tail -f logs/backup.log
```
