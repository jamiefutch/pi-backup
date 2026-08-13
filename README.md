# pi-backup — Pi Backup & Restore Utilities

Complete backup/restore for Pi coding agent. Backs up **everything** needed to restore to identical state after a clean reinstall.

## Installation

### Via Pi Package Manager (recommended)

```bash
# From npm (when published)
pi install npm:@jamiefutch/pi-backup@latest

# From git
pi install git:github.com/jamiefutch/pi-backup@main

# From local path
pi install /path/to/pi-backup
```

### Manual (add to settings.json)

```json
{
  "packages": ["npm:@jamiefutch/pi-backup"]
}
```

Then restart Pi or run `/reload`.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `backup-pi.sh` / `backup-pi.ps1` | Creates timestamped backup of all Pi config, skills, extensions, memory |
| `pi-clean-reinstall.sh` / `pi-clean-reinstall.ps1` | Nuclear reinstall — wipes `~/.pi`, uninstalls/reinstalls Pi (dangerous) |
| `restore-pi.sh` / `restore-pi.ps1` | Restores backup after fresh Pi install |

| Platform | Extensions |
|----------|------------|
| **macOS / Linux (bash)** | `backup-pi.sh`, `restore-pi.sh`, `pi-clean-reinstall.sh` |
| **Windows (PowerShell)** | `backup-pi.ps1`, `restore-pi.ps1`, `pi-clean-reinstall.ps1` (requires PowerShell 7 / `pwsh`) |

---

## Usage

### TUI Extension (after package install)

```bash
/pi-backup
```

Opens the **Pi Backup Manager** interactive menu:

```
Pi Backup Manager — 8 backups (1 internal, 7 external)
External dir: ~/projects/personal/pi-utils/backups

 → 📦 Create internal backup  (~/.pi/backups/  — quick rollback)
   💾 Create external backup  (survives reinstall)
   📋 List all backups
   ⚙️  Configure external backup directory
   ❓ Help
   ← Exit
```

#### Main Menu Options

| Option | Description | Location |
|--------|-------------|----------|
| **📦 Create internal backup** | Fast uncompressed backup for quick rollback during normal use | `~/.pi/backups/` |
| **💾 Create external backup** | Compressed archive for disaster recovery — survives clean reinstall | resolved per priority chain |
| **📋 List all backups** | Browse, restore, copy, delete, or view manifests of all backups | Both locations |
| **⚙️ Configure external backup directory** | Set or reset the `settings.json` `externalBackupDir` value | settings.json |
| **❓ Help** | Full documentation on backup locations, what's backed up, restore process | — |
| **← Exit** | Close the backup manager | — |

#### Backup List View

```
Backups (8 total)

 → 📁 pi-backup-20260812-112053  │  2026-08-12 11:20:53  │  1.6 MB  │  347 files
   💾 pi-backup-20260812-112019.zip  │  2026-08-12 11:20:19  │  1.6 MB  │  1 files • compressed
   💾 pi-backup-20260812-095402.zip  │  2026-08-12 09:54:02  │  1.6 MB  │  1 files • compressed
   ...
   🔄 Refresh
   ← Back
```

Columns: **Location icon** • **Name** • **Timestamp** • **Size** • **File count** • **Compression status**

#### Backup Actions (after selecting a backup)

```
Backup: pi-backup-20260812-112019.zip

 → 🔄 Restore this backup  (2026-08-12 11:20:19)
   📋 Copy to internal  (~/.pi/backups/)
   📄 View manifest
   🗑️ Delete
   ← Back
```

| Action | Description |
|--------|-------------|
| **🔄 Restore** | Runs `restore-pi.sh` — overwrites all Pi config (requires confirmation) |
| **📋 Copy to internal** | Copies external backup to `~/.pi/backups/` for quick access (external only) |
| **📄 View manifest** | Opens `MANIFEST.txt` in editor (extracts from compressed archives) |
| **🗑️ Delete** | Permanently removes backup (requires confirmation) |

#### Backup Location Summary

| Location | Path | Survives Clean Reinstall? | Format |
|----------|------|---------------------------|--------|
| **Internal** | `~/.pi/backups/` | ❌ NO (wiped by `rm -rf ~/.pi`) | Uncompressed dirs |
| **External** | `~/projects/personal/pi-utils/backups/` | ✅ YES | Compressed (.7z/.zip) |

> **Key point**: Always create an **external backup** before a clean reinstall. Internal backups are for quick rollbacks during normal use only.

### Command Line (scripts directly)

#### 1. Backup (before reinstall)
```bash
~/projects/personal/pi-backup/backup-pi.sh
```

#### 2. Clean Reinstall
```bash
~/projects/personal/pi-backup/pi-clean-reinstall.sh
```

#### 3. Restore
```bash
~/projects/personal/pi-backup/restore-pi.sh ~/projects/personal/pi-utils/backups/pi-backup-20260811-143000
```

#### 4. Reinstall npm deps + verify
```bash
cd ~/.pi/agent && npm install  # or bun install
pi --version
/ctx-doctor
/loop-police-status
/scoped-memory-status
```

### Windows (PowerShell)

On Windows, use the `.ps1` scripts from PowerShell 7 (`pwsh`). The backup data directory defaults to `~/projects/personal/pi-utils/backups`.

```powershell
# 1. Backup (before reinstall)
.\backup-pi.ps1

# 2. Clean Reinstall (nuclear - wipes ~/.pi, uninstalls/reinstalls Pi)
.\pi-clean-reinstall.ps1

# 3. Restore
.\restore-pi.ps1 ~\projects\personal\pi-utils\backups\pi-backup-20260811-143000

# 4. Reinstall npm deps + verify
cd ~\.pi\agent; npm install
pi --version
/ctx-doctor
```

Customize locations in PowerShell with environment variables (same names as the bash scripts):

```powershell
$env:PI_ROOT='C:\Users\you\.pi'; $env:BACKUP_ROOT='D:\pi-backups'; .\backup-pi.ps1
```

> **Note**: If the Execution Policy blocks scripts, run once: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`. Backups are created as `.zip` via the built-in `Compress-Archive` (no external tools needed).

## What Gets Backed Up

| Category | Paths |
|----------|-------|
| **Core config** | `settings.json`, `auth.json`, `models.json`, `trust.json`, `keybindings.json`, `pix.json`, `optimizer.json`, `hermes-memory-config.json` |
| **Extension configs** | `pi-hermes-memory-cleanup/scoped-memory.json`, `loop-police.json`, `pi-rtk/config.json`, `context-mode/config.json`, `pi-timeout/config.json`, `pi-context-viewer/config.json`, `pix-optimizer/config.json`, `pi-nvidia-nim/config.json` |
| **Global skills** | `~/.pi/agent/skills/` |
| **Project skills & memory** | `~/.pi/agent/projects-memory/<project>/` |
| **Local extension source** | `~/projects/personal/pi-timeout/`, `pi-chunk/`, `pi-hermes-memory-cleanup/`, `pi-context-docs/` |
| **npm manifests** | `package.json`, `package-lock.json`, `npm-shrinkwrap.json` from `~/.pi/agent/npm/` |
| **Hermes memory (active)** | `MEMORY.md`, `USER.md`, `failures.md`, `retired-*.md` |
| **Cleanup backups** | Last 5 from `~/.pi/agent/hermes-cleanup/` |

The backup script output:
```
════════════════════════════════════════════════════════════
  Pi Complete Backup
════════════════════════════════════════════════════════════
Source:      /Users/jamiefutch/.pi
Destination: ~/projects/personal/pi-utils/backups/pi-backup-20260811-143000
...
Backup complete!
Location: ~/projects/personal/pi-utils/backups/pi-backup-20260811-143000
Size:     12M
Files:    347
```

## What Does NOT Get Backed Up (Regeneratable)

| Excluded | Why |
|----------|-----|
| `~/.pi/agent/sessions/` | Session history — regenerated |
| `~/.pi/agent/context-mode/kb.sqlite` | Knowledge base — rebuilt from indexed sources |
| `~/.pi/agent/npm/node_modules/` | Dependencies — reinstalled via `npm install` |
| `~/.pi/agent/loop-police-detections.jsonl` | Detection logs — regenerated |
| `~/.pi/agent/.pi-hermes-locks.sqlite*` | Lock files — recreated |

---

## Backup Location

```
~/projects/personal/pi-utils/backups/
├── pi-backup-20260811-143000/
│   ├── MANIFEST.txt
│   ├── settings.json
│   ├── auth.json
│   ├── models.json
│   ├── skills/
│   ├── projects-memory/
│   ├── local-extensions/
│   ├── npm-manifests/
│   ├── pi-hermes-memory/
│   └── hermes-cleanup/
└── pi-backup-20260811-150000/
    ...
```

Each backup is self-contained with a `MANIFEST.txt` listing all files.

---

## External Backup Directory Configuration

The external backup location is resolved in this priority order:

1. **`BACKUP_ROOT`** environment variable (highest priority)
2. **`externalBackupDir`** key in `~/.pi/agent/settings.json`
3. **Default**: `~/projects/personal/pi-utils/backups/`

```json
// ~/.pi/agent/settings.json
{
  "externalBackupDir": "/custom/path/to/backups"
}
```

### In the TUI

Use the **⚙️ Configure external backup directory** option in `/pi-backup` to set or reset the `settings.json` value:

- **📝 Change directory** — prompt to type a path, saved to `settings.json`
- **🔄 Reset to default** — removes the `settings.json` value, falls back to env var / default

### When the prompt appears

The configure prompt only appears when creating an external backup if **both** of these are true:
- No `BACKUP_ROOT` env var and no `externalBackupDir` in `settings.json`, AND
- The default external directory is empty or missing

If the default directory already contains backups, it is treated as configured and used directly with no prompt. Restore never prompts (it uses the selected backup's direct path).

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `PI_ROOT` | `~/.pi` | Override Pi root directory |
| `BACKUP_ROOT` | `~/projects/personal/pi-utils/backups` | Override backup destination (highest priority for the TUI too) |

```bash
# Custom locations
PI_ROOT=/custom/.pi BACKUP_ROOT=/mnt/backups ~/projects/personal/pi-backup/backup-pi.sh
```

---

## Automation (Cron)

```bash
# Daily backup at 3 AM
0 3 * * * ~/projects/personal/pi-backup/backup-pi.sh >> ~/pi-backup.log 2>&1

# Keep last 30 backups
0 4 * * * find ~/projects/personal/pi-utils/backups -maxdepth 1 -type d -name 'pi-backup-*' -mtime +30 -exec rm -rf {} \;
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| "Permission denied" | `chmod +x backup-pi.sh restore-pi.sh` |
| "npm install fails" | Check Node.js version (need ≥22), try `bun install` |
| "Skills not loading" | Verify `settings.json` has correct `packages` paths after restore |
| "Models not found" | Check `models.json` restored correctly, restart Pi |
| "Auth failed" | Verify `auth.json` restored, API keys valid |

---

## Manual Verify Checklist After Restore

- [ ] `pi --version` shows correct version
- [ ] `/ctx-doctor` shows all checks pass
- [ ] `/loop-police-status` shows config loaded
- [ ] `/scoped-memory-status` shows enabled + last injection stats
- [ ] `/memory-search "test"` returns results
- [ ] `/context-stats` shows context breakdown
- [ ] `/nim-status` connects (if NVIDIA configured)
- [ ] Local extensions load (check `settings.json` paths)
- [ ] Run a simple task to verify end-to-end

---

## License

MIT License

Copyright (c) 2025 Jamie Futch

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

See the [`LICENSE`](LICENSE) file for the full license text.