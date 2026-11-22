#!/bin/bash
# Pi Clean Reinstall Script
# Removes ALL user config, skills, extensions, and state, then reinstalls Pi.
# Run backup-pi.sh FIRST if you want to restore afterward.
#
# Safety: ~/.pi is moved aside first, and only deleted after the reinstall succeeds.
# If the uninstall/install/verify steps fail, the original ~/.pi is moved back.

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────
PI_ROOT="${PI_ROOT:-$HOME/.pi}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/pi-backups}"
PACKAGE="@earendil-works/pi-coding-agent"
PKG_MANAGER="${PKG_MANAGER:-bun}"
KEEP_OLD="${KEEP_OLD:-0}"   # set to 1 to keep the moved-aside copy after a successful reinstall
OLD_ROOT="$PI_ROOT.pre-reinstall-$(date +%Y%m%d-%H%M%S)"
MOVED=0
FINISHED=0

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

# ─── Rollback ────────────────────────────────────────────────────
# Runs on any non-zero exit after the original ~/.pi was moved aside.
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$FINISHED" != "1" && "$MOVED" == "1" && -d "$OLD_ROOT" ]]; then
    err "Reinstall failed (exit $rc). Restoring the original $PI_ROOT ..."
    rm -rf "$PI_ROOT"
    mv "$OLD_ROOT" "$PI_ROOT"
    warn "Original $PI_ROOT restored. Pi may need to be reinstalled manually: $PKG_MANAGER add -g $PACKAGE"
  fi
  return $rc
}
trap on_exit EXIT

# ─── Preflight ───────────────────────────────────────────────────
confirm() { # confirm <expected-text>; fails (exit 1) when stdin cannot be read
  local reply=""
  if ! read -r reply; then
    err "Cannot read a confirmation (stdin is not interactive). Aborted; nothing was changed."
    exit 1
  fi
  [[ "$reply" == "$1" ]]
}

has_backup() {
  compgen -G "$BACKUP_ROOT/pi-backup-*" >/dev/null 2>&1
}

preflight() {
  echo
  log "════════════════════════════════════════════════════════════"
  log "  Pi Clean Reinstall (NUCLEAR OPTION)"
  log "════════════════════════════════════════════════════════════"
  log "Target:      $PI_ROOT"
  log "Package:     $PACKAGE"
  log "Manager:     $PKG_MANAGER"
  log "Backups in:  $BACKUP_ROOT"
  echo

  if [[ ! -d "$PI_ROOT" ]]; then
    warn "$PI_ROOT does not exist — nothing to move aside."
  fi

  warn "This will DELETE:"
  warn "  $PI_ROOT          (ALL config, skills, extensions, memory, sessions)"
  warn "  global install of $PACKAGE"
  warn "($PI_ROOT is only deleted after the reinstall succeeds.)"
  echo

  if ! has_backup; then
    warn "No backup found in $BACKUP_ROOT (looked for pi-backup-*)."
    warn "Run ./backup-pi.sh first unless you really want to lose your config."
    warn "Type 'no backup' to continue WITHOUT a backup: "
    if ! confirm "no backup"; then err "Aborted."; exit 1; fi
    echo
  fi

  warn "Type 'yes' to continue: "
  if ! confirm "yes"; then err "Aborted."; exit 1; fi
  echo
}

# ─── Main ────────────────────────────────────────────────────────
main() {
  preflight

  # ── 1. Move ~/.pi aside ──────────────────────────────────────
  log "1/5  Moving $PI_ROOT aside ..."
  if [[ -e "$PI_ROOT" ]]; then
    mv "$PI_ROOT" "$OLD_ROOT"
    MOVED=1
    ok "  moved to $OLD_ROOT"
  else
    ok "  nothing to move"
  fi

  # ── 2. Uninstall Pi ──────────────────────────────────────────
  log "2/5  Uninstalling $PACKAGE via $PKG_MANAGER ..."
  "$PKG_MANAGER" remove -g "$PACKAGE" || warn "  uninstall reported an issue (may already be removed)"
  ok "  uninstall step done"

  # ── 3. Reinstall Pi ──────────────────────────────────────────
  log "3/5  Installing $PACKAGE via $PKG_MANAGER ..."
  "$PKG_MANAGER" add -g "$PACKAGE" || { err "  install failed"; exit 1; }
  ok "  installed"

  # ── 4. Verify ────────────────────────────────────────────────
  log "4/5  Verifying the install (pi --version) ..."
  pi --version || { err "  'pi --version' failed after install"; exit 1; }
  ok "  pi runs (it creates a fresh $PI_ROOT on first start)"

  # ── 5. Remove the moved-aside copy ───────────────────────────
  FINISHED=1
  if [[ "$MOVED" == "1" ]]; then
    if [[ "$KEEP_OLD" == "1" ]]; then
      log "5/5  Keeping the old config at $OLD_ROOT (KEEP_OLD=1)"
    else
      log "5/5  Deleting the old config at $OLD_ROOT ..."
      rm -rf "$OLD_ROOT"
      ok "  deleted"
    fi
  else
    log "5/5  Nothing to clean up"
  fi

  echo
  log "════════════════════════════════════════════════════════════"
  ok "Clean reinstall complete!"
  echo
  log "Next steps:"
  log "  1. Restore:  ./restore-pi.sh <backup-dir-or-archive>"
  log "  2. Reinstall npm deps:  cd ~/.pi/agent && npm install"
  log "  3. Verify:  pi --version, /ctx-doctor, /loop-police-status, /scoped-memory-status"
  echo
}

main "$@"
