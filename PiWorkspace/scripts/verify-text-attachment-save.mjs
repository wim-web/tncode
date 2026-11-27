import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { once } from "node:events";
import {
  appendFileSync, closeSync, existsSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, readdirSync,
  realpathSync, rmSync, unlinkSync, writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { userInfo } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const usage = "Usage: node verify-text-attachment-save.mjs --check|--foreground AX_BINARY [PI_WORKSPACE_APP]";
const [mode, driver, bundle = resolve(import.meta.dirname, "../dist/Pi Workspace.app"), extra] = process.argv.slice(2);
assert(["--check", "--foreground"].includes(mode) && driver && !extra, usage);
const appBundle = realpathSync(bundle);
const ax = realpathSync(driver);
const run = (program, args, options = {}) => execFileSync(program, args, {
  encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], timeout: 10_000, ...options,
}).trimEnd();
const sign = path => run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path], { timeout: 60_000 });
const workerPath = "Contents/Resources/Sidecar/worker.mjs";
const executablePath = "Contents/MacOS/PiWorkspace";
const preferences = join(userInfo().homedir, "Library/Preferences");
const sandbox = "/usr/bin/sandbox-exec";
// Block AppKit from persisting the native panel's recents and layout.
const sandboxArgs = ["-D", "PERSONAL_PREFERENCES=" + preferences, "-p", [
  "(version 1)", "(allow default)", "(deny user-preference-write)",
  '(deny file-write* (subpath (param "PERSONAL_PREFERENCES")))',
].join("\n")];

sign(appBundle);
assert(readFileSync(join(appBundle, workerPath), "utf8").includes('command.type === "readSentFile"'),
  "Build Pi Workspace at d37008c or later before running this verifier.");
assert(run(ax, ["--help"]).includes("save-fixture-file"), "Compile scripts/ax.swift from this checkout.");
const trust = run(ax, ["trust"]);
const sandboxCheck = spawnSync(sandbox, [...sandboxArgs, "/usr/bin/true"], { encoding: "utf8", timeout: 5_000 });
console.log(trust);
if (sandboxCheck.status !== 0) console.error(sandboxCheck.stderr?.trim() || "Could not apply the preference sandbox.");
assert.equal(sandboxCheck.status, 0, "Run from a macOS session that can apply the preference sandbox.");
assert.match(trust, /accessibility=true keyboard=true/, "The AX driver needs existing Accessibility and keyboard access.");
if (mode === "--check") {
  console.log("Signed attachment build, AX driver, and preference sandbox are ready.");
  process.exit(0);
}
assert.equal(run(ax, ["desktop-ready", "0"]), "ready", "The foreground run needs an unlocked macOS desktop.");

process.umask(0o077);
const root = mkdtempSync("/private/tmp/pi-text-attachments-");
const workspace = join(root, "workspace");
const project = join(root, "project");
const app = join(root, "Pi Workspace.app");
const executable = join(app, executablePath);
const index = join(workspace, "workspace.json");
const writer = join(root, "write-pasteboard");
const pasteboard = "dev.piworkspace.verification." + randomUUID();
const launchArgs = ["--workspace", workspace, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)"];
const appEnv = { ...process.env, PI_WORKSPACE_TEST_PASTEBOARD: pasteboard };
const uuid = () => randomUUID().toUpperCase();
const projectID = uuid(), threadID = uuid();
const caption = "Two local text attachments";
const reply = "Loopback attachment receipt.";
const model = "text-attachment-save-fixture";
const key = randomBytes(32).toString("hex");
const name = "same.txt";
const samples = [
  "\uFEFF  First 日本語 👩🏽‍💻 e\u0301\r\nLast line\n\n",
  "Second ελληνικά 🌸\r\n\n  Tail",
].map((text, i) => ({
  text, bytes: Buffer.from(text), path: join(root, "source-" + i, name),
}));
const digest = bytes => createHash("sha256").update(bytes).digest("hex");
let requestCount = 0, fixtureError, child, closed, launchNumber = 0, credentialAttempted = false, credentialArgs;
const server = createServer(async (request, response) => {
  try {
    assert.equal(++requestCount, 1, "Expected only the explicit submission to call the model.");
    assert.equal(request.method, "POST");
    assert.equal(request.url, "/v1/chat/completions");
    assert(request.headers.authorization === "Bearer " + key, "Unexpected fixture credential.");
    const body = await new Response(request).json();
    assert.equal(body.model, model);
    const users = body.messages.filter(message => message.role === "user");
    assert.equal(users.length, 1);
    assert(users[0].content.every(part => part.type === "text"));
    const expected = [caption, ...samples.map(({ text }) => 'Attached text file "same.txt":\n' + text)].join("\n\n");
    assert.equal(users[0].content.map(part => part.text).join(""), expected);
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const [delta, finish_reason] of [[{ role: "assistant", content: reply }, null], [{}, "stop"]]) {
      const chunk = {
        id: model, object: "chat.completion.chunk", created: 1, model,
        choices: [{ index: 0, delta, finish_reason }],
      };
      response.write("data: " + JSON.stringify(chunk) + "\n\n");
    }
    response.end("data: [DONE]\n\n");
  } catch (error) {
    fixtureError = error;
    response.writeHead(400).end();
  }
});

function record(message) {
  appendFileSync(join(root, "report.txt"), message + "\n");
  console.log(message);
}
const drive = (action, ...args) => run(ax, [action, String(child.pid), ...args]);
const value = id => drive("get", id, "--values", "--depth", "0");
const tree = () => drive("dump", "--values").split('  role="AXMenuBar"')[0];
const enabled = id => value(id).includes("enabled=true");
function has(id) {
  try { return Boolean(value(id)); }
  catch (error) {
    if (String(error.stderr).includes("No element has that identifier.")) return false;
    throw error;
  }
}
function press(id) {
  try { drive("press", id, "--no-activate"); }
  catch (error) {
    if (!/AX error -2520[045]/.test(String(error.stderr))) throw error;
  }
}
async function until(read, description) {
  const deadline = performance.now() + 20_000;
  let lastError;
  do {
    if (fixtureError) throw fixtureError;
    try {
      const value = read();
      if (value) return value;
    } catch (error) { lastError = error; }
    await delay(120);
  } while (performance.now() < deadline);
  throw new Error("Timed out waiting for " + description, { cause: lastError });
}
async function launch() {
  const log = openSync(join(root, "app-" + ++launchNumber + ".log"), "wx");
  child = spawn(sandbox, [...sandboxArgs, executable, ...launchArgs], {
    cwd: root, env: appEnv, stdio: ["ignore", log, log],
  });
  closeSync(log);
  let launchError;
  closed = once(child, "close").catch(error => { launchError = error; });
  await until(() => {
    if (launchError) throw launchError;
    assert(child.exitCode === null && child.signalCode === null, "The fixture app exited. See its log.");
    return has("composer");
  }, "the fixture app's composer");
  drive("activate");
}
async function quit() {
  press("terminate:");
  await until(() => child.exitCode === 0, "a clean fixture app quit");
  await closed;
  child = undefined;
}
function conversation() {
  const state = JSON.parse(readFileSync(index, "utf8"));
  assert.equal(state.selectedProject, projectID);
  const p = state.projects.find(p => p.id === projectID);
  assert.equal(p.selectedConversation, threadID);
  assert.equal(p.conversations.length, 1);
  return p.conversations[0];
}
function checkDraft(expected) {
  const draft = conversation();
  assert.equal(draft.id, threadID);
  assert.equal(draft.isDraft, true);
  assert.equal(draft.composerText, caption);
  const attachments = draft.composerAttachments ?? [];
  assert.equal(attachments.length, expected.length);
  assert.equal(new Set(attachments.map(file => file.id)).size, expected.length);
  for (const [i, { bytes, id }] of expected.entries()) {
    const file = attachments[i];
    assert(file.id && (!id || file.id === id));
    assert.equal(file.name, name);
    assert.equal(file.payload.mimeType, "text/plain");
    assert.deepEqual(Buffer.from(file.payload.data, "base64"), bytes);
  }
  return attachments;
}
async function attach(sample, expected) {
  run(writer, [pasteboard, "file", sample.path]);
  drive("type", "composer", "--replace");
  drive("key-focused", "composer", "9", "cmd", "--no-activate");
  const attachments = await until(() => checkDraft([...expected, sample]), "native file paste into the draft");
  return attachments.at(-1).id;
}
async function preview(sample, origin) {
  const id = (origin === "Draft" ? "preview-attachment-" : "sent-attachment-") + sample.id;
  await until(() => value(id).includes(name), "same-named attachment " + sample.id);
  press(id);
  await until(() => value("file-preview-contents").includes("value=" + JSON.stringify(sample.text)),
    "the exact UTF-8 preview of " + sample.id);
  assert(drive("get", "attachment-file-preview", "--values", "--depth", "5").includes(JSON.stringify(origin)));
  assert.equal(has("remove-file-preview"), origin === "Draft");
}
async function closePreview() {
  press("close-file-preview");
  await until(() => !has("attachment-file-preview"), "the preview to close");
}
async function exportFile(sample, control, cancel = false) {
  const directory = join(root, "export-" + randomUUID());
  const marker = basename(directory) + "-proof.txt";
  mkdirSync(directory);
  writeFileSync(join(directory, marker), "Unique Save panel destination proof.\n", { flag: "wx" });
  press(control);
  await until(() => has("save-panel"), "the real NSSavePanel");
  const proof = drive("save-fixture-file", workspace, directory, ...(cancel ? ["--cancel"] : []));
  const destination = join(directory, name);
  assert.equal(proof, "Verified Save panel destination: " + destination);
  record(proof);
  await until(() => !has("save-panel"), "the system Save panel to close");
  assert(!has("attachment-save-error"));
  if (cancel) {
    assert.deepEqual(readdirSync(directory), [marker]);
    record("Cancel closed the real Save panel without creating a file.");
  } else {
    await until(() => existsSync(destination), "the saved file");
    assert(lstatSync(destination).isFile());
    assert.equal(realpathSync(destination), destination);
    assert.deepEqual(readFileSync(destination), sample.bytes);
    assert.deepEqual(readdirSync(directory).sort(), [marker, name].sort());
    record("Saved " + sample.id + " with SHA-256 " + digest(sample.bytes));
  }
  unlinkSync(join(directory, marker));
  return directory;
}
function checkHistory() {
  const folder = join(workspace, "sessions", projectID, threadID);
  const sessions = readdirSync(folder).filter(path => path.endsWith(".jsonl"));
  assert.equal(sessions.length, 1);
  const records = readFileSync(join(folder, sessions[0]), "utf8").trimEnd().split("\n").map(line => JSON.parse(line));
  const userMessages = records.filter(record => record.message?.role === "user");
  assert.equal(userMessages.length, 1);
  const receipt = userMessages[0].message.workspaceInput;
  assert.equal(receipt.text, caption);
  assert.deepEqual(receipt.attachments.map(file => [file.id, file.name, Buffer.from(file.textData, "base64")]),
    samples.map(sample => [sample.id, name, sample.bytes]));
}

try {
  record("Private fixture and evidence: " + root);
  run("/usr/bin/ditto", [appBundle, app], { timeout: 60_000 });
  sign(app);
  const signature = spawnSync("/usr/bin/codesign", ["-d", "--verbose=4", app], { encoding: "utf8" });
  assert.equal(signature.status, 0);
  record(signature.stderr.match(/^CDHash=[0-9a-f]+$/m)[0]);
  run("/usr/bin/swiftc", ["-module-cache-path", join(root, "module-cache"),
    join(import.meta.dirname, "fixtures/write-pasteboard.swift"), "-o", writer], { timeout: 60_000 });
  rmSync(join(root, "module-cache"), { recursive: true, force: true });
  for (const path of [workspace, project, ...samples.map(sample => dirname(sample.path))]) mkdirSync(path);
  for (const sample of samples) writeFileSync(sample.path, sample.bytes, { flag: "wx" });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const endpoint = "http://127.0.0.1:" + server.address().port + "/v1";
  const standardizedWorkspace = run(ax, ["workspace-path", workspace]);
  credentialArgs = ["-s", "dev.piworkspace.model-key." + digest(standardizedWorkspace), "-a", "local:" + endpoint];
  writeFileSync(index, JSON.stringify({
    welcomeCompleted: true, selectedProject: projectID, model: { provider: "local", model, endpoint, contextWindow: 8192 },
    projects: [{ id: projectID, path: project, title: "UTF-8 fixture", allowEdits: false, selectedConversation: threadID,
      conversations: [{ id: threadID, title: "UTF-8 attachments", archived: false, isDraft: true, composerText: caption }],
    }],
  }));
  credentialAttempted = true;
  run(sandbox, [...sandboxArgs, executable, "--workspace", workspace, "--set-api-key-from-stdin"], { input: key, env: appEnv });

  await launch();
  samples[0].id = await attach(samples[0], []);
  samples[1].id = await attach(samples[1], [samples[0]]);
  const removed = samples[1].id;
  await preview(samples[1], "Draft");
  press("remove-file-preview");
  await until(() => checkDraft([samples[0]]) && !has("attachment-file-preview") &&
    !has("preview-attachment-" + removed), "removal of only the selected attachment");
  samples[1].id = await attach(samples[1], [samples[0]]);
  assert.notEqual(samples[1].id, removed);
  await quit();
  for (const sample of samples) unlinkSync(sample.path);
  checkDraft(samples);
  assert.equal(requestCount, 0);
  record("Removed one same-named attachment in the preview. The other ID and bytes survived. Both source files were deleted after the draft was saved.");

  await launch();
  for (const sample of samples) {
    await preview(sample, "Draft");
    if (sample === samples[0]) await exportFile(sample, "save-file-preview");
    await closePreview();
  }
  checkDraft(samples);
  await until(() => enabled("send-message"), "an enabled Send button");
  press("send-message");
  await until(() => requestCount === 1 && samples.every(sample => has("sent-attachment-" + sample.id)) &&
    tree().includes(reply) && conversation().isDraft === false, "one submitted turn and the loopback reply");
  await quit();
  checkHistory();

  await launch();
  await until(() => samples.every(sample => has("sent-attachment-" + sample.id)) && tree().includes(reply),
    "the submitted attachments and reply after reopening Pi history");
  assert(samples.every(sample => !existsSync(sample.path)));
  await preview(samples[0], "Sent");
  await closePreview();
  const canceled = await exportFile(samples[0], "download-sent-attachment-" + samples[0].id, true);
  await exportFile(samples[0], "download-sent-attachment-" + samples[0].id);
  await preview(samples[1], "Sent");
  await exportFile(samples[1], "save-file-preview");
  await closePreview();
  await quit();
  checkHistory();
  assert.deepEqual(readdirSync(canceled), []);
  assert.equal(requestCount, 1);
  record("PASS: reopened draft and Pi history preserved both UTF-8 payloads. Native Cancel and all three exports passed.");
} catch (error) {
  if (child?.pid && child.exitCode === null) {
    try { writeFileSync(join(root, "failure-ui.txt"), tree()); } catch {}
  }
  throw error;
} finally {
  if (child?.pid && child.exitCode === null && child.signalCode === null) child.kill();
  await closed;
  server.close();
  server.closeAllConnections();
  try {
    if (credentialAttempted) {
      const remove = spawnSync("/usr/bin/security", ["delete-generic-password", ...credentialArgs], { stdio: "ignore" });
      assert([0, 44].includes(remove.status), "Could not remove the synthetic fixture credential.");
      const check = spawnSync("/usr/bin/security", ["find-generic-password", ...credentialArgs], { stdio: "ignore" });
      assert.equal(check.status, 44, "The synthetic fixture credential still exists.");
    }
  } finally {
    try { run(ax, ["release-test-pasteboard", pasteboard]); }
    finally { rmSync(app, { recursive: true, force: true }); }
  }
}
