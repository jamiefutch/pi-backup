// Helpers for extension tests. Lives in tests/, NOT extensions/ (Pi would load anything in extensions/).
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, chmodSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(here, "..", "..");
export const EXTENSION_PATH = join(REPO_ROOT, "extensions", "pi-backup-manager.ts");

/** Create a sandbox and point every root the extension reads at it. Call BEFORE loadExtension(). */
export function setupSandbox() {
	const sandbox = realpathSync(mkdtempSync(join(tmpdir(), "pi-backup-ts-test.")));
	const home = join(sandbox, "home");
	const bin = join(sandbox, "bin");
	mkdirSync(join(home, ".pi", "agent"), { recursive: true });
	mkdirSync(join(sandbox, "tmp"), { recursive: true });
	mkdirSync(bin, { recursive: true });
	process.env.HOME = home;
	process.env.USERPROFILE = home;
	process.env.TMPDIR = join(sandbox, "tmp");
	process.env.TEMP = process.env.TMPDIR;
	process.env.TMP = process.env.TMPDIR;
	process.env.PI_BACKUP_NO_CLIPBOARD = "1";
	delete process.env.BACKUP_ROOT;
	process.env.PATH = `${bin}${process.platform === "win32" ? ";" : ":"}${process.env.PATH}`;
	for (const v of ["HOME", "TMPDIR"]) {
		if (!process.env[v].startsWith(sandbox)) throw new Error(`${v} escaped the sandbox`);
	}
	return {
		sandbox,
		home,
		bin,
		piRoot: join(home, ".pi"),
		settingsFile: join(home, ".pi", "agent", "settings.json"),
		internalDir: join(home, ".pi", "backups"),
		tmpDir: join(sandbox, "tmp"),
		cleanup: () => rmSync(sandbox, { recursive: true, force: true }),
	};
}

/** Write an executable stub script into the sandbox bin dir (POSIX only). */
export function writeStub(box, name, body) {
	const p = join(box.bin, name);
	writeFileSync(p, `#!/bin/sh\n${body}\n`);
	chmodSync(p, 0o755);
	return p;
}

/** Import the extension fresh and capture the registered command. */
export async function loadExtension() {
	const mod = await import(pathToFileURL(EXTENSION_PATH).href + `?t=${Date.now()}${Math.random()}`);
	const commands = {};
	mod.default({ registerCommand: (name, def) => { commands[name] = def; } });
	return commands;
}

/**
 * Scripted fake ctx. `selects` is a list of substrings; each ctx.ui.select call consumes one and
 * returns the first option containing it. When the list is exhausted select returns undefined (exit).
 */
export function fakeCtx({ selects = [], confirms = [], inputs = [] } = {}) {
	const notices = [];
	const editors = [];
	const selectTitles = [];
	const selectOptions = [];
	const ctx = {
		mode: "tui",
		notices,
		editors,
		selectTitles,
		selectOptions,
		ui: {
			notify: (message, level) => { notices.push({ message, level }); },
			select: async (title, options) => {
				selectTitles.push(title);
				selectOptions.push(options);
				const want = selects.shift();
				if (want === undefined) return undefined;
				const hit = options.find((o) => o.includes(want));
				if (!hit) throw new Error(`no option containing [${want}] in: ${JSON.stringify(options)}`);
				return hit;
			},
			confirm: async () => (confirms.length ? confirms.shift() : false),
			input: async () => (inputs.length ? inputs.shift() : undefined),
			editor: async (title, content) => { editors.push({ title, content }); },
		},
	};
	return ctx;
}

export async function runCommand(commands, ctx) {
	await commands["pi-backup"].handler("", ctx);
}
