import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { once } from "node:events";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, renameSync, rmdirSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { resetProjectModel, setProjectModel, verifyPRFilesCheckout, verifyPreview, verifyPullRequests } from "./verify-panels.mjs";
import { restoreAppearance, verifyAbout, verifyAppearance, verifySettingsSearch } from "./verify-settings-panels.mjs";
import { verifyFiles } from "./verify-workspace-files.mjs";
import { verifyQueue } from "./verify-message-queue.mjs";
import { verifyCommandPalette, verifyPaletteMessage } from "./verify-command-palette.mjs";
import { closeTerminalPane, verifyInteractiveShell, verifyTerminalPanes } from "./verify-terminal-panes.mjs";
import { verifyFork, verifyInterruptedReply } from "./verify-fork-ui.mjs";
import { verifyAttachmentUI } from "./verify-attachment-ui.mjs";
import { linkFixturePullRequest, verifyLinkOnlyDraftMove, verifyRestoredLink } from "./verify-linked-prs.mjs";
import { verifyProjectClone } from "./verify-project-clone.mjs";
import { createUsageFixture } from "./fixtures/usage.mjs";
import { verifyUsage } from "./verify-usage-ui.mjs";
import { createWorkspaceControlsFixture, setWorktreeLocation, verifyWorkspaceControls } from "./verify-workspace-controls.mjs";
import { verifyConversationControls } from "./verify-conversation-controls.mjs";
import { verifyDraftProjects } from "./verify-draft-project-chooser.mjs";
import { verifyWorktreeBases } from "./verify-worktree-bases.mjs";
import { verifyThreadActions } from "./verify-thread-actions.mjs";
import { verifySidebarPersistence } from "./verify-sidebar-persistence.mjs";
import { verifyChatImages } from "./verify-chat-images.mjs";
import { verifyProjectSettings } from "./verify-project-settings.mjs";
import { verifyThreadSnooze } from "./verify-thread-snooze.mjs";
import { verifyNewThreadRoutes, verifyStartupRetry } from "./verify-new-thread-routes.mjs";
import { verifyStartupRecovery } from "./verify-startup-recovery.mjs";
import { verifyRightTerminal } from "./verify-right-terminal.mjs";
import { verifyInheritedAccount, verifyModelAccount } from "./verify-model-account.mjs";
import { verifyLocalChanges } from "./verify-local-changes.mjs";
import { verifySideChatPanel } from "./verify-side-chat-panel.mjs";

const packagedApp = process.env.PI_WORKSPACE_VERIFY_APP
  ? resolve(process.env.PI_WORKSPACE_VERIFY_APP)
  : resolve(import.meta.dirname, "../dist/Pi Workspace.app");
let app = packagedApp;
let testBundleDirectory;
const ax = process.argv[2];
assert(ax, "Pass the path to the macOS AX driver.");
const backgroundChecks = ["--startup-draft-only", "--recovery-actions-only", "--pr-files-only", "--right-terminal-only",
  "--model-account-only", "--local-changes-only", "--side-chat-only"];
const backgroundScenario = process.argv.slice(3).find(flag => backgroundChecks.includes(flag));
if (backgroundScenario) assert.equal(process.argv.length, 4, "Run a background scenario on its own.");
assert.match(execFileSync(ax, ["trust"], { encoding: "utf8" }), backgroundScenario ? /accessibility=true/ : /accessibility=true keyboard=true/);
const minimumIdle = Number(process.env.PI_WORKSPACE_VERIFY_IDLE_SECONDS ?? 0);
assert(Number.isFinite(minimumIdle) && minimumIdle >= 0);

const workspacePath = path => execFileSync(ax, ["workspace-path", path], { encoding: "utf8" }).trimEnd();
const directory = workspacePath(mkdtempSync("/private/tmp/pi-workspace-verification-"));
assert.equal(spawnSync("/usr/bin/git", ["-C", directory, "rev-parse", "--show-toplevel"], { stdio: "ignore" }).status, 128,
             "The disposable fixture must start outside an existing Git checkout.");
const reportDirectory = mkdtempSync(resolve(import.meta.dirname, "../dist/verification-"));
symlinkSync(directory, join(reportDirectory, "fixture"), "dir");
const project = join(directory, "Sample Project");
const worktreeTest = process.argv.includes("--worktree");
const basesOnly = process.argv.includes("--worktree-bases-only");
const imagesOnly = process.argv.includes("--image-preview-only");
const projectFlowsOnly = process.argv.includes("--project-flows-only") || basesOnly;
const fixtureModel = process.argv.includes("--fixture-model") || projectFlowsOnly || imagesOnly;
const terminalFixture = join(directory, "verification-shell");
const workspace = join(directory, "workspace");
const customWorktrees = join(directory, "Custom Worktrees");
const forgeState = join(directory, "forge-state");
const forgeLog = join(directory, "forge-calls.log");
const pasteboard = "dev.piworkspace.verification." + randomBytes(16).toString("hex");
const logs = join(reportDirectory, "logs");
const report = join(logs, "report.txt");
for (const path of [project, workspace, logs]) mkdirSync(path, { mode: 0o700 });
const secret = randomBytes(32).toString("hex");
const expected = Buffer.from("Bearer " + secret);
const firstPrompt = fixtureModel ? "fixture stream" : "What is the capital of France? Answer in one short sentence.";
const secondPrompt = fixtureModel ? "fixture resume" : "What country did my first message mention? Name only the country.";
const targets = [];
let releaseFirst;
const firstPartialCanFinish = new Promise(resolve => { releaseFirst = resolve; });
let rejectNextRequest = false;
let holdForStop = false;
let nextQueueResponse;
let streamClosed = false;
let requestedWrite;
let rejected = 0;
let appPID;
let backgroundInput = Boolean(backgroundScenario);
let launchNumber = 0;
let keySaved = false;
let keyAccount;

function record(text) {
  assert(!text.includes(secret), "A verification message contained the API key.");
  appendFileSync(report, text + "\n", { mode: 0o600 });
  console.log(text);
}

function recordVerifiedBundle(bundle) {
  execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle]);
  const signature = spawnSync("/usr/bin/codesign", ["-d", "--verbose=4", bundle], { encoding: "utf8" });
  assert.equal(signature.status, 0);
  const codeDirectoryHash = signature.stderr.match(/^CDHash=([0-9a-f]+)$/m)?.[1];
  assert(codeDirectoryHash, "The bundle has no readable code directory hash.");
  const digest = file => createHash("sha256").update(readFileSync(file)).digest("hex");
  const sidecar = join(bundle, "Contents/Resources/Sidecar");
  const sdk = JSON.parse(readFileSync(join(sidecar, "node_modules/@earendil-works/pi-coding-agent/package.json"), "utf8"));
  writeFileSync(join(logs, "artifact.json"), JSON.stringify({
    verifiedAt: new Date().toISOString(), codeDirectoryHash,
    executableSHA256: digest(join(bundle, "Contents/MacOS/PiWorkspace")),
    workerSHA256: digest(join(sidecar, "worker.mjs")), piVersion: sdk.version,
    verifierSHA256: digest(import.meta.filename),
  }, null, 2) + "\n", { mode: 0o600, flag: "wx" });
}

function fixtureChunk(index, delta, finish_reason = null) {
  return "data: " + JSON.stringify({
    id: "fixture-" + index, object: "chat.completion.chunk", created: 1, model: "smollm2:135m",
    choices: [{ index: 0, delta, finish_reason }],
  }) + "\n\n";
}

function fixtureReply(index) {
  const json = (delta, reason) => fixtureChunk(index, delta, reason);
  const words = index === 0 ? ["Fixture stream started. ", "Second delta. Fixture complete."] : ["Fixture resumed", "."];
  const body = json({ role: "assistant" }) + words.map(content => json({ content })).join("") +
    json({}, "stop") + "data: [DONE]\n\n";
  return new Response(body, { headers: { "Content-Type": "text/event-stream" } });
}

let previewDocument = 0;
const previewNetwork = { revision: 0, delayedRequests: 0, cancelledRequests: 0, releaseDelayed: false, recovered: false, queries: [] };
const server = createServer(async (request, response) => {
  if (request.method === "GET" && request.url.startsWith("/preview/search?")) {
    previewNetwork.queries.push(new URL(request.url, "http://localhost").searchParams.get("q"));
    response.writeHead(200, { "Content-Type": "text/html" }).end("<h1>Search arrived</h1>");
    return;
  }
  if (request.method === "GET" && request.url === "/preview/revision") {
    response.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "no-store" }).end(
      '<h1>Page revision ' + ++previewNetwork.revision + '</h1><button id="zoom-marker" style="width:100px;height:32px">Zoom marker</button>');
    return;
  }
  if (request.method === "GET" && request.url === "/preview/delayed") {
    previewNetwork.delayedRequests++;
    if (previewNetwork.releaseDelayed) response.writeHead(200, { "Content-Type": "text/html" }).end("<h1>Released page</h1>");
    else response.on("close", () => { previewNetwork.cancelledRequests++; });
    return;
  }
  if (request.method === "GET" && request.url === "/preview/unreachable") {
    if (previewNetwork.recovered) response.writeHead(200, { "Content-Type": "text/html" }).end("<h1>Server recovered</h1>");
    else request.socket.destroy();
    return;
  }
  if (request.method === "GET" && request.url === "/preview/profile") {
    response.writeHead(200, { "Content-Type": "text/html", "Cache-Control": "no-store" }).end(
      `<h1>Preview document ${++previewDocument}</h1><p id="visits"></p><script>
      const visits = Number(localStorage.getItem("visits") || 0) + 1;
      localStorage.setItem("visits", visits);
      document.querySelector("#visits").textContent = "Profile visit " + visits;
      </script>`);
    return;
  }
  if (request.method === "GET" && ["/preview/one", "/preview/two"].includes(request.url)) {
    const label = "Local preview " + request.url.split("/").at(-1);
    response.writeHead(200, { "Content-Type": "text/html" }).end("<title>" + label + "</title><h1>" + label + "</h1>");
    return;
  }
  const actual = Buffer.from(request.headers.authorization ?? "");
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    response.writeHead(401).end();
    return;
  }
  if (rejectNextRequest) {
    rejected++;
    response.writeHead(401, { "Content-Type": "application/json" }).end(JSON.stringify({
      error: { message: "Run check returned the API key: " + secret },
    }));
    return;
  }
  try {
    const body = await new Response(request).text();
    const target = { body: JSON.parse(body), fragments: [] };
    targets.push(target);
    if (nextQueueResponse) {
      const wait = nextQueueResponse;
      nextQueueResponse = undefined;
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.write(fixtureChunk(targets.length, { role: "assistant", content: "Queue fixture is waiting." }));
      await Promise.race([wait, once(response, "close")]);
      if (!response.destroyed) response.end(fixtureChunk(targets.length, {}, "stop") + "data: [DONE]\n\n");
      return;
    }
    if (requestedWrite && target.body.messages.at(-1)?.role === "user") {
      const call = { index: 0, id: "write-" + targets.length, type: "function",
        function: { name: "write", arguments: JSON.stringify({ path: requestedWrite, content: "Approved fixture write.\n" }) } };
      response.writeHead(200, { "Content-Type": "text/event-stream" }).end(
        fixtureChunk(targets.length, { role: "assistant", tool_calls: [call] }) +
        fixtureChunk(targets.length, {}, "tool_calls") + "data: [DONE]\n\n");
      return;
    }
    if (holdForStop) {
      response.on("close", () => { streamClosed = true; });
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.write(fixtureChunk(targets.length, { role: "assistant", content: "Partial reply before Stop." }));
      return;
    }
    const result = fixtureModel ? fixtureReply(targets.length - 1) : await fetch("http://127.0.0.1:18541/v1/chat/completions", {
      method: "POST", headers: { "Content-Type": "application/json" }, body,
      signal: AbortSignal.timeout(50_000),
    });
    target.status = result.status;
    response.writeHead(result.status, { "Content-Type": result.headers.get("content-type") });
    let pending = "";
    for await (const chunk of result.body.pipeThrough(new TextDecoderStream())) {
      pending += chunk;
      let end;
      while ((end = pending.indexOf("\n\n")) >= 0) {
        const frame = pending.slice(0, end + 2);
        pending = pending.slice(end + 2);
        response.write(frame);
        const item = frame.slice(6).trim();
        if (!item.startsWith("{")) continue;
        const fragment = JSON.parse(item).choices?.[0]?.delta?.content;
        if (fragment) target.fragments.push(fragment);
        if (targets[0] === target && target.fragments.length === 1 && fragment) {
          await firstPartialCanFinish;
        }
      }
    }
    response.end(pending);
    target.completed = true;
  } catch {
    response.destroy();
  }
});

function drive(operation, id, input) {
  return execFileSync(ax, [operation, String(appPID), ...id], {
    encoding: "utf8", input, timeout: ["select-folder", "select-path"].includes(operation) ? 15_000 : 5_000,
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function updateKey(argument, input, root = workspace) {
  execFileSync(join(app, "Contents/MacOS/PiWorkspace"), ["--workspace", root, argument], {
    input, timeout: 10_000, stdio: ["pipe", "pipe", "pipe"],
  });
}

const failedCredentialCleanup = new Set();
function removeFixtureCredential(root, account) {
  const service = "dev.piworkspace.model-key." + createHash("sha256").update(root).digest("hex");
  const args = ["-s", service, "-a", account];
  const remove = spawnSync("/usr/bin/security", ["delete-generic-password", ...args], { stdio: "ignore" });
  const check = spawnSync("/usr/bin/security", ["find-generic-password", ...args], { stdio: "ignore" });
  if ((remove.status !== 0 && remove.status !== 44) || check.status !== 44) failedCredentialCleanup.add(root);
}

async function until(check, label, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      const result = check();
      if (result) return result;
    } catch { /* wait for the UI element */ }
    await delay(120);
  }
  throw new Error("Timed out waiting for " + label);
}

const visible = (id) => drive("get", [id]);
const tree = () => drive("dump", ["--values"]).split("  role=\"AXMenuBar\"")[0];
const press = (id) => drive("press", backgroundInput ? [id, "--no-activate"] : [id]);
function pressDismissal(id) {
  try { press(id); }
  catch (error) { if (!/AX error -2520[045]/.test(String(error.stderr))) throw error; }
}
const panelDriver = {
  press, visible, tree, setField, until, closeSettings, openModelSettings: settings,
  activate: () => drive("activate", []),
  focus: id => {
    if (backgroundInput) assert(visible(id).includes("focused=true"), "The background field lacks focus: " + id);
    else drive("type", [id], "");
  },
  selection: (id, ...range) => drive("selection", [id, ...range.map(String)]).trim().split(/\s+/).map(Number),
  selectPath: path => drive("select-path", [path]),
  dismiss: pressDismissal,
  value: id => drive("get", [id, "--values"]),
  subtree: (id, depth) => drive("get", [id, "--values", "--depth", String(depth)]),
  selectedText: id => drive("selected-text", [id]),
  checkCopy: text => { execFileSync(ax, ["check-copy", pasteboard], { input: text, stdio: ["pipe", "pipe", "pipe"] }); return true; },
  checkImage: png => { execFileSync(ax, ["check-image", pasteboard], { input: Buffer.from(png, "base64"), stdio: "pipe" }); return true; },
  closeWindow: id => drive("close-window", [id]),
  sizeWindow: (width, height) => drive("size-window", ["workspace", String(width), String(height)]),
  menuItem: name => drive("menu-item", backgroundInput ? [name, "--no-activate"] : [name]),
  openThreadLink: link => drive("open-thread-link", [link]),
  escapeMenu: () => drive("key", ["53"]),
  showMenu: id => drive("show-menu", [id]),
  click: (id, ...flags) => drive("click", [id, ...flags]),
  pick: (id, title) => drive("pick", [id, title]),
  segment: (group, label) => drive("segment", [group, label]),
  key: code => drive("key-focused", ["browser-address", String(code)]),
  keyFor: (id, code, ...modifiers) => drive("key-focused", [id, String(code), ...modifiers, ...(backgroundInput ? ["--no-activate"] : [])]),
  frame: id => drive("frame", [id]).trim().split(/\s+/).map(Number),
  popoverFrame: id => drive("frame", [id, "--popover"]).trim().split(/\s+/).map(Number),
  webFrame: id => drive("web-frame", [id]).trim().split(/\s+/).map(Number),
  drag: (id, x, y, dx, dy) => drive("drag", [id, ...[x, y, dx, dy].map(String)]),
};

function replyVisible(target) {
  const plain = (text) => text.replace(/\\[nrt]/g, " ").replace(/[\p{P}\p{S}\s]+/gu, " ").trim();
  const reply = plain(target.fragments.join(""));
  return reply.length > 0 && plain(tree()).includes(reply);
}

async function waitForIdle(pid) {
  while (minimumIdle > 0 && execFileSync(ax, ["desktop-ready", String(minimumIdle)], { encoding: "utf8" }).trim() !== "ready") {
    if (pid) process.kill(pid, 0);
    await delay(1000);
  }
}

async function waitForFixtureWindow(control, pid) {
  const label = "main window: " + control;
  if (backgroundInput) {
    try {
      await until(() => visible(control), label, 2000);
      return;
    } catch {}
    if (execFileSync(ax, ["desktop-ready", "0"], { encoding: "utf8" }).trim() !== "ready") {
      record("WindowServer has not exposed the test window while the display is locked or asleep. Waiting for the window without activating it.");
      while (execFileSync(ax, ["desktop-ready", "0"], { encoding: "utf8" }).trim() !== "ready") {
        process.kill(pid, 0);
        try { visible(control); return; } catch {}
        await delay(3000);
      }
    }
  }
  await until(() => visible(control), label);
}

async function activateLaunchedApp() {
  let deadline = Date.now() + 20_000;
  let reportedWait = false;
  for (;;) {
    try {
      drive("activate", []);
      return;
    } catch (error) {
      const reason = String(error.stderr ?? error.message).trim();
      if (minimumIdle > 0 && (reason.includes("Another application is receiving input") || reason.includes("shared desktop is locked or asleep"))) {
        if (!reportedWait) {
          record("The fixture window remained in the background while the desktop was in use.");
          reportedWait = true;
        }
        await waitForIdle(appPID);
        deadline = Date.now() + 20_000;
      } else if (Date.now() >= deadline) {
        throw new Error("Could not activate the fixture app. " + reason);
      } else await delay(150);
    }
  }
}

async function launch(expectedControl = "model-settings", root = workspace, shell = worktreeTest ? terminalFixture : "/bin/sh",
                      background = Boolean(backgroundScenario)) {
  backgroundInput = background;
  if (!background) await waitForIdle();
  launchNumber++;
  execFileSync("/usr/bin/open", [
    "-n", ...(background || minimumIdle > 0 ? ["-g"] : []), "-a", app, "--stdout", join(logs, launchNumber + ".out"),
    "--stderr", join(logs, launchNumber + ".err"),
    "--env", "SHELL=" + shell,
    "--env", "PATH=" + resolve(import.meta.dirname, "fixtures/github-read") + ":/usr/bin:/bin",
    "--env", "PI_GH_FIXTURE_STATE=" + forgeState, "--env", "GH_CONFIG_DIR=" + join(directory, "gh"),
    "--env", "PI_GH_FIXTURE_LOG=" + forgeLog,
    "--env", "PI_WORKSPACE_TEST_PASTEBOARD=" + pasteboard,
    "--args", "--workspace", root,
    "-ApplePersistenceIgnoreState", "YES",
  ]);
  const id = await until(() => {
    const result = execFileSync("/bin/ps", ["-axo", "pid=,args="], { encoding: "utf8" });
    const process = result.split("\n").find(line => line.includes("/MacOS/PiWorkspace --workspace " + root + " "));
    return process && Number(process.trim().split(/\s+/)[0]);
  }, "app process");
  appPID = id;
  if (!background) await activateLaunchedApp();
  await waitForFixtureWindow(expectedControl, id);
  return id;
}

async function waitForExit(id) {
  await until(() => {
    try { process.kill(id, 0); } catch { return true; }
    return false;
  }, "clean application exit");
}

async function quit(control = "terminate:") {
  pressDismissal(control);
  await waitForExit(appPID);
  appPID = undefined;
}

async function settings() {
  press("model-settings");
  await until(() => visible("settings-nav-model"), "model page in Settings navigation");
  press("settings-nav-model");
  await until(() => visible("key-input"), "API key field");
}

async function closeSettings() {
  press("save-settings");
  await until(() => {
    try { visible("save-settings"); } catch { return true; }
    return false;
  }, "settings sheet to close");
}

async function setField(id, text, ready = () => true) {
  const displayed = () => drive("get", [id, "--values"]).includes("value=" + JSON.stringify(text)) && ready();
  for (const action of backgroundInput ? ["set"] : ["type", "set", "type"]) {
    try {
      if (displayed()) return;
      drive(action, action === "type" ? [id, "--replace"] : [id], text);
      await until(displayed, id + " contents", 1500);
      return;
    } catch {}
  }
  assert(displayed(), "The native field did not accept input: " + id);
}

async function typePrompt(prompt) {
  await until(() => visible("composer").includes("enabled=true"), "editable message composer");
  await setField("composer", prompt);
}

async function chooseLocalFolder(entry = "open-project") {
  press(entry);
  await until(() => visible("project-source-local"), "project sources");
  press("project-source-local");
  await until(() => visible("project-path"), "Local folder");
}

async function verifyPathCompletion(projectID, threadID) {
  const palette = join(directory, "Palette fixture");
  for (const name of ["Palette Alpha", "Palette Alpine", "Palette Beta"]) mkdirSync(join(palette, name), { recursive: true });
  symlinkSync(project, join(palette, "Palette Alpha", "Leaf One"));
  const pathIs = path => drive("get", ["project-path", "--values"]).includes("value=" + JSON.stringify(path));
  await chooseLocalFolder();
  await setField("project-path", palette + "/pal");
  await until(() => visible("project-path-suggestion-Palette Alpha"), "folder matches");
  const key = code => drive("key-focused", ["project-path", String(code)]);
  key(48);
  await until(() => pathIs(palette + "/Palette "), "Tab completes common prefix including space");
  key(125);
  key(125);
  key(48);
  await until(() => pathIs(palette + "/Palette Alpha/") && visible("project-path-suggestion-Leaf One"), "enter the highlighted folder");
  key(48);
  await until(() => pathIs(palette + "/Palette Alpha/Leaf One/"), "Tab enters the only child");
  key(36);
  await until(() => !tree().includes('id="project-path"') && visible("composer").includes("focused=true"), "Return registers the completed folder");
  const index = JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  assert.equal(index.selectedProject, projectID);
  assert.equal(index.projects.find(p => p.id === projectID).selectedConversation, threadID);
  assert.equal(index.projects.length, 2);
  record("Tab completed a shared folder prefix, arrows selected a directory, and Tab entered its sole child. Return on its symlink opened the existing project and draft.");
}

async function openProject() {
  const index = () => JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  if (fixtureModel) {
    assert.equal(index().projects.length, 0);
    press("start-without-project");
    const scratch = await until(() => {
      const project = index().projects.find(p => p.kind === "scratch");
      return project && visible("composer") && project;
    }, "No project from empty Home");
    assert.equal(realpathSync(scratch.path), realpathSync(join(workspace, "scratch", scratch.id)));
    await openDraftActions();
    press("discard-draft");
    await until(() => index().projects.length === 0 && visible("empty-open-project"), "discard the empty scratch draft and return Home");
    record("Start without a project on empty Home opened the scratch draft in its private directory. Discard returned to empty Home.");
  }
  await chooseLocalFolder();
  press("cancel-project");
  await until(() => !tree().includes('id="project-path"'), "cancelled project picker");
  assert.equal(index().projects.length, 0);
  await chooseLocalFolder("empty-open-project");
  await setField("project-path", join(directory, "missing folder"), () => visible("confirm-project").includes("enabled=true"));
  press("confirm-project");
  await until(() => visible("project-path-error"), "invalid path feedback");
  assert.equal(index().projects.length, 0);
  await setField("project-path", project);
  press("confirm-project");
  await until(() => visible("composer").includes("focused=true"), "registered folder's focused composer");
  const saved = index();
  const added = saved.projects.find(item => item.id === saved.selectedProject);
  assert.equal(added.path, project);
  assert.ok(added.selectedConversation);
  assert(!tree().includes("thread-row-"), "Empty drafts should not appear in the thread list.");
  await chooseLocalFolder();
  const missingChild = join(project, "missing folder");
  await setField("project-path", missingChild);
  async function finishFolderPicker(button, folder) {
    press("browse-project");
    await until(() => visible("open-panel"), "system folder picker");
    if (folder) await until(() => { drive("select-folder", [folder]); return true; }, "select the exact fixture folder in the native browser");
    await until(() => visible(button).includes("enabled=true"), "enabled native picker button");
    pressDismissal(button);
    await until(() => !tree().includes('id="open-panel"') && visible("project-path"), "return to the project path");
  }
  await finishFolderPicker("CancelButton");
  assert(drive("get", ["project-path", "--values"]).includes(missingChild));
  await setField("project-path", join(directory, "missing folder"));
  await finishFolderPicker("OKButton", project);
  const returnedPath = drive("get", ["project-path", "--values"]);
  const valueStart = returnedPath.indexOf(" value=");
  assert(valueStart >= 0, "Browse returned no folder path");
  const selectedPath = JSON.parse(returnedPath.slice(valueStart + " value=".length));
  assert.equal(realpathSync(selectedPath), realpathSync(project), "Browse did not return the selected folder");
  press("confirm-project");
  await until(() => !tree().includes('id="project-path"'), "confirmed OS folder");
  assert.equal(index().projects.length, 1);
  assert.equal(index().selectedProject, added.id);
  assert.equal(index().projects[0].selectedConversation, added.selectedConversation);
  await chooseLocalFolder();
  const alias = join(directory, "project-alias");
  symlinkSync(project, alias);
  await setField("project-path", alias);
  press("confirm-project");
  await until(() => !tree().includes('id="project-path"'), "confirmed folder alias");
  assert.equal(index().projects.length, 1);
  assert.equal(index().projects[0].id, added.id);

  press("open-project");
  await until(() => visible("project-source-new"), "New project source");
  press("project-source-new");
  await until(() => visible("project-parent-path"), "repository parent folder");
  await setField("project-parent-path", directory);
  await setField("project-name", "Sample Project");
  press("confirm-project");
  await until(() => visible("project-path-error"), "existing destination must remain intact");
  assert.equal(index().projects.length, 1);
  await setField("project-name", "Second Project");
  press("confirm-project");
  await until(() => index().projects.length === 2 && !tree().includes('id="project-name"'), "created repository and draft");
  const other = index().projects.find(item => item.id === index().selectedProject);
  assert.equal(other.title, "Second Project");
  assert.equal(git(other.path, "rev-parse", "--is-inside-work-tree"), "true");
  await chooseLocalFolder();
  await setField("project-path", "../Sample Project");
  press("confirm-project");
  await until(() => index().selectedProject === added.id && visible("composer").includes("focused=true"), "relative folder reopens first project");
  assert.equal(index().projects.length, 2);
  assert.equal(index().projects[0].selectedConversation, added.selectedConversation);
  await verifyPathCompletion(added.id, added.selectedConversation);
  record("New project rejected an occupied destination and created a fresh Git repository. A relative folder path reopened the original draft.");
}

async function send(prompt) {
  await until(() => !tree().includes("Opening thread…"), "Pi to become ready");
  await typePrompt(prompt);
  const requests = targets.length + rejected;
  press("send-message");
  await until(() => targets.length + rejected > requests || tree().includes("Preparing worktree…") || visible("stop-message"), "message send");
}

function git(directory, ...arguments_) {
  return execFileSync("/usr/bin/git", ["-C", directory, ...arguments_], {
    encoding: "utf8", stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

function makeRepository() {
  writeFileSync(terminalFixture, `#!/bin/sh
if [ -t 0 ]; then
  pwd -P > tty-proof.txt
  printf '%s\n' "$$" > retained-shell.txt
  printf '%s\n' 'Fixture terminal ready.'
  printf 'Fixture terminal PID %s\n' "$$"
fi
exec /bin/sh -i
`, { mode: 0o700 });
  git(project, "init", "--initial-branch", "main");
  git(project, "config", "user.name", "Pi Workspace Test");
  git(project, "config", "user.email", "fixture@example.invalid");
  git(project, "config", "commit.gpgsign", "false");
  git(project, "config", "core.hooksPath", join(directory, "no fixture hooks"));
  git(project, "remote", "add", "origin", "https://github.com/fixture/workspace.git");
  writeFileSync(forgeState, "initial\n");
  writeFileSync(join(project, "base.txt"), "base content\n");
  writeFileSync(join(project, "README.md"), "T3 audit sample.\n");
  git(project, "add", "base.txt", "README.md");
  git(project, "commit", "-m", "Fixture base");
  writeFileSync(join(project, "base.txt"), "unsaved root checkout edit\n");
  appendFileSync(join(project, "README.md"), "Uncommitted fixture line.\n");
}

async function chooseNewWorktree(branch, expectedCheckouts = 1) {
  await until(() => visible("choose-workspace"), "thread workspace button");
  press("choose-workspace");
  await until(() => visible("worktree-branch"), "worktree creation controls");
  await delay(240);
  await setField("worktree-branch", branch);
  press("create-worktree");
  await until(() => tree().includes("New worktree") && !tree().includes("worktree-branch"), "selected worktree draft");
  assert.equal(git(project, "worktree", "list", "--porcelain").split("\n").filter(line => line.startsWith("worktree ")).length, expectedCheckouts);
  try { press("toggle-changes"); } catch { /* the button is disabled for a pending checkout */ }
  assert(!tree().includes('id="git-refresh"'));
}

async function verifyDraftCopy(id, expected) {
  await openDraftActions();
  press("draft-copy");
  await until(() => visible(id), "draft copy action " + id);
  press(id);
  await until(() => {
    execFileSync(ax, ["check-copy", pasteboard], { input: expected, stdio: ["pipe", "pipe", "pipe"] });
    return true;
  }, "expected working path or branch in the isolated macOS pasteboard");
}

async function openDraftActions() {
  for (let attempt = 0; attempt < 3; attempt++) {
    press("conversation-title");
    try {
      await until(() => visible("draft-copy"), "draft actions", 1500);
      return;
    } catch (error) {
      if (attempt === 2) throw error;
    }
  }
}

async function verifyExistingDraft(projectID, savedID, checkout) {
  const requestCount = targets.length;
  press("new-conversation");
  await until(() => visible("new-thread-project-" + projectID), "project chooser for a new draft");
  press("new-thread-project-" + projectID);
  await until(() => visible("composer").includes("focused=true"), "chosen project's draft");
  const readIndex = () => JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  const index = readIndex();
  assert.equal(index.selectedProject, projectID);
  assert.notEqual(index.projects.find(p => p.id === projectID).selectedConversation, savedID);
  press("choose-workspace");
  const option = "existing-worktree-" + checkout;
  await until(() => visible(option), "existing worktree in the picker");
  press(option);
  await until(() => !tree().includes('id="worktree-base"') && visible("choose-workspace").includes("Worktree"), "existing checkout selected");
  await verifyDraftCopy("draft-copy-path", checkout);
  await verifyDraftCopy("draft-copy-branch", git(checkout, "branch", "--show-current"));
  await verifyLinkOnlyDraftMove(panelDriver, readIndex);
  assert.equal(targets.length, requestCount);
  const worktrees = git(project, "worktree", "list", "--porcelain");
  const rootEdit = git(project, "diff", "--", "base.txt");
  await chooseNewWorktree("main", 2);
  const prompt = "Run this fallback in the project folder.";
  await typePrompt(prompt);
  await until(() => visible("send-message").includes("enabled=true"), "ready for failed checkout");
  press("send-message");
  await until(() => visible("worktree-launch-work-locally") && visible("worktree-launch-error"), "recoverable checkout failure");
  assert.equal(targets.length, requestCount);
  press("worktree-launch-work-locally");
  await until(() => targets.length === requestCount + 1 && replyVisible(targets.at(-1)) && visible("send-message"), "one completed fallback turn");
  const messages = targets.at(-1).body.messages;
  assert.equal(messages.filter(message => message.role === "user" && JSON.stringify(message.content).includes(prompt)).length, 1);
  assert(messages.some(message => message.role === "system" && JSON.stringify(message.content).includes(project)));
  assert.deepEqual(git(project, "worktree", "list", "--porcelain"), worktrees);
  assert.equal(git(project, "diff", "--", "base.txt"), rootEdit);
  record("Work locally after a failed checkout sent the original prompt once from the project folder. Existing checkouts and edits stayed intact.");
  press("toggle-terminal");
  await until(() => visible("thread-terminal").includes("focused=true"), "fallback project's terminal");
  const terminal = await verifyInteractiveShell(panelDriver, project);
  await closeTerminalPane(panelDriver);
  record("In the project folder, typed pwd printed the root. Control-C interrupted cat, and the shell then ran tty on " + terminal + ".");
  press("thread-row-" + savedID);
  await until(() => tree().includes(firstPrompt), "resume the submitted conversation");
  record("The new-thread project chooser opened a separate draft in the selected project. Copy on its existing worktree returned that checkout's path and current branch without sending a model request.");
}

async function verifyDefaultWorktree(index, projectID, originalID, previousCheckout) {
  await setWorktreeLocation(panelDriver, index, customWorktrees);
  const marker = join(previousCheckout, "storage-reset-note.txt");
  writeFileSync(marker, "Keep this edit in the custom checkout.\n");
  await setWorktreeLocation(panelDriver, index, "");
  assert.equal(readFileSync(marker, "utf8"), "Keep this edit in the custom checkout.\n");
  press("new-conversation");
  await until(() => visible("new-thread-project-" + projectID), "choose the project for another worktree");
  press("new-thread-project-" + projectID);
  await until(() => visible("composer").includes("focused=true"), "new draft after resetting storage");
  const thread = index().projects.find(p => p.id === projectID).selectedConversation;
  assert.notEqual(thread, originalID);
  await chooseNewWorktree("default-after-reset", 2);
  const count = targets.length;
  await send("Verify the new thread starts in the default worktree folder.");
  await until(() => targets.length === count + 1 && replyVisible(targets.at(-1)), "one turn in the default checkout");
  const created = index().projects.find(p => p.id === projectID).conversations.find(t => t.id === thread);
  assert.equal(realpathSync(created.location.worktree.path), realpathSync(join(workspace, "worktrees", projectID, thread)));
  assert(targets.at(-1).body.messages.some(m => m.role === "system" && JSON.stringify(m.content).includes(created.location.worktree.path)));
  assert.equal(readFileSync(marker, "utf8"), "Keep this edit in the custom checkout.\n");
  assert.equal(git(previousCheckout, "branch", "--show-current"), "ui-worktree");
  press("thread-row-" + originalID);
  await until(() => index().projects.find(p => p.id === projectID).selectedConversation === originalID, "original worktree thread");
  record("With worktree storage reset, the next thread ran once under the default root. The earlier custom checkout retained its branch and working file.");
}

async function verifyCheckout(checkout) {
  const branch = git(checkout, "branch", "--show-current");
  assert.equal(branch, "ui-worktree");
  assert.equal(git(project, "branch", "--show-current"), "main");
  assert.equal(readFileSync(join(project, "base.txt"), "utf8"), "unsaved root checkout edit\n");
  assert.equal(readFileSync(join(checkout, "base.txt"), "utf8"), "base content\n");
  assert(targets[0].body.messages.some(message =>
    message.role === "system" && JSON.stringify(message.content).includes(checkout)));
  record("Pi used the newly created worktree, and the original branch and unstaged edit stayed in place.");

  press("toggle-terminal");
  await until(() => visible("thread-terminal"), "PTY terminal in the app");
  await until(() => visible("thread-terminal").includes("focused=true"), "terminal has keyboard focus");
  const proof = join(checkout, "tty-proof.txt");
  await until(() => existsSync(proof), "PTY proof file in the selected worktree");
  assert.equal(realpathSync(readFileSync(proof, "utf8").trim()), realpathSync(checkout));
  assert(!existsSync(join(project, "tty-proof.txt")));
  const shellProof = join(checkout, "retained-shell.txt");
  await until(() => existsSync(shellProof), "terminal shell PID");
  const shellPID = Number(readFileSync(shellProof, "utf8"));
  assert(shellPID > 0);
  press("toggle-terminal");
  press("toggle-terminal");
  await until(() => visible("thread-terminal"), "reopened terminal");
  await delay(300);
  assert.equal(Number(readFileSync(shellProof, "utf8")), shellPID);
  process.kill(shellPID, 0);
  await until(() => drive("get", ["thread-terminal", "--values"]).includes("Fixture terminal ready."), "reopened terminal output");
  await verifyTerminalPanes(panelDriver, shellPID);
  record("The terminal drawer measured 280 points by default and retained its dragged 360-point height and shell across hide and reopen. Five distinct PTYs exercised both split directions and the four-pane limit. Previous and next focused the expected pane, and confirmed close stopped only that shell.");

  writeFileSync(join(checkout, "base.txt"), "first edit\n");
  git(checkout, "add", "base.txt");
  appendFileSync(join(checkout, "base.txt"), "second edit\n");
  const excludedDiff = git(checkout, "diff", "HEAD", "--", "base.txt");
  press("toggle-changes");
  await until(() => visible("git-file-tty-proof.txt"), "untracked file in Changes");
  press("git-file-tty-proof.txt");
  await until(() => tree().includes("+") && tree().includes(checkout), "file contents in the diff");
  const subject = "Verify the in-app commit";
  assert(visible("git-commit").includes("enabled=false"), "A blank commit message must disable Commit.");
  drive("type", ["git-commit-message"], subject);
  await until(() => drive("get", ["git-commit-message", "--values"]).includes("value=" + JSON.stringify(subject)),
              "typed commit message");
  press("git-include-all");
  await until(() => visible("git-commit").includes("enabled=false"), "empty commit selection");
  press("git-include-tty-proof.txt");
  await until(() => visible("git-commit").includes("enabled=true"), "enabled commit button");
  press("git-commit");
  await until(() => git(checkout, "log", "-1", "--format=%s") === subject, "commit recorded in Git");
  assert.equal(git(checkout, "show", "--format=", "--name-only", "HEAD"), "tty-proof.txt");
  assert.match(git(checkout, "status", "--porcelain"), /\?\? retained-shell\.txt/);
  assert.equal(git(checkout, "diff", "--cached", "--name-only"), "");
  assert.equal(git(checkout, "diff", "--", "base.txt"), excludedDiff);
  assert.equal(git(project, "log", "-1", "--format=%s"), "Fixture base");
  press("toggle-changes");
  record("Changes committed only the checked file. The excluded tracked file kept both edits unstaged. The other untracked file and original checkout were unchanged.");
}

async function verifyApprovals(cwd) {
  press("tool-permissions");
  await until(() => visible("tool-mode-supervised"), "Supervised mode in the permissions menu");
  press("tool-mode-supervised");
  await until(() => visible("tool-permissions").includes("Supervised"), "Supervised selection");
  for (const decision of ["decline", "approve"]) {
    requestedWrite = decision + "-fixture.txt";
    const file = join(cwd, requestedWrite);
    await send("Request the " + decision + " fixture write.");
    await until(() => visible(decision + "-tool"), "tool decision for " + requestedWrite);
    assert(tree().includes(requestedWrite));
    assert(!existsSync(file));
    press(decision + "-tool");
    await until(() => visible("send-message") && !tree().includes('id="tool-approval"'), "tool decision completed");
    if (decision === "approve") assert.equal(readFileSync(file, "utf8"), "Approved fixture write.\n");
    else assert(!existsSync(file));
  }
  requestedWrite = undefined;
  record("Supervised displayed each write before execution. Decline left the file absent. Approve created only the requested file.");
}

async function verifySidebar(savedID) {
  async function focusSearch() {
    if (visible("thread-search").includes("focused=true")) return;
    panelDriver.focus("composer");
    panelDriver.keyFor("composer", 3, "cmd", "shift");
    await until(() => visible("thread-search").includes("focused=true"), "Command-Shift-F focuses sidebar search");
  }
  const index = () => JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  const third = join(directory, "Third Project");
  mkdirSync(third);
  for (const folder of [join(directory, "Second Project"), third]) {
    await chooseLocalFolder();
    await setField("project-path", folder);
    press("confirm-project");
    await until(() => !tree().includes('id="project-path"') && visible("composer").includes("focused=true"), "folder's draft");
    await typePrompt("Draft for " + folder.split("/").at(-1));
  }
  const [first, second, last] = index().projects;
  const requestCount = targets.length;
  const thirdText = "Draft for Third Project with a final edit";
  const lastDraft = () => index().projects.find(p => p.id === last.id).conversations.find(t => t.id === last.selectedConversation);
  await until(() => lastDraft().composerText === "Draft for Third Project", "baseline draft saved");
  const backup = join(workspace, "workspace.previous.json");
  const held = join(directory, "held-workspace-index");
  const blocker = join(backup, "fixture-obstruction");
  renameSync(backup, held);
  mkdirSync(backup);
  writeFileSync(blocker, "blocked");
  try {
    await typePrompt(thirdText);
    await until(() => visible("retry-saving-draft"), "failed autosave is visible");
    press("terminate:");
    await until(() => visible("retry-save-and-quit"), "quit deferred while the draft cannot be saved");
    process.kill(appPID, 0);
    assert.equal(lastDraft().composerText, "Draft for Third Project");
  } finally {
    unlinkSync(blocker);
    rmdirSync(backup);
    renameSync(held, backup);
  }
  pressDismissal("retry-save-and-quit");
  await waitForExit(appPID);
  appPID = undefined;
  await launch();
  const composerHas = text => drive("get", ["composer", "--values"]).includes("value=" + JSON.stringify(text));
  await until(() => index().selectedProject === last.id && composerHas(thirdText), "restore selected unfinished draft on launch");
  record("Quit was cancelled while the draft backup was unwritable. Retry and Quit after repair saved the final edit, and the app reopened it in the same thread.");
  press("thread-row-" + second.selectedConversation);
  await until(() => composerHas("Draft for Second Project"), "restore the other unfinished draft");
  assert.equal(targets.length, requestCount);
  record("Two distinct unsent messages and their thread IDs survived quit, relaunch and switching, with no additional model request.");
  const row = (id) => 'id="thread-row-' + id + '"';
  press("thread-filters");
  await until(() => visible("project-filter-" + first.id), "project scope checkboxes");
  press("project-filter-" + first.id);
  press("project-filter-" + second.id);
  press("close-thread-filters");
  await until(() => {
    const list = tree();
    return list.includes(row(savedID)) && list.includes(row(second.selectedConversation)) && !list.includes(row(last.selectedConversation));
  }, "two selected projects visible, third excluded");
  press("thread-filters");
  press("project-filter-all");
  press("close-thread-filters");
  await until(() => visible("thread-row-" + last.selectedConversation), "All Projects restores third draft");
  record("The project filter showed both checked projects, excluded the third, and restored all three on reset.");
  await focusSearch();
  for (const clear of ["button", "escape"]) {
    await setField("thread-search", "Not a fixture thread");
    await until(() => visible("clear-thread-search") && !tree().includes(row(savedID)), "no matching fixture threads");
    if (clear === "button") press("clear-thread-search");
    else drive("key-focused", ["thread-search", "53"]);
    await until(() => visible("thread-row-" + savedID) && visible("thread-row-" + second.selectedConversation) &&
                      drive("get", ["thread-search", "--values"]).includes('value=""'), "clear search by " + clear);
  }
  record("Clear and the Escape key each restored the submitted thread and unsent drafts to the sidebar.");
  await setField("thread-search", "Second Project");
  await until(() => !tree().includes(row(savedID)) && visible("thread-row-" + second.selectedConversation), "matching project in search");
  drive("confirm", ["thread-search"]);
  await until(() => index().selectedProject === second.id && drive("get", ["composer", "--values"]).includes("Draft for Second Project"),
              "confirming the search opens the selected draft with its text");
  await focusSearch();
  await setField("thread-search", "Partial reply before Stop.");
  const match = await until(() => tree().match(new RegExp('id="(message-search-result-' + savedID + '-([^"]+))"')), "match in a previous message");
  press(match[1]);
  await until(() => visible("transcript-message-" + match[2]), "matching message in the original conversation");
  await until(() => index().selectedProject === first.id && index().projects[0].selectedConversation === savedID, "return to saved conversation");
  record("Command-Shift-F focused sidebar search. AXConfirm reopened the matching draft with its text.");
  record("Searching an older assistant reply opened its stored message ID in the original thread.");
  press("thread-row-" + last.selectedConversation);
  await until(() => composerHas(thirdText), "third draft before Discard");
  await openDraftActions();
  press("discard-draft");
  await until(() => !index().projects.find(p => p.id === last.id).conversations.some(t => t.id === last.selectedConversation), "discard selected draft");
  assert.equal(index().projects.find(p => p.id === second.id).conversations.find(t => t.id === second.selectedConversation).composerText, "Draft for Second Project");
  press("thread-row-" + savedID);
  await until(() => index().selectedProject === first.id, "submitted thread after discard");
  record("Discard removed only the selected draft. Its project and the second project's unsent text remained.");
  return match[2];
}

async function verifyScratch(originalThread) {
  const index = () => JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  press("new-conversation");
  await until(() => visible("new-thread-no-project"), "No project in the new-thread chooser");
  press("new-thread-no-project");
  const scratch = await until(() => {
    const data = index();
    return data.projects.find(p => p.kind === "scratch" && p.id === data.selectedProject);
  }, "scratch workspace");
  assert.equal(realpathSync(scratch.path), realpathSync(join(workspace, "scratch", scratch.id)));
  await send("Verify the scratch thread and its history.");
  await until(() => visible("send-message") && tree().includes("Verify the scratch thread and its history."), "scratch turn completed");
  const history = join(workspace, "sessions", scratch.id, scratch.selectedConversation);
  const files = readdirSync(history).filter(name => name.endsWith(".jsonl"));
  assert.equal(files.length, 1);
  const transcript = readFileSync(join(history, files[0]));
  press("conversation-title");
  await until(() => visible("turn-into-project"), "scratch conversion");
  press("turn-into-project");
  await until(() => visible("project-created"), "project created in place");
  const converted = index().projects.find(p => p.id === scratch.id);
  assert.equal(converted.path, scratch.path);
  assert.equal(converted.selectedConversation, scratch.selectedConversation);
  assert.equal(converted.kind, undefined);
  assert.deepEqual(readFileSync(join(history, files[0])), transcript);
  press("thread-row-" + originalThread);
  await until(() => index().projects[0].selectedConversation === originalThread && index().selectedProject === index().projects[0].id, "original workspace");
  record("A scratch thread sent from its private folder. Conversion kept the folder, thread ID and history file.");
}

function inspectFiles() {
  const files = [directory, logs].flatMap(root => readdirSync(root, { recursive: true, withFileTypes: true }));
  for (const entry of files) {
    assert.notEqual(entry.name, "auth.json");
    if (entry.isFile()) {
      assert(!readFileSync(join(entry.parentPath, entry.name)).includes(secret),
             "Plaintext API key in " + entry.name);
    }
  }
  assert(files.some(entry => entry.isFile() && entry.name.endsWith(".jsonl")), "Pi transcript is missing");
  return files.filter(entry => entry.isFile() && entry.name.endsWith(".jsonl")).map(entry => entry.name);
}

async function verifyConversations() {
  if (worktreeTest) makeRepository();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const endpoint = "http://127.0.0.1:" + server.address().port + "/v1";
  keyAccount = "local:" + endpoint;
  writeFileSync(join(workspace, "workspace.json"), JSON.stringify({
    projects: [], newWorktreesStartFromRemote: false,
    model: { provider: "local", endpoint, model: "smollm2:135m", contextWindow: 8192, localTools: fixtureModel, localImages: fixtureModel },
  }), { mode: 0o600 });

  record("Verification folder: " + reportDirectory);
  record("Isolated fixture: " + directory);
  record(fixtureModel ? "Model endpoint: deterministic loopback fixture." : "Model endpoint: loopback Ollama.");
  if (worktreeTest) {
    updateKey("--set-api-key-from-stdin", secret);
    keySaved = true;
  }
  const firstPID = await launch();
  const startTitle = worktreeTest ? "Start" : "Start without an agent";
  assert(visible("start-workspace").includes(JSON.stringify(startTitle)));
  press("start-workspace");
  await until(() => visible("empty-open-project"), "empty workspace after Welcome");
  await settings();
  if (!worktreeTest) {
    keySaved = true;
    drive("type", ["key-input"], secret);
    await closeSettings();
    await settings();
  }
  await until(() => visible("remove-api-key"), "saved Keychain entry");
  await closeSettings();
  await openProject();
  await verifyAbout(panelDriver, app);
  record("Both About entry points matched the bundle version and build. The searchable offline SwiftTerm notice matched its packaged LICENSE.");
  record("Cancelling and an invalid path left the index empty. Registration focused the draft. Browse returned the same folder and kept its project and draft IDs.");
  record("Welcome completed through " + startTitle + ". The configured model has a Keychain item.");
  const index = () => JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  const draftID = index().projects[0].selectedConversation;
  if (worktreeTest) {
    press("choose-workspace");
    await until(() => visible("use-project-workspace"), "local folder workspace");
    press("use-project-workspace");
    await until(() => !tree().includes('id="use-project-workspace"') && visible("choose-workspace").includes("Local"), "selected local draft");
  }
  await verifyDraftCopy("draft-copy-path", project);
  if (worktreeTest) {
    if (fixtureModel) await setWorktreeLocation(panelDriver, index, customWorktrees);
    await chooseNewWorktree("main");
    const base = index().projects[0].conversations.find(t => t.id === draftID).location.newWorktree.base;
    assert.equal(base, "refs/heads/main");
    assert.equal(git(project, "rev-parse", base), git(project, "rev-parse", "HEAD"));
    await verifyDraftCopy("draft-copy-path", project);
    await verifyDraftCopy("draft-copy-branch", "main");
    record("Copy wrote the project path for a local and a planned worktree draft, and the selected base branch, to an isolated native pasteboard.");
    await typePrompt(firstPrompt);
    await until(() => !tree().includes("Opening thread…"), "draft helper ready");
    press("send-message");
    await until(() => tree().includes("already exists") && visible("retry-worktree"), "branch collision");
    press("worktree-launch-cancel");
    await until(() => visible("send-message").includes("enabled=true") && drive("get", ["composer", "--values"]).includes(firstPrompt),
                "Cancel restores the original unsent prompt");
    assert.equal(targets.length, 0);
    assert.equal(git(project, "worktree", "list", "--porcelain").split("\n").filter(line => line.startsWith("worktree ")).length, 1);
    record("Cancel restored the unsent worktree draft before any model request, without creating a checkout.");
    press("send-message");
    await until(() => tree().includes("already exists") && visible("retry-worktree"), "retry collision after cancellation");
    assert.equal(targets.length, 0);
    await chooseNewWorktree("ui-worktree");
    const storage = fixtureModel ? customWorktrees : join(workspace, "worktrees");
    const obstruction = join(storage, index().projects[0].id, draftID);
    writeFileSync(obstruction, "fixture", { flag: "wx" });
    press("retry-worktree");
    await until(() => visible("worktree-launch-error") && visible("retry-worktree"), "worktree failure and Retry");
    const failedDraft = index().projects[0].conversations.find(t => t.id === draftID);
    assert.equal(failedDraft.worktreeLaunch.stage, "createCheckout");
    const selectedBase = failedDraft.location.newWorktree.base;
    assert.equal(git(project, "rev-parse", selectedBase), git(project, "rev-parse", "main"));
    assert(drive("get", ["worktree-launch-prompt", "--values"]).includes(firstPrompt));
    async function openFailedSetupDetails() {
      await until(() => panelDriver.value("worktree-launch-details").includes("value=0"), "setup details initially collapsed");
      press("worktree-launch-details");
      await until(() => panelDriver.value("worktree-launch-stage").includes("Create worktree") &&
        panelDriver.value("worktree-launch-branch").includes("ui-worktree") &&
        panelDriver.value("worktree-launch-base").includes(selectedBase) &&
        panelDriver.value("worktree-launch-path").includes(obstruction), "actual failed step, ref, branch and pinned destination");
    }
    await openFailedSetupDetails();
    assert.equal(index().projects[0].selectedConversation, draftID);
    assert.equal(targets.length, 0);
    assert.equal(git(project, "worktree", "list", "--porcelain").split("\n").filter(line => line.startsWith("worktree ")).length, 1);
    await quit();
    await launch();
    press("thread-row-" + draftID);
    await until(() => visible("retry-worktree"), "Retry after relaunch");
    assert(drive("get", ["worktree-launch-prompt", "--values"]).includes(firstPrompt));
    await openFailedSetupDetails();
    if (fixtureModel) {
      assert.equal(index().worktreesDirectory, customWorktrees);
      await setWorktreeLocation(panelDriver, index, "");
      assert.equal(readFileSync(obstruction, "utf8"), "fixture");
    }
    unlinkSync(obstruction);
    press("retry-worktree");
    record("Preparation failed before any model request. Relaunch retained the prompt, failure stage and thread ID. Retry used the repaired worktree store.");
  } else {
    await send(firstPrompt);
  }
  await until(() => targets[0]?.fragments.length && tree().includes('id="streaming-reply"'), "partial reply on screen");
  assert(!targets[0].completed, "The model stream had already completed.");
  record("The actual SwiftUI window showed a partial reply while the response was still open.");
  releaseFirst();
  await until(() => targets[0]?.completed && replyVisible(targets[0]), "first reply on screen", 50_000);
  await until(() => visible("send-message"), "first turn settled");
  assert.equal(targets[0].status, 200);
  const previous = JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  const threadID = previous.projects[0].selectedConversation;
  const projectID = previous.selectedProject;
  const conversation = () => index().projects.find(p => p.id === projectID).conversations.find(t => t.id === threadID);
  assert.equal(threadID, draftID);
  assert.equal(targets[0].body.messages.filter(message => message.role === "user" && JSON.stringify(message.content).includes(firstPrompt)).length, 1);
  const selectedThread = previous.projects[0].conversations.find(thread => thread.id === threadID);
  const checkout = selectedThread.location?.worktree?.path;
  if (fixtureModel && worktreeTest) {
    assert.equal(realpathSync(checkout), realpathSync(join(customWorktrees, projectID, threadID)));
    record("Retry from the saved thread created the checkout at its pinned custom location after relaunch and a settings reset.");
  }
  if (worktreeTest) assert.equal(git(project, "worktree", "list", "--porcelain").split("\n").filter(line => line.startsWith("worktree ")).length, 2);
  record("First request returned HTTP 200. Reply: " + JSON.stringify(targets[0].fragments.join("").trim()));
  if (worktreeTest) {
    await verifyCheckout(checkout);
    await verifyPullRequests(panelDriver, forgeState, forgeLog, checkout);
    await linkFixturePullRequest(panelDriver, conversation);
    record("The mock forge read PRs and Issues only from the selected checkout. Label search, distinct pages, a changed head and Issue body, page retry, and recovery from signed-out and missing-Issue responses passed.");
  }
  if (fixtureModel) {
    let previewShellPID;
    const shellProof = worktreeTest ? join(checkout, "retained-shell.txt") : undefined;
    if (worktreeTest) {
      press("toggle-terminal");
      await until(() => visible("thread-terminal"), "terminal alongside browser preview");
      previewShellPID = await until(() => {
        const id = Number(readFileSync(shellProof, "utf8"));
        if (!(id > 0)) return false;
        process.kill(id, 0);
        return id;
      }, "live terminal before undocking");
    }
    await verifyPreview(panelDriver, new URL(endpoint).origin, previewNetwork,
      worktreeTest ? () => verifyFiles(panelDriver, checkout, project, git) : undefined);
    if (worktreeTest) {
      assert.equal(Number(readFileSync(shellProof, "utf8")), previewShellPID);
      process.kill(previewShellPID, 0);
      assert(drive("get", ["thread-terminal", "--values"]).includes("Fixture terminal ready."));
      const terminal = await verifyInteractiveShell(panelDriver, checkout);
      record("In the linked worktree, typed pwd printed the checkout. Control-C interrupted cat, and the shell then ran tty on " + terminal + ".");
      record("Files selected the exact text of line 6000 beyond the first MiB after paging and reopening. The image preview exposed its dimensions and zoom. The repaired two-page PDF opened, searched to its second page and survived cancelling export.");
      record("Files searched and refreshed the checkout tree, showed binary and large-text previews, and saved only the working file. Git's staged bytes, parent checkout, browser page, composer text, and live PTY survived. Read-only and externally changed files retained their pending edits.");
      await closeTerminalPane(panelDriver);
    }
    record("Dragged and resized the in-chat Mini Player; redocking retained the live document, draft and zoom. Browser tabs kept separate history and shared storage only within their profile. Moving the page to a separate window and closing it preserved the tab.");
    record("Zoom changed the rendered width of a 100 CSS-pixel button. Refresh fetched a new revision, Stop cancelled an outstanding GET, and the error view showed details and reloaded the repaired local server.");
    record("Browser Settings rejected a custom URL missing %s. Enter navigated a bare loopback host and sent the exact search term to the chosen local engine. An unsupported address kept the page.");
    await setProjectModel(panelDriver, "fixture-project-model");
    const widths = await verifyAppearance(panelDriver);
    record("Light, Dark and all three width choices were reachable. Composer widths in points were " + JSON.stringify(widths) + "; the draft kept its text.");
  }

  await quit();
  const secondPID = await launch();
  assert.notEqual(firstPID, secondPID);
  await until(() => visible("composer"), "composer after relaunch");
  const landing = JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  assert.equal(landing.selectedProject, previous.selectedProject);
  if (fixtureModel) {
    await restoreAppearance(panelDriver);
    record("Relaunch restored Dark and Wide. Restore Defaults returned to System and Comfortable.");
    assert.equal(landing.projects[0].selectedConversation, threadID);
    await until(() => drive("get", ["composer", "--values"]).includes("Keep this text while previewing."), "unsent text in the selected conversation after relaunch");
  } else {
    assert.notEqual(landing.projects[0].selectedConversation, threadID);
    assert.equal(landing.projects[0].conversations.filter(thread => thread.isDraft).length, 1);
    press("thread-row-" + threadID);
  }
  await until(() => replyVisible(targets[0]), "previous reply in the reopened window");
  await send(secondPrompt);
  await until(() => targets[1]?.completed && replyVisible(targets[1]), "second reply on screen", 50_000);
  await until(() => visible("send-message"), "second turn settled");
  assert.equal(targets[1].status, 200);
  assert.equal(targets.length, 2);
  if (fixtureModel) {
    assert.equal(targets[1].body.model, "fixture-project-model");
    assert.equal(landing.model.model, "smollm2:135m");
    assert.equal(landing.projects[1].modelOverride, undefined);
    await resetProjectModel(panelDriver, "smollm2:135m");
    record("Only the first project used the override for a model request after relaunch. Reset restored the inherited model and kept its Keychain item.");
  }
  assert(targets[1].body.messages.some(message => message.role === "user" && JSON.stringify(message.content).includes(firstPrompt)));
  assert(targets[1].body.messages.some(message => message.role === "assistant" && JSON.stringify(message.content).includes(targets[0].fragments.join("").trim())));
  const reopened = JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  assert.equal(reopened.projects[0].selectedConversation, threadID);
  if (worktreeTest) {
    assert(targets[1].body.messages.some(message =>
      message.role === "system" && JSON.stringify(message.content).includes(checkout)));
    record("Relaunch used the persisted worktree for the second Pi request.");
  }
  record("Relaunched app " + firstPID + " → " + secondPID + ". Same conversation ID; second request included the first turn.");
  record("Second request returned HTTP 200. Reply: " + JSON.stringify(targets[1].fragments.join("").trim()));

  if (fixtureModel) {
    await verifyAttachmentUI(panelDriver, { workspace, checkout: checkout ?? project, conversation, targets, quit, launch });
    record("The native picker loaded two same-name PNGs and UTF-8 text. A missing attachment blocked Send until Attach Again repaired its original ID. Both previews opened. After removing red and relaunching, the provider received the blue PNG and complete text, and both retained IDs appeared in the transcript.");
    const childID = await verifyFork(panelDriver, { workspace, projectID, threadID, index, targets, send });
    record("Forking at the second reply copied exactly those first two turns. A single child continuation kept both histories independent, and opening the source restored its unsent draft.");
    if (worktreeTest) {
      await verifyRestoredLink(panelDriver, childID, conversation);
      record("The parent linked #42 by number and URL without duplicating it. Copy produced the expected URL and number. The link survived relaunch, remained absent from the child, and unlinked locally.");
    }
    holdForStop = true;
    await send("Hold a stream open for the Stop test.");
    await until(() => tree().includes("Partial reply before Stop."), "partial reply before Stop");
    press("stop-message");
    await until(() => streamClosed && visible("send-message"), "Stop to close the active model stream");
    assert(tree().includes("Partial reply before Stop."));
    await verifyInterruptedReply(panelDriver, workspace, projectID, threadID);
    holdForStop = false;
    record("Stop closed the model stream, restored Send and kept the partial reply in the same conversation. The saved aborted message showed its replay notice and had no new-fork button.");
    await verifyApprovals(checkout ?? project);
    await verifyQueue(panelDriver, {
      workspace, projectID: previous.selectedProject, threadID, requestCount: () => targets.length, send, quit, launch,
      gate() { let release; nextQueueResponse = new Promise(resolve => { release = resolve; }); return release; }
    });
    record("Five queued instructions collapsed and expanded without changing the total. Cancel/edit, reorder and removal kept their item IDs. Two steers arrived during the active run and the remaining items ran in order. Stop and relaunch held pending items until explicitly started or resumed; Pi recorded eight distinct delivery IDs exactly once.");
    const matchedMessage = await verifySidebar(threadID);
    await verifyCommandPalette(panelDriver, index, () => targets.length);
    await verifyPaletteMessage(panelDriver, index, threadID, matchedMessage, "Partial reply before Stop.");
    record("Command-K opened and closed the palette; Escape, Backspace and Return preserved focus and draft ownership. The project selector created one draft, the modal folder picker kept the shortcut, and Home and Search opened their workspace destinations.");
    if (worktreeTest) {
      await verifyExistingDraft(previous.selectedProject, threadID, checkout);
      await verifyDefaultWorktree(index, previous.selectedProject, threadID, checkout);
    }
    await verifyScratch(threadID);
    await verifySettingsSearch(panelDriver, index);
    record("Settings search on General handled no results and Escape. Return focused the project model ID and license search. SwiftTerm's packaged license was readable, and switching panes preserved the unsaved model edit without changing its stored value.");
    await verifyProjectClone(panelDriver, { directory, git, index, quit, launch, requestCount: () => targets.length, verifyMoves: worktreeTest });
    record("Cloning the temporary bare repository preserved an occupied destination. The new checkout matched its exact branch, HEAD, origin and bytes. Its project and draft IDs survived relaunch without a model request.");
    if (worktreeTest) record("A blocked file edit could be copied from another checkout and followed the moved worktree after write access returned. A same-byte replacement stayed protected through Quit and explicit discard.");
  }
  rejectNextRequest = true;
  await send("Check error handling.");
  await until(() => rejected === 1 && tree().includes("[API key removed]"), "redacted provider error");
  record("A provider HTTP 401 echoed the disposable key. The app displayed a redacted error.");

  await settings();
  press("remove-api-key");
  await closeSettings();
  await settings();
  assert.throws(() => visible("remove-api-key"));
  await closeSettings();
  keySaved = false;
  const requestCount = targets.length + rejected;
  await typePrompt("Try sending without a saved key.");
  await until(() => visible("send-message").includes("enabled=true"), "ready to check missing key");
  press("send-message");
  await until(() => visible("key-input"), "missing key opens Settings");
  assert.equal(targets.length + rejected, requestCount);
  await closeSettings();
  await quit();
  const transcripts = inspectFiles();
  assert.equal(transcripts.length, fixtureModel ? (worktreeTest ? 5 : 3) : 1);
  record("No auth.json or plaintext key under the project, app data, transcripts, or captured logs. Keychain test item removed.");
  if (fixtureModel) {
    const previousIndex = JSON.parse(readFileSync(join(workspace, "workspace.previous.json"), "utf8"));
    const damaged = "{incomplete fixture";
    writeFileSync(join(workspace, "workspace.json"), damaged);
    await launch("workspace-startup-restore");
    press("workspace-startup-restore");
    await until(() => visible("model-settings"), "restored workspace window");
    const restored = JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
    assert.deepEqual(restored.projects.map(p => p.id), previousIndex.projects.map(p => p.id));
    assert(readdirSync(workspace).some(name => name.startsWith("workspace.corrupt-") && readFileSync(join(workspace, name), "utf8") === damaged));
    await quit();
    assert.deepEqual(inspectFiles().sort(), transcripts.sort());
    record("The recovery screen restored the previous project index, retained the damaged bytes and kept all " + transcripts.length + " session histories.");
  }
}

const usageWorkspace = join(directory, "usage-workspace");
const controlsWorkspace = join(directory, "controls-workspace");
try {
  const usageOnly = process.argv.includes("--usage-only");
  const controlsOnly = process.argv.includes("--workspace-controls-only");
  const conversationOnly = process.argv.includes("--conversation-controls-only");
  const threadActionsOnly = process.argv.includes("--thread-actions-only");
  const sidebarOnly = process.argv.includes("--sidebar-and-checks-only");
  const terminalOnly = process.argv.includes("--terminal-only");
  const projectSettingsOnly = process.argv.includes("--project-settings-only");
  const snoozeOnly = process.argv.includes("--snooze-only");
  const newThreadOnly = process.argv.includes("--new-thread-routes-only");
  const focused = [
    usageOnly, controlsOnly, conversationOnly, projectFlowsOnly, threadActionsOnly,
    sidebarOnly, imagesOnly, terminalOnly, projectSettingsOnly, snoozeOnly, newThreadOnly, backgroundScenario,
  ].some(Boolean);
  testBundleDirectory = mkdtempSync("/private/tmp/pi-workspace-test-app-");
  app = join(testBundleDirectory, "Pi Workspace.app");
  execFileSync("/bin/cp", ["-cR", packagedApp, app]);
  recordVerifiedBundle(app);
  if (focused) {
    record("Verification folder: " + reportDirectory);
    record("Isolated fixture: " + directory);
  } else await verifyConversations();
  if (usageOnly || (!focused && fixtureModel && !worktreeTest)) {
    const fixture = await createUsageFixture(usageWorkspace, join(app, "Contents/Resources/Sidecar"));
    await launch("model-settings", usageWorkspace);
    await verifyUsage(panelDriver, fixture, async () => {
      await quit();
      await launch("model-settings", usageWorkspace);
    });
    await quit();
    record("Command-U opened and closed Usage. C, T and L selected the metrics. Command-Shift-1 through 4 selected the periods. Typing C in Settings search edited the field.");
    record("Saved Pi usage matched 310, 350, 480 and 720 tokens. Refresh added the 23-token reply. Removing a saved fork flagged incomplete usage and removed its 60 tokens. Restoring it recovered 503. The selected seven-day cost and unfinished draft survived relaunch.");
  }
  if (controlsOnly || (!focused && fixtureModel && worktreeTest)) {
    const fixture = createWorkspaceControlsFixture(controlsWorkspace, git);
    const launchControls = () => launch("model-settings", controlsWorkspace, fixture.shell);
    await launchControls();
    await verifyWorkspaceControls(panelDriver, fixture, git, record, async () => {
      await quit();
      await launchControls();
    });
    await quit();
    record("The new Git branch started at the selected alternate commit. Choosing a branch already in use moved the same draft to its linked checkout and preserved the original checkout and index.");
  }
  if (projectSettingsOnly) {
    await verifyProjectSettings(panelDriver, { root: join(directory, "project-settings"), git, launch, quit, record });
  }
  if (snoozeOnly) {
    await verifyThreadSnooze(panelDriver, { root: join(directory, "snooze"), quit, launch, record,
      relaunch: (control, root) => launch(control, root, undefined, true) });
  }
  if (newThreadOnly) {
    await verifyNewThreadRoutes(panelDriver, { root: join(directory, "new-thread-routes"), quit, launch, record });
  }
  if (backgroundScenario === "--startup-draft-only") {
    await verifyStartupRetry(panelDriver, { root: join(directory, "startup-draft"), quit, launch, record, background: true });
  }
  if (backgroundScenario === "--recovery-actions-only") {
    await verifyStartupRecovery(panelDriver, { root: join(directory, "recovery-actions"), app, quit, launch, record });
  }
  if (backgroundScenario === "--right-terminal-only") {
    await verifyRightTerminal(panelDriver, { root: join(directory, "right-terminal"), git, launch, quit, record });
  }
  if (backgroundScenario === "--model-account-only") {
    await verifyModelAccount(panelDriver, { root: join(directory, "model-account"), launch, quit, record,
      credential: updateKey, removeFixtureCredential });
    await verifyInheritedAccount(panelDriver, { root: join(directory, "inherited-account"), launch, quit, record,
      credential: updateKey, removeFixtureCredential });
  }
  if (backgroundScenario === "--local-changes-only") {
    await verifyLocalChanges(panelDriver, { root: join(directory, "local-changes"), git, launch, quit, record });
  }
  if (backgroundScenario === "--side-chat-only") {
    await verifySideChatPanel(panelDriver, { root: join(directory, "side-chat"), launch, quit, record,
      credential: updateKey, removeFixtureCredential });
  }
  if (backgroundScenario === "--pr-files-only") {
    makeRepository();
    await verifyPRFilesCheckout(panelDriver, { directory, project, workspace, git, launch, quit, record, forgeState, forgeLog });
  }
  if (terminalOnly) {
    makeRepository();
    const projectID = randomUUID().toUpperCase(), threadID = randomUUID().toUpperCase();
    writeFileSync(join(workspace, "workspace.json"), JSON.stringify({ welcomeCompleted: true, selectedProject: projectID,
      projects: [{ id: projectID, title: "Terminal fixture", path: project, allowEdits: false, selectedConversation: threadID,
        conversations: [{ id: threadID, title: "Terminal", archived: false, isDraft: true, composerText: "Keep this draft." }] }],
      model: { provider: "local", model: "terminal-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
    }), { mode: 0o600 });
    await launch("model-settings", workspace, terminalFixture);
    press("toggle-terminal");
    const pid = await until(() => Number(readFileSync(join(project, "retained-shell.txt"), "utf8")) || false, "test shell PID");
    await verifyTerminalPanes(panelDriver, pid);
    await quit();
    record("The drawer grew from 280 to 360 points and returned to 280. Its original PTY survived resize, splits, hide and reopen. Closing individual panes terminated only their own shells.");
  }
  if (imagesOnly) {
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    releaseFirst();
    await verifyChatImages(panelDriver, { root: join(directory, "chat-images"), key: secret, credential: updateKey,
      removeFixtureCredential, launch, quit, targets, record, endpoint: "http://127.0.0.1:" + server.address().port + "/v1" });
    assert.equal(inspectFiles().length, 1);
  }
  if (sidebarOnly) {
    await verifySidebarPersistence(panelDriver, { root: join(directory, "grouped-sidebar"), git, launch, quit, record,
      stateFile: forgeState, logFile: forgeLog });
  }
  if (threadActionsOnly) {
    await verifyThreadActions(panelDriver, { root: join(directory, "thread-actions"), app, git, launch, quit, record });
    assert.equal(inspectFiles().length, 3);
  }
  if (conversationOnly) {
    await verifyConversationControls(panelDriver, {
      root: join(directory, "find-and-questions"), app, key: secret, credential: updateKey, removeFixtureCredential, launch, quit, record,
    });
    assert.equal(inspectFiles().length, 2);
    record("The two Pi histories remained separate, with no plaintext fixture key or auth.json under the verification directory.");
  }
  if (projectFlowsOnly) {
    if (!basesOnly) {
      await verifyDraftProjects(panelDriver, { root: join(directory, "draft-projects"), launch, quit });
      record("An empty draft opened the other project's populated draft. Moving it to a project and then No project preserved its ID, text and note bytes. Adding or cancelling a project returned to the same composer, including after relaunch.");
    }
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    releaseFirst();
    await verifyWorktreeBases(panelDriver, {
      root: join(directory, "worktree-bases"), git, endpoint: "http://127.0.0.1:" + server.address().port + "/v1",
      credential: updateKey, removeFixtureCredential, key: secret, launch, quit, send, targets, record,
    });
    assert.equal(inspectFiles().length, 3);
  }
} catch (error) {
  let message = error.message.replaceAll(secret, "[redacted]");
  if (appPID) {
    let summary = "";
    try { summary = tree().replaceAll(secret, "[redacted]"); } catch { /* app exited */ }
    writeFileSync(join(logs, "failure-ui.txt"), summary, { mode: 0o600 });
    try { await quit(); } catch {
      try {
        process.kill(appPID, "SIGTERM");
        await waitForExit(appPID);
        appPID = undefined;
      } catch (terminationError) {
        if (terminationError.code === "ESRCH") appPID = undefined;
        else message += " (app exit not confirmed)";
      }
    }
  }
  if (keySaved) removeFixtureCredential(workspace, keyAccount);
  record("FAIL: " + message);
  process.exitCode = 1;
} finally {
  if (failedCredentialCleanup.size) {
    record("FAIL: Could not confirm Keychain cleanup for " + [...failedCredentialCleanup].join(", "));
    process.exitCode = 1;
  }
  releaseFirst();
  server.closeAllConnections();
  server.close();
  execFileSync(ax, ["release-test-pasteboard", pasteboard], { stdio: "ignore" });
  if (testBundleDirectory && !appPID) rmSync(testBundleDirectory, { recursive: true, force: true });
  const preferenceChecks = [[usageWorkspace, "browser", "usagePeriod"]];
  if (fixtureModel) preferenceChecks.push([workspace, "browser", "browserSearchSettings"], [workspace, "appearance", "appearance.colorScheme"]);
  for (const [root, feature, key] of preferenceChecks) {
    const scope = createHash("sha256").update(root).digest("hex");
    const domain = "dev.piworkspace." + feature + "." + scope;
    const result = spawnSync("/usr/bin/defaults", ["read", domain, key], { stdio: "ignore" });
    if (result.status === 0) execFileSync("/usr/bin/defaults", ["delete", domain], { stdio: "ignore" });
  }
}
