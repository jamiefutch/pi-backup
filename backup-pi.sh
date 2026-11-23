#!/bin/bash
# Pi Complete Backup Script
# Backs up ALL user configuration, skills, extensions, and state
# Run before reinstall; restore with restore-pi.sh after fresh install

set -euo pipefail

# Backups contain credentials (auth.json): keep everything we create private to this user.
umask 077

# ─── Config ──────────────────────────────────────────────────────
PI_ROOT="${PI_ROOT:-$HOME/.pi}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/pi-backups}"
LOCAL_EXT_ROOT="${LOCAL_EXT_ROOT:-$HOME/projects}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/pi-backup-$TIMESTAMP"   # staging dir (compressed into archive below)
KEEP_UNCOMPRESSED="${KEEP_UNCOMPRESSED:-0}"  # set to 1 to keep the staging dir after archiving

# ─── Compression tool detection ────────────────────────────────
# Only needed for compressed (external) backups. Internal backups
# (KEEP_UNCOMPRESSED=1) are plain staging directories and need no tool.
# Prefer 7zip (best ratio) if present, fall back to zip.
ZIP_EXT="zip"
ZIP_TOOL=""
ARCHIVE=""
if [[ "$KEEP_UNCOMPRESSED" != "1" ]]; then
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
fi

# ─── Cleanup on failure ───────────────────────────────────────
# A half-built staging dir (or partial archive) is removed if the script fails.
# A successful run, or a failed compression (staging is intact), keeps it.
STAGING_CREATED=0
KEEP_STAGING_ON_FAIL=0
cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ "$STAGING_CREATED" == "1" && "$KEEP_STAGING_ON_FAIL" != "1" ]]; then
      rm -rf "$BACKUP_DIR"
    fi
    [[ -n "$ARCHIVE" ]] && rm -f "$ARCHIVE"
  fi
  return $rc
}
trap cleanup EXIT

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

# ─── Manifest ────────────────────────────────────────────────────
# What gets backed up is defined once, in backup-manifest.txt (shared with restore).
MANIFEST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup-manifest.txt"
[[ -f "$MANIFEST_FILE" ]] || { echo "[ERR] backup-manifest.txt not found next to $0" >&2; exit 1; }

# ─── Helpers ─────────────────────────────────────────────────────
strip_cr() { printf '%s' "${1%$'\r'}"; }

copy_if_exists() {
  local src="$1" dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
    ok "  ${dst#"$BACKUP_DIR"/}"
  else
    warn "  ${dst#"$BACKUP_DIR"/} — not found, skipping"
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

# Portable tree copy with exclusions (no rsync needed): tar pipe.
copy_source_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  (cd "$src" && tar -cf - --exclude=node_modules --exclude=dist --exclude=build --exclude=.git \
      --exclude=coverage --exclude='*.log' .) | (cd "$dst" && tar -xf -)
}

# auth.json holds credentials: optionally excluded, always private, always flagged.
backup_auth() {
  local src="$1" dst="$2"
  if [[ "${PI_BACKUP_EXCLUDE_AUTH:-0}" == "1" ]]; then
    warn "  auth.json — excluded (PI_BACKUP_EXCLUDE_AUTH=1)"
    return 0
  fi
  copy_if_exists "$src" "$dst"
  if [[ -f "$dst" ]]; then
    chmod 600 "$dst"
    warn "  auth.json holds your API credentials and is included in this backup."
    warn "  Keep the backup private; set PI_BACKUP_EXCLUDE_AUTH=1 to leave it out."
  fi
}

# SQLite databases use WAL, so a plain copy can miss committed data. sqlite3's .backup
# reads through the WAL and writes a consistent snapshot.
backup_sqlite() {
  local src="$1" dst="$2"
  if [[ ! -f "$src" ]]; then
    warn "  ${dst#"$BACKUP_DIR"/} — not found, skipping"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$src" ".timeout 5000" ".backup '$dst'" || { err "  sqlite3 failed to back up ${src}"; return 1; }
    ok "  ${dst#"$BACKUP_DIR"/} (sqlite3 snapshot)"
  else
    warn "  sqlite3 not found: copying ${src##*/} directly. Changes not yet checkpointed may be missing; install sqlite3 or quit Pi first."
    cp -a "$src" "$dst"
    ok "  ${dst#"$BACKUP_DIR"/}"
  fi
}

backup_manifest_entries() {
  local total step=0 kind f1 f2 f3 f4 gate
  total="$(grep -c '^section|' "$MANIFEST_FILE" || true)"
  while IFS='|' read -r kind f1 f2 f3 f4 || [[ -n "$kind" ]]; do
    kind="$(strip_cr "$kind")"; f1="$(strip_cr "${f1:-}")"; f2="$(strip_cr "${f2:-}")"; f3="$(strip_cr "${f3:-}")"; f4="$(strip_cr "${f4:-}")"
    # optional|ENV|kind|pi path|backup path: shift the fields left, skip unless ENV=1
    if [[ "$kind" == optional ]]; then
      gate="$f1"; kind="$f2"; f1="$f3"; f2="$f4"; f3=""; f4=""
      if [[ "${!gate:-0}" != "1" ]]; then
        log "  $f1 — optional, not included (set $gate=1 to include)"
        continue
      fi
    fi
    case "$kind" in
      ''|'#'*) continue ;;
      section)
        step=$((step+1)); log "$step/$total  $f1..." ;;
      file)
        if [[ "$f2" == "auth.json" ]]; then backup_auth "$PI_ROOT/$f1" "$BACKUP_DIR/$f2"
        else copy_if_exists "$PI_ROOT/$f1" "$BACKUP_DIR/$f2"; fi ;;
      sqlite)
        backup_sqlite "$PI_ROOT/$f1" "$BACKUP_DIR/$f2" ;;
      dir)
        copy_dir_if_exists "$PI_ROOT/$f1" "$BACKUP_DIR/$f2" ;;
      dir-each)
        if [[ -d "$PI_ROOT/$f1" ]]; then
          mkdir -p "$BACKUP_DIR/$f2"
          local sub name
          for sub in "$PI_ROOT/$f1"/*/; do
            [[ -d "$sub" ]] || continue
            name="$(basename "$sub")"
            copy_dir_if_exists "$sub" "$BACKUP_DIR/$f2/$name"
          done
          ok "  $f2/ ($(ls -1 "$BACKUP_DIR/$f2" 2>/dev/null | wc -l | tr -d ' ') projects)"
        else
          warn "  $f2/ — not found"
        fi ;;
      local-ext)
        if [[ -d "$LOCAL_EXT_ROOT/$f1" ]]; then
          copy_source_tree "$LOCAL_EXT_ROOT/$f1" "$BACKUP_DIR/local-extensions/$f1"
          ok "  $f1/ (source only)"
        else
          warn "  $f1 — not found at $LOCAL_EXT_ROOT/$f1"
        fi ;;
      npm)
        if [[ -d "$PI_ROOT/$f1" ]]; then
          # Only package.json and lockfiles, never node_modules
          local f rel
          while IFS= read -r f; do
            rel="${f#$PI_ROOT/$f1/}"
            mkdir -p "$BACKUP_DIR/$f2/$(dirname "$rel")"
            cp "$f" "$BACKUP_DIR/$f2/$rel"
          done < <(find "$PI_ROOT/$f1" -maxdepth 3 -type f -not -path '*/node_modules/*' \( -name "package.json" -o -name "package-lock.json" -o -name "npm-shrinkwrap.json" -o -name "pnpm-lock.yaml" \))
          ok "  npm manifests (package.json, lockfiles)"
        else
          warn "  $(basename "$f1")/ — not found"
        fi ;;
      recent)
        if [[ -d "$PI_ROOT/$f1" ]]; then
          mkdir -p "$BACKUP_DIR/$f2"
          local d
          while IFS= read -r d; do
            copy_dir_if_exists "$d" "$BACKUP_DIR/$f2/$(basename "$d")"
          done < <(find "$PI_ROOT/$f1" -maxdepth 1 -type d -name "20*" | sort -r | head -n "${f3:-5}")
        else
          warn "  $(basename "$f1")/ — not found"
        fi ;;
      *) warn "Unknown manifest entry type: $kind" ;;
    esac
  done < "$MANIFEST_FILE"
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
  STAGING_CREATED=1

  backup_manifest_entries

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

  # ── 9. Compress (external backups only) ───────────────────────
  if [[ "$KEEP_UNCOMPRESSED" == "1" ]]; then
    log "9/9  Skipping compression for internal backup"
  else
    log "9/9  Compressing backup ($ZIP_TOOL)..."
    local name comp_out comp_rc=0
    name="$(basename "$BACKUP_DIR")"
    if [[ "$ZIP_TOOL" == "zip" ]]; then
      comp_out="$(cd "$BACKUP_ROOT" && zip -rq "$(basename "$ARCHIVE")" "$name" 2>&1)" || comp_rc=$?
    else
      comp_out="$(cd "$BACKUP_ROOT" && "$ZIP_TOOL" a -t7z -mx=9 "$(basename "$ARCHIVE")" "$name" 2>&1)" || comp_rc=$?
    fi
    if [[ $comp_rc -ne 0 ]]; then
      warn "  Compression with $ZIP_TOOL failed (exit $comp_rc): $comp_out"
      warn "  Keeping uncompressed staging dir: $BACKUP_DIR"
      KEEP_STAGING_ON_FAIL=1
      exit 1
    fi
    ok "  $ARCHIVE"
    # ── 10. Clean up staging dir ────────────────────────────────
    rm -rf "$BACKUP_DIR"
  fi

  # ── Summary ───────────────────────────────────────────────────
  echo
  log "════════════════════════════════════════════════════════════"
  ok "Backup complete!"
  local result
  if [[ "$KEEP_UNCOMPRESSED" == "1" ]]; then
    result="$BACKUP_DIR"
    log "Staging:  $BACKUP_DIR"
    log "Size:     $(du -sh "$BACKUP_DIR" | cut -f1)"
  else
    result="$ARCHIVE"
    log "Archive:  $ARCHIVE"
    log "Size:     $(du -h "$ARCHIVE" | cut -f1)"
  fi
  echo
  log "To restore after reinstall:"
  log "  ./restore-pi.sh $result"
  echo
}

main "$@"