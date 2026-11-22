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
$BackupRoot = if ($env:BACKUP_ROOT) { $env:BACKUP_ROOT } else { Join-Path $HOME 'pi-backups' }
$LocalExtRoot = if ($env:LOCAL_EXT_ROOT) { $env:LOCAL_EXT_ROOT } else { Join-Path $HOME 'projects' }
$Timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$ArchiveBase = "pi-backup-$Timestamp"
$ArchiveDir  = Join-Path $BackupRoot $ArchiveBase
$KeepUncompressed = $env:KEEP_UNCOMPRESSED -eq '1'
$SevenZip = @('7zz', '7z', '7za') | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
$ArchiveExtension = if ($SevenZip) { '7z' } else { 'zip' }

function Log  { Write-Host "[INFO]  $args"     -ForegroundColor Cyan }
function OK   { Write-Host "[OK]    $args"     -ForegroundColor Green }
function Warn { Write-Host "[WARN]  $args"     -ForegroundColor Yellow }
function Err  { Write-Host "[ERR]   $args"     -ForegroundColor Red; exit 1 }

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


# Restrict a path to the current user on Unix (no-op on Windows, where ACLs apply).
function Set-PrivateMode([string]$path, [bool]$isDir = $false) {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { return }
    try {
        $mode = if ($isDir) { 'UserRead,UserWrite,UserExecute' } else { 'UserRead,UserWrite' }
        [System.IO.File]::SetUnixFileMode($path, [System.IO.UnixFileMode]$mode)
    } catch { Warn "  could not restrict permissions on ${path}: $($_.Exception.Message)" }
}

# auth.json holds credentials: optionally excluded, always private, always flagged.
function Backup-Auth([string]$src, [string]$dst) {
    if ($env:PI_BACKUP_EXCLUDE_AUTH -eq '1') {
        Warn "  auth.json - excluded (PI_BACKUP_EXCLUDE_AUTH=1)"
        return
    }
    Copy-IfExists $src $dst
    if (Test-Path -LiteralPath $dst) {
        Set-PrivateMode $dst
        Warn "  auth.json holds your API credentials and is included in this backup."
        Warn "  Keep the backup private; set PI_BACKUP_EXCLUDE_AUTH=1 to leave it out."
    }
}

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
        # Fallback without robocopy: recurse so existing destination dirs are merged, not nested.
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

# A half-built staging dir (or partial archive) is removed if the script fails.
# A successful run, or a failed compression (staging is intact), keeps it.
$Completed = $false
$KeepStagingOnFail = $false
$archivePath = $null
try {
New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null
Set-PrivateMode $ArchiveDir $true

Write-Host ""
Log "================================================================"
Log "  Pi Complete Backup"
Log "================================================================"
Log "Source:      $PiRoot"
Log "Destination: $ArchiveDir"
Write-Host ""

$agentDir = Join-Path $PiRoot 'agent'
$entries = @(Read-Manifest $ManifestFile)
$total = @($entries | Where-Object { $_.Kind -eq 'section' }).Count
$step = 0
foreach ($e in $entries) {
    switch ($e.Kind) {
        'section' { $step++; Log "$step/$total  $($e.A)..." }
        'file' {
            if ($e.B -eq 'auth.json') { Backup-Auth (P $PiRoot $e.A) (P $ArchiveDir $e.B) }
            else { Copy-IfExists (P $PiRoot $e.A) (P $ArchiveDir $e.B) }
        }
        'dir' { Copy-DirIfExists (P $PiRoot $e.A) (P $ArchiveDir $e.B) }
        'dir-each' {
            $src = P $PiRoot $e.A
            if (Test-Path -LiteralPath $src -PathType Container) {
                $dst = P $ArchiveDir $e.B
                New-Item -ItemType Directory -Path $dst -Force | Out-Null
                foreach ($sub in Get-ChildItem -LiteralPath $src -Directory) {
                    Copy-DirIfExists $sub.FullName (Join-Path $dst $sub.Name)
                }
                $count = @(Get-ChildItem -LiteralPath $dst -Directory -ErrorAction SilentlyContinue).Count
                OK "  $($e.B)/ ($count projects)"
            } else {
                Warn "  $($e.B)/ - not found"
            }
        }
        'local-ext' {
            $src = Join-Path $LocalExtRoot $e.A
            if (Test-Path -LiteralPath $src) {
                $dst = P $ArchiveDir "local-extensions/$($e.A)"
                Copy-Tree $src $dst -excludeDirs @('node_modules','dist','build','coverage','.git') -excludeFiles @('*.log')
                OK "  $($e.A)/ (source only)"
            } else {
                Warn "  $($e.A) - not found at $LocalExtRoot/$($e.A)"
            }
        }
        'npm' {
            $src = P $PiRoot $e.A
            if (Test-Path -LiteralPath $src -PathType Container) {
                # Only package.json and lockfiles, never node_modules (depth matches the bash script)
                $names = @('package.json','package-lock.json','npm-shrinkwrap.json','pnpm-lock.yaml')
                $found = Get-ChildItem -LiteralPath $src -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
                    Where-Object { $names -contains $_.Name -and $_.FullName -notmatch '[\\/]node_modules[\\/]' }
                foreach ($m in $found) {
                    $rel = $m.FullName.Substring($src.Length).TrimStart('\','/')
                    $target = P $ArchiveDir "$($e.B)/$($rel.Replace('\','/'))"
                    $targetDir = Split-Path $target -Parent
                    if (!(Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
                    Copy-Item -LiteralPath $m.FullName -Destination $target -Force
                }
                OK "  npm manifests (package.json, lockfiles)"
            } else {
                Warn "  npm/ - not found"
            }
        }
        'recent' {
            $src = P $PiRoot $e.A
            if (Test-Path -LiteralPath $src -PathType Container) {
                $dst = P $ArchiveDir $e.B
                New-Item -ItemType Directory -Path $dst -Force | Out-Null
                $n = if ($e.C) { [int]$e.C } else { 5 }
                $recent = Get-ChildItem -LiteralPath $src -Directory | Where-Object { $_.Name -like '20*' } | Sort-Object Name -Descending | Select-Object -First $n
                foreach ($d in $recent) { Copy-DirIfExists $d.FullName (Join-Path $dst $d.Name) }
            } else {
                Warn "  $($e.A)/ - not found"
            }
        }
        default { Warn "Unknown manifest entry type: $($e.Kind)" }
    }
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

# ── 9. Compress (external backups only) ───────────────────
if ($KeepUncompressed) {
    Log "9/9  Skipping compression for internal backup"
} else {
    Log "9/9  Compressing backup ($ArchiveExtension)..."
    $archivePath = Join-Path $BackupRoot ($ArchiveBase + ".$ArchiveExtension")
    try {
        if ($SevenZip) {
            # Run from $BackupRoot with relative names so the archive has a single
            # top-level pi-backup-*/ entry (same layout as the bash script).
            Push-Location -LiteralPath $BackupRoot
            try {
                $sevenOut = & $SevenZip.Source a -t7z -mx=9 "$ArchiveBase.7z" $ArchiveBase 2>&1
                $sevenRc = $LASTEXITCODE
            } finally {
                Pop-Location
            }
            if ($sevenRc -ne 0) { throw "7zip exited with code ${sevenRc}: $(($sevenOut | Out-String).Trim())" }
        } else {
            Compress-Archive -LiteralPath $ArchiveDir -DestinationPath $archivePath -CompressionLevel Optimal -Force
        }
        Set-PrivateMode $archivePath
        OK "  $archivePath"
    } catch {
        Warn "  Compression ($ArchiveExtension) failed: $($_.Exception.Message)"
        Warn "  Keeping uncompressed staging dir: $ArchiveDir"
        if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue }
        $archivePath = $null
        $KeepStagingOnFail = $true
        exit 1
    }
    # ── 10. Clean up staging dir ──────────────────────────
    Remove-Item -LiteralPath $ArchiveDir -Recurse -Force
}

# ── Summary ───────────────────────────────────────────────
Write-Host ""
Log "================================================================"
OK "Backup complete!"
if ($KeepUncompressed) {
    $result = $ArchiveDir
    Log "Staging:  $ArchiveDir"
} else {
    $result = $archivePath
    Log "Archive:  $archivePath"
    Log "Size:     $([math]::Round((Get-Item -LiteralPath $archivePath).Length / 1MB, 1)) MB"
}
Write-Host ""
Log "To restore after reinstall:"
Log "  .\restore-pi.ps1 $result"
Write-Host ""
$Completed = $true
} finally {
    if (-not $Completed -and -not $KeepStagingOnFail) {
        if (Test-Path -LiteralPath $ArchiveDir) { Remove-Item -LiteralPath $ArchiveDir -Recurse -Force -ErrorAction SilentlyContinue }
        if ($archivePath -and (Test-Path -LiteralPath $archivePath)) { Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue }
    }
}
