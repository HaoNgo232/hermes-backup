# Hermes Backup to Google Drive

Automated workflow script to back up, super-compress, and restore your [Hermes Agent](https://github.com/NousResearch/hermes-agent) data to Google Drive with Systemd timer scheduling and Grandfather-Father-Son (GFS) retention.

---

## Quick Start

### 1. Install dependencies

```bash
sudo apt update && sudo apt install -y rclone unzip zip xz-utils util-linux
```

### 2. Clone repository & run setup

```bash
git clone https://github.com/HaoNgo232/hermes-backup.git ~/hermes-backup
cd ~/hermes-backup
./setup.sh
```

If `setup.sh` reports that `gdrive-hermes` is not configured, run `rclone config` to set up your Google Drive connection (see [Google Drive Setup Details](#google-drive-setup-details) below), then run `./setup.sh` again.

### 3. Verify status

```bash
./status.sh
```

Backups will run automatically **every 4 hours** (02:00, 06:00, 10:00, 14:00, 18:00, 22:00).

> [!TIP]
> **Optional (for unattended operation after logout/reboot):**
> If you want systemd backup timers to run after you log out or reboot, enable user linger:
>
> ```bash
> sudo loginctl enable-linger "$USER"
> ```

---

## Common Commands

| Task                                 | Command                                                              | Description                                                             |
| :----------------------------------- | :------------------------------------------------------------------- | :---------------------------------------------------------------------- |
| **Check backup system health**       | `./status.sh`                                                        | Read-only check for remote reachability, timer state, and latest backup |
| **Run a manual backup now**          | `./backup.sh`                                                        | Immediate manual backup, upload & GFS retention                         |
| **Restore the latest backup**        | `./restore.sh`                                                       | Download and restore the most recent backup from Google Drive           |
| **Restore a specific backup**        | `./restore.sh <filename>`                                            | Restore a specific `.tar.xz` or `.zip` backup file                      |
| **Install / update systemd timer**   | `./install-systemd.sh`                                               | Dynamically render & enable user systemd timer units                    |
| **Test systemd service immediately** | `systemctl --user start hermes-cloud-backup.service`                 | Trigger the systemd service manually                                    |
| **View recent backup log**           | `tail -n 100 logs/backup.log`                                        | View log output of `backup.sh`                                          |
| **Debug systemd timer failures**     | `journalctl --user -u hermes-cloud-backup.service -n 100 --no-pager` | View systemd service journal logs                                       |

---

## Restoring Data

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

## Google Drive Setup Details

_(You only need to do this step once, or when configuring a new Google account/remote.)_

Run `rclone config` and select the following options in order:

1. `n` _(New remote)_ -> Enter name: **`gdrive-hermes`**
2. Select storage type: enter **`drive`** _(Google Drive)_
3. `client_id` & `client_secret`: press **Enter** (leave empty)
4. `scope`: press **Enter** (default: `drive.file`)
5. `service_account_file`: press **Enter** (leave empty)
6. `Edit advanced config?`: select **`n`**
7. `Use auto config?`: select **`y`** _(your browser opens; sign in to Google and click **Allow**)_
8. `Shared Drive?`: select **`n`**
9. `Keep this "gdrive-hermes" remote?`: select **`y`**
10. `q` _(quit configuration)_

After setting up the remote, run `./setup.sh` to complete the installation.

---

## How Automatic Backups & Retention Work

### Schedule

Backups run automatically **every 4 hours** via a Systemd user timer with `Persistent=true` and a 5-minute randomized delay.

### GFS Retention Policy

After each backup upload, old remote backups are pruned according to a Grandfather-Father-Son (GFS) retention schedule:

| Age Tier                            | Retention Rule              | Estimated Files Kept |
| :---------------------------------- | :-------------------------- | :------------------- |
| **0 to 2 days old** (`age <= 2`)    | Keep **ALL** backups        | ~12 files            |
| **3 to 7 days old** (`age <= 7`)    | Keep **1 backup per day**   | ~5 files             |
| **8 to 28 days old** (`age <= 28`)  | Keep **1 backup per week**  | ~3 files             |
| **29 to 90 days old** (`age <= 90`) | Keep **1 backup per month** | ~2 files             |
| **Older than 90 days** (`age > 90`) | Prune remote file           | 0 files              |

_Approximately **~22 backup archives** are maintained on Google Drive. Final deletion behavior on Google Drive depends on your rclone remote trash settings._

---

## Environment Variables

You can customize behavior using environment variables:

| Variable           | Default Value                         | Description                          |
| :----------------- | :------------------------------------ | :----------------------------------- |
| `BACKUP_REMOTE`    | `gdrive-hermes:HermesBackups`         | Destination rclone remote and folder |
| `HERMES_BIN`       | Resolved via `command -v hermes`      | Custom path to `hermes` executable   |
| `BACKUP_LOCK_FILE` | `$XDG_RUNTIME_DIR/hermes-backup.lock` | Exclusive lock file path             |
| `BACKUP_LOG_DIR`   | `<repo_dir>/logs`                     | Directory for log files              |

---

## Troubleshooting

| Symptom                             | Cause                                               | Solution                                                                                                                                 |
| :---------------------------------- | :-------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------- |
| `hermes: command not found`         | `hermes` is not in system `PATH`                    | Set `HERMES_BIN=/path/to/hermes` or re-run `./setup.sh`                                                                                  |
| `rclone remote not found`           | Remote `gdrive-hermes` is not configured            | Run `rclone config` and create `gdrive-hermes` remote                                                                                    |
| `Another backup is already running` | A backup or timer-triggered job is currently active | Wait for active run to finish. Check `./status.sh` or `logs/backup.log`. Do not remove lock files unless confirmed no process is running |
| Timer doesn't run after reboot      | User linger disabled                                | Enable linger with `sudo loginctl enable-linger $USER`                                                                                   |

---

## License

[MIT](LICENSE)
