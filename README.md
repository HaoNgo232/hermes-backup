# Hermes Backup sang Google Drive (Đơn giản)

Tự động backup dữ liệu Hermes Agent lên Google Drive mỗi 4 tiếng.

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

## 1. Backup (chỉ cần 1 lệnh duy nhất)

```bash
./backup.sh
```

**Lần đầu chạy**: Script sẽ tự động cài Systemd Timer để backup **mỗi 4 tiếng** (2h, 6h, 10h, 14h, 18h, 22h). Từ đó không cần làm gì nữa.

**Chiến lược lưu trữ GFS** (tự động dọn dẹp bản cũ):
| Tầng | Giữ bao nhiêu | Mục đích |
|------|---------------|----------|
| Gần đây | Tất cả trong 2 ngày | Phục hồi nhanh |
| Hàng ngày | 1 bản/ngày × 7 ngày | Lỗi phát hiện trong tuần |
| Hàng tuần | 1 bản/tuần × 4 tuần | Lỗi phát hiện chậm |
| Hàng tháng | 1 bản/tháng × 3 tháng | Bảo hiểm dài hạn |

---

## 2. Khôi phục dữ liệu (Restore)

Chạy 1 lệnh duy nhất để tự động tải bản backup mới nhất và import:

```bash
./restore.sh
```

*(Hoặc khôi phục một bản cụ thể: `./restore.sh <tên-file-backup.zip>`)*

---

## Xem nhật ký (Logs)

```bash
tail -f logs/backup.log
tail -f logs/restore.log
```

## Kiểm tra trạng thái timer

```bash
systemctl --user list-timers hermes-cloud-backup.timer
```
