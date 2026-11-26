import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes, timingSafeEqual } from "node:crypto";
import { once } from "node:events";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const app = resolve(import.meta.dirname, "../dist/Pi Workspace.app");
const ax = process.argv[2];
assert(ax, "Pass the path to the macOS AX driver.");
assert.match(execFileSync(ax, ["trust"], { encoding: "utf8" }), /accessibility=true keyboard=true/);

const directory = mkdtempSync(resolve(import.meta.dirname, "../dist/verification-"));
const project = join(directory, "Sample Project");
const worktreeTest = process.argv.includes("--worktree");
const terminalFixture = join(directory, "verification-shell");
const workspace = join(directory, "workspace");
const logs = join(directory, "logs");
const report = join(logs, "report.txt");
for (const path of [project, workspace, logs]) mkdirSync(path, { mode: 0o700 });
const secret = randomBytes(32).toString("hex");
const expected = Buffer.from("Bearer " + secret);
const firstPrompt = "What is the capital of France? Answer in one short sentence.";
const secondPrompt = "What country did my first message mention? Name only the country.";
const targets = [];
let releaseFirst;
const firstPartialCanFinish = new Promise(resolve => { releaseFirst = resolve; });
let rejectNextRequest = false;
let rejected = 0;
let appPID;
let keySaved = false;

function record(text) {
  assert(!text.includes(secret), "A verification message contained the API key.");
  appendFileSync(report, text + "\n", { mode: 0o600 });
  console.log(text);
}

const server = createServer(async (request, response) => {
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
    const result = await fetch("http://127.0.0.1:18541/v1/chat/completions", {
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

function replyVisible(target) {
  const plain = (text) => text.replace(/\\[nrt]/g, " ").replace(/[\p{P}\p{S}\s]+/gu, " ").trim();
  const reply = plain(target.fragments.join(""));
  return reply.length > 0 && plain(tree()).includes(reply);
}

async function launch(first) {
  execFileSync("/usr/bin/open", [
    "-n", "-a", app, "--stdout", join(logs, first ? "first.out" : "second.out"),
    "--stderr", join(logs, first ? "first.err" : "second.err"),
    "--env", "SHELL=" + (worktreeTest ? terminalFixture : "/bin/sh"), "--args", "--workspace", workspace,
  ]);
  const id = await until(() => {
    const result = execFileSync("/bin/ps", ["-axo", "pid=,args="], { encoding: "utf8" });
    const process = result.split("\n").find(line => line.includes("/MacOS/PiWorkspace --workspace " + workspace));
    return process && Number(process.trim().split(/\s+/)[0]);
  }, "app process");
  appPID = id;
  await until(() => visible("model-settings"), "main window");
  return id;
}

async function quit() {
  const id = appPID;
  press("terminate:");
  await until(() => {
    try { process.kill(id, 0); } catch { return true; }
    return false;
  }, "clean application exit");
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

async function setField(id, text) {
  try {
    drive("set", [id], text);
  } catch {
    drive("type", [id, "--replace"], text);
  }
  await until(() => drive("get", [id, "--values"]).includes("value=" + JSON.stringify(text)), id + " contents");
}

async function typePrompt(prompt) {
  await until(() => visible("composer"), "message composer");
  const displayed = () => drive("get", ["composer", "--values"]).includes("value=" + JSON.stringify(prompt));
  if (!displayed()) drive("type", ["composer", "--replace"], prompt);
  await until(displayed, "prompt text in the composer");
}

async function openProject() {
  press("open-project");
  await until(() => visible("project-path"), "Add project dialog");
  await setField("project-path", join(directory, "missing folder"));
  press("confirm-project");
  await until(() => visible("project-path-error"), "invalid path feedback");
  await setField("project-path", project);
  press("confirm-project");
  await until(() => tree().includes('value="Sample Project"') || tree().includes('description="Sample Project"'),
              "selected project in the window");
  const saved = JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  assert.equal(saved.projects.find(item => item.id === saved.selectedProject)?.path, project);
}

async function send(prompt) {
  await typePrompt(prompt);
  await until(() => !tree().includes("Opening thread…"), "Pi to become ready");
  press("send-message");
  await until(() => tree().includes("Preparing worktree…") || visible("stop-message"), "message send");
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
  writeFileSync(join(project, "base.txt"), "base content\n");
  git(project, "add", "base.txt");
  git(project, "commit", "-m", "Fixture base");
  writeFileSync(join(project, "base.txt"), "unsaved root checkout edit\n");
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

  press("toggle-changes");
  await until(() => visible("git-file-tty-proof.txt"), "untracked file in Changes");
  press("git-file-tty-proof.txt");
  await until(() => tree().includes("+") && tree().includes(checkout), "file contents in the diff");
  press("git-stage-tty-proof.txt");
  await until(() => git(checkout, "diff", "--cached", "--name-only") === "tty-proof.txt", "staged file in Git");
  const subject = "Verify the in-app commit";
  drive("type", ["git-commit-message"], subject);
  await until(() => drive("get", ["git-commit-message", "--values"]).includes("value=" + JSON.stringify(subject)),
              "typed commit message");
  await until(() => visible("git-commit").includes("enabled=true"), "enabled commit button");
  press("git-commit");
  await until(() => git(checkout, "log", "-1", "--format=%s") === subject, "commit recorded in Git");
  assert.equal(git(checkout, "show", "--format=", "--name-only", "HEAD"), "tty-proof.txt");
  assert.match(git(checkout, "status", "--porcelain"), /\?\? retained-shell\.txt/);
  assert.equal(git(project, "log", "-1", "--format=%s"), "Fixture base");
  press("toggle-changes");
  record("Changes displayed a real patch. Stage and Commit affected the requested file in the worktree; the other file stayed untracked.");
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
  writeFileSync(join(workspace, "workspace.json"), JSON.stringify({
    projects: [], model: { provider: "local", endpoint, model: "smollm2:135m", contextWindow: 8192 },
  }), { mode: 0o600 });

  record("Verification folder: " + directory);
  updateKey("--set-api-key-from-stdin", secret);
  keySaved = true;
  const firstPID = await launch(true);
  await settings();
  await until(() => visible("remove-api-key"), "saved Keychain entry");
  await closeSettings();
  await openProject();
  record("Open Project opened the app dialog. An invalid path showed an error; the valid folder was added and selected through the UI.");
  press("new-conversation");
  await until(() => visible("conversation-title"), "new conversation");
  record("App opened Sample Project, created a conversation, and found the Swift-provisioned Keychain item.");
  if (worktreeTest) {
    await chooseNewWorktree("main");
    await typePrompt(firstPrompt);
    await until(() => !tree().includes("Opening thread…"), "draft helper ready");
    press("send-message");
    await until(() => tree().includes("already exists"), "worktree creation error");
    assert(drive("get", ["composer", "--values"]).includes(firstPrompt));
    assert.equal(targets.length, 0);
    record("A branch collision stopped the send and kept the draft text.");
    await chooseNewWorktree("ui-worktree");
    record("Choosing New worktree left the project unchanged before the first send.");
  }

  await send(firstPrompt);
  await until(() => targets[0]?.fragments.length && tree().includes('id="streaming-reply"'), "partial reply on screen");
  assert(!targets[0].completed, "The model stream had already completed.");
  record("The actual SwiftUI window showed a partial reply while the response was still open.");
  releaseFirst();
  await until(() => targets[0]?.completed && replyVisible(targets[0]), "first reply on screen", 50_000);
  await until(() => visible("send-message"), "first turn settled");
  assert.equal(targets[0].status, 200);
  const previous = JSON.parse(readFileSync(join(workspace, "workspace.json"), "utf8"));
  const threadID = previous.projects[0].selectedConversation;
  const selectedThread = previous.projects[0].conversations.find(thread => thread.id === threadID);
  const checkout = selectedThread.location?.worktree?.path;
  record("First request returned HTTP 200. Reply: " + JSON.stringify(targets[0].fragments.join("").trim()));
  if (worktreeTest) await verifyCheckout(checkout);

  await quit();
  const secondPID = await launch(false);
  assert.notEqual(firstPID, secondPID);
  await until(() => replyVisible(targets[0]), "previous reply in the reopened window");
  await send(secondPrompt);
  await until(() => targets[1]?.completed && replyVisible(targets[1]), "second reply on screen", 50_000);
  await until(() => visible("send-message"), "second turn settled");
  assert.equal(targets[1].status, 200);
  assert.equal(targets.length, 2);
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
  await quit();
  const transcripts = inspectFiles();
  assert.equal(transcripts.length, 1);
  record("No auth.json or plaintext key under the project, app data, transcripts, or captured logs. Keychain test item removed.");
} catch (error) {
  let message = error.message.replaceAll(secret, "[redacted]");
  if (appPID) {
    let summary = "";
    try { summary = tree().replaceAll(secret, "[redacted]"); } catch { /* app exited */ }
    writeFileSync(join(logs, "failure-ui.txt"), summary, { mode: 0o600 });
    try { await quit(); } catch { try { process.kill(appPID, "SIGTERM"); } catch { /* exited */ } }
  }
  if (keySaved) {
    try { updateKey("--remove-api-key"); }
    catch { message += " (Keychain cleanup not confirmed)"; }
  }
  record("FAIL: " + message);
  process.exitCode = 1;
} finally {
  releaseFirst();
  server.closeAllConnections();
  server.close();
}
