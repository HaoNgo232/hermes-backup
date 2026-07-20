# SPEC v1 — Optional Client-Side Encryption for hermes-backup

**Target repository:** `HaoNgo232/hermes-backup`

**Purpose:**  
Add optional client-side encryption for cloud backups with rclone crypt, while preserving the existing simple backup/restore/systemd workflow.

This specification is implementation-oriented. Follow the architecture, module boundaries, state model, and idempotency rules exactly.

---

# 1. Product goal

`hermes-backup` currently:

```text
hermes backup
  → ZIP archive
  → decompress/recompress as tar.xz
  → rclone upload to cloud
  → GFS retention
```

Add an optional encryption layer:

```text
hermes backup
  → ZIP archive
  → existing tar.xz compression
  → rclone crypt encrypts locally
  → upload encrypted data to cloud
```

When restoring:

```text
rclone crypt decrypts locally
  → existing tar.xz extraction
  → recreate ZIP
  → hermes import
```

The implementation MUST use `rclone crypt`.

Do NOT implement custom encryption.  
Do NOT implement password-protected ZIP.  
Do NOT implement ZipCrypto.  
Do NOT make encryption mandatory.

---

# 2. User-facing behavior

## 2.1. Existing users: unchanged by default

If encryption is not enabled:

```text
./setup.sh
./backup.sh
./restore.sh
./status.sh
```

must keep existing behavior.

Current backups remain plaintext archives stored through the configured base rclone remote.

## 2.2. New optional setup prompt

During interactive `setup.sh`, after validating the normal rclone cloud remote, prompt:

```text
Enable client-side encryption for cloud backups? [y/N]:
```

Rules:

- Default is `N`.
- `N`, empty input, invalid input: encryption remains disabled.
- `Y` or `y`: initialize encrypted backup mode.
- Non-interactive setup MUST NOT silently enable encryption.
- Encryption setup MUST NOT require the user to enter a password for every backup.
- Encryption setup MUST generate strong random recovery material automatically.

## 2.3. User experience after encrypted setup

After encryption is configured:

```text
./backup.sh
```

works without asking for a password.

```text
./restore.sh
```

works without asking for a password as long as local rclone configuration remains available.

Cloud storage contains encrypted data. A user opening Google Drive or the underlying raw cloud remote must not be able to read archive contents or meaningful archive filenames.

---

# 3. High-level architecture

## 3.1. Backup destinations

There are always two conceptual destinations.

```text
1. Base remote:
   The real cloud provider remote.

   Example:
     gdrive-hermes:

2. Crypt remote:
   An rclone "crypt" remote layered over a dedicated folder
   on the base remote.

   Example:
     hermes-backup-crypt:
       → gdrive-hermes:HermesBackupsEncrypted
```

When encryption is disabled:

```text
backup destination = BASE_REMOTE + BASE_PATH
```

When encryption is enabled:

```text
backup destination = CRYPT_REMOTE + CRYPT_PATH
```

Usually `CRYPT_PATH` is the root of the crypt remote:

```text
hermes-backup-crypt:
```

The raw/base encrypted storage path MUST be separate from the plaintext backup folder.

Recommended defaults:

```text
Plaintext cloud folder:
  HermesBackups

Encrypted raw cloud folder:
  HermesBackupsEncrypted
```

## 3.2. Data flow

### Plaintext mode

```text
Hermes state
  → hermes backup
  → hermes-backup-<timestamp>.zip
  → tar.xz
  → rclone copyto
  → BASE_REMOTE:HermesBackups/
```

### Encrypted mode

```text
Hermes state
  → hermes backup
  → hermes-backup-<timestamp>.zip
  → tar.xz
  → rclone copyto through CRYPT_REMOTE
  → rclone encrypts content/name locally
  → BASE_REMOTE:HermesBackupsEncrypted/
```

### Encrypted restore

```text
CRYPT_REMOTE
  → rclone decrypts while downloading
  → local .tar.xz archive
  → extract
  → recreate ZIP
  → hermes import --force
```

---

# 4. Required code architecture

Refactor shared logic out of large scripts. Do not duplicate encryption/state/rclone logic across `setup.sh`, `backup.sh`, `restore.sh`, and `status.sh`.

## 4.1. Required repository structure

Add this structure:

```text
hermes-backup/
├── backup.sh
├── restore.sh
├── setup.sh
├── status.sh
├── install-systemd.sh
├── uninstall.sh
│
├── lib/
│   ├── common.sh
│   ├── state.sh
│   ├── rclone.sh
│   └── encryption.sh
│
├── systemd/
│   ├── hermes-cloud-backup.service
│   └── hermes-cloud-backup.timer
│
├── tests/
│   ├── test_state.sh
│   ├── test_encryption_logic.sh
│   └── test_idempotency.sh
│
├── README.md
├── LICENSE
└── .gitignore
```

All executable scripts must use:

```bash
set -Eeuo pipefail
```

All top-level scripts must source shared libraries using a path derived from the script directory.

Example conceptual dependency graph:

```text
setup.sh
  ├── lib/common.sh
  ├── lib/state.sh
  ├── lib/rclone.sh
  └── lib/encryption.sh

backup.sh
  ├── lib/common.sh
  ├── lib/state.sh
  ├── lib/rclone.sh
  └── lib/encryption.sh

restore.sh
  ├── lib/common.sh
  ├── lib/state.sh
  ├── lib/rclone.sh
  └── lib/encryption.sh

status.sh
  ├── lib/common.sh
  ├── lib/state.sh
  ├── lib/rclone.sh
  └── lib/encryption.sh
```

## 4.2. Module responsibilities

### `lib/common.sh`

This module owns generic utilities only.

Responsibilities:

- determine `SCRIPT_DIR`;
- define application config directory;
- define application state file path;
- define log path;
- create directories with secure permissions;
- logging functions;
- ANSI/no-ANSI output;
- safe temp directory creation;
- command existence checks;
- safe cleanup helpers;
- atomic file-write helper;
- boolean validation;
- interactive terminal detection;
- lock helper if shared by scripts.

Must NOT contain:

- encryption-specific logic;
- rclone config parsing;
- Hermes backup business logic.

### `lib/state.sh`

This module owns application state.

Responsibilities:

- load state file;
- validate state schema;
- initialize missing default state;
- write state atomically;
- expose getter/setter functions;
- preserve unrelated valid state values;
- ensure permissions;
- manage recovery reminder state.

Must NOT contain:

- actual recovery password;
- actual salt;
- OAuth token;
- rclone config content;
- archive filenames;
- backup execution logic.

### `lib/rclone.sh`

This module owns generic rclone operations.

Responsibilities:

- detect rclone;
- detect configured rclone remotes;
- validate a remote is reachable;
- normalize remote paths;
- copy file to remote;
- list backup files;
- fetch file from remote;
- verify remote object exists/non-zero;
- remove remote files during retention;
- ensure failures are returned clearly;
- redact potentially sensitive command output.

Must NOT contain:

- encryption state decisions;
- secret generation;
- recovery reminder text;
- Hermes-specific archive logic.

### `lib/encryption.sh`

This module owns all rclone crypt behavior.

Responsibilities:

- detect whether encryption is enabled in application state;
- validate configured crypt remote;
- detect whether a remote is type `crypt`;
- create crypt remote during initial setup;
- generate crypt password and salt;
- return active upload/download remote;
- prevent fallback to plaintext remote;
- generate user-facing encryption status text;
- provide recovery reminder text;
- validate encrypted state consistency.

Must NOT contain:

- archive compression;
- GFS retention algorithm;
- systemd installation;
- direct `hermes import` logic.

---

# 5. Local paths and persistent state

## 5.1. Application config directory

Use:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/hermes-backup/
```

Define:

```text
APP_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hermes-backup"
APP_STATE_FILE="${APP_CONFIG_DIR}/state.env"
```

Requirements:

```text
APP_CONFIG_DIR permissions: 0700
APP_STATE_FILE permissions: 0600
```

Create safely when needed.

## 5.2. State file contents

State file contains non-secret configuration only.

Example:

```text
STATE_SCHEMA_VERSION=1

ENCRYPTION_ENABLED=false
ENCRYPTION_MODE=none

BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackups

CRYPT_REMOTE=
CRYPT_PATH=

RECOVERY_NOTICE_STATE=shown

ENCRYPTION_SETUP_COMPLETED_AT=
```

Example after encrypted setup:

```text
STATE_SCHEMA_VERSION=1

ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt

BASE_REMOTE=gdrive-hermes:
BASE_PATH=HermesBackupsEncrypted

CRYPT_REMOTE=hermes-backup-crypt:
CRYPT_PATH=

RECOVERY_NOTICE_STATE=pending

ENCRYPTION_SETUP_COMPLETED_AT=2026-07-20T12:34:56Z
```

## 5.3. Allowed values

```text
ENCRYPTION_ENABLED:
  true | false

ENCRYPTION_MODE:
  none | rclone-crypt

RECOVERY_NOTICE_STATE:
  pending | shown
```

Invalid state must cause a clear error and non-zero exit.

Never assume an invalid/missing state means encryption should be disabled.

If state is inconsistent, fail closed.

Example:

```text
ENCRYPTION_ENABLED=true
CRYPT_REMOTE=
```

must produce:

```text
[ERR] Encryption state is inconsistent: CRYPT_REMOTE is missing.
[ERR] Backup was not started to avoid an accidental plaintext upload.
```

---

# 6. Secret model

## 6.1. What is secret

The following are secrets:

- rclone crypt password;
- rclone crypt salt/password2;
- Google Drive OAuth token;
- rclone configuration content;
- API tokens and credentials;
- any generated recovery material.

## 6.2. Where operational secrets live

Operational rclone crypt settings live in the user’s rclone config:

```text
~/.config/rclone/rclone.conf
```

or the platform-specific rclone config location.

This is necessary so automatic backup can run unattended.

The project’s own `state.env` MUST NOT store crypt password or salt.

## 6.3. Recovery material

During initial encrypted setup, generate:

```text
1. Crypt password
2. Crypt salt/password2
```

These are recovery material.

They allow the user to recreate the crypt remote if:

```text
- the VPS/computer is lost;
- rclone.conf is lost;
- the cloud backup remains available.
```

## 6.4. Recovery material output rule

Recovery material may only be displayed:

```text
- during interactive encrypted setup;
- directly to a TTY;
- once;
- after crypt remote has been successfully created;
- before encrypted setup is marked complete.
```

Never output recovery material to:

- application log files;
- systemd journal;
- redirected stdout/stderr;
- CI logs;
- shell history;
- source code;
- state file;
- Git;
- cloud backup folder.

If setup is not attached to an interactive terminal:

```text
Do not enable encryption.
Exit non-zero.
Explain that encrypted setup must be run interactively.
```

## 6.5. Required recovery screen

During interactive encryption setup, display:

```text
======================================================================
IMPORTANT: ENCRYPTED BACKUP RECOVERY MATERIAL
======================================================================

Your cloud backups will be encrypted before upload.

Save BOTH values below in a password manager, encrypted offline note,
or another secure location independent from:

  - this VPS/computer
  - this Hermes installation
  - this rclone configuration
  - this cloud-storage account and backup folder

If you lose both this machine/rclone configuration and these values,
encrypted backups cannot be restored.

Recovery password:
  <generated crypt password>

Recovery salt:
  <generated crypt salt>

Do NOT save these values in the same Google Drive folder that stores
the encrypted backups.

Type SAVED to confirm that you saved the recovery material:
======================================================================
```

After user types exactly:

```text
SAVED
```

continue setup.

Otherwise:

```text
- do not mark encryption setup complete;
- do not install/enable encrypted timer configuration;
- exit non-zero with clear instructions;
- do not delete the newly created crypt remote automatically.
```

Reason: deleting or changing remote config could make cleanup unsafe.

---

# 7. Encryption configuration

## 7.1. Crypt remote defaults

During encryption setup, use:

```text
CRYPT_REMOTE_NAME=hermes-backup-crypt
```

The final rclone remote string is:

```text
hermes-backup-crypt:
```

The raw encrypted storage path defaults to:

```text
HermesBackupsEncrypted
```

The crypt remote wraps:

```text
<BASE_REMOTE>HermesBackupsEncrypted
```

Example:

```text
gdrive-hermes:HermesBackupsEncrypted
```

## 7.2. Required rclone crypt options

Configure rclone crypt with:

```text
filename_encryption = standard
directory_name_encryption = true
```

Data encryption remains enabled as provided by rclone crypt.

Use a random password and random salt/password2.

Do not let the user choose a weak human password in v1.

## 7.3. Crypt remote creation rules

Creating a crypt remote must:

1. validate the base remote is reachable;
2. verify the base remote is writable;
3. check whether `hermes-backup-crypt:` already exists;
4. if no conflicting remote exists, create it;
5. validate the resulting remote is type `crypt`;
6. validate it points to the expected base remote/path;
7. save state only after validation succeeds;
8. show recovery material only after validation succeeds.

---

# 8. Idempotency rules

## 8.1. Setup state matrix

| Existing state | Expected behavior |
|---|---|
| No state file, no crypt remote | Normal new setup flow |
| State says encryption disabled | Offer normal optional encryption prompt |
| State says encryption enabled; crypt remote valid | Print “already configured”; preserve all encryption configuration |
| State says encryption enabled; reminder pending | Preserve pending state; do not reset |
| State says encryption enabled; reminder shown | Preserve shown state; do not display again |
| Crypt remote exists but app state does not | Do not overwrite it; show conflict/repair instruction |
| State says encryption enabled but crypt remote missing | Fail closed; do not create a new remote/key automatically |
| State says encryption enabled but crypt remote points elsewhere | Fail closed; do not overwrite |
| User chooses “No encryption” after encryption exists | Do not silently disable; require explicit future migration/disable operation |
| Setup rerun after successful setup | Must not generate a new password or salt |

## 8.2. No silent mutation rule

The following actions require an explicit future maintenance command and must NOT happen in normal `setup.sh`:

- changing base remote;
- changing encrypted cloud path;
- changing crypt remote name;
- changing crypt password;
- changing crypt salt;
- disabling encryption;
- adopting an unknown existing crypt remote;
- deleting a crypt remote;
- migrating old plaintext backups.

For v1, if such a condition occurs, print an error and instruct the user to repair manually or wait for a future maintenance command.

## 8.3. Backup fail-closed rule

If:

```text
ENCRYPTION_ENABLED=true
```

and the crypt remote cannot be validated, then:

```text
- do not use BASE_REMOTE;
- do not upload plaintext;
- do not run remote retention cleanup;
- exit non-zero.
```

Required log:

```text
[ERR] Encryption is enabled, but the configured crypt remote is unavailable.
[ERR] Backup was not uploaded to prevent an accidental plaintext cloud upload.
[INFO] Restore the rclone configuration or repair the crypt remote using the saved recovery material.
```

---

# 9. `setup.sh` detailed behavior

## 9.1. Setup sequence

```text
1. Validate required dependencies.
2. Resolve Hermes binary.
3. Validate rclone base remote.
4. Load existing state.
5. Handle idempotency state.
6. If encryption is not configured, ask optional encryption prompt.
7. If encryption enabled:
   - create/validate crypt remote;
   - display recovery material to TTY;
   - require SAVED confirmation;
   - write encrypted state atomically;
   - set RECOVERY_NOTICE_STATE=pending.
8. Install/validate systemd timer.
9. Print status summary.
```

## 9.2. Existing encrypted setup

If valid encryption is already configured:

```text
[OK] Client-side encryption is already configured.
[INFO] Existing crypt remote was retained.
[INFO] No recovery password or salt was regenerated.
[INFO] Recovery reminder state: shown|pending
```

Do not show recovery secret again.  
Do not show first-backup reminder from setup.  
The reminder is only owned by `backup.sh`.

## 9.3. State write timing

Encrypted setup is considered complete only after all are true:

```text
- crypt remote exists;
- crypt remote validation succeeds;
- user entered SAVED;
- atomic state write succeeds.
```

Only then write:

```text
ENCRYPTION_ENABLED=true
ENCRYPTION_MODE=rclone-crypt
RECOVERY_NOTICE_STATE=pending
```

---

# 10. `backup.sh` detailed behavior

## 10.1. Backup sequence

```text
1. Acquire existing backup lock.
2. Load and validate state.
3. Resolve active destination:
   - plaintext mode: BASE_REMOTE + BASE_PATH;
   - encrypted mode: CRYPT_REMOTE + CRYPT_PATH.
4. If encrypted, validate crypt remote before creating/uploading archive.
5. If encrypted and reminder is pending:
   - print reminder;
   - log reminder;
   - atomically set reminder state to shown.
6. Run existing Hermes backup creation flow.
7. Run existing compression flow.
8. Upload archive to active destination.
9. Verify upload through active destination.
10. Run GFS retention through active destination only after upload verification.
11. Clean temporary workspace.
```

## 10.2. First-backup recovery reminder

When:

```text
ENCRYPTION_ENABLED=true
RECOVERY_NOTICE_STATE=pending
```

show exactly this text before creating/uploading archive:

```text
======================================================================
IMPORTANT: ENCRYPTED BACKUP RECOVERY REMINDER
======================================================================

Cloud backup encryption is enabled.

Your backup data is encrypted before it is uploaded. The cloud provider
cannot read the archive without the encryption recovery material.

Save the recovery password and recovery salt in a password manager,
encrypted offline storage, or another secure location independent from:

  - this VPS/computer
  - this Hermes installation
  - this rclone configuration
  - this cloud-storage account

Do NOT store recovery material in the same Google Drive folder or
alongside the encrypted backups.

If this machine and its rclone configuration are lost, encrypted backups
cannot be restored without the saved recovery material.

This reminder is shown only once.
======================================================================
```

This reminder:

- MUST print to terminal;
- MUST be appended to the normal backup log;
- MUST NOT include actual password or salt;
- MUST display once only after state becomes `shown`.

## 10.3. Reminder atomicity

Implement as:

```text
1. Print reminder.
2. Append reminder to log.
3. Atomically change:
     RECOVERY_NOTICE_STATE=pending
   to:
     RECOVERY_NOTICE_STATE=shown
4. Continue backup.
```

If process crashes before atomic state write:

- reminder may appear again in next backup;
- this is acceptable;
- do not treat this as an error.

If process crashes after state write:

- reminder must not appear again.

## 10.4. Remote verification

Plaintext mode:

```text
verify through BASE_REMOTE.
```

Encrypted mode:

```text
verify through CRYPT_REMOTE.
```

Never verify encrypted backup by only checking the raw cloud folder.

Do not log encrypted raw object names if they are not needed.

---

# 11. `restore.sh` detailed behavior

## 11.1. Restore sequence

```text
1. Load and validate state.
2. Resolve active source:
   - plaintext mode: BASE_REMOTE + BASE_PATH;
   - encrypted mode: CRYPT_REMOTE + CRYPT_PATH.
3. If encrypted, validate crypt remote.
4. List available archive names through active source.
5. Choose latest or user-specified archive.
6. Download through active source.
7. In encrypted mode, rclone automatically decrypts locally.
8. Run existing tar.xz extraction/recreate-ZIP logic.
9. Run existing:
     hermes import --force <zip>
10. Securely clean temporary workspace.
```

## 11.2. Restore failure behavior

If encrypted state is enabled but crypt remote is not available:

```text
[ERR] Encrypted backup restore cannot continue because the configured crypt remote is unavailable.
[INFO] Restore the rclone configuration or recreate the crypt remote using the saved recovery password and recovery salt.
```

Exit non-zero.

Do not:

- fallback to raw encrypted cloud files;
- attempt to import ciphertext;
- change encryption state;
- reset recovery reminder state.

---

# 12. `status.sh` detailed behavior

## 12.1. Plaintext mode output

```text
Encryption mode: DISABLED
Cloud destination: <BASE_REMOTE><BASE_PATH>
```

## 12.2. Encrypted mode output

```text
Encryption mode: ENABLED
Encryption backend: rclone crypt
Crypt remote: <CRYPT_REMOTE>
Cloud backup data: encrypted client-side
Recovery reminder: pending|shown
```

Do not print:

- password;
- salt;
- base remote OAuth token;
- raw rclone configuration;
- raw encrypted folder internals.

## 12.3. Invalid encrypted state

If encryption is enabled but crypt remote is not valid:

```text
Encryption mode: ERROR
Reason: configured crypt remote is unavailable, invalid, or inconsistent.
Action: restore rclone configuration or repair the remote with saved recovery material.
```

`status.sh` must exit non-zero.

---

# 13. Systemd requirements

## 13.1. Preserve user configuration

Do not hard-code a conflicting `HERMES_HOME` if the project intends to support custom Hermes home paths.

Preferred behavior:

```text
- support an explicit HERMES_HOME configured by the user;
- preserve existing documented behavior;
- store resolved Hermes home safely in a non-secret state/config field if needed;
- do not overwrite an existing custom setting during setup reruns.
```

## 13.2. Environment

The systemd service must:

- run as the normal user, not root;
- use the correct `PATH`;
- use the correct `HERMES_BIN`;
- use the same application config directory;
- access the same user rclone config;
- not contain secret values directly in the unit file.

Do not place crypt password, salt, token, or full rclone config in:

```text
~/.config/systemd/user/hermes-cloud-backup.service
```

## 13.3. Encryption behavior under timer

Systemd timer backup must behave exactly like manual backup:

```text
- crypt remote used when encryption enabled;
- no password prompt;
- no plaintext fallback;
- first-backup reminder logged once if pending;
- no secret logged to journal.
```

---

# 14. Security requirements

## 14.1. Must do

```text
- Use rclone crypt.
- Encrypt filenames with standard filename encryption.
- Encrypt directory names.
- Generate random password and random salt.
- Keep operational secret material in rclone config only.
- Keep application state free of secrets.
- Use 0700 config directory permissions.
- Use 0600 state file permissions.
- Use restrictive permissions for temporary files/workspaces.
- Clean decrypted temporary artifacts on normal completion.
- Fail closed if encryption is enabled but invalid.
- Never upload plaintext if encryption was expected.
- Never log recovery password or salt.
```

## 14.2. Must not do

```text
- Do not use legacy ZipCrypto.
- Do not create a custom encryption algorithm.
- Do not store password/salt in repo files.
- Do not store password/salt in state.env.
- Do not put password/salt in systemd units.
- Do not print secret in backup logs.
- Do not print secret in status output.
- Do not upload rclone.conf into Hermes backup archive.
- Do not silently generate a new key when an encrypted state already exists.
- Do not fallback from crypt remote to base remote.
```

## 14.3. Threat model documentation

README must state clearly:

```text
Encryption protects cloud backup confidentiality if someone accesses
the cloud-storage files without access to the local rclone crypt config
or independently saved recovery material.

Encryption does not fully protect against compromise of the VPS/user
account that runs automatic backups, because that machine must be able
to access rclone configuration to run unattended backups.

Encryption does not prevent deletion of cloud backups. Retention,
cloud versioning, and a second backup destination are separate concerns.
```

---

# 15. Logging requirements

## 15.1. Required log events

Log these events:

```text
- encryption disabled/enabled;
- crypt remote validation success/failure;
- active backup mode: plaintext/encrypted;
- first encrypted-backup reminder;
- upload start;
- upload success/failure;
- verification success/failure;
- retention success/failure;
- idempotency decisions;
- repair instructions on invalid state;
- systemd setup state;
```

## 15.2. Forbidden log events

Never log:

```text
- crypt password;
- crypt salt;
- recovery material;
- rclone OAuth token;
- rclone.conf contents;
- environment values that may contain secret;
- command output that reveals secret;
- decrypted backup contents.
```

---

# 16. Error handling rules

## 16.1. Fail closed

Required:

```text
Encryption enabled + crypt unavailable
  = backup failure
  = no plaintext upload
  = no retention cleanup
```

## 16.2. Clear remediation messages

All encryption failures must explain the next action.

Example:

```text
[ERR] Encryption is enabled but crypt remote 'hermes-backup-crypt:' is unavailable.
[ERR] Backup was stopped to prevent an unencrypted cloud upload.
[INFO] Restore the local rclone configuration, or recreate the crypt remote
       using the recovery password and salt saved during encrypted setup.
```

## 16.3. Do not auto-repair crypt config

Never automatically create a replacement crypt remote when one is missing but encrypted state exists.

Reason:

```text
A new password/salt would not decrypt existing backups.
```

---

# 17. Test requirements

Add shell tests or testable functions. At minimum, test the following.

## 17.1. State tests

```text
- missing state initializes safely;
- state write is atomic;
- invalid ENCRYPTION_ENABLED is rejected;
- invalid RECOVERY_NOTICE_STATE is rejected;
- encrypted state without CRYPT_REMOTE is rejected;
- state file permissions are 0600;
- config directory permissions are 0700.
```

## 17.2. Idempotency tests

```text
- rerunning setup after encryption does not regenerate key;
- rerunning setup does not reset reminder shown → pending;
- existing valid crypt state remains unchanged;
- conflicting crypt remote is not overwritten;
- missing crypt remote with encrypted state fails closed;
- backup does not fallback to plaintext destination.
```

## 17.3. Reminder tests

```text
- pending reminder prints during first encrypted backup;
- reminder text is written to log;
- password/salt are absent from log;
- state changes pending → shown;
- subsequent backups do not print reminder;
- interrupted state write may repeat reminder but does not corrupt state.
```

## 17.4. Backup/restore behavior tests

```text
- plaintext mode uses base remote;
- encrypted mode uses crypt remote;
- encrypted remote failure blocks upload;
- retention runs only after successful verified upload;
- encrypted restore uses crypt remote;
- restore does not alter encryption state.
```

## 17.5. Secret leak tests

Search:

```text
logs/
generated systemd unit files
state.env
stdout/stderr test captures
```

Verify recovery password and salt are absent everywhere except the controlled interactive setup output.

---

# 18. README additions

Add a section:

```text
## Optional Client-Side Encryption
```

It must explain:

```text
1. Encryption is optional and disabled by default.
2. Encryption uses rclone crypt.
3. Data and archive names are encrypted before cloud upload.
4. Normal backup and restore remain unattended.
5. Recovery password and recovery salt are shown only at interactive setup.
6. User must store recovery material in a password manager or independent secure location.
7. Do not store recovery material in the same cloud account/folder as backups.
8. Losing both rclone configuration and recovery material makes encrypted backups unrecoverable.
9. Do not manipulate encrypted cloud files manually through Google Drive UI.
10. Encryption does not prevent remote deletion; backup retention/versioning remains important.
```

---

# 19. Implementation order

Implement in this order:

```text
1. Create lib/common.sh.
2. Create lib/state.sh and atomic state handling.
3. Refactor existing scripts to use shared common/state modules.
4. Create lib/rclone.sh and move generic rclone logic there.
5. Create lib/encryption.sh.
6. Add encrypted setup flow.
7. Add encrypted backup destination resolution.
8. Add first-backup reminder and atomic reminder state update.
9. Add encrypted restore destination resolution.
10. Add encrypted status reporting.
11. Update systemd integration.
12. Add tests.
13. Update README.
14. Run regression test for existing plaintext behavior.
```

---

# 20. Final invariant checklist

The implementation is correct only if all invariants hold:

```text
[ ] Encryption remains optional.
[ ] Existing plaintext workflow still works unchanged.
[ ] Encryption uses rclone crypt, not custom crypto.
[ ] Crypt password/salt are never stored in app state.
[ ] Password/salt are never logged.
[ ] Recovery material is shown only during interactive initial encrypted setup.
[ ] One recovery reminder without secret is logged exactly once on first encrypted backup.
[ ] Rerunning setup never silently changes keys.
[ ] Invalid encrypted config fails closed.
[ ] No plaintext fallback is possible when encryption is enabled.
[ ] Encrypted backup and restore work unattended through local rclone config.
[ ] State updates are atomic.
[ ] Systemd uses the same mode and does not leak secrets.
[ ] README explains recovery and limitations.
```
