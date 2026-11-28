import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const [driver, bundle] = process.argv.slice(2).map(path => resolve(path));
assert(driver && bundle, "Pass the AX driver and a packaged tncode.app.");
assert.match(execFileSync(driver, ["trust"], { encoding: "utf8" }), /accessibility=true/);
const binary = join(bundle, "Contents/MacOS/tncode");
const root = mkdtempSync("/private/tmp/pi-commit-generation-");
const workspace = join(root, "workspace");
const project = join(root, "project");
const topic = join(root, "topic");
mkdirSync(workspace);
mkdirSync(project);
const gitEnv = { ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_"))),
  GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1", GIT_OPTIONAL_LOCKS: "0" };
const git = (cwd, ...args) => execFileSync("/usr/bin/git", ["-C", cwd, ...args], { env: gitEnv, encoding: "utf8" });
const head = cwd => git(cwd, "rev-parse", "HEAD").trim();
const write = (cwd, path, text) => writeFileSync(join(cwd, path), text + "\n");
git(project, "init", "--template=", "-b", "main");
for (const [key, value] of Object.entries({ "user.name": "Fixture", "user.email": "fixture@example.invalid",
  "commit.gpgsign": "false", "core.hooksPath": join(root, "hooks") })) {
  git(project, "config", key, value);
}
for (const path of ["kept.txt", "tracked.txt"]) write(project, path, "base");
git(project, "add", "--all");
git(project, "commit", "-m", "Base");
const base = head(project);
git(project, "worktree", "add", "-b", "topic", topic);
git(topic, "branch", "other");
write(project, "tracked.txt", "original-checkout-edit");
write(topic, "kept.txt", "excluded-index-sentinel");
git(topic, "add", "kept.txt");
write(topic, "kept.txt", "excluded-worktree-sentinel");
write(topic, "tracked.txt", "excluded-unstaged-sentinel");
write(topic, "selected.txt", "selected-patch-sentinel");
write(topic, "manual.txt", "manual-patch-sentinel");
const index = git(topic, "rev-parse", "--path-format=absolute", "--git-path", "index").trim();
const originalIndex = readFileSync(index);
const cached = git(topic, "diff", "--cached");
const unstaged = git(topic, "diff");
function unchanged() {
  assert.equal(head(topic), base);
  assert.equal(head(project), base);
  assert.deepEqual(readFileSync(index), originalIndex);
  assert.equal(git(topic, "diff", "--cached"), cached);
  assert.equal(git(topic, "diff"), unstaged);
}

const key = randomBytes(32).toString("hex");
const subject = "Describe the selected fixture patch";
const requests = [];
let mode = "deny";
const server = createServer(async (req, response) => {
  if (req.url !== "/v1/chat/completions" || req.method !== "POST" || req.headers.authorization !== "Bearer " + key) {
    response.writeHead(401).end();
    return;
  }
  const body = await new Response(req).json();
  const request = { body, closed: false };
  response.once("close", () => { request.closed = true; });
  request.reply = () => {
    const chunk = (delta, finish_reason) => "data: " + JSON.stringify({
      id: "fixture", object: "chat.completion.chunk", created: 1, model: body.model,
      choices: [{ index: 0, delta, finish_reason }],
    }) + "\n\n";
    response.writeHead(200, { "Content-Type": "text/event-stream" }).end(
      chunk({ role: "assistant", content: JSON.stringify({ subject, body: "" }) }, null) +
      chunk({}, "stop") + "data: [DONE]\n\n");
  };
  requests.push(request);
  if (mode === "deny") response.writeHead(403, { "Content-Type": "application/json" })
    .end(JSON.stringify({ error: { message: "fixture denied the selected model" } }));
  if (mode === "success") request.reply();
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
const endpoint = "http://127.0.0.1:" + server.address().port + "/v1";
const uuid = () => randomUUID().toUpperCase();
const [projectID, topicID, parentID] = [uuid(), uuid(), uuid()];
const model = { provider: "local", model: "fixture-subject", endpoint, contextWindow: 8192, localTools: true };
writeFileSync(join(workspace, "workspace.json"), JSON.stringify({
  selectedProject: projectID, welcomeCompleted: true, model: { ...model, model: "unused-workspace-model" },
  projects: [{ id: projectID, title: "Fixture", path: project, allowEdits: false, modelOverride: model,
    selectedConversation: topicID, conversations: [
      { id: topicID, title: "Topic", isDraft: true, archived: false, composerText: "Topic draft",
        location: { worktree: { path: topic, base: "main" } } },
      { id: parentID, title: "Parent", isDraft: true, archived: false, composerText: "Parent draft" },
    ] }],
}));
let pid;
let installedKey = false;
async function until(check, label) {
  for (let attempt = 0; attempt < 150; attempt++) {
    try { const result = check(); if (result) return result; } catch { /* The AX control is still loading. */ }
    await delay(100);
  }
  throw new Error("Timed out waiting for " + label);
}
const drive = (command, ...args) => execFileSync(driver, [command, String(pid), ...args],
  { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
const press = id => drive("press", id, "--no-activate");
const get = id => drive("get", id, "--values");
const enabled = (id, value = true) => get(id).includes("enabled=" + value);
const ready = () => until(() => enabled("git-commit"), "enabled commit");
const found = (id, text) => until(() => get(id).includes(text), id + " " + text);
const has = id => { try { return Boolean(get(id)); } catch { return false; } };
async function openChanges() {
  if (!has("hide-right-panel")) press("toggle-right-panel");
  await found("add-panel-surface", "enabled=true");
  press("add-panel-surface");
  await found("add-panel-changes", "enabled=true");
  // The menu closes as Changes opens, which can end the press with an AX error.
  try { press("add-panel-changes"); }
  catch (error) { if (!/AX error -2520[045]/.test(String(error.stderr))) throw error; }
}
const observedRequest = count => until(() => requests[count - 1], "provider request " + count);
function verifyRequests(count) {
  assert.equal(requests.length, count);
  for (const { body } of requests) {
    assert.equal(body.model, model.model);
    assert(!body.tools?.length, "Generation needs no tools.");
    const message = JSON.stringify(body.messages.filter(message => message.role === "user"));
    assert.match(message, /selected-patch-sentinel/);
    assert.doesNotMatch(message, /excluded-|manual-patch-sentinel|original-checkout|Topic draft|Parent draft/);
  }
}

try {
  execFileSync(binary, ["--workspace", workspace, "--set-api-key-from-stdin"], { input: key });
  installedKey = true;
  execFileSync("/usr/bin/open", ["-g", "-n", "-a", bundle, "--stdout", join(root, "app.out"), "--stderr", join(root, "app.err"),
    "--env", "GIT_CONFIG_NOSYSTEM=1", "--env", "GIT_CONFIG_GLOBAL=/dev/null",
    "--args", "-AppleLanguages", "(en)", "--workspace", workspace, "-ApplePersistenceIgnoreState", "YES"]);
  pid = await until(() => execFileSync("/bin/ps", ["-axo", "pid=,args="], { encoding: "utf8" }).split("\n")
    .find(line => line.includes("/MacOS/tncode --workspace " + workspace + " "))?.trim().split(/\s+/)[0], "app PID");
  await found("toggle-right-panel", "enabled=true");
  await openChanges();
  await found("git-include-selected.txt", "enabled=true");
  press("git-include-all");
  await until(() => enabled("git-commit", false), "disabled commit with no selection");
  press("git-include-selected.txt");
  await found("git-selection-count", "1 of 4 selected");
  assert(enabled("git-commit"), "Commit must be enabled with one selected file and a blank subject.");
  execFileSync(driver, ["set", pid, "git-commit-message"], { input: "Temporary subject" });
  await found("git-commit-message", "Temporary subject");
  execFileSync(driver, ["set", pid, "git-commit-message"], { input: " " });
  await found("git-commit-message", 'value=" "');
  assert.equal(requests.length, 0);
  unchanged();
  console.log("Opening, changing file selection, and editing the subject made zero provider requests.");

  press("git-commit");
  await found("git-error", "fixture denied the selected model");
  unchanged();
  await ready();
  console.log("HTTP 403 preserved HEAD and the exact index. The same selection stayed available for retry.");

  mode = "hold";
  press("git-commit");
  const cancelled = await observedRequest(2);
  await found("git-commit-generating", "Generating commit message");
  press("git-commit-cancel");
  await until(() => cancelled.closed, "cancelled Pi stream");
  await ready();
  unchanged();

  press("git-commit");
  const edited = await observedRequest(3);
  write(topic, "selected.txt", "changed while generating");
  edited.reply();
  await found("git-error", "selected changes have changed");
  unchanged();
  write(topic, "selected.txt", "selected-patch-sentinel");
  await ready();

  press("git-commit");
  const switchedRef = await observedRequest(4);
  git(topic, "switch", "other");
  const switchedIndex = readFileSync(index);
  switchedRef.reply();
  await found("git-error", "checkout or comparison branch changed");
  assert.equal(head(topic), base);
  assert.equal(git(topic, "branch", "--show-current").trim(), "other");
  assert.deepEqual(readFileSync(index), switchedIndex);
  git(topic, "switch", "topic");
  press("git-refresh");
  await ready();

  press("git-commit");
  const moved = await observedRequest(5);
  press("thread-row-" + parentID);
  await found("composer", "Parent draft");
  await until(() => moved.closed, "checkout navigation cancelled Pi stream");
  assert.equal(head(topic), base);
  assert.equal(head(project), base);
  assert.equal(git(topic, "diff", "--cached"), cached);
  assert.equal(git(topic, "diff"), unstaged);
  console.log("Cancel, selected-content changes, same-SHA branch switch, and checkout navigation each prevented a commit.");

  press("thread-row-" + topicID);
  await found("composer", "Topic draft");
  await found("git-include-selected.txt", "enabled=true").catch(async () => {
    await openChanges();
    await found("git-include-selected.txt", "enabled=true");
  });
  const inclusion = get("git-include-selected.txt");
  if (!inclusion.includes("value=1")) press("git-include-selected.txt");
  if (!get("git-selection-count").includes("1 of 4 selected")) {
    if (!get("git-selection-count").includes("4 of 4 selected")) {
      // A mixed Include all box selects everything on the first press.
      press("git-include-all");
      await found("git-selection-count", "4 of 4 selected");
    }
    press("git-include-all");
    press("git-include-selected.txt");
  }
  await found("git-selection-count", "1 of 4 selected");
  mode = "success";
  mkdirSync(join(root, "hooks"));
  const hook = join(root, "hooks", "pre-commit");
  writeFileSync(hook, "#!/bin/sh\nprintf 'Fixture hook rejected the commit\\n' >&2\nexit 1\n", { mode: 0o700 });
  const beforeHook = readFileSync(index);
  press("git-commit");
  await found("git-error", "Fixture hook rejected the commit");
  assert.equal(head(topic), base);
  assert.deepEqual(readFileSync(index), beforeHook);
  await ready();
  writeFileSync(hook, "#!/bin/sh\nexit 0\n");
  press("git-commit");
  await until(() => git(topic, "log", "-1", "--format=%s").trim() === subject, "generated commit subject");
  await found("git-selection-count", "0 of 3 selected");
  assert.equal(git(topic, "show", "-s", "--format=%P").trim(), base);
  assert.equal(git(topic, "show", "--format=", "--name-only"), "selected.txt\n");
  assert.equal(git(topic, "show", "HEAD:selected.txt"), "selected-patch-sentinel\n");
  assert.equal(git(topic, "diff", "--cached"), cached);
  assert.equal(git(topic, "diff"), unstaged);
  assert.match(git(topic, "status", "--short"), /\?\? manual\.txt/);
  verifyRequests(7);
  const generated = head(topic);
  console.log(git(topic, "show", "--format=raw", "--stat", generated));

  press("git-include-manual.txt");
  const manualSubject = "Manual fixture subject";
  execFileSync(driver, ["set", pid, "git-commit-message"], { input: manualSubject });
  await found("git-commit-message", manualSubject);
  await ready();
  press("git-commit");
  await until(() => git(topic, "log", "-1", "--format=%s").trim() === manualSubject, "manual commit");
  assert.equal(git(topic, "show", "--format=", "--name-only"), "manual.txt\n");
  assert.equal(git(topic, "show", "-s", "--format=%P").trim(), generated);
  assert.equal(head(project), base);
  assert.equal(git(project, "show", "-s", "--format=%s").trim(), "Base");
  assert.match(git(project, "diff"), /original-checkout-edit/);
  assert.equal(git(topic, "diff", "--cached"), "");
  assert.match(git(topic, "diff"), /excluded-worktree-sentinel/);
  verifyRequests(7);
  console.log("Manual commit used the typed subject and selected path without contacting Pi.");
} finally {
  server.closeAllConnections();
  server.close();
  console.log("Evidence checkout: " + root);
  if (pid) {
    try { process.kill(Number(pid), "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
    await until(() => {
      try { process.kill(Number(pid), 0); return false; }
      catch (error) { return error.code === "ESRCH"; }
    }, "app exit");
  }
  if (installedKey) execFileSync(binary, ["--workspace", workspace, "--remove-api-key"]);
}
