# =============================================================
#  Pi Complete Restore Script (Windows PowerShell)
#  Restores a backup created by backup-pi.ps1 after a fresh Pi install
#
#  Usage:
#    .\restore-pi.ps1 <backup-directory-or-archive>
#    .\restore-pi.ps1 ~\pi-backups\pi-backup-20260811-143000
#    .\restore-pi.ps1 ~\pi-backups\pi-backup-20260811-143000.zip
# =============================================================
[CmdletBinding()]
param(
    [Parameter(Position=0, Mandatory=$false)]
    [string]$BackupArg
)

$ErrorActionPreference = 'Stop'

# ─── Config ────────────────────────────────────────────────
$PiRoot = if ($env:PI_ROOT) { $env:PI_ROOT } else { Join-Path $HOME '.pi' }
$LocalExtRoot = if ($env:LOCAL_EXT_ROOT) { $env:LOCAL_EXT_ROOT } else { Join-Path $HOME 'projects' }

function Log  { Write-Host "[INFO]  $args"     -ForegroundColor Cyan }
function OK   { Write-Host "[OK]    $args"     -ForegroundColor Green }
function Warn { Write-Host "[WARN]  $args"     -ForegroundColor Yellow }
function Err  { Write-Host "[ERR]   $args"     -ForegroundColor Red }

# ─── Manifest ──────────────────────────────────────────────
# What gets backed up / restored is defined once, in backup-manifest.txt (shared with the bash scripts).
$ManifestFile = Join-Path $PSScriptRoot 'backup-manifest.txt'
if (-not (Test-Path -LiteralPath $ManifestFile)) {
    Write-Host "[ERR]   backup-manifest.txt not found next to this script" -ForegroundColor Red
    exit 1
}

function Read-Manifest([string]$path) {
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $l = $line.TrimEnd("`r")
        if ($l -eq '' -or $l.StartsWith('#')) { continue }
        $p = $l.Split('|')
        [pscustomobject]@{
            Kind = $p[0]
            A    = if ($p.Count -gt 1) { $p[1] } else { '' }
            B    = if ($p.Count -gt 2) { $p[2] } else { '' }
            C    = if ($p.Count -gt 3) { $p[3] } else { '' }
        }
    }
}

# Manifest paths use "/"; join them under a root with the platform separator.
function P([string]$root, [string]$rel) {
    Join-Path $root ($rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
}


function Show-Usage {
    Write-Host @"
Usage: $($MyInvocation.MyCommand.Name) <backup-directory-or-archive>

Restores a Pi backup created by backup-pi.ps1

Examples:
  .\$($MyInvocation.MyCommand.Name) ~\pi-backups\pi-backup-20260811-143000
  .\$($MyInvocation.MyCommand.Name) ~\pi-backups\pi-backup-20260811-143000.zip

Accepts either an uncompressed backup directory or a compressed zip/7z archive
(as produced by backup-pi.ps1).

Prerequisites:
  - Fresh Pi install completed (pi --version works)
  - Pi NOT running
"@
    exit 1
}

if (-not $BackupArg) { Show-Usage }

function Test-PiRunning {
    # Best-effort only: process names are unreliable, so callers warn rather than block.
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        if (Get-Process -Name 'pi' -ErrorAction SilentlyContinue) { return $true }
        try {
            $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='bun.exe'" -ErrorAction Stop
            if ($procs | Where-Object { $_.CommandLine -like '*pi-coding-agent*' }) { return $true }
        } catch {}
        return $false
    }
    if (Get-Command pgrep -ErrorAction SilentlyContinue) {
        & pgrep -x pi *> $null
        if ($LASTEXITCODE -eq 0) { return $true }
        & pgrep -f 'pi-coding-agent' *> $null
        return ($LASTEXITCODE -eq 0)
    }
    return $false
}

# The extraction dir is removed in `finally`, so every exit path (abort, error,
# success) cleans up. `exit` inside `try` still runs `finally`.
$STAGE = $null
try {
# ─── Archive handling ─────────────────────────────────────
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
    $STAGE = Join-Path ([System.IO.Path]::GetTempPath()) ("pi-restore-" + [guid]::NewGuid().ToString('N'))
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
        exit 1
    }
    # The archive holds one top-level pi-backup-* dir
    $top = Get-ChildItem -LiteralPath $STAGE -Directory | Select-Object -First 1
    if (-not $top) { Err "No backup directory found inside archive."; exit 1 }
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
if (Test-PiRunning) {
    Warn "A Pi process appears to be running. Exit Pi first: files restored under a"
    Warn "running Pi can be overwritten or corrupted when it exits."
}
Write-Host ""
if ($env:PI_BACKUP_ASSUME_YES -eq '1') {
    Log "PI_BACKUP_ASSUME_YES=1 set; skipping confirmation."
} else {
    $confirm = $null
    try { $confirm = Read-Host "Continue? [y/N] " } catch { $confirm = $null }
    if ($null -eq $confirm) {
        Err "Cannot read a confirmation (stdin is not interactive)."
        Err "Run this in a terminal, or set PI_BACKUP_ASSUME_YES=1 to skip the prompt."
        exit 1
    }
    if ($confirm -notmatch '^[Yy]$') { Log "Aborted."; exit 0 }
}

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
        # Fallback without robocopy: recurse so existing destination dirs are merged,
        # not nested (Copy-Item of a dir onto an existing dir would create dst/dir/dir).
        Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
            $item = $_
            $skip = $false
            if ($item.PSIsContainer -and $item.Name -in $excludeDirs) { $skip = $true }
            if (-not $item.PSIsContainer -and ($excludeFiles | Where-Object { $item.Name -like $_ })) { $skip = $true }
            if (-not $skip) {
                $target = Join-Path $dst $item.Name
                if ($item.PSIsContainer) { Copy-Tree $item.FullName $target $excludeDirs $excludeFiles }
                else { Copy-Item -LiteralPath $item.FullName -Destination $target -Force }
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

$agentDir = Join-Path $PiRoot 'agent'
$entries = @(Read-Manifest $ManifestFile)
$total = @($entries | Where-Object { $_.Kind -eq 'section' }).Count
$step = 0
foreach ($e in $entries) {
    switch ($e.Kind) {
        'section' { $step++; Log "$step/$total  $($e.A)..." }
        'file' {
            $dst = P $PiRoot $e.A
            $src = P $BackupDir $e.B
            Restore-File $src $dst
            # Credentials: keep a restored auth.json private to this user (Unix)
            if ($e.B -eq 'auth.json' -and (Test-Path -LiteralPath $src) -and (Test-Path -LiteralPath $dst) -and -not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
                try { [System.IO.File]::SetUnixFileMode($dst, [System.IO.UnixFileMode]'UserRead,UserWrite') } catch { Warn "  could not restrict permissions on auth.json: $($_.Exception.Message)" }
            }
        }
        'dir' { Restore-Dir (P $BackupDir $e.B) (P $PiRoot $e.A) }
        { $_ -in 'dir-each','recent' } {
            $src = P $BackupDir $e.B
            if (Test-Path -LiteralPath $src -PathType Container) {
                foreach ($sub in Get-ChildItem -LiteralPath $src -Directory) {
                    Restore-Dir $sub.FullName (Join-Path (P $PiRoot $e.A) $sub.Name)
                }
                OK "  $($e.B)/ restored"
            } else {
                Warn "  No $($e.B) in backup"
            }
        }
        'local-ext' {
            $src = P $BackupDir "local-extensions/$($e.A)"
            if (Test-Path -LiteralPath $src -PathType Container) {
                $dst = Join-Path $LocalExtRoot $e.A
                New-Item -ItemType Directory -Path $dst -Force | Out-Null
                Copy-Tree $src $dst
                OK "  $($e.A)/ restored"
            } else {
                Warn "  $($e.A) - not in backup, skipping"
            }
        }
        'npm' {
            $src = P $BackupDir $e.B
            if (Test-Path -LiteralPath $src -PathType Container) {
                $dst = P $PiRoot $e.A
                New-Item -ItemType Directory -Path $dst -Force | Out-Null
                Copy-Tree $src $dst
                OK "  npm manifests restored (run 'npm install' to reinstall deps)"
            } else {
                Warn "  No npm manifests in backup"
            }
        }
        default { Warn "Unknown manifest entry type: $($e.Kind)" }
    }
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

} finally {
    if ($STAGE -and (Test-Path -LiteralPath $STAGE)) {
        Remove-Item -LiteralPath $STAGE -Recurse -Force -ErrorAction SilentlyContinue
    }
}
