# Agent Instructions for pi-backup

## Project purpose

`pi-backup` provides cross-platform backup, restore, and clean-reinstall utilities for the Pi coding agent, plus the `/pi-backup` TUI extension.

## Repository layout

- `backup-pi.sh` / `backup-pi.ps1`: create backups.
- `restore-pi.sh` / `restore-pi.ps1`: restore directory, `.zip`, or `.7z` backups.
- `pi-clean-reinstall.sh` / `pi-clean-reinstall.ps1`: destructive reinstall workflow.
- `extensions/pi-backup-manager.ts`: Pi TUI extension implementation.
- `README.md`: user-facing installation and operating documentation.

## Development commands

```bash
npm install
npm run typecheck
npm run build
bash -n backup-pi.sh restore-pi.sh pi-clean-reinstall.sh
pwsh -NoProfile -Command '$files = "backup-pi.ps1","restore-pi.ps1","pi-clean-reinstall.ps1"; foreach ($f in $files) { $tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-Location) $f), [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { throw "$f has parse errors" } }'
```

Run typecheck and both shell-language syntax checks after changes. Use temporary `PI_ROOT` and `BACKUP_ROOT` directories for backup smoke tests; never test against the real `~/.pi` without explicit authorization.

## Cross-platform requirements

- Preserve equivalent behavior across Bash and PowerShell implementations.
- Detect `7zz`, `7z`, or `7za` first on macOS, Windows, and Linux.
- Prefer 7-Zip for creating and extracting archives when available.
- Fall back to native tools when 7-Zip is unavailable: ZIP/`zip`/`unzip` on Unix and `Compress-Archive`/`Expand-Archive` on Windows.
- `.7z` archives require a 7-Zip executable; report a clear error when it is missing.
- Pass paths as argument arrays or environment variables rather than shell-interpolated command strings, especially for Windows paths containing spaces.
- Use `path.join()` and platform-aware process launching in the TypeScript extension.

## Backup and restore invariants

- Internal backups are uncompressed staging directories under `~/.pi/backups/` for quick rollback.
- External backups are compressed archives under the configured external backup directory.
- Exclude regeneratable data such as sessions, `node_modules`, context-mode databases, lock files, and detection logs.
- Do not include API credentials or unrelated local files in tests or commits.
- Restore must accept both uncompressed backup directories and supported compressed archives.
- Keep manifests accurate and ensure temporary extraction directories are cleaned up on success and failure.

## Safety

- Treat clean-reinstall scripts and restore operations as destructive. Do not execute them against a real user environment during development.
- Never commit generated backups, credentials, temporary extraction directories, or dependency directories.
- Prefer precise edits and preserve existing CLI output and environment variables (`PI_ROOT`, `BACKUP_ROOT`, `KEEP_UNCOMPRESSED`, and `PKG_MANAGER`).

## Workflow

- Create a feature branch before making changes.
- Keep Bash, PowerShell, TypeScript, and README behavior/documentation synchronized.
- Run validation before committing.
- Use focused commits and push the feature branch for review.
- If a pull request cannot be created automatically, provide the branch and compare URL.
