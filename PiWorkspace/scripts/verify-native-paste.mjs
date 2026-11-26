#!/usr/bin/env node
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { closeSync, mkdirSync, mkdtempSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { images } from "./fixtures/attachments.mjs";

const [ax, app = resolve(import.meta.dirname, "../dist/Pi Workspace.app")] = process.argv.slice(2);
assert(ax, "Usage: verify-native-paste.mjs AX_BINARY [PI_WORKSPACE_APP]");
execFileSync("codesign", ["--verify", "--deep", "--strict", app]);
assert.match(execFileSync(ax, ["trust"], { encoding: "utf8" }), /accessibility=true keyboard=true/);

const root = mkdtempSync("/private/tmp/pi-native-paste-");
const workspace = join(root, "workspace"), project = join(root, "Project");
mkdirSync(workspace);
mkdirSync(project);
const indexPath = join(workspace, "workspace.json");
const board = "dev.piworkspace.verification." + randomUUID();
const writer = join(root, "write-pasteboard");
execFileSync("xcrun", ["swiftc", resolve(import.meta.dirname, "fixtures/write-pasteboard.swift"), "-o", writer]);
const uuid = () => randomUUID().toUpperCase();
const projectID = uuid(), active = uuid(), other = uuid();
const seed = "Keep this draft 🌸";
const otherRow = { id: other, title: "Other", archived: false, isDraft: true, composerText: "Keep the other row" };
writeFileSync(indexPath, JSON.stringify({
  projects: [{ id: projectID, path: project, title: "Paste fixture", allowEdits: false, selectedConversation: active,
    conversations: [{ id: active, title: "Active", archived: false, isDraft: true, composerText: seed }, otherRow] }],
  selectedProject: projectID, welcomeCompleted: true,
  model: { provider: "OpenAI", model: "gpt-5-mini", endpoint: "http://127.0.0.1:11434/v1", contextWindow: 8192 },
}));
const log = openSync(join(root, "app.log"), "wx", 0o600);
const child = spawn(resolve(app, "Contents/MacOS/PiWorkspace"), [
  "--workspace", workspace, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)",
], { stdio: ["ignore", log, log], env: { ...process.env, PI_WORKSPACE_TEST_PASTEBOARD: board } });
closeSync(log);
let launchError;
const closed = once(child, "close").catch(error => { launchError = error; });
console.log("Native paste fixture " + root + ", PID " + child.pid);

function drive(action, args, input) {
  return execFileSync(ax, [action, String(child.pid), ...args], { encoding: "utf8", input, timeout: 8000 });
}
async function until(check, message) {
  const deadline = Date.now() + 30_000;
  let last;
  while (Date.now() < deadline) {
    if (launchError) throw launchError;
    assert(child.exitCode === null && child.signalCode === null, "The fixture process exited.");
    try { if (check()) return; } catch (error) { last = error; }
    await delay(150);
  }
  throw new Error("Timed out waiting for " + message, { cause: last });
}
const focus = () => drive("type", ["composer", "--replace"], "");
const focused = () => /focused=true/.test(drive("get", ["composer"]));
function commandKey(code) {
  drive("key-focused", ["composer", String(code), "cmd"]);
}
function menu(title) {
  assert(focused(), "The composer must own focus before Edit > " + title);
  drive("menu-item", [title]);
}
let savedIDs = [];
async function expectDraft(text, attachments, message) {
  await until(() => {
    const state = JSON.parse(readFileSync(indexPath, "utf8"));
    const p = state.projects.find(p => p.id === state.selectedProject);
    assert.equal(p.selectedConversation, active);
    assert.equal(p.conversations.length, 2);
    assert.deepEqual(p.conversations.find(t => t.id === other), otherRow);
    const draft = p.conversations.find(t => t.id === active);
    const files = draft.composerAttachments ?? [];
    if (draft.composerText !== text || files.length !== attachments.length) return false;
    assert.deepEqual(files.map(({ name, payload }) => [name, payload.mimeType, payload.data]), attachments);
    const ids = files.map(a => a.id);
    assert(ids.every(Boolean));
    assert.equal(new Set(ids).size, ids.length);
    assert.deepEqual(ids.slice(0, savedIDs.length), savedIDs);
    savedIDs = ids;
    return true;
  }, message);
  console.log(message);
}

try {
  await until(() => { focus(); return focused(); }, "the selected draft's composer");
  const unit = "日本語 with spaces 🌸\n";
  const size = 32 * 1024;
  const repeated = unit.repeat(Math.floor(size / Buffer.byteLength(unit)));
  const boundary = repeated + "x".repeat(size - Buffer.byteLength(repeated));
  const textAttachment = ["pasted-text.txt", "text/plain", Buffer.from(boundary).toString("base64")];
  const pngAttachment = ["Pasted Image.png", "image/png", images.red];

  execFileSync(writer, [board, "text"], { input: boundary });
  commandKey(9);
  await expectDraft(seed, [textAttachment], "Cmd-V attached exactly 32,768 UTF-8 bytes and preserved the seed.");

  // Select the seed for inline replacement. Paste and Match Style must bypass the attachment rule.
  focus();
  menu("Paste and Match Style");
  await expectDraft(boundary, [textAttachment], "Edit > Paste and Match Style restored the same bytes inline.");
  commandKey(6);
  await expectDraft(seed, [textAttachment], "Undo restored the seeded draft and kept its original attachment.");

  const overFileLimit = boundary + boundary + "x";
  execFileSync(writer, [board, "text"], { input: overFileLimit });
  focus();
  menu("Paste");
  await expectDraft(overFileLimit, [textAttachment], "Edit > Paste fell back inline at 65,537 bytes.");
  commandKey(6);
  await expectDraft(seed, [textAttachment], "Undo restored the draft after automatic inline fallback.");

  const alternative = "Plain text for the red image";
  execFileSync(writer, [board, "png", alternative], { input: Buffer.from(images.red, "base64") });
  commandKey(9);
  await expectDraft(seed, [textAttachment, pngAttachment], "Cmd-V chose the small PNG over its text alternative.");
  focus();
  menu("Paste and Match Style");
  await expectDraft(alternative, [textAttachment, pngAttachment], "The explicit inline paste chose the PNG's text alternative.");
  commandKey(6);
  await expectDraft(seed, [textAttachment, pngAttachment], "Both files, the seed, and the other row survived.");
} finally {
  if (child.pid && child.exitCode === null && child.signalCode === null) child.kill();
  await closed;
  execFileSync(ax, ["release-test-pasteboard", board]);
}
