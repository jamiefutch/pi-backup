# =============================================================
#  Pi Complete Restore Script (Windows PowerShell)
#  Restores a backup created by backup-pi.ps1 after a fresh Pi install
#
#  Usage:
#    .\restore-pi.ps1 <backup-directory-or-archive>
#    .\restore-pi.ps1 ~\projects\personal\pi-utils\backups\pi-backup-20260811-143000
#    .\restore-pi.ps1 ~\projects\personal\pi-utils\backups\pi-backup-20260811-143000.zip
# =============================================================
[CmdletBinding()]
param(
    [Parameter(Position=0, Mandatory=$false)]
    [string]$BackupArg
)

$ErrorActionPreference = 'Stop'

# ─── Config ────────────────────────────────────────────────
$PiRoot = if ($env:PI_ROOT) { $env:PI_ROOT } else { Join-Path $HOME '.pi' }

function Log  { Write-Host "[INFO]  $args"     -ForegroundColor Cyan }
function OK   { Write-Host "[OK]    $args"     -ForegroundColor Green }
function Warn { Write-Host "[WARN]  $args"     -ForegroundColor Yellow }
function Err  { Write-Host "[ERR]   $args"     -ForegroundColor Red }

function Show-Usage {
    Write-Host @"
Usage: $($MyInvocation.MyCommand.Name) <backup-directory-or-archive>

Restores a Pi backup created by backup-pi.ps1

Examples:
  .\$($MyInvocation.MyCommand.Name) ~\projects\personal\pi-utils\backups\pi-backup-20260811-143000
  .\$($MyInvocation.MyCommand.Name) ~\projects\personal\pi-utils\backups\pi-backup-20260811-143000.zip

Accepts either an uncompressed backup directory or a compressed zip/7z archive
(as produced by backup-pi.ps1).

Prerequisites:
  - Fresh Pi install completed (pi --version works)
  - Pi NOT running
"@
    exit 1
}

if (-not $BackupArg) { Show-Usage }

# ─── Archive handling ─────────────────────────────────────
$STAGE = $null
$BackupDir = $null
$SevenZip = @('7zz', '7z', '7za') | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1

if (Test-Path -LiteralPath $BackupArg -PathType Container) {
    # Uncompressed directory backup
    $BackupDir = $BackupArg
} elseif (Test-Path -LiteralPath $BackupArg -PathType Leaf) {
    # Compressed archive: prefer 7zip when installed, otherwise use native ZIP support.
    $extension = [System.IO.Path]::GetExtension($BackupArg).ToLowerInvariant()
    if ($extension -notin @('.zip', '.7z')) {
        Err "Unsupported backup archive: $BackupArg (need .zip or .7z)"
        exit 1
    }
    if ($extension -eq '.7z' -and -not $SevenZip) {
        Err "7zip is required to extract .7z backups. Install 7-Zip and ensure it is on PATH."
        exit 1
    }
    $STAGE = Join-Path $env:TEMP ("pi-restore-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $STAGE -Force | Out-Null
    Log "Extracting archive: $BackupArg"
    try {
        if ($SevenZip) {
            & $SevenZip.Source x -y "-o$STAGE" $BackupArg | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "7zip exited with code $LASTEXITCODE" }
        } else {
            Expand-Archive -LiteralPath $BackupArg -DestinationPath $STAGE -Force
        }
    } catch {
        Err "Failed to extract archive: $($_.Exception.Message)"
        Remove-Item -LiteralPath $STAGE -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    # The archive holds one top-level pi-backup-* dir
    $top = Get-ChildItem -LiteralPath $STAGE -Directory | Select-Object -First 1
    if (-not $top) { Err "No backup directory found inside archive."; Remove-Item $STAGE -Recurse -Force; exit 1 }
    $BackupDir = $top.FullName
    Log "Extracted to: $BackupDir"
} else {
    Err "Backup not found: $BackupArg (need a directory, .zip, or .7z)"
    exit 1
}

if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
    Err "Backup directory not found: $BackupDir"
    exit 1
}

# ─── Confirm ──────────────────────────────────────────────
Write-Host ""
Warn "================================================================"
Warn "  Pi Complete Restore"
Warn "================================================================"
Warn "This will OVERWRITE all current Pi configuration."
Warn "Backup source: $BackupDir"
Warn "Target:        $PiRoot"
Warn "Pi must NOT be running."
Write-Host ""
$confirm = Read-Host "Continue? [y/N] "
if ($confirm -notmatch '^[Yy]$') { Log "Aborted."; if ($STAGE) { Remove-Item $STAGE -Recurse -Force }; exit 0 }

# ─── Helpers ──────────────────────────────────────────────
function Restore-File([string]$src, [string]$dst) {
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        $dstDir = Split-Path $dst -Parent
        if (!(Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        OK "  $([System.IO.Path]::GetFileName($src))"
    } else {
        Warn "  $([System.IO.Path]::GetFileName($src)) - not in backup, skipping"
    }
}

function Restore-Dir([string]$src, [string]$dst) {
    if (Test-Path -LiteralPath $src -PathType Container) {
        $dstDir = Split-Path $dst -Parent
        if (!(Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        OK "  $([System.IO.Path]::GetFileName($src))/"
    } else {
        Warn "  $([System.IO.Path]::GetFileName($src))/ - not in backup, skipping"
    }
}

function Copy-Tree([string]$src, [string]$dst, [string[]]$excludeDirs = @(), [string[]]$excludeFiles = @()) {
    if (!(Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    if (Get-Command robocopy -ErrorAction SilentlyContinue) {
        $robocopyArgs = @($src, $dst, '/E')
        foreach ($d in $excludeDirs) { $robocopyArgs += @('/XD', $d) }
        foreach ($f in $excludeFiles) { $robocopyArgs += @('/XF', $f) }
        $robocopyArgs += @('/NFL','/NDL','/NJH','/NJS')
        & robocopy @robocopyArgs | Out-Null
    } else {
        Get-ChildItem -LiteralPath $src | ForEach-Object {
            $skip = $false
            if ($_.PSIsContainer -and $_.Name -in $excludeDirs) { $skip = $true }
            if (-not $_.PSIsContainer -and $_.Name -like $excludeFiles) { $skip = $true }
            if (-not $skip) {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dst $_.Name) -Recurse -Force
            }
        }
    }
}

# ─── Main ─────────────────────────────────────────────────
Write-Host ""
Log "================================================================"
Log "  Restoring Pi from backup"
Log "================================================================"
Write-Host ""

# ── 1. Core Config Files ──────────────────────────────────
Log "1/8  Core configuration files..."
$agentDir = Join-Path $PiRoot 'agent'
Restore-File (Join-Path $BackupDir 'settings.json')              (Join-Path $agentDir 'settings.json')
Restore-File (Join-Path $BackupDir 'auth.json')                  (Join-Path $agentDir 'auth.json')
Restore-File (Join-Path $BackupDir 'models.json')                (Join-Path $agentDir 'models.json')
Restore-File (Join-Path $BackupDir 'trust.json')                 (Join-Path $agentDir 'trust.json')
Restore-File (Join-Path $BackupDir 'keybindings.json')           (Join-Path $agentDir 'keybindings.json')
Restore-File (Join-Path $BackupDir 'pix.json')                   (Join-Path $agentDir 'pix.json')
Restore-File (Join-Path $BackupDir 'optimizer.json')             (Join-Path $agentDir 'optimizer.json')
Restore-File (Join-Path $BackupDir 'lmstudio.json.bak')          (Join-Path $agentDir 'lmstudio.json.bak')
Restore-File (Join-Path $BackupDir 'hermes-memory-config.json')  (Join-Path $agentDir 'hermes-memory-config.json')
Restore-File (Join-Path $BackupDir 'pi.code-workspace')          (Join-Path $agentDir 'pi.code-workspace')

# ── 2. Extension Configs ──────────────────────────────────
Log "2/8  Extension configurations..."
Restore-File (Join-Path $BackupDir 'pi-hermes-memory-cleanup\scoped-memory.json') (Join-Path $agentDir 'pi-hermes-memory-cleanup\scoped-memory.json')
Restore-File (Join-Path $BackupDir 'loop-police.json')           (Join-Path $agentDir 'loop-police.json')
Restore-File (Join-Path $BackupDir 'pi-rtk\config.json')         (Join-Path $agentDir 'pi-rtk\config.json')
Restore-File (Join-Path $BackupDir 'context-mode\config.json')   (Join-Path $agentDir 'context-mode\config.json')
Restore-File (Join-Path $BackupDir 'pi-timeout\config.json')     (Join-Path $agentDir 'pi-timeout\config.json')
Restore-File (Join-Path $BackupDir 'pi-context-viewer\config.json') (Join-Path $agentDir 'pi-context-viewer\config.json')
Restore-File (Join-Path $BackupDir 'pix-optimizer\config.json')  (Join-Path $agentDir 'pix-optimizer\config.json')
Restore-File (Join-Path $BackupDir 'pi-nvidia-nim\config.json')  (Join-Path $agentDir 'pi-nvidia-nim\config.json')

# ── 3. Global Skills ──────────────────────────────────────
Log "3/8  Global skills..."
Restore-Dir (Join-Path $BackupDir 'skills')                      (Join-Path $agentDir 'skills')

# ── 4. Project Skills & Memory ────────────────────────────
Log "4/8  Project skills & memory..."
$projSrc = Join-Path $BackupDir 'projects-memory'
if (Test-Path -LiteralPath $projSrc -PathType Container) {
    Restore-Dir $projSrc (Join-Path $agentDir 'projects-memory')
    OK "  projects-memory/ restored"
} else {
    Warn "  No project memory in backup"
}

# ── 5. Local Extensions ───────────────────────────────────
Log "5/8  Local extension source code..."
$localSrc = Join-Path $BackupDir 'local-extensions'
if (Test-Path -LiteralPath $localSrc -PathType Container) {
    foreach ($ext in Get-ChildItem -LiteralPath $localSrc -Directory) {
        $dst = Join-Path $HOME "projects\personal\$($ext.Name)"
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Tree $ext.FullName $dst
        OK "  $($ext.Name)/ restored"
    }
} else {
    Warn "  No local extensions in backup"
}

# ── 6. npm Extension Manifests ────────────────────────────
Log "6/8  npm extension manifests..."
$npmSrc = Join-Path $BackupDir 'npm-manifests'
if (Test-Path -LiteralPath $npmSrc -PathType Container) {
    $npmDst = Join-Path $agentDir 'npm'
    New-Item -ItemType Directory -Path $npmDst -Force | Out-Null
    Copy-Tree $npmSrc $npmDst
    OK "  npm manifests restored (run 'npm install' to reinstall deps)"
} else {
    Warn "  No npm manifests in backup"
}

# ── 7. Hermes Memory ──────────────────────────────────────
Log "7/8  Hermes memory (active files)..."
$hermesSrc = Join-Path $BackupDir 'pi-hermes-memory'
if (Test-Path -LiteralPath $hermesSrc -PathType Container) {
    $hermesDst = Join-Path $agentDir 'pi-hermes-memory'
    New-Item -ItemType Directory -Path $hermesDst -Force | Out-Null
    foreach ($f in @('MEMORY.md','USER.md','failures.md','retired-failures.md','retired-memory.md')) {
        Restore-File (Join-Path $hermesSrc $f) (Join-Path $hermesDst $f)
    }
} else {
    Warn "  No Hermes memory in backup"
}

# ── 8. Hermes-cleanup Backups ─────────────────────────────
Log "8/8  Hermes-cleanup backups..."
$cleanupSrc = Join-Path $BackupDir 'hermes-cleanup'
if (Test-Path -LiteralPath $cleanupSrc -PathType Container) {
    foreach ($d in Get-ChildItem -LiteralPath $cleanupSrc -Directory) {
        Restore-Dir $d.FullName (Join-Path $agentDir "hermes-cleanup\$($d.Name)")
    }
} else {
    Warn "  No cleanup backups in backup"
}

# ── Verify ────────────────────────────────────────────────
Write-Host ""
Log "================================================================"
OK "Restore complete!"
Write-Host ""
Log "Next steps:"
Log "  1. Reinstall npm extension dependencies:"
Log "     cd ~/.pi/agent && npm install"
Log "  2. Verify config:"
Log "     pi --version"
Log "     /ctx-doctor"
Log "     /loop-police-status"
Log "     /scoped-memory-status"
Log "  3. Restart Pi and verify everything works"
Write-Host ""

# ─── Cleanup ──────────────────────────────────────────────
if ($STAGE -and (Test-Path -LiteralPath $STAGE)) {
    Remove-Item -LiteralPath $STAGE -Recurse -Force
    Log "Removed temp extraction dir."
}
