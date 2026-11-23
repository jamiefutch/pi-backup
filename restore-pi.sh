#!/bin/bash
# Pi Complete Restore Script
# Restores a backup created by backup-pi.sh after a fresh Pi install

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────
PI_ROOT="${PI_ROOT:-$HOME/.pi}"
LOCAL_EXT_ROOT="${LOCAL_EXT_ROOT:-$HOME/projects}"

# ─── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*"; }

# ─── Cleanup ─────────────────────────────────────────────────────
# Registered before any temp dir is created, so every exit path (abort, error,
# success) removes the extraction dir.
STAGE=""
cleanup() {
  local rc=$?
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then
    rm -rf "$STAGE"
  fi
  return $rc
}
trap cleanup EXIT

# ─── Usage ───────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 <backup-directory-or-archive>

Restores a Pi backup created by backup-pi.sh

Examples:
  $0 ~/pi-backups/pi-backup-20260811-143000
  $0 ~/pi-backups/pi-backup-20260811-143000.7z
  $0 ~/pi-backups/pi-backup-20260811-143000.zip

Accepts either an uncompressed backup directory or a compressed
zip/7z archive (as produced by backup-pi.sh).

Prerequisites:
  - Fresh Pi install completed (pi --version works)
  - Pi NOT running

Environment:
  PI_BACKUP_ASSUME_YES=1   Skip the confirmation prompt (for scripted use)
EOF
  exit 1
}

# ─── Archive handling ───────────────────────────────────────────
# Pick a 7zip extraction tool if present, else unzip for .zip.
pick_extract_tool() {
  if command -v 7zz >/dev/null 2>&1; then echo 7zz
  elif command -v 7z >/dev/null 2>&1; then echo 7z
  elif command -v 7za >/dev/null 2>&1; then echo 7za
  else echo ""; fi
}

[[ $# -eq 1 ]] || usage
BACKUP_ARG="$1"
if [[ -d "$BACKUP_ARG" ]]; then
  # Uncompressed directory backup
  BACKUP_DIR="$BACKUP_ARG"
elif [[ -f "$BACKUP_ARG" && "$BACKUP_ARG" =~ \.(zip|7z)$ ]]; then
  # Compressed archive: extract to a temp dir first
  # Explicit template: BSD mktemp ignores $TMPDIR when called without one.
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pi-restore.XXXXXX")"
  log "Extracting archive: $BACKUP_ARG"
  tool="$(pick_extract_tool)"
  if [[ -n "$tool" ]]; then
    "$tool" x -o"$STAGE" "$BACKUP_ARG" >/dev/null
  elif [[ "$BACKUP_ARG" == *.zip ]] && command -v unzip >/dev/null 2>&1; then
    unzip -q "$BACKUP_ARG" -d "$STAGE"
  else
    err "No 7zip or native ZIP extractor available for $BACKUP_ARG."; exit 1
  fi
  # The archive holds one top-level pi-backup-* dir
  BACKUP_DIR="$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$BACKUP_DIR" ]] || { err "No backup directory found inside archive."; exit 1; }
  log "Extracted to: $BACKUP_DIR"
else
  err "Backup not found: $BACKUP_ARG (need a directory, .zip, or .7z)"
  exit 1
fi
[[ -d "$BACKUP_DIR" ]] || { err "Backup directory not found: $BACKUP_DIR"; exit 1; }

# ─── Confirm ─────────────────────────────────────────────────────
echo
warn "════════════════════════════════════════════════════════════"
warn "  Pi Complete Restore"
warn "════════════════════════════════════════════════════════════"
warn "This will OVERWRITE all current Pi configuration."
warn "Backup source: $BACKUP_DIR"
warn "Target:        $PI_ROOT"
warn "Pi must NOT be running."

# Best-effort running-Pi check. It only warns: process names are unreliable.
if command -v pgrep >/dev/null 2>&1 && { pgrep -x pi >/dev/null 2>&1 || pgrep -f 'pi-coding-agent' >/dev/null 2>&1; }; then
  warn "A Pi process appears to be running. Exit Pi first: files restored under a"
  warn "running Pi can be overwritten or corrupted when it exits."
fi
echo

if [[ "${PI_BACKUP_ASSUME_YES:-0}" == "1" ]]; then
  log "PI_BACKUP_ASSUME_YES=1 set; skipping confirmation."
else
  REPLY=""
  if ! read -rp "Continue? [y/N] " -n 1 REPLY; then
    echo
    err "Cannot read a confirmation (stdin is not interactive)."
    err "Run this in a terminal, or set PI_BACKUP_ASSUME_YES=1 to skip the prompt."
    exit 1
  fi
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }
fi

# ─── Manifest ────────────────────────────────────────────────────
# What gets restored is defined once, in backup-manifest.txt (shared with backup).
MANIFEST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup-manifest.txt"
[[ -f "$MANIFEST_FILE" ]] || { err "backup-manifest.txt not found next to $0"; exit 1; }

# ─── Helpers ─────────────────────────────────────────────────────
strip_cr() { printf '%s' "${1%$'\r'}"; }

restore_file() {
  local src="$1" dst="$2"
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    ok "  ${src#"$BACKUP_DIR"/}"
  else
    warn "  ${src#"$BACKUP_DIR"/} — not in backup, skipping"
  fi
}

restore_dir() {
  local src="$1" dst="$2"
  if [[ -d "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    cp -a "$src" "$dst"
    ok "  $(basename "$src")/"
  else
    warn "  $(basename "$src")/ — not in backup, skipping"
  fi
}

restore_manifest_entries() {
  local total step=0 kind f1 f2 f3
  total="$(grep -c '^section|' "$MANIFEST_FILE" || true)"
  while IFS='|' read -r kind f1 f2 f3 || [[ -n "$kind" ]]; do
    kind="$(strip_cr "$kind")"; f1="$(strip_cr "${f1:-}")"; f2="$(strip_cr "${f2:-}")"; f3="$(strip_cr "${f3:-}")"
    case "$kind" in
      ''|'#'*) continue ;;
      section)
        step=$((step+1)); log "$step/$total  $f1..." ;;
      file)
        restore_file "$BACKUP_DIR/$f2" "$PI_ROOT/$f1"
        # Credentials: keep a restored auth.json private to this user
        if [[ "$f2" == "auth.json" && -f "$BACKUP_DIR/$f2" && -f "$PI_ROOT/$f1" ]]; then chmod 600 "$PI_ROOT/$f1"; fi ;;
      dir)
        restore_dir "$BACKUP_DIR/$f2" "$PI_ROOT/$f1" ;;
      dir-each|recent)
        if [[ -d "$BACKUP_DIR/$f2" ]]; then
          local sub name
          for sub in "$BACKUP_DIR/$f2"/*/; do
            [[ -d "$sub" ]] || continue
            name="$(basename "$sub")"
            restore_dir "$sub" "$PI_ROOT/$f1/$name"
          done
          ok "  $f2/ restored"
        else
          warn "  No $f2 in backup"
        fi ;;
      local-ext)
        if [[ -d "$BACKUP_DIR/local-extensions/$f1" ]]; then
          mkdir -p "$LOCAL_EXT_ROOT/$f1"
          cp -a "$BACKUP_DIR/local-extensions/$f1/." "$LOCAL_EXT_ROOT/$f1/"
          ok "  $f1/ restored"
        else
          warn "  $f1 — not in backup, skipping"
        fi ;;
      npm)
        if [[ -d "$BACKUP_DIR/$f2" ]]; then
          mkdir -p "$PI_ROOT/$f1"
          cp -a "$BACKUP_DIR/$f2/." "$PI_ROOT/$f1/"
          ok "  npm manifests restored (run 'npm install' or 'bun install' to reinstall deps)"
        else
          warn "  No npm manifests in backup"
        fi ;;
      *) warn "Unknown manifest entry type: $kind" ;;
    esac
  done < "$MANIFEST_FILE"
}

# ─── Main ────────────────────────────────────────────────────────
main() {
  log "════════════════════════════════════════════════════════════"
  log "  Restoring Pi from backup"
  log "════════════════════════════════════════════════════════════"
  echo

  restore_manifest_entries

  # ── Verify ────────────────────────────────────────────────────
  echo
  log "════════════════════════════════════════════════════════════"
  ok "Restore complete!"
  echo
  log "Next steps:"
  log "  1. Reinstall npm extension dependencies:"
  log "     cd ~/.pi/agent && npm install  # or bun install"
  log "  2. Verify config:"
  log "     pi --version"
  log "     /ctx-doctor"
  log "     /loop-police-status"
  log "     /scoped-memory-status"
  log "  3. Restart Pi and verify everything works"
  echo
}

main "$@"