# pi-backup remediation plan

Branch: `20261122-repo-cleanup` (existing). One commit per phase. No push or publish without explicit approval.

## Ground rules

- **Never touch the real `~/.pi`.** Every test runs in a `mktemp -d` sandbox with `HOME`, `PI_ROOT`, `BACKUP_ROOT`, `LOCAL_EXT_ROOT` and `TMPDIR` all pointed inside it. The test helper aborts if any of them resolves outside the sandbox.
- **Tests first.** Each bug gets a test that fails on the current code before the fix, and passes after.
- **Bash/PowerShell parity.** Every script change is made in both languages in the same commit, per `.pi/agents.md`.
- **Update README and the TUI help text with every behavior change.** Bump the version at the end.

## Decisions (defaults chosen, change if you disagree)

| # | Decision | Default |
|---|----------|---------|
| D1 | How the TUI restores without running inside live Pi (bug 2) | The TUI does not run the restore in-process. It shows the exact command to run after exiting Pi and copies it where possible. The `PI_BACKUP_ASSUME_YES` flag (bug 1) still ships for scripted use. |
| D2 | Credential handling (bug 5) | Warn, tighten permissions (`umask 077`, `chmod 600 auth.json`), and add `PI_BACKUP_EXCLUDE_AUTH=1` to skip `auth.json`. No built-in encryption, because a password on the 7z command line leaks via `ps`. |
| D3 | `dist/` (publish workflow) | Pi loads `.ts` directly, so `dist/` stays unpublished. CI gates on `typecheck` plus tests, and also runs `build` as a compile check. |
| D4 | Clean-reinstall order | Move `~/.pi` aside, reinstall, verify, then delete the moved copy. Roll back on failure. |
| D5 | Single source of truth for file lists | One manifest file read by all four scripts, plus a test that checks the README against it. |

## Phase 0: Baseline and test harness

1. `npm ci`, then record the baseline: `npm run typecheck`, `bash -n`, the pwsh parse check. Check `git ls-files -s '*.sh'` shows mode `100755`, because the TUI executes scripts by path.
2. Add `tests/helpers.sh` and `tests/helpers.ps1`: sandbox creation, fixture `~/.pi` tree (fake `settings.json`, `auth.json` with a dummy token, skills, one local extension), assertion helpers, and a guard against paths outside the sandbox. Stub `pi`, `bun` and `7z` on `PATH` where a test needs them.
3. Add `tests/run.sh`, a runner that works on macOS, Linux and Windows (Git Bash or pwsh).
4. TS tests use `node:test` with `--experimental-strip-types`. They import the extension, pass a fake `pi` (captures `registerCommand`), and drive the handler with a scripted fake `ctx.ui` (`select`, `confirm`, `input`, `notify`, `editor`). `HOME` is set before a dynamic `import()`, because the module reads it at load time. Keep one process per test file. **Do not put helper modules in `extensions/`**, since Pi would try to load them as extensions.
5. Write the failing tests for bugs 1, 3, 4, 6 and 8 and confirm each fails for the stated reason. Add the characterization tests: a backup then restore round trip, with a tree diff.
6. Add the `package.json` `test` script. Add `tests` to `.npmignore` or leave it out of `files`.

**Verify:** the red tests fail as described. The round-trip characterization test passes on unmodified code.

## Phase 1: Script correctness (bash and ps1 together)

**Bug 1, restore fails with no stdin**
- `restore-pi.sh` and `restore-pi.ps1`: if `PI_BACKUP_ASSUME_YES=1`, skip the prompt. If stdin is not a TTY and the flag is unset, exit with a clear message ("non-interactive; set PI_BACKUP_ASSUME_YES=1") instead of a silent exit 1.
- Tests: `restore-pi.sh dir </dev/null` fails with the message. With the flag it succeeds and the tree matches. Run the same on pwsh.

**Bug 2 (script side)**
- Best-effort "Pi running" check in both restore scripts (`pgrep` on Unix, `Get-Process` on Windows). It **warns** and prints the risk. It does not block, because process names are unreliable. `PI_BACKUP_ASSUME_YES` does not suppress the warning.

**Bug 3, internal backups compressed**
- `backup-pi.sh`: skip step 9 when `KEEP_UNCOMPRESSED=1`. Make the zip/7z tool requirement conditional, so an internal backup works with no zip installed. Print `Staging:` only. Match the ps1 wording. Keep the TUI's `Staging:` / `Archive:` parse working.
- Tests: with `KEEP_UNCOMPRESSED=1`, the `BACKUP_ROOT` holds exactly one directory and no archive. With `0`, it holds exactly one archive and no leftover directory.
- `discoverBackups` also lists archives found in the internal dir, so existing double copies stay visible.

**Bug 4, leaked temp dirs**
- `restore-pi.sh`: define `cleanup()` and `trap cleanup EXIT` immediately after `mktemp -d`. Remove the tail cleanup. Cover the Aborted path, the `set -e` failure path and the no-backup-dir path.
- `backup-pi.sh`: `trap` removes a half-built staging dir on failure only. A successful staging dir is kept when `KEEP_UNCOMPRESSED=1`.
- `restore-pi.ps1`, `backup-pi.ps1`: `try/finally`. Confirm that `exit` inside `try` still runs `finally` (test it with pwsh locally).
- `copyBackupToInternal` and `viewManifest` in the TS: `finally { rmSync(tmpDir) }`. Also remove a partial `destPath` on failure.
- Tests: set `TMPDIR` to the sandbox, then run each of (abort with `n`, truncated archive, mid-restore failure, success). Assert the sandbox `TMPDIR` is empty afterwards. TS: a corrupt archive leaves no `.tmp-*` in the internal dir.

**Bug 7, ps1 archive layout**
- `backup-pi.ps1`: `Push-Location $BackupRoot`, pass the relative `$ArchiveBase` to 7z, `Pop-Location` in `finally`. Same as the bash version.
- Verify: `7z l` on the result shows a single top-level `pi-backup-*/` entry. Restore of that archive works. Runs on the Windows CI runner (7-Zip is preinstalled there). Locally on macOS, test the `Compress-Archive` path with pwsh.

**Bug 8, garbage warning**
- `backup-pi.ps1:221`: use `$($_.Exception.Message)`. Also fix the label, which says "Compress-Archive failed" even when 7z failed. `grep` all `.ps1` files for other `"$_.` patterns.
- Test: force a compression failure (stub 7z that exits 1) and assert the warning text has no literal `.Exception.Message`.

**Verify (phase gate):** all Phase 1 tests green on bash and pwsh. `bash -n`, the pwsh parse check and `tsc` are clean. Commit.

## Phase 2: TUI extension

**Bug 2, restore in a running Pi (D1)**
- `confirmRestore`: after confirmation, show the command to run once Pi has exited. For example `PI_BACKUP_ASSUME_YES=1 /path/restore-pi.sh '<path>'`, with Windows quoting. Do not execute it. Update the confirm text, README and help.
- `runRestore` is removed from the TUI path. Keep the helper only if a test needs it.
- Tests: confirming restore never spawns a process (assert via a spy) and notifies with the command. Quoting handles spaces in paths.

**Bug 6, corrupt settings**
- `readSettings` returns `{ok, data, error}`. Missing file is `ok` with `{}`. Parse failure is not `ok`.
- `writeSettings` refuses when the current file is corrupt. It writes atomically (temp file, then rename) and keeps the original as `settings.json.bak-<ts>` if it must replace anything.
- Read-only callers (`getExternalBackupDir`) fall back to the default and surface one warning notice. They do not throw.
- Tests: a malformed `settings.json` is byte-identical after "Change directory" and after "Reset to default", and the user sees an error. A valid file keeps its other keys.

**Smaller TUI fixes**
- Async execution: replace `execFileSync` in `runBackup` and `extractArchive` with promisified `execFile` (with `maxBuffer`, and stdout plus stderr in the failure output). `await` them in the handlers. Check the Pi extension API for a status/working indicator before using one; do not assume it exists.
- Exact matching: build a `Map<label, BackupInfo>` with unique labels (append the location and a short index on collision). Replace `selected.includes(b.name)`. Test with `pi-backup-X` (dir, internal) and `pi-backup-X.7z` (external) at the same timestamp.
- Remove the `console.error` at load. Test that stderr is empty on load.
- Update the help text to match the README (internal = directories only, credentials warning).

**Verify:** `npm run typecheck`, `npm run build`, and the TS tests all pass. Commit.

## Phase 3: Credentials (bug 5, D2)

- Both backup scripts: `umask 077` / restrictive ACL note, `chmod 600` on `auth.json` in the backup. Add `PI_BACKUP_EXCLUDE_AUTH=1`. Print a one-line warning when `auth.json` is included.
- Restore: `chmod 600` on a restored `auth.json`.
- README gets a "Security" section. The TUI help text and the create-external-backup notify mention it.
- Tests: with `EXCLUDE_AUTH=1` the archive has no `auth.json`. By default the staged file mode is `600`. The warning is printed. A help-text test asserts the warning is present.

**Verify and commit.**

## Phase 4: Clean-reinstall safety

- Both reinstall scripts: remove `BUN_HOME`. Rewrite step 4 so it says what it does (verifies `pi --version`).
- New order (D4): preflight, then check for a recent backup (any `pi-backup-*` in `BACKUP_ROOT`). If none exists, require typing an extra confirmation. Then move `$PI_ROOT` to `$PI_ROOT.pre-reinstall-<ts>`, uninstall, install, verify `pi --version`. On failure, move it back and exit non-zero. On success, delete the moved copy unless `KEEP_OLD=1`.
- Tests with stub `bun` and `pi` on `PATH`: success deletes the old tree. Install failure leaves `~/.pi` intact. No backup triggers the extra prompt. Never call the real package manager.

**Verify and commit.**

## Phase 5: De-duplicate file lists (D5)

Done after the tests exist, because it touches every script.
- Add `backup-manifest.txt` (LF-only, enforced in `.gitattributes`; parsers also strip `\r`). Lines look like `file|agent/settings.json|settings.json`, `dir|...`, `local-ext|pi-timeout`.
- `backup-pi.sh`, `restore-pi.sh` and both ps1 files read it. Add the file to `package.json` `files`.
- A test compares the manifest to the README tables, so drift fails CI.
- The Phase 0 round-trip test must still pass byte-for-byte. Add a parity test that lists the same fixture through bash and pwsh and compares the file sets.

**Verify and commit.**

## Phase 6: CI and publish

- New `.github/workflows/ci.yml`: matrix `ubuntu`, `macos`, `windows`. Steps: `npm ci`, typecheck, build, `bash -n` and pwsh parse, run the tests. Windows runs the 7z layout test (bug 7).
- `publish-npm.yml`: add `needs` on the CI job (or the same steps inline), run typecheck and tests before `npm publish`. Keep the tag/version check.
- Dependencies: look up the current `@earendil-works/pi-coding-agent` version with `npm view`. Set the peer range to a tested range, and the dev dependency to a caret on the lockfile version. Re-run `npm ci`, typecheck and tests.
- D3: confirm `npm pack --dry-run` lists only the intended files (extensions, scripts, manifest, README, LICENSE) and not `tests` or `dist`.

**Verify:** `npm pack --dry-run` output reviewed. Workflow YAML checked with `actionlint` if available. Matrix results only exist after a push, which needs your approval.

## Phase 7: Docs and release

- README: fix the sample output (capture the real output from a sandbox run), the restore section, the Security section, the env var list (`PI_BACKUP_ASSUME_YES`, `PI_BACKUP_EXCLUDE_AUTH`, `KEEP_OLD`), and the clean-reinstall behavior. Update `.pi/agents.md` with the test commands.
- Bump the version in `package.json` (minor bump, new env vars). Add a changelog entry.

## Final verification gate

1. `npm run typecheck && npm run build && npm test` is green.
2. `bash -n` on all shell scripts and the pwsh parse check pass.
3. The end-to-end sandbox round trip passes: backup, mutate, restore with `PI_BACKUP_ASSUME_YES=1`, then a tree diff. Repeat for the directory, `.zip` and `.7z` formats (`.7z` on CI or after installing 7-Zip locally with your approval).
4. Leak check: after the whole suite, the sandbox `TMPDIR` and internal backup dir hold no `.tmp-*`.
5. `git status` shows no generated backups, credentials or `dist/`. The real `~/.pi` is unmodified (checksum the tree before and after the suite).
6. Each of the 8 bugs and 9 smaller issues maps to at least one passing test or a documented manual check (table below).

| Item | Verified by |
|------|-------------|
| 1 | restore no-stdin test (sh, ps1) |
| 2 | TUI spawn-spy test, running-Pi warning test |
| 3 | internal/external output shape test |
| 4 | TMPDIR leak tests (sh, ps1, TS) |
| 5 | exclude-auth test, mode 600 test, warning text test |
| 6 | corrupt settings byte-identity test |
| 7 | Windows CI `7z l` layout test |
| 8 | stub-7z failure message test |
| Blocking I/O | async handler test (event loop ticks during a slow stub script) |
| Loose matching | same-timestamp collision test |
| Stderr on load | empty-stderr test |
| Duplicated lists | manifest vs README test, bash/pwsh parity test |
| README sample | diff against a captured real run |
| Dead code, reinstall messages | grep test plus reinstall stub test |
| Reinstall safety | stub `bun`/`pi` tests |
| Publish workflow | `npm pack --dry-run` review, CI run |
| No tests | the suite itself |

## Plan review: gaps found and how this plan addresses them

1. **Bug 1 and bug 2 conflict.** The suggested fix (TUI sets a flag) makes the restore run inside live Pi, which is bug 2. Resolved with D1: the flag is for scripted use, and the TUI hands off a command instead.
2. **Helper modules in `extensions/` would be loaded by Pi as extensions.** Tests drive the public default export with a fake `ctx` instead of requiring new exports or a new module in that directory.
3. **macOS cannot verify 7z or Windows behavior.** `7z` is not installed locally and bug 7 is Windows-only. Covered by the CI matrix. Local runs cover the zip path and pwsh. Installing 7-Zip locally needs your approval.
4. **Test safety.** Scripts call `pi --version`, `hostname` and write to `LOCAL_EXT_ROOT` (`~/projects`). The sandbox overrides all roots, stubs `pi`, and aborts on any out-of-sandbox path.
5. **Leaving `exit` inside `try` in PowerShell.** Behavior is verified with pwsh locally rather than assumed.
6. **Refactoring risk in Phase 5.** It is ordered after the characterization tests and requires byte-identical round trips. CRLF handling and `files` packaging are called out.
7. **Existing users have double copies in `~/.pi/backups/`.** Discovery lists archives in the internal dir, so nothing becomes invisible.
8. **Exec bit.** The TUI runs scripts by path, so Phase 0 checks mode `100755` in git.
9. **Corrupt settings must not break read-only paths.** Reading degrades to defaults with one warning. Only writes refuse.
10. **Help text and README drift** is itself a bug source (Phase 2 and 7 update both, and a test checks the manifest against the README).
11. **Clean-reinstall must not be run for real.** Stubs for `bun` and `pi` only.
12. **Release hygiene.** Version bump, changelog, `npm pack --dry-run`, and publish gated on CI. Pushing and tagging stay with you.
13. **Unverifiable here:** the `.7z` end-to-end result and the Windows matrix. These are reported as unverified until CI runs, not claimed as passing.
