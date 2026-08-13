# =============================================================
#  Pi Complete Backup Script (Windows PowerShell)
#  Backs up ALL user configuration, skills, extensions, and state
#  Run before reinstall; restore with restore-pi.ps1 after fresh install
#
#  Usage:
#    .\backup-pi.ps1                      # default locations
#    $env:PI_ROOT='...'; .\backup-pi.ps1  # custom Pi root
#    $env:BACKUP_ROOT='...'; .\backup-pi.ps1  # custom backup root
# =============================================================
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ─── Config ────────────────────────────────────────────────
$PiRoot   = if ($env:PI_ROOT)    { $env:PI_ROOT }    else { Join-Path $HOME '.pi' }
$BackupRoot = if ($env:BACKUP_ROOT) { $env:BACKUP_ROOT } else { Join-Path $HOME 'projects\personal\pi-utils\backups' }
$Timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$ArchiveBase = "pi-backup-$Timestamp"
$ArchiveDir  = Join-Path $BackupRoot $ArchiveBase
$KeepUncompressed = $env:KEEP_UNCOMPRESSED -eq '1'

function Log  { Write-Host "[INFO]  $args"     -ForegroundColor Cyan }
function OK   { Write-Host "[OK]    $args"     -ForegroundColor Green }
function Warn { Write-Host "[WARN]  $args"     -ForegroundColor Yellow }
function Err  { Write-Host "[ERR]   $args"     -ForegroundColor Red; exit 1 }

function Copy-IfExists([string]$src, [string]$dst) {
    if (Test-Path -LiteralPath $src) {
        $dstDir = Split-Path $dst -Parent
        if (!(Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        OK "  $([System.IO.Path]::GetFileName($src))"
    } else {
        Warn "  $([System.IO.Path]::GetFileName($src)) - not found, skipping"
    }
}

function Copy-DirIfExists([string]$src, [string]$dst) {
    if (Test-Path -LiteralPath $src) {
        $dstDir = Split-Path $dst -Parent
        if (!(Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        OK "  $([System.IO.Path]::GetFileName($src))/"
    } else {
        Warn "  $([System.IO.Path]::GetFileName($src))/ - not found, skipping"
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
        # Fallback: manual recursive copy with exclusions
        $dirs = if ($excludeDirs.Count) { @{ } } else { @{ } }
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

New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null

Write-Host ""
Log "================================================================"
Log "  Pi Complete Backup"
Log "================================================================"
Log "Source:      $PiRoot"
Log "Destination: $ArchiveDir"
Write-Host ""

# ── 1. Core Config Files ──────────────────────────────────
Log "1/8  Core configuration files..."
$agentDir = Join-Path $PiRoot 'agent'
Copy-IfExists (Join-Path $agentDir 'settings.json')           (Join-Path $ArchiveDir 'settings.json')
Copy-IfExists (Join-Path $agentDir 'auth.json')               (Join-Path $ArchiveDir 'auth.json')
Copy-IfExists (Join-Path $agentDir 'models.json')             (Join-Path $ArchiveDir 'models.json')
Copy-IfExists (Join-Path $agentDir 'trust.json')              (Join-Path $ArchiveDir 'trust.json')
Copy-IfExists (Join-Path $agentDir 'keybindings.json')        (Join-Path $ArchiveDir 'keybindings.json')
Copy-IfExists (Join-Path $agentDir 'pix.json')                (Join-Path $ArchiveDir 'pix.json')
Copy-IfExists (Join-Path $agentDir 'optimizer.json')          (Join-Path $ArchiveDir 'optimizer.json')
Copy-IfExists (Join-Path $agentDir 'lmstudio.json.bak')       (Join-Path $ArchiveDir 'lmstudio.json.bak')
Copy-IfExists (Join-Path $agentDir 'hermes-memory-config.json') (Join-Path $ArchiveDir 'hermes-memory-config.json')
Copy-IfExists (Join-Path $agentDir 'pi.code-workspace')       (Join-Path $ArchiveDir 'pi.code-workspace')

# ── 2. Extension Configs ──────────────────────────────────
Log "2/8  Extension configurations..."
Copy-IfExists (Join-Path $agentDir 'pi-hermes-memory-cleanup\scoped-memory.json') (Join-Path $ArchiveDir 'pi-hermes-memory-cleanup\scoped-memory.json')
Copy-IfExists (Join-Path $agentDir 'loop-police.json')        (Join-Path $ArchiveDir 'loop-police.json')
Copy-IfExists (Join-Path $agentDir 'pi-rtk\config.json')      (Join-Path $ArchiveDir 'pi-rtk\config.json')
Copy-IfExists (Join-Path $agentDir 'context-mode\config.json') (Join-Path $ArchiveDir 'context-mode\config.json')
Copy-IfExists (Join-Path $agentDir 'pi-timeout\config.json')  (Join-Path $ArchiveDir 'pi-timeout\config.json')
Copy-IfExists (Join-Path $agentDir 'pi-context-viewer\config.json') (Join-Path $ArchiveDir 'pi-context-viewer\config.json')
Copy-IfExists (Join-Path $agentDir 'pix-optimizer\config.json') (Join-Path $ArchiveDir 'pix-optimizer\config.json')
Copy-IfExists (Join-Path $agentDir 'pi-nvidia-nim\config.json') (Join-Path $ArchiveDir 'pi-nvidia-nim\config.json')

# ── 3. Global Skills ──────────────────────────────────────
Log "3/8  Global skills..."
Copy-DirIfExists (Join-Path $agentDir 'skills')              (Join-Path $ArchiveDir 'skills')

# ── 4. Project Skills & Memory ────────────────────────────
Log "4/8  Project skills & memory..."
$projMem = Join-Path $agentDir 'projects-memory'
if (Test-Path -LiteralPath $projMem) {
    $projDst = Join-Path $ArchiveDir 'projects-memory'
    Copy-DirIfExists $projMem $projDst
    $count = @(Get-ChildItem -LiteralPath $projDst -Directory -ErrorAction SilentlyContinue).Count
    OK "  projects-memory/ ($count projects)"
} else {
    Warn "  projects-memory/ - not found"
}

# ── 5. Local Extensions (source code only, no node_modules) ─
Log "5/8  Local extension source code..."
$localExts = @('pi-timeout', 'pi-chunk', 'pi-hermes-memory-cleanup', 'pi-context-docs')
foreach ($ext in $localExts) {
    $src = Join-Path $HOME "projects\personal\$ext"
    if (Test-Path -LiteralPath $src) {
        $dst = Join-Path $ArchiveDir "local-extensions\$ext"
        $extDstDir = Join-Path $ArchiveDir 'local-extensions'
        if (!(Test-Path -LiteralPath $extDstDir)) { New-Item -ItemType Directory -Path $extDstDir -Force | Out-Null }
        # Copy source, exclude node_modules, dist, build, .git, coverage, logs
        Copy-Tree $src $dst -excludeDirs @('node_modules','dist','build','coverage','.git') -excludeFiles @('*.log')
        OK "  $ext/ (source only)"
    } else {
        Warn "  $ext - not found at ~/projects/personal/$ext"
    }
}

# ── 6. npm Extension Manifests (package.json + lock) ─────
Log "6/8  npm extension manifests..."
$npmDir = Join-Path $agentDir 'npm'
if (Test-Path -LiteralPath $npmDir) {
    # Only copy package.json and lockfiles, not node_modules
    $manifests = Get-ChildItem -LiteralPath $npmDir -Recurse -Depth 3 -Include @('package.json','package-lock.json','npm-shrinkwrap.json','pnpm-lock.yaml') -ErrorAction SilentlyContinue
    foreach ($m in $manifests) {
        $rel = $m.FullName.Substring($npmDir.Length).TrimStart('\')
        $dstDir = Join-Path $ArchiveDir "npm-manifests\$($rel | Split-Path -Parent)"
        if (!(Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $m.FullName -Destination (Join-Path $dstDir $m.Name) -Force
    }
    OK "  npm manifests (package.json, lockfiles)"
} else {
    Warn "  npm/ - not found"
}

# ── 7. Hermes Memory (active files only, not sessions DB) ─
Log "7/8  Hermes memory (active files)..."
$hermes = Join-Path $agentDir 'pi-hermes-memory'
if (Test-Path -LiteralPath $hermes) {
    $hermesDst = Join-Path $ArchiveDir 'pi-hermes-memory'
    New-Item -ItemType Directory -Path $hermesDst -Force | Out-Null
    foreach ($f in @('MEMORY.md','USER.md','failures.md','retired-failures.md','retired-memory.md')) {
        Copy-IfExists (Join-Path $hermes $f) (Join-Path $hermesDst $f)
    }
} else {
    Warn "  pi-hermes-memory/ - not found"
}

# ── 8. Recent hermes-cleanup Backups (last 5) ─────────────
Log "8/8  Recent hermes-cleanup backups (last 5)..."
$cleanup = Join-Path $agentDir 'hermes-cleanup'
if (Test-Path -LiteralPath $cleanup) {
    $recent = Get-ChildItem -LiteralPath $cleanup -Directory | Where-Object { $_.Name -match '^\d{4}' } | Sort-Object Name -Descending | Select-Object -First 5
    foreach ($d in $recent) {
        Copy-DirIfExists $d.FullName (Join-Path $ArchiveDir "hermes-cleanup\$($d.Name)")
    }
} else {
    Warn "  hermes-cleanup/ - not found"
}

# ── Manifest ──────────────────────────────────────────────
Log "Creating manifest..."
$piVersion = (& pi --version 2>$null) -join ''
if (-not $piVersion) { $piVersion = 'unknown' }
$manifest = @"
Pi Complete Backup Manifest
===========================
Created:     $(Get-Date)
Pi Root:     $PiRoot
Pi Version:  $piVersion
Host:        $env:COMPUTERNAME
User:        $env:USERNAME

Contents:
"@
$relFiles = Get-ChildItem -LiteralPath $ArchiveDir -Recurse -File | ForEach-Object { $_.FullName.Substring($ArchiveDir.Length).TrimStart('\') } | Sort-Object
$manifest += ($relFiles -join "`n") + "`n"
Set-Content -LiteralPath (Join-Path $ArchiveDir 'MANIFEST.txt') -Value $manifest -Encoding UTF8

# ── 9. Compress ───────────────────────────────────────────
Log "9/9  Compressing backup..."
$archivePath = Join-Path $BackupRoot ($ArchiveBase + '.zip')
try {
    Compress-Archive -LiteralPath $ArchiveDir -DestinationPath $archivePath -CompressionLevel Optimal -Force
    OK "  $archivePath"
} catch {
    Warn "  Compress-Archive failed: $_.Exception.Message"
    Warn "  Keeping uncompressed staging dir: $ArchiveDir"
    $archivePath = $null
}

# ── 10. Clean up staging dir (unless told to keep it) ─────
if ($KeepUncompressed) {
    Log "Keeping uncompressed staging dir: $ArchiveDir"
} elseif ($archivePath) {
    Remove-Item -LiteralPath $ArchiveDir -Recurse -Force
}

# ── Summary ───────────────────────────────────────────────
Write-Host ""
Log "================================================================"
OK "Backup complete!"
if ($archivePath) {
    Log "Archive:  $archivePath"
    Log "Size:     $([math]::Round((Get-Item -LiteralPath $archivePath).Length / 1MB, 1)) MB"
}
if ($KeepUncompressed) { Log "Staging:  $ArchiveDir" }
Write-Host ""
Log "To restore after reinstall:"
Log "  ~/projects/personal/pi-backup/restore-pi.ps1 $archivePath"
Write-Host ""
