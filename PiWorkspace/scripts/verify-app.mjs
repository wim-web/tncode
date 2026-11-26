import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { once } from "node:events";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { resetProjectModel, setProjectModel, verifyPreview, verifyPullRequests } from "./verify-panels.mjs";

const app = resolve(import.meta.dirname, "../dist/Pi Workspace.app");
const ax = process.argv[2];
assert(ax, "Pass the path to the macOS AX driver.");
assert.match(execFileSync(ax, ["trust"], { encoding: "utf8" }), /accessibility=true keyboard=true/);

const directory = mkdtempSync(resolve(import.meta.dirname, "../dist/verification-"));
const project = join(directory, "Sample Project");
const worktreeTest = process.argv.includes("--worktree");
const fixtureModel = process.argv.includes("--fixture-model");
const terminalFixture = join(directory, "verification-shell");
const workspace = join(directory, "workspace");
const forgeState = join(directory, "forge-state");
const forgeLog = join(directory, "forge-calls.log");
const logs = join(directory, "logs");
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
let streamClosed = false;
let requestedWrite;
let rejected = 0;
let appPID;
let launchNumber = 0;
let keySaved = false;
let keyAccount;

function record(text) {
  assert(!text.includes(secret), "A verification message contained the API key.");
  appendFileSync(report, text + "\n", { mode: 0o600 });
  console.log(text);
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

const server = createServer(async (request, response) => {
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
    encoding: "utf8", input, timeout: 5_000, stdio: ["pipe", "pipe", "pipe"],
  });
}

function updateKey(argument, input) {
  execFileSync(join(app, "Contents/MacOS/PiWorkspace"), ["--workspace", workspace, argument], {
    input, timeout: 10_000, stdio: ["pipe", "pipe", "pipe"],
  });
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
const press = (id) => drive("press", [id]);
const panelDriver = { press, visible, tree, setField, until, closeSettings };

function replyVisible(target) {
  const plain = (text) => text.replace(/\\[nrt]/g, " ").replace(/[\p{P}\p{S}\s]+/gu, " ").trim();
  const reply = plain(target.fragments.join(""));
  return reply.length > 0 && plain(tree()).includes(reply);
}

async function launch(expectedControl = "model-settings") {
  launchNumber++;
  execFileSync("/usr/bin/open", [
    "-n", "-a", app, "--stdout", join(logs, launchNumber + ".out"),
    "--stderr", join(logs, launchNumber + ".err"),
    "--env", "SHELL=" + (worktreeTest ? terminalFixture : "/bin/sh"),
    "--env", "PATH=" + resolve(import.meta.dirname, "fixtures/github-read") + ":/usr/bin:/bin",
    "--env", "PI_GH_FIXTURE_STATE=" + forgeState, "--env", "GH_CONFIG_DIR=" + join(directory, "gh"),
    "--env", "PI_GH_FIXTURE_LOG=" + forgeLog,
    "--args", "--workspace", workspace,
    "-ApplePersistenceIgnoreState", "YES",
  ]);
  const id = await until(() => {
    const result = execFileSync("/bin/ps", ["-axo", "pid=,args="], { encoding: "utf8" });
    const process = result.split("\n").find(line => line.includes("/MacOS/PiWorkspace --workspace " + workspace));
    return process && Number(process.trim().split(/\s+/)[0]);
  }, "app process");
  appPID = id;
  await until(() => { drive("activate", []); return true; }, "activate isolated app");
  await until(() => visible(expectedControl), "main window: " + expectedControl);
  return id;
}

async function waitForExit(id) {
  await until(() => {
    try { process.kill(id, 0); } catch { return true; }
    return false;
  }, "clean application exit");
}

async function quit() {
  press("terminate:");
  await waitForExit(appPID);
  appPID = undefined;
}

async function settings() {
  press("model-settings");
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
  for (const action of ["type", "set", "type"]) {
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
  await until(() => visible("composer"), "message composer");
  const displayed = () => drive("get", ["composer", "--values"]).includes("value=" + JSON.stringify(prompt));
  if (!displayed()) drive("type", ["composer", "--replace"], prompt);
  await until(displayed, "prompt text in the composer");
}

async function chooseLocalFolder(entry = "open-project") {
  press(entry);
  await until(() => visible("project-source-local"), "project sources");
  press("project-source-local");
  await until(() => visible("project-path"), "Local folder");
}

async function openProject() {
  await chooseLocalFolder();
  press("cancel-project");
  await until(() => !tree().includes('id="project-path"'), "cancelled project picker");
  const index = () => JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
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
  press("browse-project");
  await until(() => visible("open-panel"), "system folder picker");
  press("CancelButton");
  await until(() => !tree().includes('id="open-panel"'), "system picker cancellation");
  assert(drive("get", ["project-path", "--values"]).includes(missingChild));
  press("browse-project");
  await until(() => visible("OKButton").includes("enabled=true"), "Choose folder");
  press("OKButton");
  await until(() => !tree().includes('id="open-panel"'), "system folder selection");
  const returnedPath = drive("get", ["project-path", "--values"]);
  assert(returnedPath.includes("value=" + JSON.stringify(project)), "Browse did not return the selected folder");
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

async function chooseNewWorktree(branch) {
  await until(() => visible("choose-workspace"), "thread workspace button");
  press("choose-workspace");
  await until(() => visible("worktree-branch"), "worktree creation controls");
  await delay(240);
  await setField("worktree-branch", branch);
  press("create-worktree");
  await until(() => tree().includes("New worktree") && !tree().includes("worktree-branch"), "selected worktree draft");
  assert.equal(git(project, "worktree", "list", "--porcelain").split("\n").filter(line => line.startsWith("worktree ")).length, 1);
  try { press("toggle-changes"); } catch { /* the button is disabled for a pending checkout */ }
  assert(!tree().includes('id="git-refresh"'));
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
  const proof = join(checkout, "tty-proof.txt");
  await until(() => existsSync(proof), "PTY proof file in the selected worktree");
  assert.equal(realpathSync(readFileSync(proof, "utf8").trim()), checkout);
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
  press("close-terminal");
  await until(() => {
    try { process.kill(shellPID, 0); } catch { return true; }
    return false;
  }, "shell exits when its drawer is closed");
  record("The terminal launched an interactive shell on a PTY in the worktree, kept the same shell across hide and reopen, and closed it explicitly.");

  writeFileSync(join(checkout, "base.txt"), "first edit\n");
  git(checkout, "add", "base.txt");
  appendFileSync(join(checkout, "base.txt"), "second edit\n");
  const excludedDiff = git(checkout, "diff", "HEAD", "--", "base.txt");
  press("toggle-changes");
  await until(() => visible("git-file-tty-proof.txt"), "untracked file in Changes");
  press("git-file-tty-proof.txt");
  await until(() => tree().includes("+") && tree().includes(checkout), "file contents in the diff");
  const subject = "Verify the in-app commit";
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
  drive("activate", []);
  drive("menu-command", ["f"]);
  await until(() => visible("thread-search").includes("focused=true"), "registered Command-F menu action focuses search");
  await setField("thread-search", "Second Project");
  await until(() => !tree().includes(row(savedID)) && visible("thread-row-" + second.selectedConversation), "matching project in search");
  drive("confirm", ["thread-search"]);
  await until(() => index().selectedProject === second.id && drive("get", ["composer", "--values"]).includes("Draft for Second Project"),
              "confirming the search opens the selected draft with its text");
  drive("menu-command", ["f"]);
  await setField("thread-search", "Partial reply before Stop.");
  const match = await until(() => tree().match(new RegExp('id="(message-search-result-' + savedID + '-([^"]+))"')), "match in a previous message");
  press(match[1]);
  await until(() => visible("transcript-message-" + match[2]), "matching message in the original conversation");
  await until(() => index().selectedProject === first.id && index().projects[0].selectedConversation === savedID, "return to saved conversation");
  record("Invoking the menu command registered for Command-F focused search. AXConfirm reopened the matching draft with its text.");
  record("Searching an older assistant reply opened its stored message ID in the original thread.");
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
  assert.equal(scratch.path, join(workspace, "scratch", scratch.id));
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
  const files = readdirSync(directory, { recursive: true, withFileTypes: true });
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

try {
  if (worktreeTest) makeRepository();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const endpoint = "http://127.0.0.1:" + server.address().port + "/v1";
  keyAccount = "local:" + endpoint;
  writeFileSync(join(workspace, "workspace.json"), JSON.stringify({
    projects: [], model: { provider: "local", endpoint, model: "smollm2:135m", contextWindow: 8192, localTools: fixtureModel },
  }), { mode: 0o600 });

  record("Verification folder: " + directory);
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
  record("Cancelling and an invalid path left the index empty. Registration focused the draft. Browse returned the same folder and kept its project and draft IDs.");
  record("Welcome completed through " + startTitle + ". The configured model has a Keychain item.");
  const index = () => JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  const draftID = index().projects[0].selectedConversation;
  if (worktreeTest) {
    await chooseNewWorktree("main");
    await typePrompt(firstPrompt);
    await until(() => !tree().includes("Opening thread…"), "draft helper ready");
    press("send-message");
    await until(() => tree().includes("already exists") && visible("retry-worktree"), "branch collision");
    assert.equal(targets.length, 0);
    await chooseNewWorktree("ui-worktree");
    const obstruction = join(workspace, "worktrees", index().projects[0].id, draftID);
    writeFileSync(obstruction, "fixture", { flag: "wx" });
    press("retry-worktree");
    await until(() => visible("worktree-launch-error") && visible("retry-worktree"), "worktree failure and Retry");
    assert(drive("get", ["worktree-launch-prompt", "--values"]).includes(firstPrompt));
    assert.equal(index().projects[0].selectedConversation, draftID);
    assert.equal(targets.length, 0);
    assert.equal(git(project, "worktree", "list", "--porcelain").split("\n").filter(line => line.startsWith("worktree ")).length, 1);
    await quit();
    await launch();
    press("thread-row-" + draftID);
    await until(() => visible("retry-worktree"), "Retry after relaunch");
    assert(drive("get", ["worktree-launch-prompt", "--values"]).includes(firstPrompt));
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
  assert.equal(threadID, draftID);
  assert.equal(targets[0].body.messages.filter(message => message.role === "user" && JSON.stringify(message.content).includes(firstPrompt)).length, 1);
  const selectedThread = previous.projects[0].conversations.find(thread => thread.id === threadID);
  const checkout = selectedThread.location?.worktree?.path;
  if (worktreeTest) assert.equal(git(project, "worktree", "list", "--porcelain").split("\n").filter(line => line.startsWith("worktree ")).length, 2);
  record("First request returned HTTP 200. Reply: " + JSON.stringify(targets[0].fragments.join("").trim()));
  if (worktreeTest) {
    await verifyCheckout(checkout);
    await verifyPullRequests(panelDriver, forgeState, forgeLog, checkout);
    record("Mock gh returned PR 42 and its checks from the selected checkout. Refresh displayed the new head and updated checks.");
  }
  if (fixtureModel) {
    await verifyPreview(panelDriver, new URL(endpoint).origin);
    record("WebKit opened both loopback pages, went back and forward, zoomed and retained the unsent composer text.");
    await setProjectModel(panelDriver, "fixture-project-model");
  }

  await quit();
  const secondPID = await launch();
  assert.notEqual(firstPID, secondPID);
  await until(() => visible("composer").includes("focused=true"), "focused draft after relaunch");
  const landing = JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  assert.equal(landing.selectedProject, previous.selectedProject);
  assert.notEqual(landing.projects[0].selectedConversation, threadID);
  assert.equal(landing.projects[0].conversations.filter(thread => thread.isDraft).length, 1);
  assert(!replyVisible(targets[0]));
  press("thread-row-" + threadID);
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
    holdForStop = true;
    await send("Hold a stream open for the Stop test.");
    await until(() => tree().includes("Partial reply before Stop."), "partial reply before Stop");
    press("stop-message");
    await until(() => streamClosed && visible("send-message"), "Stop to close the active model stream");
    assert(tree().includes("Partial reply before Stop."));
    holdForStop = false;
    record("Stop closed the model stream, restored Send and kept the partial reply in the same conversation.");
    await verifyApprovals(checkout ?? project);
    await verifySidebar(threadID);
    await verifyScratch(threadID);
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
  assert.equal(transcripts.length, fixtureModel ? 2 : 1);
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
    record("The recovery screen restored the previous project index, retained the damaged bytes and kept both session histories.");
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
      } catch (terminationError) {
        if (terminationError.code !== "ESRCH") message += " (app exit not confirmed)";
      }
    }
  }
  if (keySaved) {
    try { updateKey("--remove-api-key"); }
    catch {
      const service = "dev.piworkspace.model-key." + createHash("sha256").update(workspace).digest("hex");
      try { execFileSync("/usr/bin/security", ["delete-generic-password", "-s", service, "-a", keyAccount], { stdio: "ignore" }); }
      catch (cleanupError) { if (cleanupError.status !== 44) message += " (Keychain cleanup not confirmed)"; }
    }
  }
  record("FAIL: " + message);
  process.exitCode = 1;
} finally {
  releaseFirst();
  server.closeAllConnections();
  server.close();
}
