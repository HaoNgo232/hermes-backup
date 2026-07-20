![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnu-bash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black)
![Google Drive](https://img.shields.io/badge/Google%20Drive-4285F4?logo=googledrive&logoColor=white)
![rclone](https://img.shields.io/badge/rclone-205493)
![systemd](https://img.shields.io/badge/systemd-000000)
![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow)

# Hermes Backup to Google Drive

Bash wrapper scripts that automate [Hermes Agent](https://github.com/NousResearch/hermes-agent) backup and restore workflows by orchestrating `hermes` CLI, `rclone`, and `systemd` user timers.

**What these scripts do for you:**

- 📦 **Backs up your Hermes data** to Google Drive automatically every 4 hours
- 🗜️ **Compresses your backup** to save storage space (with an optional "super compression" mode for even smaller files)
- 🔄 **Manages old backups** by keeping recent ones and gradually cleaning up older ones, so you don't run out of Drive space
- 🔒 **Optionally encrypts your data** before uploading, so even Google can't read your files
- ⏰ **Runs on a schedule** using your server's built-in scheduler (systemd timer), so you don't need to remember to do it manually

---

## Quick Start

### 1. Install required software

These are the tools that Hermes Backup needs to work. Copy and paste this command into your terminal:

```bash
sudo apt update && sudo apt install -y rclone unzip zip xz-utils util-linux shellcheck
```

### 2. Download Hermes Backup and run setup

This downloads the backup scripts to your server and walks you through the initial configuration:

```bash
git clone https://github.com/HaoNgo232/hermes-backup.git ~/hermes-backup
cd ~/hermes-backup
./setup.sh
```

If `setup.sh` tells you that `gdrive-hermes` is not configured, you need to connect your Google Drive first. See [Connecting Google Drive](#connecting-google-drive) below, then run `./setup.sh` again.

### 3. Make sure everything is working

Run this command to check that your backup system is healthy:

```bash
./status.sh
```

If everything shows green/OK, you're done! Backups will now run automatically **every 4 hours** (at 02:00, 06:00, 10:00, 14:00, 18:00, 22:00).

> [!TIP]
> **Keep backups running after you log out or reboot:**
> By default, your scheduled backups only run while you're logged in. To keep them running all the time (even after you close the terminal or restart the server), run this once:
>
> ```bash
> sudo loginctl enable-linger "$USER"
> ```

**What just happened?** You installed the backup scripts, connected to Google Drive, and set up automatic backups. From now on, your Hermes data is being backed up every 4 hours without you doing anything.

---

## Everyday Commands

These are the commands you'll use most often:

| What you want to do              | Command                   | What it does                                                                          |
| :------------------------------- | :------------------------ | :------------------------------------------------------------------------------------ |
| **See if everything is working** | `./status.sh`             | Checks your Google Drive connection, backup schedule, and latest backup               |
| **Back up right now**            | `./backup.sh`             | Runs a backup immediately instead of waiting for the next scheduled one               |
| **Restore your latest backup**   | `./restore.sh`            | Downloads and restores your most recent backup from Google Drive                      |
| **Restore a specific backup**    | `./restore.sh <filename>` | Restores a particular backup file (e.g., `hermes-backup-20-07-2026_14h00p00s.tar.xz`) |
| **Run setup again**              | `./setup.sh`              | Re-run the setup wizard (useful after changing settings)                              |
| **Test everything end-to-end**   | `./setup.sh --test`       | Runs setup and then does a real test backup to make sure everything works             |

> [!WARNING]
> **About restoring:** Restoring a backup will **overwrite** your current Hermes data with the backup version. Make sure this is what you want before running `./restore.sh`.

---

## Setup Options Explained

During `./setup.sh`, you'll be asked a couple of yes/no questions. Here's what they mean:

### Encryption (Scrambling your files before upload)

```text
Enable client-side encryption for cloud backups? [y/N]:
```

- **Press Enter or type `N`:** Your backups are uploaded as-is. Simple and easy to restore.
- **Type `y`:** Your files are scrambled (encrypted) on your computer _before_ being uploaded. Even if someone gains access to your Google Drive, they can't read your backup files. However, you must save two recovery keys — if you lose both your server and those keys, your backups are gone forever.

See [Encryption Details](#encryption-details) below if you choose `y`.

### Super Compression (Shrinking file size)

```text
Enable super compression (.tar.xz)? [y/N]:
```

- **Press Enter or type `N`:** Uses standard `.zip` compression. Fast to create and fast to restore.
- **Type `y`:** Uses `.tar.xz` compression, which creates significantly smaller files but takes more time and CPU power.

---

## Encryption Details

> [!NOTE]
> Encryption is **optional** and **off by default**. This section only applies if you chose `y` during setup.

### What encryption does

When encryption is enabled:

- Your backup files are scrambled on your computer **before** uploading to Google Drive
- Nobody can read your backups without the encryption keys — not even Google
- Scheduled backups still run automatically without asking for a password
- Restoring also works automatically using your local settings

### Recovery keys — your "spare house key"

When you turn on encryption, the setup wizard generates two secret keys:

1. **Recovery Password** — a long random string used to encrypt/decrypt your data
2. **Recovery Salt** — a second random string that strengthens the encryption (like adding a unique fingerprint to your password)

These are shown on your screen **only once** during setup:

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
> **Think of these keys like a spare house key.** Your server already has the "main key" built in, so day-to-day backups work automatically. But if your server crashes and you need to set up a new one, you'll need these recovery keys to unlock your encrypted backups. If you lose both your server AND the recovery keys, your backups are locked forever — nobody can open them.

### 3 simple rules for encrypted backups

1. 🔐 **Save both keys right away.** Copy the Recovery Password and Recovery Salt into a password manager (like Bitwarden or 1Password) or write them down and store them somewhere safe.
2. 🚫 **Don't store the keys in the same place as your backups.** If your Google account gets hacked, you don't want the attacker to also find your recovery keys. Keep them in a separate, secure location.
3. 🤖 **Don't touch the files in Google Drive.** Encrypted files look like random gibberish names (e.g., `a1b2c3d4...`). Don't rename or delete them in Google Drive — let the backup scripts manage everything.

> [!WARNING]
> **No keys = no recovery!**
> If your server is wiped **AND** you've lost your saved recovery keys, your encrypted backups **cannot be unlocked by anyone** — including us or Google. Keep your recovery keys safe!

### What encryption protects (and what it doesn't)

- ✅ **Protects against:** Someone accessing your Google Drive files without your permission — they can't read your encrypted backups
- ❌ **Does NOT protect against:** Someone hacking into your actual server — because the server needs the encryption keys to run automatic backups, a hacker with server access could access those keys
- ❌ **Does NOT prevent deletion:** Encryption scrambles your files so they can't be read, but it doesn't stop someone from deleting them

### Recovering encrypted backups on a new server

If your original server is lost and you need to set up fresh:

**Step 1:** Install rclone and connect your Google Drive (same as initial setup):

```bash
sudo apt install -y rclone
rclone config
```

Create a remote named `gdrive-hermes` following the steps in [Connecting Google Drive](#connecting-google-drive).

**Step 2:** Set up the encryption layer. Run `rclone config` again and create a new remote. When rclone asks you each question, enter these values exactly:

| rclone asks               | You enter                              |
| :------------------------ | :------------------------------------- |
| Name                      | `hermes-backup-crypt`                  |
| Storage type              | `crypt`                                |
| Remote to encrypt/decrypt | `gdrive-hermes:HermesBackupsEncrypted` |
| How to encrypt filenames  | `standard`                             |
| Encrypt directory names   | `true`                                 |
| Password                  | Your saved **Recovery Password**       |
| Password2 (salt)          | Your saved **Recovery Salt**           |

**Step 3:** Verify that rclone can see your encrypted backups:

```bash
rclone lsf hermes-backup-crypt:
```

You should see your backup filenames listed. If you see nothing or get an error, double-check your Recovery Password and Salt.

**Step 4:** Recreate the settings file so Hermes Backup knows encryption is enabled. Copy and paste this entire block into your terminal — it creates a small configuration file in the right location:

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

You don't need to edit anything in the block above — just paste it as-is.

**Step 5:** Verify, set up the timer, and restore:

```bash
./status.sh
./install-systemd.sh
./restore.sh
```

> [!NOTE]
> Do NOT generate a new password or salt for an existing encrypted backup folder. New keys cannot unlock old backups!

---

## Retention Policy (GFS)

Old backups are pruned automatically after each successful backup run according to a Grandfather-Father-Son (GFS) policy (implemented in `backup.sh` based on file age in days):

- **0 to 2 days old (`age <= 2 days`)**: Keep **ALL** backups (up to ~12 archives for 4-hour schedule).
- **3 to 7 days old (`3 <= age <= 7 days`)**: Keep **1 backup per day** (the latest backup of each day, ~5 archives).
- **8 to 28 days old (`8 <= age <= 28 days`)**: Keep **1 backup per week** (the latest backup of each ISO week, ~3 archives).
- **29 to 90 days old (`29 <= age <= 90 days`)**: Keep **1 backup per month** (the latest backup of each month, ~2 archives).
- **Older than 90 days (`age > 90 days`)**: Automatically deleted from remote storage.

At any given time, approximately **~22 backup archives** are maintained on your remote destination.

---

## Health Check

Run `./status.sh` at any time to see if your backup system is healthy:

```bash
./status.sh
```

- **Green / "HEALTHY":** Everything is working. No action needed.
- **Red / "ACTION REQUIRED":** Something needs your attention (e.g., Google Drive connection lost, timer stopped). The output will tell you what to fix.

---

## Connecting Google Drive

This section walks you through connecting your server to Google Drive so backups can be uploaded automatically. **You only need to do this once.**

Run `rclone config` and follow these steps:

1. Type `n` to create a new remote → enter the name **`gdrive-hermes`**
2. Select storage type → type **`drive`** (Google Drive)
3. `client_id` → press **Enter** (leave empty)
4. `client_secret` → press **Enter** (leave empty)
5. `scope` → press **Enter** (use the default)
6. `service_account_file` → press **Enter** (leave empty)
7. `Edit advanced config?` → type **`n`**
8. `Use auto config?` → type **`y`** — your browser will open. Log into your Google account and click **Allow**
9. `Shared Drive?` → type **`n`**
10. `Keep this "gdrive-hermes" remote?` → type **`y`**
11. Type **`q`** to quit configuration

After this, run `./setup.sh` to complete the installation.

---

## Restoring Data

### Restore the most recent backup

```bash
./restore.sh
```

This downloads the latest backup from Google Drive and restores it.

### Restore a specific backup

If you want to restore a particular backup file:

```bash
./restore.sh hermes-backup-20-07-2026_14h00p00s.tar.xz
```

> [!WARNING]
> Restoring runs `hermes import --force`, which **overwrites your current Hermes data** with the backup version.

---

## Uninstalling

To stop automatic backups and remove the scheduled timer:

```bash
./uninstall.sh
```

> [!NOTE]
> This only removes the backup schedule. It does **NOT** delete the backup scripts, your log files, your Google Drive connection, or your backups on Google Drive.

---

## Settings File

Hermes Backup saves its settings in a file on your computer:

- **Location:** `~/.config/hermes-backup/state.env`
- **Contains:** Backup configuration (which Google Drive remote to use, whether encryption is enabled, etc.)
- **Does NOT contain:** Any passwords or secret keys

Your Google Drive connection settings are stored separately in rclone's own configuration file (run `rclone config file` to see where).

---

## Frequently Asked Questions

**Do I need to run backups manually?**
No. Once you run `./setup.sh`, backups happen automatically every 4 hours. You can still run `./backup.sh` anytime if you want an immediate backup.

**Will this delete my existing Hermes data?**
No. The backup process only exports a copy of your data — it never modifies or deletes your running Hermes installation. Only `./restore.sh` overwrites data (and it warns you first).

**What happens if my server crashes?**
Your backups are safe on Google Drive. Set up a new server, install Hermes Backup, connect to the same Google Drive, and run `./restore.sh` to get your data back.

**Do I need encryption?**
Standard (unencrypted) backup is simpler and easier to recover. Encryption adds privacy but requires managing recovery keys. See [Setup Options Explained](#setup-options-explained) for the tradeoffs.

**How much Google Drive space does this use?**
About 22 backup files are kept at any time. The actual storage used depends on the size of your Hermes data.

**How do I change settings after setup?**
Run `./setup.sh` again. It will walk you through the same options and update your configuration.

---

## Advanced / For Power Users

<details>
<summary>Click to expand advanced options</summary>

### Timer Management

| Task                                  | Command                                                  | Description                                         |
| :------------------------------------ | :------------------------------------------------------- | :-------------------------------------------------- |
| **Install / update the backup timer** | `./setup.sh`                                             | Validates setup and installs the systemd user timer |
| **Re-render systemd unit files**      | `./install-systemd.sh`                                   | Needed if you moved the hermes-backup folder        |
| **Uninstall the timer**               | `./uninstall.sh`                                         | Stops and removes the scheduled backup timer        |
| **View timer schedule**               | `systemctl --user list-timers hermes-cloud-backup.timer` | Shows when the next backup is scheduled             |

### Debugging

| Task                           | Command                                                              |
| :----------------------------- | :------------------------------------------------------------------- |
| **View recent backup log**     | `tail -n 100 logs/backup.log`                                        |
| **View systemd journal logs**  | `journalctl --user -u hermes-cloud-backup.service -n 100 --no-pager` |
| **Trigger backup via systemd** | `systemctl --user start hermes-cloud-backup.service`                 |
| **Single-line health summary** | `./status.sh --check`                                                |

### Environment Variables

These are for advanced customization only:

| Variable           | Default Value                         | Description                                |
| :----------------- | :------------------------------------ | :----------------------------------------- |
| `BACKUP_REMOTE`    | `gdrive-hermes:HermesBackups`         | Google Drive remote and folder for backups |
| `HERMES_BIN`       | Auto-detected via `command -v hermes` | Custom path to `hermes` executable         |
| `BACKUP_LOCK_FILE` | `$XDG_RUNTIME_DIR/hermes-backup.lock` | Lock file to prevent concurrent backups    |
| `BACKUP_LOG_DIR`   | `<repo_dir>/logs`                     | Where backup logs are saved                |
| `RESTORE_LOG_DIR`  | `<repo_dir>/logs`                     | Where restore logs are saved               |
| `MAX_LOG_LINES`    | `5000`                                | Log file is rotated after this many lines  |
| `KEEP_LOG_LINES`   | `2000`                                | Lines kept after log rotation              |

</details>

---

## Troubleshooting

| Problem                             | What's happening                                       | How to fix it                                                                               |
| :---------------------------------- | :----------------------------------------------------- | :------------------------------------------------------------------------------------------ |
| `Cannot access rclone remote`       | Your Google Drive connection expired or was revoked    | Run `rclone config reconnect gdrive-hermes:` and then test with `rclone lsf gdrive-hermes:` |
| `setup.sh --test fails`             | The test backup didn't complete successfully           | Check the logs: `journalctl --user -u hermes-cloud-backup.service -n 100 --no-pager`        |
| `hermes: command not found`         | The scripts can't find the Hermes program              | Set the path manually: `HERMES_BIN=/path/to/hermes ./setup.sh`                              |
| `rclone remote not found`           | Google Drive hasn't been connected yet                 | Follow the steps in [Connecting Google Drive](#connecting-google-drive)                     |
| `Another backup is already running` | A backup is still in progress                          | Wait for it to finish. Check `./status.sh` or `tail logs/backup.log`                        |
| Timer doesn't run after reboot      | The server stops your scheduled tasks when you log out | Run `sudo loginctl enable-linger $USER`                                                     |
| Something else went wrong           | —                                                      | Run `./status.sh` and share the output when asking for help                                 |

---

## License

[MIT](LICENSE)
