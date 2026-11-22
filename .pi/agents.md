# Agent Instructions for pi-backup

## Project purpose

`pi-backup` provides cross-platform backup, restore, and clean-reinstall utilities for the Pi coding agent, plus the `/pi-backup` TUI extension.

## Repository layout

- `backup-pi.sh` / `backup-pi.ps1`: create backups.
- `restore-pi.sh` / `restore-pi.ps1`: restore directory, `.zip`, or `.7z` backups.
- `pi-clean-reinstall.sh` / `pi-clean-reinstall.ps1`: destructive reinstall workflow.
- `extensions/pi-backup-manager.ts`: Pi TUI extension implementation.
- `backup-manifest.txt`: single source of truth for backed-up paths, read by all four backup/restore scripts.
- `tests/`: sandboxed test harness (`helpers.sh`, `run.sh`, `sh/`, `ps1/`, `ts/`).
- `README.md`: user-facing installation and operating documentation.

## Development commands

```bash
npm install
npm run typecheck
npm run build
bash -n backup-pi.sh restore-pi.sh pi-clean-reinstall.sh
pwsh -NoProfile -Command '$files = "backup-pi.ps1","restore-pi.ps1","pi-clean-reinstall.ps1"; foreach ($f in $files) { $tokens=$null; $errors=$null; [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-Location) $f), [ref]$tokens, [ref]$errors) | Out-Null; if ($errors.Count) { throw "$f has parse errors" } }'
```

Tests (all run inside a `mktemp` sandbox; the helper aborts if any root points outside it):

```bash
npm test                              # tests/run.sh: bash+pwsh script tests, native pwsh 7z test, node:test extension tests
bash tests/sh/restore.test.sh         # a single script-test file (add TEST_FLAVORS=sh to skip pwsh)
node --experimental-strip-types --no-warnings --test tests/ts/ui.test.mjs   # one extension test file
```

- Script tests run once per flavor (bash and pwsh) via `run_script <flavor> <name>`; keep both implementations passing the same test.
- Extension tests need one process per file (the module reads `HOME` at import) and live in `tests/ts/`. **Never put helpers in `extensions/`: Pi loads everything there as an extension.**
- `PI_BACKUP_SCRIPT_DIR` (test hook) points the extension at stub scripts; `PI_BACKUP_NO_CLIPBOARD=1` disables clipboard copy.
- What is backed up is defined once in `backup-manifest.txt`; update it, the README "What Gets Backed Up" table, and run `tests/sh/manifest.test.sh`.

Run typecheck, the tests, and both shell-language syntax checks after changes. Use temporary `PI_ROOT` and `BACKUP_ROOT` directories for backup smoke tests; never test against the real `~/.pi` without explicit authorization.

## Cross-platform requirements

- Preserve equivalent behavior across Bash and PowerShell implementations.
- Detect `7zz`, `7z`, or `7za` first on macOS, Windows, and Linux.
- Prefer 7-Zip for creating and extracting archives when available.
- Fall back to native tools when 7-Zip is unavailable: ZIP/`zip`/`unzip` on Unix and `Compress-Archive`/`Expand-Archive` on Windows.
- `.7z` archives require a 7-Zip executable; report a clear error when it is missing.
- Pass paths as argument arrays or environment variables rather than shell-interpolated command strings, especially for Windows paths containing spaces.
- Use `path.join()` and platform-aware process launching in the TypeScript extension.

## Backup and restore invariants

- Internal backups are uncompressed staging directories under `~/.pi/backups/` for quick rollback (`KEEP_UNCOMPRESSED=1`: no archive, no compression tool needed).
- External backups are compressed archives under the configured external backup directory.
- Exclude regeneratable data such as sessions, `node_modules`, context-mode databases, lock files, and detection logs.
- Backups contain `auth.json` credentials: keep them private (`umask 077`, `600`), honor `PI_BACKUP_EXCLUDE_AUTH=1`, and never include real credentials in tests or commits.
- The TUI must never run restore in-process (Pi owns the files); it shows the command to run after exiting Pi. Scripts use `PI_BACKUP_ASSUME_YES=1` for non-interactive restore.
- Clean reinstall moves `~/.pi` aside, reinstalls, verifies, then deletes (rollback on failure). Tests use stub `bun`/`pi` only.
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
- Update the project documentation after every code update.  README.md etc.