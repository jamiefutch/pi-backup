import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync, mkdirSync, readdirSync, statSync, readFileSync, writeFileSync, rmSync, cpSync } from "node:fs";

const PI_ROOT = join(process.env.HOME || "", ".pi");
const INTERNAL_BACKUP_DIR = join(PI_ROOT, "backups");
const SETTINGS_FILE = join(PI_ROOT, "agent", "settings.json");
const DEFAULT_EXTERNAL_DIR = join(process.env.HOME || "", "projects", "personal", "pi-utils", "backups");
const PACKAGE_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

interface BackupInfo {
	name: string;
	path: string;
	timestamp: string;
	size: string;
	files: number;
	isCompressed: boolean;
	location: "internal" | "external";
}

function readSettings(): any {
	try {
		if (existsSync(SETTINGS_FILE)) {
			return JSON.parse(readFileSync(SETTINGS_FILE, "utf-8"));
		}
	} catch {}
	return {};
}

function writeSettings(settings: any): void {
	mkdirSync(dirname(SETTINGS_FILE), { recursive: true });
	writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2), "utf-8");
}

function getExternalBackupDir(ctx?: any): string {
	// 1. Environment variable (highest priority)
	if (process.env.BACKUP_ROOT) {
		return process.env.BACKUP_ROOT;
	}

	// 2. settings.json
	const settings = readSettings();
	if (settings.externalBackupDir) {
		return settings.externalBackupDir;
	}

	// 3. Default fallback
	return DEFAULT_EXTERNAL_DIR;
}

async function promptForExternalBackupDir(ctx: any): Promise<string | null> {
	const currentDefault = getExternalBackupDir();
	const source = process.env.BACKUP_ROOT ? "BACKUP_ROOT env var"
		: readSettings().externalBackupDir ? "settings.json"
		: "default";
	const input = await ctx.ui.input(
		`Configure external backup directory\n\nCurrent: ${currentDefault}\nSource: ${source}\n\nEnter a new path or press Enter to keep the current value:`,
		currentDefault,
	);

	if (input === undefined) return null; // User cancelled

	const chosenPath = input.trim() || currentDefault;

	// Save to settings.json
	const settings = readSettings();
	settings.externalBackupDir = chosenPath;
	writeSettings(settings);
	ctx.ui.notify(`Saved external backup directory to settings.json:\n${chosenPath}`, "info");

	// Ensure directory exists
	mkdirSync(chosenPath, { recursive: true });

	return chosenPath;
}

function resolveExternalBackupDir(ctx?: any): string {
	return getExternalBackupDir(ctx);
}

function getBackupScriptPath(): string {
	return join(PACKAGE_ROOT, "backup-pi.sh");
}

function getRestoreScriptPath(): string {
	return join(PACKAGE_ROOT, "restore-pi.sh");
}

function ensureDirs(externalDir: string) {
	if (!existsSync(INTERNAL_BACKUP_DIR)) mkdirSync(INTERNAL_BACKUP_DIR, { recursive: true });
	if (!existsSync(externalDir)) mkdirSync(externalDir, { recursive: true });
}

function parseTimestamp(name: string): string {
	const match = name.match(/pi-backup-(\d{8}-\d{6})/);
	return match ? match[1] : "unknown";
}

function formatTimestamp(ts: string): string {
	if (ts === "unknown") return "unknown";
	return `${ts.slice(0,4)}-${ts.slice(4,6)}-${ts.slice(6,8)} ${ts.slice(9,11)}:${ts.slice(11,13)}:${ts.slice(13,15)}`;
}

function getDirSize(path: string): { size: string; files: number } {
	let totalSize = 0;
	let fileCount = 0;
	try {
		const entries = readdirSync(path, { withFileTypes: true });
		for (const entry of entries) {
			const full = join(path, entry.name);
			if (entry.isDirectory()) {
				const sub = getDirSize(full);
				totalSize += parseSize(sub.size);
				fileCount += sub.files;
			} else {
				const stat = statSync(full);
				totalSize += stat.size;
				fileCount++;
			}
		}
	} catch {}
	return { size: formatBytes(totalSize), files: fileCount };
}

function getFileSize(path: string): { size: string; files: number } {
	try {
		const stat = statSync(path);
		return { size: formatBytes(stat.size), files: 1 };
	} catch {
		return { size: "0 B", files: 0 };
	}
}

function parseSize(str: string): number {
	const match = str.match(/^([\d.]+)\s*(\w+)$/);
	if (!match) return 0;
	const num = parseFloat(match[1]);
	const unit = match[2].toUpperCase();
	const multipliers: Record<string, number> = { B: 1, KB: 1024, MB: 1024**2, GB: 1024**3, TB: 1024**4 };
	return num * (multipliers[unit] || 1);
}

function formatBytes(bytes: number): string {
	if (bytes === 0) return "0 B";
	const k = 1024;
	const sizes = ["B", "KB", "MB", "GB", "TB"];
	const i = Math.floor(Math.log(bytes) / Math.log(k));
	return `${parseFloat((bytes / Math.pow(k, i)).toFixed(1))} ${sizes[i]}`;
}

function discoverBackups(ctx?: any): BackupInfo[] {
	const externalDir = resolveExternalBackupDir(ctx);
	ensureDirs(externalDir);
	const backups: BackupInfo[] = [];

	if (existsSync(INTERNAL_BACKUP_DIR)) {
		for (const entry of readdirSync(INTERNAL_BACKUP_DIR, { withFileTypes: true })) {
			if (entry.isDirectory() && entry.name.startsWith("pi-backup-")) {
				const path = join(INTERNAL_BACKUP_DIR, entry.name);
				const { size, files } = getDirSize(path);
				backups.push({
					name: entry.name,
					path,
					timestamp: parseTimestamp(entry.name),
					size,
					files,
					isCompressed: false,
					location: "internal",
				});
			}
		}
	}

	if (existsSync(externalDir)) {
		for (const entry of readdirSync(externalDir, { withFileTypes: true })) {
			if (entry.name.startsWith("pi-backup-")) {
				const path = join(externalDir, entry.name);
				const isCompressed = entry.name.endsWith(".zip") || entry.name.endsWith(".7z");
				const { size, files } = isCompressed ? getFileSize(path) : getDirSize(path);
				backups.push({
					name: entry.name,
					path,
					timestamp: parseTimestamp(entry.name),
					size,
					files,
					isCompressed,
					location: "external",
				});
			}
		}
	}

	return backups.sort((a, b) => b.timestamp.localeCompare(a.timestamp));
}

function runBackup(internal: boolean, ctx?: any): { success: boolean; output: string; backupPath?: string } {
	try {
		const externalDir = resolveExternalBackupDir(ctx);
		const env = { ...process.env };
		if (internal) {
			env.BACKUP_ROOT = INTERNAL_BACKUP_DIR;
			env.KEEP_UNCOMPRESSED = "1"; // keep staging dir for fast rollback
		} else {
			env.BACKUP_ROOT = externalDir;
			env.KEEP_UNCOMPRESSED = "0"; // external: compressed archive only
		}
		const output = execSync(getBackupScriptPath(), { env, encoding: "utf-8", maxBuffer: 10 * 1024 * 1024 });
		const match = output.match(/Staging:\s+(.+)$/m) || output.match(/Archive:\s+(.+)$/m);
		const backupPath = match ? match[1].trim() : undefined;
		return { success: true, output, backupPath };
	} catch (e: any) {
		return { success: false, output: e.stdout || e.stderr || e.message };
	}
}

function runRestore(backupPath: string): { success: boolean; output: string } {
	try {
		const output = execSync(`${getRestoreScriptPath()} "${backupPath}"`, { encoding: "utf-8", maxBuffer: 10 * 1024 * 1024 });
		return { success: true, output };
	} catch (e: any) {
		return { success: false, output: e.stdout || e.stderr || e.message };
	}
}

function copyBackupToInternal(backup: BackupInfo): { success: boolean; output: string } {
	if (backup.location === "internal") return { success: true, output: "Already in internal storage" };
	try {
		const destName = backup.name;
		const destPath = join(INTERNAL_BACKUP_DIR, destName);
		if (backup.isCompressed) {
			const tmpDir = join(INTERNAL_BACKUP_DIR, `.tmp-${Date.now()}`);
			mkdirSync(tmpDir, { recursive: true });
			if (backup.name.endsWith(".zip")) {
				execSync(`unzip -q "${backup.path}" -d "${tmpDir}"`);
			} else {
				execSync(`7z x -o"${tmpDir}" "${backup.path}" >/dev/null`);
			}
			const extracted = readdirSync(tmpDir)[0];
			cpSync(join(tmpDir, extracted), destPath, { recursive: true });
			rmSync(tmpDir, { recursive: true, force: true });
		} else {
			cpSync(backup.path, destPath, { recursive: true });
		}
		return { success: true, output: `Copied to ${destPath}` };
	} catch (e: any) {
		return { success: false, output: e.message };
	}
}

function deleteBackup(backup: BackupInfo): { success: boolean; output: string } {
	try {
		rmSync(backup.path, { recursive: true, force: true });
		return { success: true, output: `Deleted ${backup.name}` };
	} catch (e: any) {
		return { success: false, output: e.message };
	}
}

function formatBackupLine(b: BackupInfo): string {
	const locIcon = b.location === "internal" ? "📁" : "💾";
	const comp = b.isCompressed ? " • compressed" : "";
	return `${locIcon} ${b.name}  │  ${formatTimestamp(b.timestamp)}  │  ${b.size}  │  ${b.files} files${comp}`;
}

function findFile(dir: string, name: string): string | null {
	for (const entry of readdirSync(dir, { withFileTypes: true })) {
		const full = join(dir, entry.name);
		if (entry.isDirectory()) {
			const found = findFile(full, name);
			if (found) return found;
		} else if (entry.name === name) {
			return full;
		}
	}
	return null;
}

export default function piBackupManagerExtension(pi: ExtensionAPI) {
	console.error("[pi-backup-manager] Extension loaded");
	pi.registerCommand("pi-backup", {
		description: "Manage Pi backups - create, restore, view, copy, delete",
		handler: async (_args, ctx) => {
			if (ctx.mode !== "tui") {
				ctx.ui.notify("Backup manager only available in TUI mode", "error");
				return;
			}
			await showMainMenu(ctx);
		},
	});
}

async function showMainMenu(ctx: any) {
	while (true) {
		const externalDir = resolveExternalBackupDir(ctx);
		const backups = discoverBackups(ctx);
		const internalCount = backups.filter(b => b.location === "internal").length;
		const externalCount = backups.filter(b => b.location === "external").length;

		const choice = await ctx.ui.select(
			`Pi Backup Manager — ${backups.length} backups (${internalCount} internal, ${externalCount} external)\nExternal dir: ${externalDir}`,
			[
				"📦 Create internal backup  (~/.pi/backups/  — quick rollback)",
				"💾 Create external backup  (survives reinstall)",
				"📋 List all backups",
				"⚙️  Configure external backup directory",
				"❓ Help",
				"← Exit",
			],
		);

		if (!choice || choice.startsWith("←")) return;

		if (choice.startsWith("📦")) await createBackup(ctx, true);
		else if (choice.startsWith("💾")) await createBackup(ctx, false);
		else if (choice.startsWith("📋")) await showBackupList(ctx);
		else if (choice.startsWith("⚙️")) await configureExternalDir(ctx);
		else if (choice.startsWith("❓")) await showHelp(ctx);
	}
}

async function createBackup(ctx: any, internal: boolean) {
	// For external backup, ensure directory is configured.
	// Only prompt if no env/settings value AND the default dir is empty/missing.
	if (!internal) {
		const externalDir = getExternalBackupDir(ctx);
		const settings = readSettings();
		const explicitlyConfigured = process.env.BACKUP_ROOT || settings.externalBackupDir;
		const defaultHasContent = existsSync(externalDir) && readdirSync(externalDir).length > 0;
		if (!explicitlyConfigured && !defaultHasContent) {
			const configured = await promptForExternalBackupDir(ctx);
			if (!configured) return;
		}
	}

	ctx.ui.notify(`Creating ${internal ? "internal" : "external"} backup...`, "info");
	const result = runBackup(internal, ctx);
	if (result.success) {
		ctx.ui.notify(`Backup created successfully${result.backupPath ? `\n${result.backupPath}` : ""}`, "info");
	} else {
		ctx.ui.notify(`Backup failed:\n${result.output}`, "error");
	}
}

async function showBackupList(ctx: any) {
	let backups = discoverBackups(ctx);
	if (backups.length === 0) {
		ctx.ui.notify("No backups found", "info");
		return;
	}

	while (true) {
		const lines = backups.map(formatBackupLine);
		lines.push("🔄 Refresh");
		lines.push("← Back");

		const selected = await ctx.ui.select(`Backups (${backups.length} total)`, lines);
		if (!selected || selected.startsWith("←")) return;
		if (selected.startsWith("🔄")) { backups = discoverBackups(ctx); continue; }

		const backup = backups.find(b => selected.includes(b.name));
		if (!backup) continue;

		await showBackupActions(ctx, backup);
		backups = discoverBackups(ctx);
	}
}

async function showBackupActions(ctx: any, backup: BackupInfo) {
	const isInternal = backup.location === "internal";
	const actions = [
		`🔄 Restore this backup  (${formatTimestamp(backup.timestamp)})`,
	];

	if (!isInternal) {
		actions.push("📋 Copy to internal  (~/.pi/backups/)");
	}

	actions.push(
		"📄 View manifest",
		"🗑️ Delete",
		"← Back",
	);

	const choice = await ctx.ui.select(`Backup: ${backup.name}`, actions);
	if (!choice || choice.startsWith("←")) return;

	if (choice.startsWith("🔄")) await confirmRestore(ctx, backup);
	else if (choice.startsWith("📋")) {
		const result = copyBackupToInternal(backup);
		ctx.ui.notify(result.success ? result.output : `Failed: ${result.output}`, result.success ? "info" : "error");
	} else if (choice.startsWith("📄")) await viewManifest(ctx, backup);
	else if (choice.startsWith("🗑️")) await confirmDelete(ctx, backup);
}

async function confirmRestore(ctx: any, backup: BackupInfo) {
	// Restore uses the backup's direct path, so no directory config is needed here.
	const confirmed = await ctx.ui.confirm(
		`Restore ${backup.name}?`,
		`⚠️  This will OVERWRITE all current Pi configuration!\n` +
		`Backup: ${formatTimestamp(backup.timestamp)} • ${backup.size} • ${backup.files} files\n` +
		`Pi must NOT be running during restore.\n\n` +
		`Are you sure?`,
	);
	if (!confirmed) return;

	ctx.ui.notify("Restoring... (this may take a moment)", "info");
	const result = runRestore(backup.path);
	if (result.success) {
		ctx.ui.notify("Restore complete!\n\nNext steps:\n1. cd ~/.pi/agent && npm install\n2. pi --version\n3. /ctx-doctor", "info");
	} else {
		ctx.ui.notify(`Restore failed:\n${result.output}`, "error");
	}
}

async function confirmDelete(ctx: any, backup: BackupInfo) {
	const confirmed = await ctx.ui.confirm(
		`Delete ${backup.name}?`,
		`This cannot be undone.\n${formatTimestamp(backup.timestamp)} • ${backup.size} • ${backup.files} files`,
	);
	if (!confirmed) return;

	const result = deleteBackup(backup);
	ctx.ui.notify(result.success ? result.output : `Failed: ${result.output}`, result.success ? "info" : "error");
}

async function viewManifest(ctx: any, backup: BackupInfo) {
	let manifestPath: string;
	if (backup.isCompressed) {
		const tmpDir = join(INTERNAL_BACKUP_DIR, `.tmp-manifest-${Date.now()}`);
		mkdirSync(tmpDir, { recursive: true });
		try {
			if (backup.name.endsWith(".zip")) {
				execSync(`unzip -q "${backup.path}" "*/MANIFEST.txt" -d "${tmpDir}"`);
			} else {
				execSync(`7z x -o"${tmpDir}" "${backup.path}" "*/MANIFEST.txt" >/dev/null`);
			}
			const found = findFile(tmpDir, "MANIFEST.txt");
			if (found) manifestPath = found;
			else throw new Error("MANIFEST.txt not found in archive");
		} catch (e: any) {
			ctx.ui.notify(`Failed to extract manifest: ${e.message}`, "error");
			rmSync(tmpDir, { recursive: true, force: true });
			return;
		}
		rmSync(tmpDir, { recursive: true, force: true });
	} else {
		manifestPath = join(backup.path, "MANIFEST.txt");
	}

	if (!existsSync(manifestPath)) {
		ctx.ui.notify("No manifest found in backup", "warning");
		return;
	}

	const content = readFileSync(manifestPath, "utf-8");
	await ctx.ui.editor(`MANIFEST — ${backup.name}`, content);
}

async function configureExternalDir(ctx: any) {
	const current = getExternalBackupDir(ctx);
	const source = process.env.BACKUP_ROOT ? "environment variable (BACKUP_ROOT)"
		: readSettings().externalBackupDir ? "settings.json"
		: "default (not yet saved)";

	const choice = await ctx.ui.select(
		`Current external backup directory:\n${current}\n\nSource: ${source}`,
		[
			"📝 Change directory",
			"🔄 Reset to default",
			"← Back",
		],
	);

	if (!choice || choice.startsWith("←")) return;

	if (choice.startsWith("📝")) {
		await promptForExternalBackupDir(ctx);
	} else if (choice.startsWith("🔄")) {
		const settings = readSettings();
		delete settings.externalBackupDir;
		writeSettings(settings);
		ctx.ui.notify("Reset to default. Will use environment variable or default path.", "info");
	}
}

async function showHelp(ctx: any) {
	const externalDir = resolveExternalBackupDir(ctx);
	const help = `# Pi Backup Manager Help

## Backup Locations

### 📁 Internal (~/.pi/backups/)
- **Purpose**: Quick rollback during normal use
- **Survives**: Pi updates, extension installs, config changes
- **Does NOT survive**: Clean reinstall (\`rm -rf ~/.pi\`)
- **Format**: Uncompressed directories (fast access)

### 💾 External (${externalDir})
- **Purpose**: Disaster recovery
- **Survives**: Clean reinstall, disk failure (if copied elsewhere)
- **Does NOT survive**: Deleting the backup directory
- **Format**: Compressed archives (.7z/.zip) + optional uncompressed

## Configuration Priority

The external backup directory is resolved in this order:

1. **BACKUP_ROOT** environment variable (highest priority)
2. **settings.json** → \`externalBackupDir\` 
3. **Default**: \`~/projects/personal/pi-utils/backups/\`

Use **⚙️ Configure external backup directory** in the main menu to change the settings.json value.

## When to Use Which

| Scenario | Recommended |
|----------|-------------|
| Before installing risky extension | Internal |
| Before changing config files | Internal |
| Before Pi update | Both |
| Before clean reinstall | **External (required)** |
| Moving to new machine | External |

## Restore Process

1. Select backup → Restore
2. Script overwrites all config in \`~/.pi/agent/\`
3. **After restore**: Run \`cd ~/.pi/agent && npm install\`
4. Verify: \`pi --version\`, \`/ctx-doctor\`

## Manual Backup/Restore

\`\`\`bash
# Create external backup (uses BACKUP_ROOT or default)
~/projects/personal/pi-backup/backup-pi.sh

# Override backup location
BACKUP_ROOT=/mnt/backups ~/projects/personal/pi-backup/backup-pi.sh

# Restore from external
~/projects/personal/pi-backup/restore-pi.sh ~/projects/personal/pi-utils/backups/pi-backup-20260811-143000
\`\`\`

## What Gets Backed Up

✅ settings.json, auth.json, models.json, trust.json, keybindings.json
✅ All extension configs (loop-police, context-mode, hermes-memory, etc.)
✅ Global skills (\`~/.pi/agent/skills/\`)
✅ Project skills & memory (\`~/.pi/agent/projects-memory/\`)
✅ Local extension source code (pi-timeout, pi-chunk, etc.)
✅ npm manifests (package.json, lockfiles)
✅ Hermes memory files (MEMORY.md, USER.md, failures.md)
✅ Recent hermes-cleanup backups

## What Does NOT Get Backed Up (Regeneratable)

❌ Sessions (\`~/.pi/agent/sessions/\`)
❌ Context-mode KB (\`context-mode/kb.sqlite\`)
❌ node_modules/
❌ loop-police-detections.jsonl
❌ Lock files`;

	await ctx.ui.editor("Pi Backup Manager Help", help);
}