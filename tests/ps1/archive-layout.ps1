# Native PowerShell test (runs on Windows CI): a 7z archive made by backup-pi.ps1 has a single
# top-level pi-backup-*/ entry, restores cleanly, and leaves no temp dirs behind.
# Skips (exit 0) when no 7-Zip executable is installed. Never touches the real ~/.pi.
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$sevenZip = @('7zz', '7z', '7za') | ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $sevenZip) { Write-Host "SKIP: no 7-Zip on PATH"; exit 0 }

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("pi-backup-ps-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox | Out-Null
$sandbox = (Resolve-Path -LiteralPath $sandbox).Path
$failed = 0
function Check([bool]$ok, [string]$msg) { if (-not $ok) { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:failed++ } else { Write-Host "ok: $msg" } }

try {
    $h = Join-Path $sandbox 'home'; $tmp = Join-Path $sandbox 'tmp'; $bk = Join-Path $sandbox 'backups'
    $pi = Join-Path $h '.pi'; $ext = Join-Path $sandbox 'projects'
    foreach ($d in @($h, $tmp, $bk, $ext, (Join-Path $pi 'agent\skills\demo'))) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $pi 'agent\settings.json') -Value '{"theme":"dark"}'
    Set-Content -LiteralPath (Join-Path $pi 'agent\skills\demo\SKILL.md') -Value 'demo'

    $env:HOME = $h; $env:USERPROFILE = $h; $env:PI_ROOT = $pi; $env:BACKUP_ROOT = $bk
    $env:LOCAL_EXT_ROOT = $ext; $env:TEMP = $tmp; $env:TMP = $tmp; $env:TMPDIR = $tmp
    $env:KEEP_UNCOMPRESSED = '0'; $env:PI_BACKUP_ASSUME_YES = '1'
    foreach ($name in 'HOME','PI_ROOT','BACKUP_ROOT','LOCAL_EXT_ROOT','TEMP') {
        $val = [Environment]::GetEnvironmentVariable($name)
        if (-not $val.StartsWith($sandbox)) { throw "$name=$val escaped the sandbox $sandbox" }
    }

    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'backup-pi.ps1') | Out-Null
    Check ($LASTEXITCODE -eq 0) "backup-pi.ps1 exits 0"
    $archive = Get-ChildItem -LiteralPath $bk -Filter 'pi-backup-*.7z' | Select-Object -First 1
    Check ($null -ne $archive) "a .7z archive was created"
    Check (-not (Get-ChildItem -LiteralPath $bk -Directory)) "staging dir was removed after compressing"

    $listing = & $sevenZip.Source l -slt $archive.FullName
    $paths = $listing | Where-Object { $_ -like 'Path = *' } | ForEach-Object { $_.Substring(7) } | Where-Object { $_ -ne $archive.FullName }
    $tops = $paths | ForEach-Object { ($_ -split '[\\/]')[0] } | Sort-Object -Unique
    Check (@($tops).Count -eq 1) "single top-level entry (found: $($tops -join ', '))"
    Check ($tops -like 'pi-backup-*') "top-level entry is pi-backup-*"

    Remove-Item -LiteralPath (Join-Path $pi 'agent\skills') -Recurse -Force
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'restore-pi.ps1') $archive.FullName | Out-Null
    Check ($LASTEXITCODE -eq 0) "restore-pi.ps1 exits 0"
    Check (Test-Path -LiteralPath (Join-Path $pi 'agent\skills\demo\SKILL.md')) "restore brought the skill back"
    Check (-not (Get-ChildItem -LiteralPath $tmp -Force)) "no temp leftovers in TEMP"
} finally {
    if ($sandbox -like '*pi-backup-ps-test-*') { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($failed) { Write-Host "$failed check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "archive layout test passed"
