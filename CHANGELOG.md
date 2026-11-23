# Changelog

## 1.2.0

### Added
- Backups include the memory database (`pi-hermes-memory/sessions.db`), taken with `sqlite3 .backup` so changes still in the WAL file are kept. Restore clears stale `-wal`/`-shm`/`-journal` files before putting the database back.
- Backups include memory skills (`pi-hermes-memory/skills/`) and the skill-migration marker.
- Backups include extension state: `missions/`, `extensions/`, `anti-stall.json`, `crashes.json`, `run-history.jsonl`, `models-store.json`, `pi-subagents/last-seen-version.json`.
- Opt-in items, each set with an environment variable: `PI_BACKUP_INCLUDE_SESSIONS=1` (session history), `PI_BACKUP_INCLUDE_GIT=1` (cloned git packages), `PI_BACKUP_INCLUDE_BIN=1` (bundled binaries).
- The manifest supports `sqlite|` and `optional|ENV|` entries, read by the bash and PowerShell scripts.

## 1.1.13

### Fixed
- `CHANGELOG.md` is now published with the package, so Pi can show "Extension Updates" after an upgrade.
- The `@earendil-works/pi-coding-agent` peer dependency range is now `*`, as the Pi package docs require for host-provided packages.

## 1.1.12

### Fixed
- **Restore with no stdin** failed silently. It now prints a clear message, and `PI_BACKUP_ASSUME_YES=1` skips the prompt for scripted use. PowerShell restore no longer proceeds when stdin is empty.
- **TUI restore** no longer runs inside the live Pi process. It shows (and copies, where possible) the command to run after exiting Pi. Both restore scripts warn when a Pi process appears to be running.
- **Internal backups** no longer also create a compressed archive, and no longer require `zip`/7-Zip (`KEEP_UNCOMPRESSED=1`).
- **Temp directories leaked** on abort, error and failure paths in `restore-pi.sh/.ps1`, `backup-pi.sh/.ps1` and the TUI (`copy to internal`, `view manifest`). `mktemp` now honors `TMPDIR` on macOS.
- **Corrupt `settings.json`** was silently overwritten by the TUI. It is now left untouched with an error; writes are atomic and keep `settings.json.bak-<timestamp>` copies.
- **PowerShell 7z archives** now have the same single top-level `pi-backup-*/` layout as bash. The compression-failure warning printed a literal `.Exception.Message`; fixed.
- PowerShell `Copy-Tree` (without robocopy) nested directories instead of merging them; fixed. PowerShell restore of `projects-memory` is now per project like bash.
- npm manifest backup no longer picks up `node_modules/*/package.json`.
- TUI: selecting a backup matches exactly (no substring mix-ups), no frozen UI during long operations, no console output at load, copy-to-internal of an archive creates `pi-backup-<ts>` (not `pi-backup-<ts>.7z/`).
- Clean reinstall is rollback-safe (moves `~/.pi` aside, deletes it only after a verified reinstall), asks for an extra confirmation if no backup exists, and no longer has dead `BUN_HOME` code or a misleading step 4.

### Added
- `PI_BACKUP_EXCLUDE_AUTH=1`, `PI_BACKUP_ASSUME_YES=1`, `KEEP_OLD=1`.
- Backups and archives are private (`umask 077`, `auth.json` mode `600`); credential warnings in script output, TUI help and the README Security section.
- `backup-manifest.txt`: one list of backed-up paths shared by all four scripts (the `rsync` dependency is gone).
- Test suite (`npm test`), CI on Linux/macOS/Windows, and publish gated on CI.

### Changed
- Peer dependency on `@earendil-works/pi-coding-agent` is `>=0.84.1` (typechecked against 0.84.1 and 1.6.0); `package-lock.json` is now committed.
