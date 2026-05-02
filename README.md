# ios-cloud-backup

Back up your iPhone to any cloud storage on macOS — Proton Drive, OneDrive, Google Drive, iCloud, Dropbox, or a local NAS.

Each backup is compressed, split into 5 GB parts, and protected with PAR2 recovery files. Old backups are automatically rotated.

## Requirements

- macOS (uses native tools: `tar`, `split`, `stat`, `osascript`)
- [`par2tools`](https://github.com/Parchive/par2cmdline) — `brew install par2tools`
- Any cloud storage folder mounted locally

## Quick start

**1. Set your destination** — copy `.env.example` to `.env` and fill in `CLOUD_DIR`:

```bash
cp .env.example .env
```

```
CLOUD_DIR="$HOME/Library/CloudStorage/ProtonDrive-you@example.com-folder/ios_backups"
```

`.env` is local to your machine and never committed. You can also pass `CLOUD_DIR` as an environment variable directly:

```bash
export CLOUD_DIR="$HOME/Library/CloudStorage/ProtonDrive-you@example.com-folder/ios_backups"
```

**2. Run:**

```bash
chmod +x backup_ios.sh
./backup_ios.sh
```

**3. Dry run** (validates everything, writes nothing):

```bash
./backup_ios.sh --dry-run
```

## Configuration

Set variables in `.env` (recommended) or export them as environment variables. All have sensible defaults except `CLOUD_DIR`.

| Variable              | Default | Description |
|-----------------------|---------|-------------|
| `CLOUD_DIR`           | *(required)* | Destination folder in your cloud storage |
| `KEEP_LAST`           | `5` | Number of backups to retain |
| `MAX_BACKUP_AGE_DAYS` | `7` | Warn if the iPhone backup is older than N days |
| `SPLIT_SIZE`          | `5g` | Maximum size per split part |
| `PAR2_REDUNDANCY`     | `15` | PAR2 redundancy percentage |
| `LOG_FILE`            | `~/Library/Logs/backup_ios.log` | Log file path |

## Cloud provider examples

| Provider | `CLOUD_DIR` path |
|---|---|
| Proton Drive | `~/Library/CloudStorage/ProtonDrive-you@example.com-folder/ios_backups` |
| OneDrive | `~/Library/CloudStorage/OneDrive-Personal/ios_backups` |
| Google Drive | `~/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/ios_backups` |
| iCloud Drive | `~/Library/Mobile Documents/com~apple~CloudDocs/ios_backups` |
| Dropbox | `~/Dropbox/ios_backups` |
| Local / NAS | `/Volumes/MyNAS/ios_backups` |

## Global install (optional)

Copy the script to `/usr/local/bin` so it runs from anywhere:

```bash
sudo cp backup_ios.sh /usr/local/bin/backup-ios
sudo chmod +x /usr/local/bin/backup-ios
```

Then call it directly:

```bash
backup-ios
backup-ios --dry-run
```

To uninstall:

```bash
sudo rm /usr/local/bin/backup-ios
```

## Automatic scheduling (launchd)

`install.sh` generates a launchd plist with the correct machine-specific paths and loads it as a user agent (default: every Sunday at 03:00).

```bash
chmod +x install.sh
./install.sh
```

The installer prompts for `CLOUD_DIR` if not already set as an environment variable.

```bash
./install.sh --uninstall        # remove the scheduled agent
```

```bash
launchctl kickstart -k "gui/$(id -u)/local.backup-ios"   # run immediately
```

To change the schedule, edit `SCHEDULE_WEEKDAY`, `SCHEDULE_HOUR`, and `SCHEDULE_MINUTE` at the top of `install.sh` and re-run it.

## Output structure

```
CLOUD_DIR/
└── backup_iphone_YYYY-MM-DD/
    ├── ios_backup_YYYY-MM-DD.part_000
    ├── ios_backup_YYYY-MM-DD.part_001
    ├── ...
    ├── ios_backup_YYYY-MM-DD.par2
    └── ios_backup_YYYY-MM-DD.vol*.par2
```

## Recovery

Verify integrity:
```bash
cd backup_iphone_YYYY-MM-DD
par2 verify ios_backup_YYYY-MM-DD.par2
```

Repair if needed (uses PAR2 redundancy blocks):
```bash
par2 repair ios_backup_YYYY-MM-DD.par2
```

Restore:
```bash
cat ios_backup_YYYY-MM-DD.part_* > ios_backup_YYYY-MM-DD.tar.gz
tar -xzf ios_backup_YYYY-MM-DD.tar.gz
```

## Log

```bash
tail -f ~/Library/Logs/backup_ios.log
```

The log is automatically trimmed to the last 512 KB on each run.

## Verify download

```
c933a8eb97045dfe00be62c8fd8b38386b5f6a7299ba33a154f93f6f8430d661  backup_ios.sh
3c8d38c9891748b61d3a0cbc97d61efc3854f761cb82e8fa4b163df5a5904cf4  install.sh
```

```bash
shasum -a 256 -c <(cat <<'EOF'
c933a8eb97045dfe00be62c8fd8b38386b5f6a7299ba33a154f93f6f8430d661  backup_ios.sh
3c8d38c9891748b61d3a0cbc97d61efc3854f761cb82e8fa4b163df5a5904cf4  install.sh
EOF
)
```
