# =============================================================
#  Pi Clean Reinstall Script (Windows PowerShell)
#  Removes ALL user config, skills, extensions, and state, then reinstalls Pi.
#  Run backup-pi.ps1 FIRST if you want to restore afterward.
#
#  Safety: ~/.pi is moved aside first and only deleted after the reinstall
#  succeeds. If uninstall/install/verify fails, the original is moved back.
#
#  Usage:
#    .\pi-clean-reinstall.ps1                     # default (bun)
#    $env:PKG_MANAGER='npm'; .\pi-clean-reinstall.ps1
#    $env:KEEP_OLD='1'; .\pi-clean-reinstall.ps1  # keep the moved-aside copy
# =============================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ─── Config ────────────────────────────────────────────────
$PiRoot = if ($env:PI_ROOT) { $env:PI_ROOT } else { Join-Path $HOME '.pi' }
$BackupRoot = if ($env:BACKUP_ROOT) { $env:BACKUP_ROOT } else { Join-Path $HOME 'pi-backups' }
$Package = '@earendil-works/pi-coding-agent'
$PkgManager = if ($env:PKG_MANAGER) { $env:PKG_MANAGER } else { 'bun' }
$KeepOld = $env:KEEP_OLD -eq '1'
$OldRoot = "$PiRoot.pre-reinstall-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$Moved = $false
$Finished = $false

function Log  { Write-Host "[INFO]  $args"     -ForegroundColor Cyan }
function OK   { Write-Host "[OK]    $args"     -ForegroundColor Green }
function Warn { Write-Host "[WARN]  $args"     -ForegroundColor Yellow }
function Err  { Write-Host "[ERR]   $args"     -ForegroundColor Red; exit 1 }

# Read one confirmation line; exits (without changing anything) when stdin cannot be read.
function Read-Confirmation([string]$prompt) {
    $reply = $null
    try { $reply = Read-Host $prompt } catch { $reply = $null }
    if ($null -eq $reply) {
        Write-Host "[ERR]   Cannot read a confirmation (stdin is not interactive). Aborted; nothing was changed." -ForegroundColor Red
        exit 1
    }
    return $reply
}

try {
# ─── Preflight ─────────────────────────────────────────────
Write-Host ""
Log "================================================================"
Log "  Pi Clean Reinstall (NUCLEAR OPTION)"
Log "================================================================"
Log "Target:      $PiRoot"
Log "Package:     $Package"
Log "Manager:     $PkgManager"
Log "Backups in:  $BackupRoot"
Write-Host ""

if (-not (Test-Path -LiteralPath $PiRoot)) {
    Warn "$PiRoot does not exist - nothing to move aside."
}

Warn "This will DELETE:"
Warn "  $PiRoot          (ALL config, skills, extensions, memory, sessions)"
Warn "  global install of $Package"
Warn "($PiRoot is only deleted after the reinstall succeeds.)"
Write-Host ""

$hasBackup = $false
if (Test-Path -LiteralPath $BackupRoot) {
    $hasBackup = [bool](Get-ChildItem -LiteralPath $BackupRoot -Filter 'pi-backup-*' -ErrorAction SilentlyContinue | Select-Object -First 1)
}
if (-not $hasBackup) {
    Warn "No backup found in $BackupRoot (looked for pi-backup-*)."
    Warn "Run .\backup-pi.ps1 first unless you really want to lose your config."
    $reply = Read-Confirmation "Type 'no backup' to continue WITHOUT a backup"
    if ($reply -ne 'no backup') { Err "Aborted." }
    Write-Host ""
}

$confirm = Read-Confirmation "Type 'yes' to continue"
if ($confirm -ne 'yes') { Err "Aborted." }
Write-Host ""

# ── 1. Move $PiRoot aside ─────────────────────────────────
Log "1/5  Moving $PiRoot aside ..."
if (Test-Path -LiteralPath $PiRoot) {
    Move-Item -LiteralPath $PiRoot -Destination $OldRoot
    $Moved = $true
    OK "  moved to $OldRoot"
} else {
    OK "  nothing to move"
}

# ── 2. Uninstall Pi ───────────────────────────────────────
Log "2/5  Uninstalling $Package via $PkgManager ..."
& $PkgManager remove -g $Package 2>$null
if ($LASTEXITCODE -ne 0) { Warn "  uninstall reported an issue (may already be removed)" }
OK "  uninstall step done"

# ── 3. Reinstall Pi ───────────────────────────────────────
Log "3/5  Installing $Package via $PkgManager ..."
& $PkgManager add -g $Package
if ($LASTEXITCODE -ne 0) { Err "Failed to install $Package via $PkgManager" }
OK "  installed"

# ── 4. Verify ─────────────────────────────────────────────
Log "4/5  Verifying the install (pi --version) ..."
& pi --version
if ($LASTEXITCODE -ne 0) { Err "'pi --version' failed after install" }
OK "  pi runs (it creates a fresh $PiRoot on first start)"

# ── 5. Remove the moved-aside copy ────────────────────────
$Finished = $true
if ($Moved) {
    if ($KeepOld) {
        Log "5/5  Keeping the old config at $OldRoot (KEEP_OLD=1)"
    } else {
        Log "5/5  Deleting the old config at $OldRoot ..."
        Remove-Item -LiteralPath $OldRoot -Recurse -Force
        OK "  deleted"
    }
} else {
    Log "5/5  Nothing to clean up"
}

Write-Host ""
Log "================================================================"
OK "Clean reinstall complete!"
Write-Host ""
Log "Next steps:"
Log "  1. Restore:  ./restore-pi.ps1 <backup-dir-or-archive>"
Log "  2. Reinstall npm deps:  cd ~/.pi/agent && npm install"
Log "  3. Verify:  pi --version, /ctx-doctor, /loop-police-status, /scoped-memory-status"
Write-Host ""
} finally {
    if ($Moved -and -not $Finished -and (Test-Path -LiteralPath $OldRoot)) {
        Write-Host "[ERR]   Reinstall failed. Restoring the original $PiRoot ..." -ForegroundColor Red
        if (Test-Path -LiteralPath $PiRoot) { Remove-Item -LiteralPath $PiRoot -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $OldRoot -Destination $PiRoot
        Write-Host "[WARN]  Original $PiRoot restored. Pi may need to be reinstalled manually: $PkgManager add -g $Package" -ForegroundColor Yellow
    }
}
