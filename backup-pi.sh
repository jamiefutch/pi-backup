#!/bin/bash
# Pi Complete Backup Script
# Backs up ALL user configuration, skills, extensions, and state
# Run before reinstall; restore with restore-pi.sh after fresh install

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────
PI_ROOT="${PI_ROOT:-$HOME/.pi}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/projects/personal/pi-utils/backups}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/pi-backup-$TIMESTAMP"   # staging dir (compressed into archive below)
KEEP_UNCOMPRESSED="${KEEP_UNCOMPRESSED:-0}"  # set to 1 to keep the staging dir after archiving

# ─── Compression tool detection ────────────────────────────────
# Prefer 7zip (best ratio) if present, fall back to zip.
ZIP_EXT="zip"
ZIP_TOOL=""
if command -v 7zz >/dev/null 2>&1; then
  ZIP_TOOL="7zz"
  ZIP_EXT="7z"
elif command -v 7z >/dev/null 2>&1; then
  ZIP_TOOL="7z"
  ZIP_EXT="7z"
elif command -v 7za >/dev/null 2>&1; then
  ZIP_TOOL="7za"
  ZIP_EXT="7z"
elif command -v zip >/dev/null 2>&1; then
  ZIP_TOOL="zip"
  ZIP_EXT="zip"
fi
[[ -n "$ZIP_TOOL" ]] || { echo "[ERR] Neither 7zip nor zip found. Install one for compressed backups." >&2; exit 1; }
ARCHIVE="$BACKUP_ROOT/pi-backup-$TIMESTAMP.$ZIP_EXT"

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

# ─── Helpers ─────────────────────────────────────────────────────
copy_if_exists() {
  local src="$1" dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    ok "  $(basename "$src")"
  else
    warn "  $(basename "$src") — not found, skipping"
  fi
}

copy_dir_if_exists() {
  local src="$1" dst="$2"
  if [[ -d "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    ok "  $(basename "$src")/"
  else
    warn "  $(basename "$src")/ — not found, skipping"
  fi
}

# ─── Main ────────────────────────────────────────────────────────
main() {
  echo
  log "════════════════════════════════════════════════════════════"
  log "  Pi Complete Backup"
  log "════════════════════════════════════════════════════════════"
  log "Source:      $PI_ROOT"
  log "Destination: $BACKUP_DIR"
  echo

  mkdir -p "$BACKUP_DIR"

  # ── 1. Core Config Files ──────────────────────────────────────
  log "1/8  Core configuration files..."
  copy_if_exists "$PI_ROOT/agent/settings.json"           "$BACKUP_DIR/settings.json"
  copy_if_exists "$PI_ROOT/agent/auth.json"               "$BACKUP_DIR/auth.json"
  copy_if_exists "$PI_ROOT/agent/models.json"             "$BACKUP_DIR/models.json"
  copy_if_exists "$PI_ROOT/agent/trust.json"              "$BACKUP_DIR/trust.json"
  copy_if_exists "$PI_ROOT/agent/keybindings.json"        "$BACKUP_DIR/keybindings.json"
  copy_if_exists "$PI_ROOT/agent/pix.json"                "$BACKUP_DIR/pix.json"
  copy_if_exists "$PI_ROOT/agent/optimizer.json"          "$BACKUP_DIR/optimizer.json"
  copy_if_exists "$PI_ROOT/agent/lmstudio.json.bak"       "$BACKUP_DIR/lmstudio.json.bak"
  copy_if_exists "$PI_ROOT/agent/hermes-memory-config.json" "$BACKUP_DIR/hermes-memory-config.json"
  copy_if_exists "$PI_ROOT/agent/pi.code-workspace"       "$BACKUP_DIR/pi.code-workspace"

  # ── 2. Extension Configs ──────────────────────────────────────
  log "2/8  Extension configurations..."
  copy_if_exists "$PI_ROOT/agent/pi-hermes-memory-cleanup/scoped-memory.json" \
    "$BACKUP_DIR/pi-hermes-memory-cleanup/scoped-memory.json"
  copy_if_exists "$PI_ROOT/agent/loop-police.json"        "$BACKUP_DIR/loop-police.json"
  copy_if_exists "$PI_ROOT/agent/pi-rtk/config.json"      "$BACKUP_DIR/pi-rtk/config.json"
  copy_if_exists "$PI_ROOT/agent/context-mode/config.json" "$BACKUP_DIR/context-mode/config.json"
  copy_if_exists "$PI_ROOT/agent/pi-timeout/config.json"  "$BACKUP_DIR/pi-timeout/config.json"
  copy_if_exists "$PI_ROOT/agent/pi-context-viewer/config.json" "$BACKUP_DIR/pi-context-viewer/config.json"
  copy_if_exists "$PI_ROOT/agent/pix-optimizer/config.json" "$BACKUP_DIR/pix-optimizer/config.json"
  copy_if_exists "$PI_ROOT/agent/pi-nvidia-nim/config.json" "$BACKUP_DIR/pi-nvidia-nim/config.json"

  # ── 3. Global Skills ──────────────────────────────────────────
  log "3/8  Global skills..."
  copy_dir_if_exists "$PI_ROOT/agent/skills"              "$BACKUP_DIR/skills"

  # ── 4. Project Skills & Memory ────────────────────────────────
  log "4/8  Project skills & memory..."
  if [[ -d "$PI_ROOT/agent/projects-memory" ]]; then
    mkdir -p "$BACKUP_DIR/projects-memory"
    for proj in "$PI_ROOT/agent/projects-memory"/*/; do
      [[ -d "$proj" ]] || continue
      name="$(basename "$proj")"
      copy_dir_if_exists "$proj" "$BACKUP_DIR/projects-memory/$name"
    done
    ok "  projects-memory/ ($(ls -1 "$BACKUP_DIR/projects-memory" 2>/dev/null | wc -l) projects)"
  else
    warn "  projects-memory/ — not found"
  fi

  # ── 5. Local Extensions (source code only, no node_modules) ────
  log "5/8  Local extension source code..."
  local_exts=(
    "pi-timeout"
    "pi-chunk"
    "pi-hermes-memory-cleanup"
    "pi-context-docs"
  )
  for ext in "${local_exts[@]}"; do
    if [[ -d "$HOME/projects/personal/$ext" ]]; then
      mkdir -p "$BACKUP_DIR/local-extensions/$ext"
      # Copy source, exclude node_modules, dist, build, .git, coverage
      rsync -a --exclude 'node_modules' --exclude 'dist' --exclude 'build' --exclude '.git' --exclude 'coverage' --exclude '*.log' \
        "$HOME/projects/personal/$ext/" "$BACKUP_DIR/local-extensions/$ext/"
      ok "  $ext/ (source only)"
    else
      warn "  $ext — not found at ~/projects/personal/$ext"
    fi
  done

  # ── 6. Installed npm Extensions (package.json + lock) ─────────
  log "6/8  npm extension manifests..."
  if [[ -d "$PI_ROOT/agent/npm" ]]; then
    # Only copy package.json and lockfiles, not node_modules
    find "$PI_ROOT/agent/npm" -maxdepth 3 -type f \( -name "package.json" -o -name "package-lock.json" -o -name "npm-shrinkwrap.json" -o -name "pnpm-lock.yaml" \) | while read -r f; do
      rel="${f#$PI_ROOT/agent/npm/}"
      mkdir -p "$BACKUP_DIR/npm-manifests/$(dirname "$rel")"
      cp "$f" "$BACKUP_DIR/npm-manifests/$rel"
    done
    ok "  npm manifests (package.json, lockfiles)"
  else
    warn "  npm/ — not found"
  fi

  # ── 7. Hermes Memory (active files only, not sessions DB) ─────
  log "7/8  Hermes memory (active files)..."
  if [[ -d "$PI_ROOT/agent/pi-hermes-memory" ]]; then
    mkdir -p "$BACKUP_DIR/pi-hermes-memory"
    for f in MEMORY.md USER.md failures.md; do
      copy_if_exists "$PI_ROOT/agent/pi-hermes-memory/$f" "$BACKUP_DIR/pi-hermes-memory/$f"
    done
    # Also backup retired/archived if they exist
    for f in retired-failures.md retired-memory.md; do
      copy_if_exists "$PI_ROOT/agent/pi-hermes-memory/$f" "$BACKUP_DIR/pi-hermes-memory/$f"
    done
  else
    warn "  pi-hermes-memory/ — not found"
  fi

  # ── 8. Cleanup Backups (recent) ───────────────────────────────
  log "8/8  Recent hermes-cleanup backups (last 5)..."
  if [[ -d "$PI_ROOT/agent/hermes-cleanup" ]]; then
    mkdir -p "$BACKUP_DIR/hermes-cleanup"
    find "$PI_ROOT/agent/hermes-cleanup" -maxdepth 1 -type d -name "20*" | sort -r | head -5 | while read -r d; do
      copy_dir_if_exists "$d" "$BACKUP_DIR/hermes-cleanup/$(basename "$d")"
    done
  else
    warn "  hermes-cleanup/ — not found"
  fi

  # ── Manifest ──────────────────────────────────────────────────
  log "Creating manifest..."
  cat > "$BACKUP_DIR/MANIFEST.txt" <<EOF
Pi Complete Backup Manifest
===========================
Created:     $(date)
Pi Root:     $PI_ROOT
Pi Version:  $(pi --version 2>/dev/null || echo "unknown")
Host:        $(hostname)
User:        $(whoami)

Contents:
EOF
  find "$BACKUP_DIR" -type f | sed "s|$BACKUP_DIR/||" | sort >> "$BACKUP_DIR/MANIFEST.txt"

  # ── 9. Compress ───────────────────────────────────────────────
  log "9/9  Compressing backup ($ZIP_TOOL)..."
  local name="$(basename "$BACKUP_DIR")"
  if [[ "$ZIP_TOOL" == "zip" ]]; then
    (cd "$BACKUP_ROOT" && zip -rq "$(basename "$ARCHIVE")" "$name")
  else
    (cd "$BACKUP_ROOT" && "$ZIP_TOOL" a -t7z -mx=9 "$(basename "$ARCHIVE")" "$name" >/dev/null)
  fi
  ok "  $ARCHIVE"

  # ── 10. Clean up staging dir (unless told to keep it) ─────────
  if [[ "$KEEP_UNCOMPRESSED" == "1" ]]; then
    log "Keeping uncompressed staging dir: $BACKUP_DIR"
  else
    rm -rf "$BACKUP_DIR"
  fi

  # ── Summary ───────────────────────────────────────────────────
  echo
  log "════════════════════════════════════════════════════════════"
  ok "Backup complete!"
  log "Archive:  $ARCHIVE"
  log "Size:     $(du -h "$ARCHIVE" | cut -f1)"
  [[ "$KEEP_UNCOMPRESSED" == "1" ]] && log "Staging:  $BACKUP_DIR"
  echo
  log "To restore after reinstall:"
  log "  ~/projects/personal/pi-backup/restore-pi.sh $ARCHIVE"
  echo
}

main "$@"