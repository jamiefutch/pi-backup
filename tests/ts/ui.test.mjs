import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { setupSandbox, writeStub, loadExtension, fakeCtx, runCommand, EXTENSION_PATH } from "./helpers.mjs";
import { pathToFileURL } from "node:url";

const box = setupSandbox();
const isWindows = process.platform === "win32";
const skipOnWindows = isWindows ? { skip: "uses POSIX stub scripts" } : {};

// External dir with a space in its path, to exercise quoting.
const externalDir = join(box.sandbox, "ext dir");
process.env.BACKUP_ROOT = externalDir;
mkdirSync(externalDir, { recursive: true });

const scriptDir = join(box.sandbox, "scripts");
mkdirSync(scriptDir, { recursive: true });
process.env.PI_BACKUP_SCRIPT_DIR = scriptDir;
const marker = join(box.sandbox, "restore-ran");

const commands = await loadExtension();
const TS = "20260101-000000";

test("loading the extension writes nothing to stderr", async () => {
	const writes = [];
	const origWrite = process.stderr.write.bind(process.stderr);
	const origErr = console.error;
	process.stderr.write = (chunk, ...rest) => { writes.push(String(chunk)); return true; };
	console.error = (...a) => writes.push(a.join(" "));
	try {
		await import(pathToFileURL(EXTENSION_PATH).href + `?load=${Math.random()}`).then((m) => m.default({ registerCommand() {} }));
	} finally {
		process.stderr.write = origWrite;
		console.error = origErr;
	}
	assert.deepEqual(writes, []);
});

test("restore never spawns anything; it shows a correctly quoted command", skipOnWindows, async () => {
	writeStub({ bin: scriptDir }, "restore-pi.sh", `touch '${marker}'`);
	const bk = join(externalDir, `pi-backup-${TS}`);
	mkdirSync(bk, { recursive: true });
	writeFileSync(join(bk, "settings.json"), "{}");
	const ctx = fakeCtx({ selects: ["List all", `pi-backup-${TS}`, "Restore this backup"], confirms: [true] });
	await runCommand(commands, ctx);
	assert.equal(existsSync(marker), false, "restore script must not run");
	const msg = ctx.notices.map((n) => n.message).join("\n");
	assert.match(msg, /exit Pi/i);
	assert.ok(msg.includes("PI_BACKUP_ASSUME_YES=1"));
	assert.ok(msg.includes(`'${join(scriptDir, "restore-pi.sh")}' '${bk}'`), `quoted paths with spaces in: ${msg}`);
});

test("declining the restore confirmation shows no command", skipOnWindows, async () => {
	const ctx = fakeCtx({ selects: ["List all", `pi-backup-${TS}`, "Restore this backup"], confirms: [false] });
	await runCommand(commands, ctx);
	assert.equal(ctx.notices.filter((n) => /restore, exit Pi/i.test(n.message)).length, 0);
});

test("list selection matches exactly: a .7z is not confused with a same-timestamp directory", async () => {
	mkdirSync(box.internalDir, { recursive: true });
	mkdirSync(join(box.internalDir, `pi-backup-${TS}`), { recursive: true });
	writeFileSync(join(externalDir, `pi-backup-${TS}.7z`), "not really an archive");
	const ctx = fakeCtx({ selects: ["List all", `pi-backup-${TS}.7z`] });
	await runCommand(commands, ctx);
	assert.ok(ctx.selectTitles.includes(`Backup: pi-backup-${TS}.7z`), `titles: ${JSON.stringify(ctx.selectTitles)}`);
	const ctxDir = fakeCtx({ selects: ["List all", "📁 pi-backup-" + TS] });
	await runCommand(commands, ctxDir);
	assert.ok(ctxDir.selectTitles.includes(`Backup: pi-backup-${TS}`), `titles: ${JSON.stringify(ctxDir.selectTitles)}`);
});

test("a corrupt archive leaves no temp dirs or partial copy (copy to internal, view manifest)", async () => {
	const name = `pi-backup-20260202-000000.zip`;
	writeFileSync(join(externalDir, name), "garbage, not a zip");
	const copy = fakeCtx({ selects: ["List all", name, "Copy to internal"] });
	await runCommand(commands, copy);
	assert.ok(copy.notices.some((n) => n.level === "error"), "copy failure reported");
	const view = fakeCtx({ selects: ["List all", name, "View manifest"] });
	await runCommand(commands, view);
	assert.ok(view.notices.some((n) => n.level === "error"), "manifest failure reported");
	const leftovers = readdirSync(box.internalDir).filter((f) => f.startsWith(".tmp") || f === name.replace(/\.zip$/, ""));
	assert.deepEqual(leftovers, []);
});

test("backups run without blocking the event loop", skipOnWindows, async () => {
	writeStub({ bin: scriptDir }, "backup-pi.sh", `sleep 0.6\necho "Staging:  ${box.internalDir}/pi-backup-x"`);
	let ticks = 0;
	const timer = setInterval(() => { ticks++; }, 20);
	const ctx = fakeCtx({ selects: ["Create internal backup"] });
	await runCommand(commands, ctx);
	clearInterval(timer);
	assert.ok(ctx.notices.some((n) => /Backup created/.test(n.message)), JSON.stringify(ctx.notices));
	assert.ok(ticks >= 10, `event loop ticked only ${ticks} times during the backup`);
});

test.after(() => box.cleanup());
