#!/bin/bash

# ==============================================================================
# backup_ios.sh — iOS Backup to Cloud Storage
# Compresses the latest iPhone backup, splits it into parts, generates PAR2
# recovery files, and stores them in a dated folder on any cloud provider.
# ==============================================================================

set -euo pipefail

# ===== LOCAL CONFIG =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
[ -f "$SCRIPT_DIR/.env" ] && source "$SCRIPT_DIR/.env"

# ===== CONFIG =====
BACKUP_BASE="$HOME/Library/Application Support/MobileSync/Backup"

# Destination directory inside your cloud storage.
# Can also be set via the CLOUD_DIR environment variable.
# Examples:
#   Proton Drive:  "$HOME/Library/CloudStorage/ProtonDrive-you@example.com-folder/ios_backups"
#   OneDrive:      "$HOME/Library/CloudStorage/OneDrive-Personal/ios_backups"
#   Google Drive:  "$HOME/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/ios_backups"
#   iCloud Drive:  "$HOME/Library/Mobile Documents/com~apple~CloudDocs/ios_backups"
#   Dropbox:       "$HOME/Dropbox/ios_backups"
#   Local / NAS:   "/Volumes/MyNAS/ios_backups"
CLOUD_DIR="${CLOUD_DIR:-}"

LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/backup_ios.log}"
LOCK_FILE="${TMPDIR:-/tmp}/backup_ios.lock"
KEEP_LAST=5            # number of backups to keep in cloud storage
MAX_BACKUP_AGE_DAYS=7  # warn if the iPhone backup is older than N days
SPLIT_SIZE="5g"        # maximum size of each split part
PAR2_REDUNDANCY=15     # PAR2 redundancy percentage

# ===== ARGS =====
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "❌ Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ===== HELPERS =====
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

notify() {
  local title="$1"
  local message="$2"
  osascript -e "display notification \"$message\" with title \"$title\" sound name \"Glass\"" 2>/dev/null || true
}

rotate_log() {
  [ -f "$LOG_FILE" ] || return 0
  local max=524288  # 512 KB
  local size
  size=$(stat -f "%z" "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$size" -gt "$max" ]; then
    tail -c "$max" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
}

# ===== TRAP: cleanup on failure =====
CLEANUP_DIR=""
cleanup_on_error() {
  log "❌ Backup failed. Cleaning up partial files..."
  if [ -n "$CLEANUP_DIR" ] && [ -d "$CLEANUP_DIR" ]; then
    rm -rf "$CLEANUP_DIR"
    log "🗑️  Partial folder removed: $CLEANUP_DIR"
  fi
  notify "iOS Backup" "❌ Failed — check log at ~/Library/Logs/backup_ios.log"
}
trap cleanup_on_error ERR INT TERM
trap 'rm -f "$LOCK_FILE"' EXIT

# ===== START =====
rotate_log
if [ "$DRY_RUN" = true ]; then
  log "====== iOS BACKUP START (DRY-RUN) ======"
else
  log "====== iOS BACKUP START ======"
fi

# ===== LOCK FILE =====
if [ -f "$LOCK_FILE" ]; then
  OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    log "❌ Another backup is already running (PID $OLD_PID). Exiting."
    exit 1
  else
    log "⚠️  Stale lock file found (PID $OLD_PID). Removing."
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"

# ===== VALIDATE CONFIG =====
if [ -z "$CLOUD_DIR" ]; then
  log "❌ CLOUD_DIR is not set. Edit the script or set the CLOUD_DIR environment variable."
  log "   Examples:"
  log "     Proton Drive:  \$HOME/Library/CloudStorage/ProtonDrive-you@example.com-folder/ios_backups"
  log "     OneDrive:      \$HOME/Library/CloudStorage/OneDrive-Personal/ios_backups"
  log "     Google Drive:  \$HOME/Library/CloudStorage/GoogleDrive-you@example.com/My Drive/ios_backups"
  log "     iCloud Drive:  \$HOME/Library/Mobile Documents/com~apple~CloudDocs/ios_backups"
  log "     Dropbox:       \$HOME/Dropbox/ios_backups"
  notify "iOS Backup" "❌ CLOUD_DIR not configured — edit backup_ios.sh"
  exit 1
fi

# ===== CHECK DEPENDENCIES =====
if ! command -v par2 &>/dev/null; then
  log "❌ 'par2' is not installed. Install with: brew install par2tools"
  notify "iOS Backup" "❌ par2 not installed — run: brew install par2tools"
  exit 1
fi

# ===== CHECK iOS BACKUP FOLDER =====
if [ ! -d "$BACKUP_BASE" ]; then
  log "❌ iOS backup folder not found: $BACKUP_BASE"
  notify "iOS Backup" "❌ iOS backup folder not found"
  exit 1
fi

# ===== FIND LATEST BACKUP =====
log "🔍 Looking for the most recent iOS backup..."
LATEST_BACKUP=$(find "$BACKUP_BASE" -mindepth 1 -maxdepth 1 -type d -print0 \
  | xargs -0 stat -f "%m %N" \
  | sort -rn \
  | head -n 1 \
  | cut -d' ' -f2-)

if [ -z "$LATEST_BACKUP" ]; then
  log "❌ No backup found in: $BACKUP_BASE"
  notify "iOS Backup" "❌ No iOS backup found"
  exit 1
fi

log "📱 Backup found: $(basename "$LATEST_BACKUP")"

# ===== CHECK BACKUP AGE =====
BACKUP_MOD=$(stat -f "%m" "$LATEST_BACKUP")
NOW=$(date +%s)
AGE_DAYS=$(( (NOW - BACKUP_MOD) / 86400 ))

if [ "$AGE_DAYS" -gt "$MAX_BACKUP_AGE_DAYS" ]; then
  log "⚠️  Warning: backup is ${AGE_DAYS} days old (limit: ${MAX_BACKUP_AGE_DAYS}). Consider connecting your iPhone first."
  notify "iOS Backup" "⚠️  Backup is ${AGE_DAYS} days old — connect your iPhone first?"
fi

# ===== CHECK FREE SPACE =====
BACKUP_SIZE=$(du -sk "$LATEST_BACKUP" | awk '{print $1}')  # in KB
FREE_SPACE=$(df -k "$CLOUD_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || df -k "$HOME" | awk 'NR==2 {print $4}')
# Estimate: ~60% compressed + split overhead + PAR2 (15%)
NEEDED=$(( BACKUP_SIZE * 8 / 10 ))

log "📊 Backup size: $(( BACKUP_SIZE / 1024 )) MB | Estimated space needed: $(( NEEDED / 1024 )) MB"

if [ "$FREE_SPACE" -lt "$NEEDED" ]; then
  log "❌ Not enough disk space. Free: $(( FREE_SPACE / 1024 )) MB | Needed: $(( NEEDED / 1024 )) MB"
  notify "iOS Backup" "❌ Not enough disk space"
  exit 1
fi

# ===== DRY-RUN: summary and exit =====
if [ "$DRY_RUN" = true ]; then
  DATE_PREVIEW=$(date +'%Y-%m-%d')
  EXISTING_COUNT=$(find "$CLOUD_DIR" -mindepth 1 -maxdepth 1 -type d -name "backup_iphone_*" 2>/dev/null | wc -l | tr -d ' ')
  log "🔍 [DRY-RUN] What would happen:"
  log "   iOS backup      : $(basename "$LATEST_BACKUP") (${AGE_DAYS} day(s) old)"
  log "   Destination     : ${CLOUD_DIR}/backup_iphone_${DATE_PREVIEW}"
  log "   Original size   : $(( BACKUP_SIZE / 1024 )) MB"
  log "   Split           : ${SPLIT_SIZE} parts | PAR2 ${PAR2_REDUNDANCY}% redundancy"
  log "   Current backups : ${EXISTING_COUNT} → keep last ${KEEP_LAST}"
  if [ "$EXISTING_COUNT" -ge "$KEEP_LAST" ]; then
    log "   Deletions       : $(( EXISTING_COUNT + 1 - KEEP_LAST )) old backup(s)"
  fi
  log "====== iOS BACKUP END (DRY-RUN) ======"
  notify "iOS Backup" "🔍 Dry-run complete — check log for details"
  exit 0
fi

# ===== CREATE DATED FOLDER IN CLOUD STORAGE =====
DATE=$(date +"%Y-%m-%d")
DEST_DIR="${CLOUD_DIR}/backup_iphone_${DATE}"

if [ -d "$DEST_DIR" ]; then
  log "⚠️  Folder already exists: $DEST_DIR — replacing..."
  rm -rf "$DEST_DIR"
fi

mkdir -p "$DEST_DIR"
CLEANUP_DIR="$DEST_DIR"
log "📁 Folder created: $DEST_DIR"

# ===== FILE NAMES =====
BASENAME="ios_backup_${DATE}"
TARFILE="${DEST_DIR}/${BASENAME}.tar.gz"

# ===== CREATE TAR.GZ =====
log "🗜️  Compressing backup..."
tar -czf "$TARFILE" -C "$(dirname "$LATEST_BACKUP")" "$(basename "$LATEST_BACKUP")"
TAR_SIZE=$(du -sh "$TARFILE" | awk '{print $1}')
log "✅ Compression complete: $TAR_SIZE"

# ===== SPLIT =====
log "✂️  Splitting into ${SPLIT_SIZE} parts..."
split -b "$SPLIT_SIZE" -d -a 3 "$TARFILE" "${DEST_DIR}/${BASENAME}.part_"

rm "$TARFILE"
PART_COUNT=$(find "$DEST_DIR" -name "${BASENAME}.part_*" | wc -l | tr -d ' ')
log "✅ Split into ${PART_COUNT} parts"

# ===== PAR2 =====
log "🧩 Generating PAR2 (${PAR2_REDUNDANCY}% redundancy)..."
par2 create -r"$PAR2_REDUNDANCY" -n10 -q "${DEST_DIR}/${BASENAME}.par2" "${DEST_DIR}/${BASENAME}.part_"*
log "✅ PAR2 generated"

# ===== VERIFY PAR2 =====
log "🔎 Verifying PAR2 integrity..."
par2 verify -q "${DEST_DIR}/${BASENAME}.par2"
log "✅ PAR2 verified — integrity confirmed"

# ===== CLEAN UP OLD BACKUPS =====
log "🧹 Checking for old backups (keeping last ${KEEP_LAST})..."
EXISTING_BACKUPS=$(find "$CLOUD_DIR" -mindepth 1 -maxdepth 1 -type d -name "backup_iphone_*" | sort -r)
TOTAL=$(echo "$EXISTING_BACKUPS" | grep -c . || true)

if [ "$TOTAL" -gt "$KEEP_LAST" ]; then
  TO_DELETE=$(echo "$EXISTING_BACKUPS" | tail -n +"$(( KEEP_LAST + 1 ))")
  while IFS= read -r old_dir; do
    log "🗑️  Removing old backup: $(basename "$old_dir")"
    rm -rf "$old_dir"
  done <<< "$TO_DELETE"
fi

# ===== DONE =====
CLEANUP_DIR=""  # disable cleanup trap — completed successfully
FINAL_SIZE=$(du -sh "$DEST_DIR" | awk '{print $1}')
log "✅ Backup completed successfully!"
log "   Destination : $DEST_DIR"
log "   Size        : $FINAL_SIZE"
log "   Parts       : $PART_COUNT"
log "====== iOS BACKUP END ======"

notify "iOS Backup" "✅ Done — ${PART_COUNT} parts, ${FINAL_SIZE} in backup_iphone_${DATE}"
