import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync, mkdirSync, readdirSync, statSync, readFileSync, writeFileSync, rmSync, cpSync, renameSync, copyFileSync } from "node:fs";

const execFileAsync = promisify(execFile);
const MAX_BUFFER = 50 * 1024 * 1024;

const HOME_DIR = process.env.HOME || process.env.USERPROFILE || "";
const IS_WINDOWS = process.platform === "win32";
const PI_ROOT = join(HOME_DIR, ".pi");
const INTERNAL_BACKUP_DIR = join(PI_ROOT, "backups");
const SETTINGS_FILE = join(PI_ROOT, "agent", "settings.json");
const DEFAULT_EXTERNAL_DIR = join(HOME_DIR, "pi-backups");
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

interface SettingsResult {
	ok: boolean;
	data: Record<string, any>;
	error?: string;
}

/** A missing file is fine ({}). A file that exists but cannot be parsed is NOT ok. */
function readSettings(): SettingsResult {
	if (!existsSync(SETTINGS_FILE)) return { ok: true, data: {} };
	try {
		const parsed = JSON.parse(readFileSync(SETTINGS_FILE, "utf-8"));
		if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
			return { ok: false, data: {}, error: "settings.json is not a JSON object" };
		}
		return { ok: true, data: parsed };
	} catch (e: any) {
		return { ok: false, data: {}, error: `settings.json could not be parsed (${e.message})` };
	}
}

const SETTINGS_BACKUPS_KEPT = 3;

/**
 * Read-modify-write settings.json safely: refuses if the current file is corrupt, writes to a temp
 * file and renames it into place, and keeps the previous version as settings.json.bak-<timestamp>.
 */
function updateSettings(mutate: (settings: Record<string, any>) => void): { ok: boolean; error?: string } {
	const current = readSettings();
	if (!current.ok) {
		return { ok: false, error: `${current.error}. Left untouched; fix or remove ${SETTINGS_FILE} and try again.` };
	}
	mutate(current.data);
	const dir = dirname(SETTINGS_FILE);
	const tmp = `${SETTINGS_FILE}.tmp-${process.pid}-${Date.now()}`;
	try {
		mkdirSync(dir, { recursive: true });
		writeFileSync(tmp, JSON.stringify(current.data, null, 2), "utf-8");
		if (existsSync(SETTINGS_FILE)) {
			const stamp = new Date().toISOString().replace(/[:.]/g, "-");
			copyFileSync(SETTINGS_FILE, `${SETTINGS_FILE}.bak-${stamp}`);
			const old = readdirSync(dir).filter((f) => f.startsWith("settings.json.bak-")).sort();
			for (const f of old.slice(0, Math.max(0, old.length - SETTINGS_BACKUPS_KEPT))) {
				rmSync(join(dir, f), { force: true });
			}
		}
		renameSync(tmp, SETTINGS_FILE);
		return { ok: true };
	} catch (e: any) {
		rmSync(tmp, { force: true });
		return { ok: false, error: e.message };
	}
}

let corruptSettingsWarned = false;

/** Read-only callers fall back to defaults and surface a single warning. */
function readSettingsForDisplay(ctx?: any): Record<string, any> {
	const result = readSettings();
	if (result.ok) {
		corruptSettingsWarned = false;
		return result.data;
	}
	if (!corruptSettingsWarned) {
		corruptSettingsWarned = true;
		ctx?.ui?.notify?.(`${result.error}. Using default settings; ${SETTINGS_FILE} was not modified.`, "warning");
	}
	return {};
}

function getExternalBackupDir(ctx?: any): string {
	// 1. Environment variable (highest priority)
	if (process.env.BACKUP_ROOT) {
		return process.env.BACKUP_ROOT;
	}

	// 2. settings.json
	const settings = readSettingsForDisplay(ctx);
	if (settings.externalBackupDir) {
		return settings.externalBackupDir;
	}

	// 3. Default fallback
	return DEFAULT_EXTERNAL_DIR;
}

async function promptForExternalBackupDir(ctx: any): Promise<string | null> {
	const currentDefault = getExternalBackupDir(ctx);
	const source = process.env.BACKUP_ROOT ? "BACKUP_ROOT env var"
		: readSettingsForDisplay(ctx).externalBackupDir ? "settings.json"
		: "default";
	const input = await ctx.ui.input(
		`Configure external backup directory\n\nCurrent: ${currentDefault}\nSource: ${source}\n\nEnter a new path or press Enter to keep the current value:`,
		currentDefault,
	);

	if (input === undefined) return null; // User cancelled

	const chosenPath = input.trim() || currentDefault;

	// Save to settings.json (refuses if the existing file is corrupt)
	const saved = updateSettings((settings) => { settings.externalBackupDir = chosenPath; });
	if (!saved.ok) {
		ctx.ui.notify(`Could not save external backup directory: ${saved.error}`, "error");
		return null;
	}
	ctx.ui.notify(`Saved external backup directory to settings.json:\n${chosenPath}`, "info");

	// Ensure directory exists
	mkdirSync(chosenPath, { recursive: true });

	return chosenPath;
}

function resolveExternalBackupDir(ctx?: any): string {
	return getExternalBackupDir(ctx);
}

// PI_BACKUP_SCRIPT_DIR is a test hook that points at stub scripts.
function scriptDir(): string {
	return process.env.PI_BACKUP_SCRIPT_DIR || PACKAGE_ROOT;
}

function getBackupScriptPath(): string {
	return join(scriptDir(), IS_WINDOWS ? "backup-pi.ps1" : "backup-pi.sh");
}

function getRestoreScriptPath(): string {
	return join(scriptDir(), IS_WINDOWS ? "restore-pi.ps1" : "restore-pi.sh");
}

async function findSevenZip(): Promise<string | null> {
	const lookup = IS_WINDOWS ? "where.exe" : "which";
	for (const candidate of ["7zz", "7z", "7za"]) {
		try {
			await execFileAsync(lookup, [candidate]);
			return candidate;
		} catch {}
	}
	return null;
}

async function expandZipWithPowerShell(archivePath: string, destination: string): Promise<void> {
	await execFileAsync("pwsh", [
		"-NoProfile",
		"-Command",
		"Expand-Archive -LiteralPath $env:PI_BACKUP_ARCHIVE -DestinationPath $env:PI_BACKUP_DEST -Force",
	], {
		env: { ...process.env, PI_BACKUP_ARCHIVE: archivePath, PI_BACKUP_DEST: destination },
		maxBuffer: MAX_BUFFER,
	});
}

async function extractArchive(archivePath: string, destination: string): Promise<void> {
	const sevenZip = await findSevenZip();
	if (sevenZip) {
		await execFileAsync(sevenZip, ["x", "-y", `-o${destination}`, archivePath], { maxBuffer: MAX_BUFFER });
		return;
	}
	if (archivePath.endsWith(".zip")) {
		if (IS_WINDOWS) await expandZipWithPowerShell(archivePath, destination);
		else await execFileAsync("unzip", ["-q", archivePath, "-d", destination], { maxBuffer: MAX_BUFFER });
		return;
	}
	throw new Error("7zip is required to extract .7z backups and was not found on PATH");
}

/** stdout and stderr of a failed child process, falling back to the error message. */
function describeExecError(e: any): string {
	const text = [e?.stdout, e?.stderr].filter((v) => typeof v === "string" && v.trim()).join("\n").trim();
	return text || e?.message || String(e);
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

async function runBackup(internal: boolean, ctx?: any): Promise<{ success: boolean; output: string; backupPath?: string }> {
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
		const command = IS_WINDOWS ? "pwsh" : getBackupScriptPath();
		const args = IS_WINDOWS ? ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", getBackupScriptPath()] : [];
		const { stdout, stderr } = await execFileAsync(command, args, { env, encoding: "utf-8", maxBuffer: MAX_BUFFER });
		const output = `${stdout}${stderr ? `\n${stderr}` : ""}`;
		const match = output.match(/Staging:\s+(.+)$/m) || output.match(/Archive:\s+(.+)$/m);
		const backupPath = match ? match[1].trim() : undefined;
		return { success: true, output, backupPath };
	} catch (e: any) {
		return { success: false, output: describeExecError(e) };
	}
}

function shellQuote(value: string): string {
	return IS_WINDOWS ? `'${value.replace(/'/g, "''")}'` : `'${value.replace(/'/g, `'\\''`)}'`;
}

/**
 * The command the user should run AFTER exiting Pi. Restore must not run inside the live Pi
 * process: Pi would keep (and later rewrite) the files being replaced.
 */
function buildRestoreCommand(backupPath: string): string {
	const script = getRestoreScriptPath();
	if (IS_WINDOWS) {
		return `$env:PI_BACKUP_ASSUME_YES='1'; pwsh -NoProfile -ExecutionPolicy Bypass -File ${shellQuote(script)} ${shellQuote(backupPath)}`;
	}
	return `PI_BACKUP_ASSUME_YES=1 ${shellQuote(script)} ${shellQuote(backupPath)}`;
}

/** Best-effort clipboard copy. Disabled with PI_BACKUP_NO_CLIPBOARD=1 (used by tests). */
async function copyToClipboard(text: string): Promise<boolean> {
	if (process.env.PI_BACKUP_NO_CLIPBOARD === "1") return false;
	const candidates: Array<[string, string[]]> = IS_WINDOWS
		? [["clip", []]]
		: process.platform === "darwin"
			? [["pbcopy", []]]
			: [["wl-copy", []], ["xclip", ["-selection", "clipboard"]], ["xsel", ["--clipboard", "--input"]]];
	for (const [cmd, args] of candidates) {
		try {
			await new Promise<void>((resolve, reject) => {
				const child = spawn(cmd, args, { stdio: ["pipe", "ignore", "ignore"] });
				child.on("error", reject);
				child.on("close", (code) => (code === 0 ? resolve() : reject(new Error(`exit ${code}`))));
				child.stdin.on("error", reject);
				child.stdin.end(text);
			});
			return true;
		} catch {}
	}
	return false;
}

async function copyBackupToInternal(backup: BackupInfo): Promise<{ success: boolean; output: string }> {
	if (backup.location === "internal") return { success: true, output: "Already in internal storage" };
	const destPath = join(INTERNAL_BACKUP_DIR, backup.isCompressed ? backup.name.replace(/\.(zip|7z)$/, "") : backup.name);
	let tmpDir: string | null = null;
	let created = false;
	try {
		if (existsSync(destPath)) throw new Error(`Already exists in internal storage: ${destPath}`);
		mkdirSync(INTERNAL_BACKUP_DIR, { recursive: true });
		if (backup.isCompressed) {
			tmpDir = join(INTERNAL_BACKUP_DIR, `.tmp-${Date.now()}`);
			mkdirSync(tmpDir, { recursive: true });
			await extractArchive(backup.path, tmpDir);
			const extracted = readdirSync(tmpDir)[0];
			if (!extracted) throw new Error(`Archive is empty: ${backup.path}`);
			created = true;
			cpSync(join(tmpDir, extracted), destPath, { recursive: true });
		} else {
			created = true;
			cpSync(backup.path, destPath, { recursive: true });
		}
		created = false; // complete
		return { success: true, output: `Copied to ${destPath}` };
	} catch (e: any) {
		if (created) rmSync(destPath, { recursive: true, force: true });
		return { success: false, output: describeExecError(e) };
	} finally {
		if (tmpDir) rmSync(tmpDir, { recursive: true, force: true });
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

/** Show a working status while a long task runs, when the host supports it. */
async function withStatus<T>(ctx: any, message: string, task: () => Promise<T>): Promise<T> {
	const setStatus = typeof ctx?.ui?.setStatus === "function" ? ctx.ui.setStatus.bind(ctx.ui) : null;
	setStatus?.("pi-backup", message);
	try {
		return await task();
	} finally {
		setStatus?.("pi-backup", undefined);
	}
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
		const settings = readSettingsForDisplay(ctx);
		const explicitlyConfigured = process.env.BACKUP_ROOT || settings.externalBackupDir;
		const defaultHasContent = existsSync(externalDir) && readdirSync(externalDir).length > 0;
		if (!explicitlyConfigured && !defaultHasContent) {
			const configured = await promptForExternalBackupDir(ctx);
			if (!configured) return;
		}
	}

	ctx.ui.notify(`Creating ${internal ? "internal" : "external"} backup...`, "info");
	const result = await withStatus(ctx, `Creating ${internal ? "internal" : "external"} backup…`, () => runBackup(internal, ctx));
	if (result.success) {
		const credentials = "\n⚠️  The backup contains auth.json (API credentials). Keep it private.";
		ctx.ui.notify(`Backup created successfully${result.backupPath ? `\n${result.backupPath}` : ""}${credentials}`, "info");
	} else {
		ctx.ui.notify(`Backup failed:\n${result.output}`, "error");
	}
}

/** Unique, exact-match labels for the backup list (never substring-match names). */
function buildLabels(backups: BackupInfo[]): Map<string, BackupInfo> {
	const labels = new Map<string, BackupInfo>();
	for (const b of backups) {
		const base = formatBackupLine(b);
		let label = base;
		for (let n = 2; labels.has(label); n++) label = `${base}  (${b.location} #${n})`;
		labels.set(label, b);
	}
	return labels;
}

async function showBackupList(ctx: any) {
	let backups = discoverBackups(ctx);
	if (backups.length === 0) {
		ctx.ui.notify("No backups found", "info");
		return;
	}

	while (true) {
		const labels = buildLabels(backups);
		const lines = [...labels.keys()];
		lines.push("🔄 Refresh");
		lines.push("← Back");

		const selected = await ctx.ui.select(`Backups (${backups.length} total)`, lines);
		if (!selected || selected.startsWith("←")) return;
		if (selected.startsWith("🔄")) { backups = discoverBackups(ctx); continue; }

		const backup = labels.get(selected);
		if (!backup) continue;

		await showBackupActions(ctx, backup);
		backups = discoverBackups(ctx);
		if (backups.length === 0) return;
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
		const result = await withStatus(ctx, "Copying backup…", () => copyBackupToInternal(backup));
		ctx.ui.notify(result.success ? result.output : `Failed: ${result.output}`, result.success ? "info" : "error");
	} else if (choice.startsWith("📄")) await viewManifest(ctx, backup);
	else if (choice.startsWith("🗑️")) await confirmDelete(ctx, backup);
}

async function confirmRestore(ctx: any, backup: BackupInfo) {
	// Restore replaces files that the running Pi process owns, so the TUI never runs it in-process.
	const confirmed = await ctx.ui.confirm(
		`Restore ${backup.name}?`,
		`⚠️  Restoring OVERWRITES all current Pi configuration.\n` +
		`Backup: ${formatTimestamp(backup.timestamp)} • ${backup.size} • ${backup.files} files\n\n` +
		`Pi cannot restore itself while running. Choosing Yes shows the command to run\n` +
		`AFTER you exit Pi (nothing is changed now).\n\n` +
		`Continue?`,
	);
	if (!confirmed) return;

	const command = buildRestoreCommand(backup.path);
	const copied = await copyToClipboard(command);
	ctx.ui.notify(
		`To restore, exit Pi, then run this in a terminal:\n\n${command}\n\n` +
		`${copied ? "(Copied to the clipboard.)\n" : ""}` +
		`Afterwards: cd ~/.pi/agent && npm install, then pi --version and /ctx-doctor.`,
		"info",
	);
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
	let content: string;
	if (backup.isCompressed) {
		mkdirSync(INTERNAL_BACKUP_DIR, { recursive: true });
		const tmpDir = join(INTERNAL_BACKUP_DIR, `.tmp-manifest-${Date.now()}`);
		mkdirSync(tmpDir, { recursive: true });
		try {
			await withStatus(ctx, "Reading manifest…", () => extractArchive(backup.path, tmpDir));
			const found = findFile(tmpDir, "MANIFEST.txt");
			if (!found) throw new Error("MANIFEST.txt not found in archive");
			content = readFileSync(found, "utf-8");
		} catch (e: any) {
			ctx.ui.notify(`Failed to extract manifest: ${describeExecError(e)}`, "error");
			return;
		} finally {
			rmSync(tmpDir, { recursive: true, force: true });
		}
	} else {
		const manifestPath = join(backup.path, "MANIFEST.txt");
		if (!existsSync(manifestPath)) {
			ctx.ui.notify("No manifest found in backup", "warning");
			return;
		}
		content = readFileSync(manifestPath, "utf-8");
	}

	await ctx.ui.editor(`MANIFEST — ${backup.name}`, content);
}

async function configureExternalDir(ctx: any) {
	const current = getExternalBackupDir(ctx);
	const source = process.env.BACKUP_ROOT ? "environment variable (BACKUP_ROOT)"
		: readSettingsForDisplay(ctx).externalBackupDir ? "settings.json"
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
		const saved = updateSettings((settings) => { delete settings.externalBackupDir; });
		if (!saved.ok) {
			ctx.ui.notify(`Could not reset external backup directory: ${saved.error}`, "error");
			return;
		}
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
- **Format**: Uncompressed directories only (fast access)

### 💾 External (${externalDir})
- **Purpose**: Disaster recovery
- **Survives**: Clean reinstall, disk failure (if copied elsewhere)
- **Does NOT survive**: Deleting the backup directory
- **Format**: Compressed archives (.7z/.zip)

## ⚠️ Credentials

Backups include \`auth.json\` (API keys / tokens) unless you set \`PI_BACKUP_EXCLUDE_AUTH=1\`.
Treat every backup as a secret: keep it private and never share or commit it.

## Configuration Priority

The external backup directory is resolved in this order:

1. **BACKUP_ROOT** environment variable (highest priority)
2. **settings.json** → \`externalBackupDir\` 
3. **Default**: \`~/pi-backups/\`

Use **⚙️ Configure external backup directory** in the main menu to change the settings.json value.
If settings.json is corrupt, it is never overwritten: defaults are used and you are told.

## When to Use Which

| Scenario | Recommended |
|----------|-------------|
| Before installing risky extension | Internal |
| Before changing config files | Internal |
| Before Pi update | Both |
| Before clean reinstall | **External (required)** |
| Moving to new machine | External |

## Restore Process

Pi cannot restore itself while it is running, so the TUI never restores in-process.

1. Select backup → Restore → confirm
2. The TUI shows (and copies, where possible) the exact command
3. **Exit Pi**, then run that command in a terminal
4. **After restore**: Run \`cd ~/.pi/agent && npm install\`
5. Verify: \`pi --version\`, \`/ctx-doctor\`

## Manual Backup/Restore

\`\`\`bash
# Create external backup (uses BACKUP_ROOT or default)
./backup-pi.sh

# Override backup location
BACKUP_ROOT=/mnt/backups ./backup-pi.sh

# Restore from external
./restore-pi.sh ~/pi-backups/pi-backup-20260811-143000

# Scripted restore (skip the prompt)
PI_BACKUP_ASSUME_YES=1 ./restore-pi.sh ~/pi-backups/pi-backup-20260811-143000
\`\`\`

## What Gets Backed Up

✅ settings.json, auth.json, models.json, trust.json, keybindings.json
✅ All extension configs (loop-police, context-mode, hermes-memory, etc.)
✅ Global skills (\`~/.pi/agent/skills/\`)
✅ Project skills & memory (\`~/.pi/agent/projects-memory/\`)
✅ Local extension source code (pi-timeout, pi-chunk, etc.)
✅ npm manifests (package.json, lockfiles)
✅ Hermes memory files (MEMORY.md, USER.md, failures.md)
✅ Memory database (sessions.db, snapshotted with sqlite3) and memory skills
✅ Extension state (missions, extensions, anti-stall, models-store, run-history)
✅ Recent hermes-cleanup backups

## Optional (set to 1 to include)

🔸 Session history (\`PI_BACKUP_INCLUDE_SESSIONS=1\`, large)
🔸 Cloned git packages (\`PI_BACKUP_INCLUDE_GIT=1\`)
🔸 Bundled binaries (\`PI_BACKUP_INCLUDE_BIN=1\`)

## What Does NOT Get Backed Up (Regeneratable)

❌ Sessions, unless \`PI_BACKUP_INCLUDE_SESSIONS=1\` (\`~/.pi/agent/sessions/\`)
❌ Context-mode KB (\`context-mode/kb.sqlite\`)
❌ node_modules/
❌ loop-police-detections.jsonl
❌ Lock files`;

	await ctx.ui.editor("Pi Backup Manager Help", help);
}
