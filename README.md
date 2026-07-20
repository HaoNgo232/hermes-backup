# Hermes Backup to Google Drive (Simple)

Automatically back up Hermes Agent data to Google Drive every four hours.

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

**First run**: The script automatically installs a Systemd Timer to run backups **every four hours** (02:00, 06:00, 10:00, 14:00, 18:00, and 22:00). No further action is needed.

**GFS retention strategy** (automatically removes old backups):

| Tier    | Retention                     | Purpose                           |
| ------- | ----------------------------- | --------------------------------- |
| Recent  | Every backup for 2 days       | Fast recovery                     |
| Daily   | 1 backup per day × 7 days     | Issues discovered during the week |
| Weekly  | 1 backup per week × 4 weeks   | Issues discovered later           |
| Monthly | 1 backup per month × 3 months | Long-term protection              |

---

## 2. Restore Data

Run one command to automatically download and import the latest backup:

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
