#!/bin/bash
# Pi Complete Restore Script
# Restores a backup created by backup-pi.sh after a fresh Pi install

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────
PI_ROOT="${PI_ROOT:-$HOME/.pi}"

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

# ─── Usage ───────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 <backup-directory-or-archive>

Restores a Pi backup created by backup-pi.sh

Examples:
  $0 ~/projects/personal/pi-utils/backups/pi-backup-20260811-143000
  $0 ~/projects/personal/pi-utils/backups/pi-backup-20260811-143000.7z
  $0 ~/projects/personal/pi-utils/backups/pi-backup-20260811-143000.zip

Accepts either an uncompressed backup directory or a compressed
zip/7z archive (as produced by backup-pi.sh).

Prerequisites:
  - Fresh Pi install completed (pi --version works)
  - Pi NOT running
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
  STAGE=""
elif [[ -f "$BACKUP_ARG" && "$BACKUP_ARG" =~ \.(zip|7z)$ ]]; then
  # Compressed archive: extract to a temp dir first
  STAGE="$(mktemp -d)"
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
  [[ -n "$BACKUP_DIR" ]] || { err "No backup directory found inside archive."; rm -rf "$STAGE"; exit 1; }
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
echo
read -rp "Continue? [y/N] " -n 1
echo
[[ $REPLY =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

# ─── Helpers ─────────────────────────────────────────────────────
restore_file() {
  local src="$1" dst="$2"
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    ok "  $(basename "$src")"
  else
    warn "  $(basename "$src") — not in backup, skipping"
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

# ─── Main ────────────────────────────────────────────────────────
main() {
  log "════════════════════════════════════════════════════════════"
  log "  Restoring Pi from backup"
  log "════════════════════════════════════════════════════════════"
  echo

  # ── 1. Core Config Files ──────────────────────────────────────
  log "1/8  Core configuration files..."
  restore_file "$BACKUP_DIR/settings.json"              "$PI_ROOT/agent/settings.json"
  restore_file "$BACKUP_DIR/auth.json"                  "$PI_ROOT/agent/auth.json"
  restore_file "$BACKUP_DIR/models.json"                "$PI_ROOT/agent/models.json"
  restore_file "$BACKUP_DIR/trust.json"                 "$PI_ROOT/agent/trust.json"
  restore_file "$BACKUP_DIR/keybindings.json"           "$PI_ROOT/agent/keybindings.json"
  restore_file "$BACKUP_DIR/pix.json"                   "$PI_ROOT/agent/pix.json"
  restore_file "$BACKUP_DIR/optimizer.json"             "$PI_ROOT/agent/optimizer.json"
  restore_file "$BACKUP_DIR/lmstudio.json.bak"          "$PI_ROOT/agent/lmstudio.json.bak"
  restore_file "$BACKUP_DIR/hermes-memory-config.json"  "$PI_ROOT/agent/hermes-memory-config.json"
  restore_file "$BACKUP_DIR/pi.code-workspace"          "$PI_ROOT/agent/pi.code-workspace"

  # ── 2. Extension Configs ──────────────────────────────────────
  log "2/8  Extension configurations..."
  restore_file "$BACKUP_DIR/pi-hermes-memory-cleanup/scoped-memory.json" \
    "$PI_ROOT/agent/pi-hermes-memory-cleanup/scoped-memory.json"
  restore_file "$BACKUP_DIR/loop-police.json"           "$PI_ROOT/agent/loop-police.json"
  restore_file "$BACKUP_DIR/pi-rtk/config.json"         "$PI_ROOT/agent/pi-rtk/config.json"
  restore_file "$BACKUP_DIR/context-mode/config.json"   "$PI_ROOT/agent/context-mode/config.json"
  restore_file "$BACKUP_DIR/pi-timeout/config.json"     "$PI_ROOT/agent/pi-timeout/config.json"
  restore_file "$BACKUP_DIR/pi-context-viewer/config.json" "$PI_ROOT/agent/pi-context-viewer/config.json"
  restore_file "$BACKUP_DIR/pix-optimizer/config.json"  "$PI_ROOT/agent/pix-optimizer/config.json"
  restore_file "$BACKUP_DIR/pi-nvidia-nim/config.json"  "$PI_ROOT/agent/pi-nvidia-nim/config.json"

  # ── 3. Global Skills ──────────────────────────────────────────
  log "3/8  Global skills..."
  restore_dir "$BACKUP_DIR/skills"                      "$PI_ROOT/agent/skills"

  # ── 4. Project Skills & Memory ────────────────────────────────
  log "4/8  Project skills & memory..."
  if [[ -d "$BACKUP_DIR/projects-memory" ]]; then
    for proj in "$BACKUP_DIR/projects-memory"/*/; do
      [[ -d "$proj" ]] || continue
      name="$(basename "$proj")"
      restore_dir "$proj" "$PI_ROOT/agent/projects-memory/$name"
    done
    ok "  projects-memory/ restored"
  else
    warn "  No project memory in backup"
  fi

  # ── 5. Local Extensions ───────────────────────────────────────
  log "5/8  Local extension source code..."
  if [[ -d "$BACKUP_DIR/local-extensions" ]]; then
    for ext in "$BACKUP_DIR/local-extensions"/*/; do
      [[ -d "$ext" ]] || continue
      name="$(basename "$ext")"
      mkdir -p "$HOME/projects/personal/$name"
      rsync -a "$ext/" "$HOME/projects/personal/$name/"
      ok "  $name/ restored"
    done
  else
    warn "  No local extensions in backup"
  fi

  # ── 6. npm Extension Manifests ────────────────────────────────
  log "6/8  npm extension manifests..."
  if [[ -d "$BACKUP_DIR/npm-manifests" ]]; then
    mkdir -p "$PI_ROOT/agent/npm"
    cp -a "$BACKUP_DIR/npm-manifests/"* "$PI_ROOT/agent/npm/" 2>/dev/null || true
    ok "  npm manifests restored (run 'npm install' or 'bun install' to reinstall deps)"
  else
    warn "  No npm manifests in backup"
  fi

  # ── 7. Hermes Memory ──────────────────────────────────────────
  log "7/8  Hermes memory (active files)..."
  if [[ -d "$BACKUP_DIR/pi-hermes-memory" ]]; then
    mkdir -p "$PI_ROOT/agent/pi-hermes-memory"
    for f in MEMORY.md USER.md failures.md retired-failures.md retired-memory.md; do
      restore_file "$BACKUP_DIR/pi-hermes-memory/$f" "$PI_ROOT/agent/pi-hermes-memory/$f"
    done
  else
    warn "  No Hermes memory in backup"
  fi

  # ── 8. Cleanup Backups ────────────────────────────────────────
  log "8/8  Hermes-cleanup backups..."
  if [[ -d "$BACKUP_DIR/hermes-cleanup" ]]; then
    mkdir -p "$PI_ROOT/agent/hermes-cleanup"
    for d in "$BACKUP_DIR/hermes-cleanup"/*/; do
      [[ -d "$d" ]] || continue
      name="$(basename "$d")"
      restore_dir "$d" "$PI_ROOT/agent/hermes-cleanup/$name"
    done
  else
    warn "  No cleanup backups in backup"
  fi

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

# ─── Cleanup ────────────────────────────────────────────────────
if [[ -n "${STAGE:-}" && -d "$STAGE" ]]; then
  rm -rf "$STAGE"
  log "Removed temp extraction dir."
fi