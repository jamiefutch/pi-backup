# =============================================================
#  Pi Clean Reinstall Script (Windows PowerShell)
#  Nuclear option - removes ALL user config, skills, extensions, and state,
#  then reinstalls Pi and creates a fresh ~/.pi structure.
#  Run backup-pi.ps1 FIRST if you want to restore afterward.
#
#  Usage:
#    .\pi-clean-reinstall.ps1                     # default (bun)
#    $env:PKG_MANAGER='npm'; .\pi-clean-reinstall.ps1
# =============================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ─── Config ────────────────────────────────────────────────
$PiRoot = if ($env:PI_ROOT) { $env:PI_ROOT } else { Join-Path $HOME '.pi' }
$Package = '@earendil-works/pi-coding-agent'
$PkgManager = if ($env:PKG_MANAGER) { $env:PKG_MANAGER } else { 'bun' }

function Log  { Write-Host "[INFO]  $args"     -ForegroundColor Cyan }
function OK   { Write-Host "[OK]    $args"     -ForegroundColor Green }
function Warn { Write-Host "[WARN]  $args"     -ForegroundColor Yellow }
function Err  { Write-Host "[ERR]   $args"     -ForegroundColor Red; exit 1 }

# ─── Preflight ─────────────────────────────────────────────
Write-Host ""
Log "================================================================"
Log "  Pi Clean Reinstall (NUCLEAR OPTION)"
Log "================================================================"
Log "Target:      $PiRoot"
Log "Package:     $Package"
Log "Manager:     $PkgManager"
Write-Host ""

if (-not (Test-Path -LiteralPath $PiRoot -PathType Container)) {
    Warn "$PiRoot does not exist - skipping removal."
}

Write-Host ""
Warn "This will DELETE:"
Warn "  $PiRoot          (ALL config, skills, extensions, memory, sessions)"
Warn "  global install of $Package"
Write-Host ""
$confirm = Read-Host "Type 'yes' to continue: "
if ($confirm -ne 'yes') { Err "Aborted." }
Write-Host ""

# ── 1. Remove everything ──────────────────────────────────
Log "1/4  Removing $PiRoot ..."
if (Test-Path -LiteralPath $PiRoot) { Remove-Item -LiteralPath $PiRoot -Recurse -Force }
OK "  $PiRoot removed"

# ── 2. Uninstall Pi ───────────────────────────────────────
Log "2/4  Uninstalling $Package via $PkgManager ..."
& $PkgManager remove -g $Package 2>$null
if ($LASTEXITCODE -ne 0) { Warn "  uninstall reported an issue (may already be removed)" }
OK "  uninstalled"

# ── 3. Reinstall Pi ───────────────────────────────────────
Log "3/4  Installing $Package via $PkgManager ..."
& $PkgManager add -g $Package
if ($LASTEXITCODE -ne 0) { Err "Failed to install $Package via $PkgManager" }
OK "  installed"

# ── 4. Create fresh structure ─────────────────────────────
Log "4/4  Creating fresh $PiRoot structure ..."
& pi --version
OK "  fresh ~/.pi structure created"

Write-Host ""
Log "================================================================"
OK "Clean reinstall complete!"
Write-Host ""
Log "Next steps:"
Log "  1. Restore:  ~/projects/personal/pi-backup/restore-pi.ps1 <backup-dir>"
Log "  2. Reinstall npm deps:  cd ~/.pi/agent && npm install"
Log "  3. Verify:  pi --version, /ctx-doctor, /loop-police-status, /scoped-memory-status"
Write-Host ""
