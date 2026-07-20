# Hermes Backup to Google Drive (Simple)

Automated workflow setup to back up and restore your Hermes Agent data to Google Drive.

---

## 0. Install and Connect Google Drive (One-Time Setup)

### Step 1: Install required tools (rclone and shellcheck)

```bash
sudo apt update && sudo apt install -y rclone shellcheck
```

### Step 2: Configure the Google Drive connection

```bash
rclone config
```

Select the following options in order:

1. `n` _(New remote)_ -> Enter the name: **`gdrive-hermes`**
2. Select storage type: enter **`drive`** _(Google Drive)_
3. `client_id` and `client_secret`: press **Enter** (leave empty)
4. `scope`: press **Enter** (default: `drive.file`)
5. `service_account_file`: press **Enter** (leave empty)
6. `Edit advanced config?`: select **`n`**
7. `Use auto config?`: select **`y`** _(your browser opens; sign in to Google and click **Allow**)_
8. `Shared Drive?`: select **`n`**
9. `Keep this "gdrive-hermes" remote?`: select **`y`**
10. `q` _(quit configuration)_

---

## 1. Backup

```bash
git clone https://github.com/HaoNgo232/hermes-backup.git ~/hermes-backup
cd ~/hermes-backup
./backup.sh
```

**Schedule**: Backups run **every 4 hours** (02:00, 06:00, 10:00, 14:00, 18:00, 22:00) producing 6 backups per day.

**Automatic Retention & Cleanup Rules**:
After every backup, old files on Google Drive are cleaned up based on file age:

| File Age                            | Cleanup Rule                                                     | Stored Files Count |
| ----------------------------------- | ---------------------------------------------------------------- | ------------------ |
| **0 to 2 days old** (last 48 hours) | Keep **ALL** backups                                             | ~12 files          |
| **3 to 7 days old** (days 3–7)      | Keep **1 backup per day** (removes other 5 daily backups)        | ~5 files           |
| **8 to 28 days old** (weeks 2–4)    | Keep **1 backup per week** (removes other backups of the week)   | ~3 files           |
| **29 to 90 days old** (months 2–3)  | Keep **1 backup per month** (removes other backups of the month) | ~2 files           |
| **Older than 90 days** (> 3 months) | **Permanently deleted**                                          | 0 files            |

👉 **Total stored files on Google Drive**: Always maintained at **~22 files** (~700 MB total storage with xz compression).

---

## 2. Restore Data

Run one command to download and import the latest backup:

```bash
cd ~/hermes-backup
./restore.sh
```

_(Or restore a specific backup: `./restore.sh <backup-file-name.zip>`)_

---

## View Logs

```bash
cd ~/hermes-backup
tail -f logs/backup.log
tail -f logs/restore.log
```

---

## License

[MIT](LICENSE)
