import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { closeSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { images } from "./fixtures/attachments.mjs";
import { requireDedicatedDesktop } from "./fixtures/desktop-session.mjs";

requireDedicatedDesktop();

const [ax, app = resolve(import.meta.dirname, "../dist/tncode.app")] = process.argv.slice(2);
assert(ax, "Usage: node scripts/verify-file-drops.mjs AX_BINARY [TNCODE_APP]");
assert.match(execFileSync(ax, ["trust"], { encoding: "utf8" }), /accessibility=true keyboard=true/,
             "The drag verifier needs Accessibility and event posting access in this desktop session.");

const root = mkdtempSync("/private/tmp/pi-drag-");
const workspace = join(root, "workspace");
const project = join(root, "Fixture Project");
const folder = join(root, "Dropped Project");
for (const path of [workspace, project, folder]) mkdirSync(path, { mode: 0o700 });
for (const [color, png] of Object.entries(images)) {
  writeFileSync(join(root, color + ".png"), Buffer.from(png, "base64"), { flag: "wx", mode: 0o600 });
}
console.log("File drop fixture: " + root);

const log = openSync(join(root, "app.log"), "wx", 0o600);
const child = spawn(resolve(app, "Contents/MacOS/tncode"), [
  "--workspace", workspace, "--project", project, "-ApplePersistenceIgnoreState", "YES",
], { stdio: ["ignore", log, log] });
let launchError;
const closed = once(child, "close").catch(error => { launchError = error; });
closeSync(log);

function drive(operation, args = [], input) {
  if (launchError) throw launchError;
  assert(child.pid && child.exitCode === null && child.signalCode === null, "The fixture app exited.");
  return execFileSync(ax, [operation, String(child.pid), ...args], {
    input, encoding: "utf8", timeout: operation === "drop-fixture" ? 15_000 : 5_000, stdio: ["pipe", "pipe", "pipe"],
  });
}

async function until(check, description, timeout = 10_000) {
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    if (launchError) throw launchError;
    try {
      const result = check();
      if (result) return result;
    } catch (error) { lastError = error; }
    await delay(100);
  }
  throw new Error("Timed out waiting for " + description, { cause: lastError });
}

const index = () => JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
const projectState = () => index().projects.find(p => realpathSync(p.path) === project);
const row = id => "thread-row-" + id;
const visible = id => drive("get", [id]);
const press = id => drive("press", [id]);
function drop(id, path) {
  drive("activate");
  console.log(drive("drop-fixture", [workspace, "workspace", id, path]).trim());
}

function assertDrafts(expected) {
  const withAttachments = index().projects.flatMap(p => p.conversations)
    .filter(thread => thread.composerAttachments?.length);
  assert.equal(withAttachments.length, expected.size);
  for (const thread of withAttachments) {
    assert.equal(thread.isDraft, true);
    assert.equal(thread.composerAttachments.length, 1);
    const [attachment] = thread.composerAttachments;
    const fixture = expected.get(thread.id);
    assert(fixture, "The attachment belongs to a different draft.");
    const { color, text } = fixture;
    assert.equal(thread.composerText ?? "", text);
    assert(attachment.id, "The draft attachment must have an ID.");
    assert.equal(attachment.name, color + ".png");
    assert.deepEqual(attachment.payload, { mimeType: "image/png", data: images[color] });
  }
  return withAttachments;
}

try {
  await until(() => { drive("activate"); return visible("composer"); }, "the disposable composer");
  const other = projectState().selectedConversation;
  const marker = "Draft for the thread row";
  drive("type", ["composer", "--replace"], marker);
  await until(() => projectState().conversations.find(t => t.id === other)?.composerText === marker && visible(row(other)),
              "the seeded sidebar draft");
  press("new-conversation");
  const active = await until(() => {
    const id = projectState().selectedConversation;
    return id !== other && visible("composer") && id;
  }, "a different active draft");
  assertDrafts(new Map());

  drop("composer", join(root, "red.png"));
  const red = new Map([[active, { color: "red", text: "" }]]);
  const first = await until(() => {
    const draft = projectState().conversations.find(t => t.id === active);
    return (draft?.composerText || draft?.composerAttachments?.length) && draft;
  }, "the composer to handle the red PNG");
  assert.equal(first.composerText ?? "", "", "Dropping the PNG on the composer must not insert its path as text.");
  assertDrafts(red);
  assert.equal(projectState().selectedConversation, active);
  const redID = first.composerAttachments[0].id;
  await until(() => visible("preview-attachment-" + redID), "the red composer preview");

  drop(row(other), join(root, "blue.png"));
  const both = new Map([...red, [other, { color: "blue", text: marker }]]);
  const drafts = await until(() => assertDrafts(both), "red and blue PNGs in their respective drafts");
  const attachmentIDs = drafts => new Map(drafts.map(t => [t.id, t.composerAttachments[0].id]));
  const ids = attachmentIDs(drafts);
  const blueID = ids.get(other);
  assert.equal(ids.get(active), redID);
  assert.notEqual(blueID, redID);
  assert.equal(projectState().selectedConversation, other);
  await until(() => visible("preview-attachment-" + blueID), "the blue thread's composer preview");
  console.log("Both PNGs reached only their intended drafts with matching file bytes.");

  drop("open-project", folder);
  await until(() => {
    const state = index();
    return state.projects.length === 2 && state.projects.some(p => p.id === state.selectedProject && realpathSync(p.path) === folder);
  }, "the dropped folder registered and selected from the sidebar");
  assert.deepEqual(attachmentIDs(assertDrafts(both)), ids);
  console.log("The folder drop registered and selected its own project. Both attachment drafts survived.");
} finally {
  if (child.pid && child.exitCode === null && child.signalCode === null) {
    try { press("terminate:"); } catch { /* AX can disconnect during quit. */ }
    try { await until(() => child.exitCode !== null || child.signalCode !== null, "fixture app exit"); }
    catch {
      child.kill();
      try { await until(() => child.exitCode !== null || child.signalCode !== null, "fixture process termination", 2000); }
      catch { child.kill("SIGKILL"); }
    }
  }
  await closed;
}
