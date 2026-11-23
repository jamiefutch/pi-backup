import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { setupSandbox, loadExtension, fakeCtx, runCommand } from "./helpers.mjs";

const box = setupSandbox();
const commands = await loadExtension();

const CORRUPT = '{ "externalBackupDir": "/old/path", ';

test("corrupt settings.json is left byte-identical by 'Change directory'", async () => {
	writeFileSync(box.settingsFile, CORRUPT);
	const ctx = fakeCtx({ selects: ["Configure", "Change directory"], inputs: ["/new/path"] });
	await runCommand(commands, ctx);
	assert.equal(readFileSync(box.settingsFile, "utf-8"), CORRUPT);
	assert.ok(ctx.notices.some((n) => n.level === "error" && /settings\.json/.test(n.message)), "user sees an error");
});

test("corrupt settings.json is left byte-identical by 'Reset to default'", async () => {
	writeFileSync(box.settingsFile, CORRUPT);
	const ctx = fakeCtx({ selects: ["Configure", "Reset to default"] });
	await runCommand(commands, ctx);
	assert.equal(readFileSync(box.settingsFile, "utf-8"), CORRUPT);
	assert.ok(ctx.notices.some((n) => n.level === "error" && /settings\.json/.test(n.message)), "user sees an error");
});

test("valid settings.json keeps its other keys when the directory changes", async () => {
	writeFileSync(box.settingsFile, JSON.stringify({ theme: "dark", packages: ["a"] }));
	const target = `${box.sandbox}/chosen`;
	const ctx = fakeCtx({ selects: ["Configure", "Change directory"], inputs: [target] });
	await runCommand(commands, ctx);
	const after = JSON.parse(readFileSync(box.settingsFile, "utf-8"));
	assert.equal(after.theme, "dark");
	assert.deepEqual(after.packages, ["a"]);
	assert.equal(after.externalBackupDir, target);
	assert.ok(!readdirSync(`${box.piRoot}/agent`).some((f) => f.includes(".tmp")), "no leftover temp file");
});

test("read-only paths degrade to the default and warn once on corrupt settings", async () => {
	writeFileSync(box.settingsFile, CORRUPT);
	const ctx = fakeCtx({ selects: [] }); // open menu, exit
	await runCommand(commands, ctx);
	assert.ok(ctx.selectTitles[0].includes("pi-backups"), "falls back to default external dir");
	assert.equal(ctx.notices.filter((n) => /settings\.json/.test(n.message)).length <= 1, true);
});

test.after(() => box.cleanup());
