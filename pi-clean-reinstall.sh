#!/bin/bash
# Pi Clean Reinstall Script
# Nuclear option - removes ALL user config, skills, extensions, and state,
# then reinstalls Pi and creates a fresh ~/.pi structure.
# Run backup-pi.sh FIRST if you want to restore afterward.

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────
PI_ROOT="${PI_ROOT:-$HOME/.pi}"
PACKAGE="@earendil-works/pi-coding-agent"
PKG_MANAGER="${PKG_MANAGER:-bun}"

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

# ─── Preflight ───────────────────────────────────────────────────
preflight() {
  echo
  log "════════════════════════════════════════════════════════════"
  log "  Pi Clean Reinstall (NUCLEAR OPTION)"
  log "════════════════════════════════════════════════════════════"
  log "Target:      $PI_ROOT"
  log "Package:     $PACKAGE"
  log "Manager:     $PKG_MANAGER"
  echo

  if [[ -z "${BUN_HOME:-}" ]] && [[ "$PKG_MANAGER" == "bun" ]]; then
    BUN_HOME="$HOME/.bun"
  fi

  if [[ ! -d "$PI_ROOT" ]]; then
    warn "$PI_ROOT does not exist — skipping removal."
  fi

  echo
  warn "This will DELETE:"
  warn "  $PI_ROOT          (ALL config, skills, extensions, memory, sessions)"
  warn "  global install of $PACKAGE"
  echo
  warn "Type 'yes' to continue: "
  read -r CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    err "Aborted."
    exit 1
  fi
  echo
}

# ─── Main ────────────────────────────────────────────────────────
main() {
  preflight

  # ── 1. Remove everything ─────────────────────────────────────
  log "1/4  Removing $PI_ROOT ..."
  rm -rf "$PI_ROOT"
  ok "  $PI_ROOT removed"

  # ── 2. Uninstall Pi ──────────────────────────────────────────
  log "2/4  Uninstalling $PACKAGE via $PKG_MANAGER ..."
  "$PKG_MANAGER" remove -g "$PACKAGE" || warn "  uninstall reported an issue (may already be removed)"
  ok "  uninstalled"

  # ── 3. Reinstall Pi ──────────────────────────────────────────
  log "3/4  Installing $PACKAGE via $PKG_MANAGER ..."
  "$PKG_MANAGER" add -g "$PACKAGE"
  ok "  installed"

  # ── 4. Create fresh structure ────────────────────────────────
  log "4/4  Creating fresh $PI_ROOT structure ..."
  pi --version
  ok "  fresh ~/.pi structure created"

  echo
  log "════════════════════════════════════════════════════════════"
  ok "Clean reinstall complete!"
  echo
  log "Next steps:"
  log "  1. Restore:  ~/projects/personal/pi-backup/restore-pi.sh <backup-dir>"
  log "  2. Reinstall npm deps:  cd ~/.pi/agent && npm install"
  log "  3. Verify:  pi --version, /ctx-doctor, /loop-police-status, /scoped-memory-status"
  echo
}

main "$@"
