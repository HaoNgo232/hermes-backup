# Hermes Backup to Google Drive

Automated workflow script to back up, super-compress, and restore your [Hermes Agent](https://github.com/NousResearch/hermes-agent) data to Google Drive with Systemd timer scheduling, Grandfather-Father-Son (GFS) retention, and optional client-side encryption.

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

### Routine Backup Operations

| Task                                        | Command             | Description                                                                    |
| :------------------------------------------ | :------------------ | :----------------------------------------------------------------------------- |
| **Check backup health**                     | `./status.sh`       | Read-only health check for remote reachability, timer state, and latest backup |
| **Run a manual backup now**                 | `./backup.sh`       | Immediate manual backup, upload & GFS retention                                |
| **Run a complete setup & live backup test** | `./setup.sh --test` | Execute full setup and trigger a live end-to-end backup verification           |

### Restore

| Task                          | Command                   | Description                                                   |
| :---------------------------- | :------------------------ | :------------------------------------------------------------ |
| **Restore the latest backup** | `./restore.sh`            | Download and restore the most recent backup from Google Drive |
| **Restore a specific backup** | `./restore.sh <filename>` | Restore a specific `.tar.xz` or `.zip` backup file            |

### Timer Management

| Task                               | Command                                                  | Description                                                  |
| :--------------------------------- | :------------------------------------------------------- | :----------------------------------------------------------- |
| **Install / update systemd timer** | `./setup.sh`                                             | Validate tools, check remote connection & install user timer |
| **Re-render unit templates**       | `./install-systemd.sh`                                   | Re-render systemd units when moving repo directory           |
| **Uninstall systemd timer**        | `./uninstall.sh`                                         | Stop timer and remove systemd unit files                     |
| **Inspect scheduled timer runs**   | `systemctl --user list-timers hermes-cloud-backup.timer` | View timer trigger schedule and countdown                    |

### Debugging

| Task                                 | Command                                                              | Description                          |
| :----------------------------------- | :------------------------------------------------------------------- | :----------------------------------- |
| **View recent backup log**           | `tail -n 100 logs/backup.log`                                        | View local log output of `backup.sh` |
| **View systemd service logs**        | `journalctl --user -u hermes-cloud-backup.service -n 100 --no-pager` | View systemd service journal logs    |
| **Test systemd service immediately** | `systemctl --user start hermes-cloud-backup.service`                 | Trigger the systemd service manually |

---

## Optional Client-Side Encryption

Client-side encryption is an **optional feature** and is **disabled by default**. Existing plaintext users will continue using standard unencrypted backups unless encryption is explicitly enabled during setup.

Encryption is implemented using **rclone crypt** with encrypted file contents, filenames, and directory names.

### What does it do?

- 🔒 **Data Confidentiality:** Backup archives, directory structure, and filenames are encrypted locally on your server *before* being uploaded.
- 🙈 **Unreadable Cloud Storage:** Cloud storage files are unreadable without the local `rclone` crypt configuration or independently saved recovery material.
- ⚡ **Unattended Backups:** Scheduled backups (`./backup.sh`) run automatically in the background without prompting for a password. Manual restores (`./restore.sh`) also decrypt automatically using your local rclone configuration.

---

### How to Turn It On

During `./setup.sh`, you will see this prompt:

```text
Enable client-side encryption for cloud backups? [y/N]:
```

- Type **`y`** to turn on encryption.
- Press **Enter** (or `N`) if you want standard unencrypted backups.

---

### 🔑 Understanding Recovery Material (Important!)

When you enable encryption, `./setup.sh` automatically generates two unique secret keys:

1. **Recovery Password**
2. **Recovery Salt**

These two keys are displayed on your terminal **only once** during setup.

```text
======================================================================
IMPORTANT: ENCRYPTED BACKUP RECOVERY MATERIAL
======================================================================
...
Recovery password:
  <generated-32-char-password>

Recovery salt:
  <generated-32-char-salt>
...
Type SAVED to confirm that you saved the recovery material:
======================================================================
```

> [!IMPORTANT]
> **Why do I need these keys?**  
> If your server crashes or gets replaced, you will need these two keys to unlock your encrypted backups on a new machine.

---

### 🛡️ 3 Simple Rules for Encrypted Backups

1. 🔐 **Save Both Keys Immediately:** Copy the `Recovery password` and `Recovery salt` into a password manager (like Bitwarden, 1Password) or an encrypted note.
2. 🚫 **Store Recovery Material Independently:** Store recovery keys independently so that a single cloud account lockout, compromise, or deletion event does not affect both your backups and recovery material.
3. 🤖 **Do Not Rename Files Manually:** In Google Drive, encrypted filenames will look like random strings (e.g. `a1b2c3d4...`). Do not rename or delete them directly in Google Drive interface. Let `backup.sh`, `restore.sh`, and `status.sh` manage them.

> [!WARNING]
> **No Key, No Restore!**  
> If your server is wiped **AND** you lose your saved recovery keys, your encrypted cloud backups **cannot be decrypted by anyone** (including us or Google). Keep your recovery keys safe!

---

### Threat Model & Limitations

Client-side encryption provides confidentiality guarantees under specific conditions:

- **What Encryption Protects Against:** It protects cloud backup confidentiality if an unauthorized entity accesses your raw cloud-storage files without having access to your server's local `rclone` crypt config or recovery material.
- **Server Compromise:** Encryption does not fully protect against full compromise of the local VPS or user account running automatic backups, because that machine must maintain local `rclone` credentials to perform unattended operation.
- **Deletion & Storage Wipe:** Encryption protects data confidentiality; it does not prevent cloud backups from being deleted or overwritten. Cloud versioning and maintaining a second backup destination are separate operational concerns.

---

### Recovering on a New Server

If your original server and its local `rclone.conf` are lost:

1. Install `rclone` and configure the original base cloud remote (`gdrive-hermes:`).
2. Recreate an `rclone crypt` remote (`hermes-backup-crypt:`) pointing to `gdrive-hermes:HermesBackupsEncrypted`.
3. Provide your saved **Recovery Password** and **Recovery Salt**.
4. Set `filename_encryption = standard` and `directory_name_encryption = true`.
5. Verify the crypt remote connection:

   ```bash
   rclone lsf hermes-backup-crypt:
   ```

6. Recreate your local `state.env` file before running setup or restore (since setup will refuse to auto-adopt an existing crypt remote without application state):

   ```bash
   CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hermes-backup"
   mkdir -p "${CONFIG_DIR}"
   chmod 0700 "${CONFIG_DIR}"

   cat > "${CONFIG_DIR}/state.env" <<'EOF'
   STATE_SCHEMA_VERSION=1
   ENCRYPTION_ENABLED=true
   ENCRYPTION_MODE=rclone-crypt
   BASE_REMOTE=gdrive-hermes:
   BASE_PATH=HermesBackupsEncrypted
   CRYPT_REMOTE=hermes-backup-crypt:
   CRYPT_PATH=
   RECOVERY_NOTICE_STATE=shown
   ENCRYPTION_SETUP_COMPLETED_AT=
   EOF

   chmod 0600 "${CONFIG_DIR}/state.env"
   ```

7. Execute status, install timer, and restore backups:

   ```bash
   ./status.sh
   ./install-systemd.sh
   ./restore.sh
   ```

> [!NOTE]
> Do NOT generate a new password or salt for an existing encrypted backup folder. New credentials cannot decrypt old backups!

---

## Local Configuration Files

Hermes Backup maintains state and credentials in the following local files:

- **Application State File:**  
  `${XDG_CONFIG_HOME:-$HOME/.config}/hermes-backup/state.env`  
  *(Contains operational flags, remote names, and path settings with `0600` permissions. Contains **no** passwords or secret keys).*
- **Rclone Operational Credentials:**  
  `~/.config/rclone/rclone.conf`  
  *(Contains cloud OAuth tokens and obscured crypt remote configuration).*

---

## System Diagnostics & Health Contract

The `./status.sh` diagnostic tool enforces a strict exit status contract:

- **Exit Code `0` (`OVERALL STATUS: HEALTHY`)**: Returned when Hermes is found, Google Drive remote is reachable, and the systemd timer is installed, enabled, and active.
- **Exit Code `1` (`OVERALL STATUS: ACTION REQUIRED`)**: Returned when a blocking issue exists (e.g. missing tools, Google Drive unreachable, or timer inactive).

> [!NOTE]
> User linger status is reported as a non-blocking informational warning because it only affects unattended execution after user logout or system reboot.

For automated monitoring or CI scripts, use the `--check` flag for a single-line summary output:

```bash
./status.sh --check
```

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

| Variable           | Default Value                         | Description                           |
| :----------------- | :------------------------------------ | :------------------------------------ |
| `BACKUP_REMOTE`    | `gdrive-hermes:HermesBackups`         | Destination rclone remote and folder  |
| `HERMES_BIN`       | Resolved via `command -v hermes`      | Custom path to `hermes` executable    |
| `BACKUP_LOCK_FILE` | `$XDG_RUNTIME_DIR/hermes-backup.lock` | Exclusive lock file path              |
| `BACKUP_LOG_DIR`   | `<repo_dir>/logs`                     | Directory for backup log files        |
| `RESTORE_LOG_DIR`  | `<repo_dir>/logs`                     | Directory for restore log files       |
| `MAX_LOG_LINES`    | `5000`                                | Rotate log file after this many lines |
| `KEEP_LOG_LINES`   | `2000`                                | Lines to retain after log rotation    |

---

## Uninstallation Scope

Running `./uninstall.sh` removes installed systemd unit files (`~/.config/systemd/user/hermes-cloud-backup.*`) and reloads the systemd daemon.

> [!NOTE]
> Running `./uninstall.sh` is completely non-destructive: it does **NOT** delete the repository directory, local log files, rclone configuration, or Google Drive backups.

---

## Troubleshooting

| Symptom                             | Cause                                                           | Solution                                                                                                       |
| :---------------------------------- | :-------------------------------------------------------------- | :------------------------------------------------------------------------------------------------------------- |
| `Cannot access rclone remote`       | OAuth token expired, network error, or revoked Drive permission | Reconnect Google Drive with `rclone config reconnect gdrive-hermes:` and test with `rclone lsf gdrive-hermes:` |
| `setup.sh --test fails`             | Systemd service execution or backup process failed              | Inspect service logs with `journalctl --user -u hermes-cloud-backup.service -n 100 --no-pager`                 |
| `hermes: command not found`         | `hermes` is not in system `PATH`                                | Set `HERMES_BIN=/path/to/hermes` or re-run `./setup.sh`                                                        |
| `rclone remote not found`           | Remote `gdrive-hermes` is not configured                        | Run `rclone config` and create `gdrive-hermes` remote                                                          |
| `Another backup is already running` | A backup or timer-triggered job is currently active             | Wait for active run to finish. Check `./status.sh` or `logs/backup.log`                                        |
| Timer doesn't run after reboot      | User linger disabled                                            | Enable linger with `sudo loginctl enable-linger $USER`                                                         |

---

## License

[MIT](LICENSE)
