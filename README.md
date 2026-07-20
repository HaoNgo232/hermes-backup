# Hermes Backup to Google Drive

Automated workflow script to back up, super-compress, and restore your [Hermes Agent](https://github.com/HaoNgo232/hermes-agent) data to Google Drive with Systemd timer scheduling and Grandfather-Father-Son (GFS) retention.

---

## 1. System Requirements & Prerequisites

Ensure the required runtime dependencies are installed on your Linux system:

```bash
sudo apt update && sudo apt install -y rclone unzip zip xz-utils util-linux
```

*Note: `shellcheck` can be installed for development/linting (`sudo apt install shellcheck`).*

---

## 2. One-Time Google Drive Setup (`rclone`)

Configure `rclone` to connect to your Google Drive account:

```bash
rclone config
```

Select the following options in order:

1. `n` *(New remote)* -> Enter name: **`gdrive-hermes`**
2. Select storage type: enter **`drive`** *(Google Drive)*
3. `client_id` & `client_secret`: press **Enter** (leave empty)
4. `scope`: press **Enter** (default: `drive.file`)
5. `service_account_file`: press **Enter** (leave empty)
6. `Edit advanced config?`: select **`n`**
7. `Use auto config?`: select **`y`** *(your browser opens; sign in to Google and click **Allow**)*
8. `Shared Drive?`: select **`n`**
9. `Keep this "gdrive-hermes" remote?`: select **`y`**
10. `q` *(quit configuration)*

---

## 3. Installation & Usage

### Step 1: Clone Repository
You can clone the repository to any path of your choice:

```bash
git clone https://github.com/HaoNgo232/hermes-backup.git ~/hermes-backup
cd ~/hermes-backup
```

### Step 2: Run a Manual Backup
Verify that Hermes and rclone are working by triggering a manual backup:

```bash
./backup.sh
```

### Step 3: Install Automatic Backup Timer
Install and activate the user-level Systemd timer:

```bash
./install-systemd.sh
```

The installer dynamically resolves your repository location and `hermes` binary path, rendering custom unit files at `~/.config/systemd/user/`.

**Schedule**: Backups run automatically **every 4 hours** (02:00, 06:00, 10:00, 14:00, 18:00, 22:00) with a 5-minute randomized delay.

---

## 4. Verification & Diagnostics

### System Health Check
Run the built-in diagnostic tool to verify repository configuration, remote connectivity, and timer status:

```bash
./status.sh
```

### Check Active Timers
View the exact next scheduled execution time:

```bash
systemctl --user list-timers hermes-cloud-backup.timer
```

### Test Service Execution Immediately
Trigger the systemd service manually without waiting for the scheduled timer:

```bash
systemctl --user start hermes-cloud-backup.service
```

### View Service Logs & Systemd Journal
View execution history and detailed diagnostic logs:

```bash
# View local log files
tail -f logs/backup.log

# View systemd service journal logs
journalctl --user -u hermes-cloud-backup.service -n 100 --no-pager
```

---

## 5. Unattended Operation (User Linger)

By default, Linux systemd user services only run while the user is actively logged into an interactive shell session.

If you want the backup timer to continue running **unattended after logout or system reboot**, enable user linger:

```bash
sudo loginctl enable-linger "$USER"
```

---

## 6. Restore Data

### Restore Latest Backup
Download and restore the most recent backup file from Google Drive:

```bash
./restore.sh
```

### Restore Specific Backup
Specify a target backup filename (`.tar.xz` or legacy `.zip`):

```bash
./restore.sh hermes-backup-20-07-2026_14h00p00s.tar.xz
```

> [!WARNING]
> Restoring data executes `hermes import --force`, which overwrites your existing Hermes database and agent configuration.

---

## 7. GFS Retention Policy

After each backup upload, old remote backups are pruned according to a Grandfather-Father-Son (GFS) retention schedule:

| Age Tier | Retention Rule | Estimated Files Kept |
| :--- | :--- | :--- |
| **0 to 2 days old** (`age <= 2`) | Keep **ALL** backups | ~12 files |
| **3 to 7 days old** (`age <= 7`) | Keep **1 backup per day** | ~5 files |
| **8 to 28 days old** (`age <= 28`) | Keep **1 backup per week** | ~3 files |
| **29 to 90 days old** (`age <= 90`) | Keep **1 backup per month** | ~2 files |
| **Older than 90 days** (`age > 90`) | Prune remote file | 0 files |

*Approximately **~22 backup archives** are maintained on Google Drive. Final deletion behavior on Google Drive depends on your rclone remote trash settings.*

---

## 8. Environment Variables

You can customize behavior using environment variables:

| Variable | Default Value | Description |
| :--- | :--- | :--- |
| `BACKUP_REMOTE` | `gdrive-hermes:HermesBackups` | Destination rclone remote and folder |
| `HERMES_BIN` | Resolved via `command -v hermes` | Custom path to `hermes` executable |
| `BACKUP_LOCK_FILE` | `$XDG_RUNTIME_DIR/hermes-backup.lock` | Exclusive lock file path |
| `BACKUP_LOG_DIR` | `<repo_dir>/logs` | Directory for log files |

---

## 9. Troubleshooting

| Symptom | Cause | Solution |
| :--- | :--- | :--- |
| `hermes: command not found` | `hermes` is not in system `PATH` | Set `HERMES_BIN=/path/to/hermes` or re-run `./install-systemd.sh` |
| `rclone remote not found` | Remote is not configured | Run `rclone config` and create `gdrive-hermes` remote |
| `Another backup is already running` | Concurrent execution blocked | Wait for active run to finish, or check lock file at `/tmp/hermes-backup-*.lock` |
| Timer doesn't run after reboot | User linger disabled | Enable linger with `sudo loginctl enable-linger $USER` |

---

## License

[MIT](LICENSE)
