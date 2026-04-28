#!/bin/bash

# ==============================================================================
# install.sh — installs or uninstalls the backup_ios launchd agent
# Generates a plist with machine-specific paths and loads it into launchd.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/backup_ios.sh"
PLIST_LABEL="local.backup-ios"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
USER_ID="$(id -u)"

# Schedule — edit to change the run time
SCHEDULE_WEEKDAY=0   # 0=Sunday, 1=Monday, 2=Tuesday, ..., 6=Saturday
SCHEDULE_HOUR=3
SCHEDULE_MINUTE=0

# ─────────────────────────────────────────────────────────────────────────────

weekday_name() {
  case "$1" in
    0) echo "Sunday"    ;; 1) echo "Monday"  ;; 2) echo "Tuesday"  ;;
    3) echo "Wednesday" ;; 4) echo "Thursday" ;; 5) echo "Friday"  ;;
    6) echo "Saturday"  ;;
  esac
}

uninstall() {
  if [ ! -f "$PLIST_DEST" ]; then
    echo "Agent is not installed."
    exit 0
  fi
  launchctl bootout "gui/$USER_ID" "$PLIST_DEST" 2>/dev/null || true
  rm "$PLIST_DEST"
  echo "✅ Agent uninstalled."
}

install_agent() {
  if [ ! -f "$SCRIPT_PATH" ]; then
    echo "❌ backup_ios.sh not found at: $SCRIPT_PATH"
    exit 1
  fi

  # Resolve CLOUD_DIR — env var, or prompt interactively
  if [ -z "${CLOUD_DIR:-}" ]; then
    echo "CLOUD_DIR is not set."
    echo ""
    echo "Enter the full path to your cloud storage destination folder."
    echo "Examples:"
    echo "  Proton Drive : $HOME/Library/CloudStorage/ProtonDrive-you@example.com-folder/ios_backups"
    echo "  OneDrive     : $HOME/Library/CloudStorage/OneDrive-Personal/ios_backups"
    echo "  Google Drive : $HOME/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/ios_backups"
    echo "  iCloud Drive : $HOME/Library/Mobile Documents/com~apple~CloudDocs/ios_backups"
    echo "  Dropbox      : $HOME/Dropbox/ios_backups"
    echo "  Local / NAS  : /Volumes/MyNAS/ios_backups"
    echo ""
    read -rp "CLOUD_DIR: " CLOUD_DIR
    echo ""
  fi

  if [ -z "${CLOUD_DIR:-}" ]; then
    echo "❌ CLOUD_DIR cannot be empty."
    exit 1
  fi

  chmod +x "$SCRIPT_PATH"

  # Unload existing agent before replacing
  if [ -f "$PLIST_DEST" ]; then
    launchctl bootout "gui/$USER_ID" "$PLIST_DEST" 2>/dev/null || true
  fi

  mkdir -p "$HOME/Library/LaunchAgents"

  # Generate plist with resolved paths
  cat > "$PLIST_DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_PATH}</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>CLOUD_DIR</key>
        <string>${CLOUD_DIR}</string>
    </dict>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>${SCHEDULE_WEEKDAY}</integer>
        <key>Hour</key>
        <integer>${SCHEDULE_HOUR}</integer>
        <key>Minute</key>
        <integer>${SCHEDULE_MINUTE}</integer>
    </dict>

    <!-- The script writes its own log; stdout/stderr go to /dev/null to avoid duplication -->
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST

  launchctl bootstrap "gui/$USER_ID" "$PLIST_DEST"

  echo "✅ Agent installed and loaded."
  echo ""
  echo "  Schedule : every $(weekday_name "$SCHEDULE_WEEKDAY") at $(printf '%02d:%02d' "$SCHEDULE_HOUR" "$SCHEDULE_MINUTE")"
  echo "  Dest     : $CLOUD_DIR"
  echo "  Log      : ~/Library/Logs/backup_ios.log"
  echo ""
  echo "  Run now  : launchctl kickstart -k \"gui/$USER_ID/$PLIST_LABEL\""
  echo "  Remove   : $0 --uninstall"
}

# ─────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --uninstall) uninstall ;;
  "")          install_agent ;;
  *)           echo "Usage: $0 [--uninstall]"; exit 1 ;;
esac
