import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { once } from "node:events";
import { appendFileSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const [tools, app, output, mode, projectPath] = process.argv.slice(2);
assert(["installed", "render"].includes(mode));
assert(projectPath, "Pass the Audit Project folder created by desktop_fixture.py prepare.");
const project = realpathSync(projectPath);
const runtime = mkdtempSync("/private/tmp/pi-swift-audit-run.");
const workspace = join(runtime, "workspace");
const inbox = join(runtime, "bitmap-inbox");
const shell = join(runtime, "audit-shell");
const executable = realpathSync(join(app, "Contents/MacOS/PiWorkspace"));
const baselinePrompt = "fixture stream";
const fullReply = "Fixture stream started. Second delta. Fixture complete.";
const key = randomBytes(32).toString("hex");
const expectedAuthorization = Buffer.from("Bearer " + key);
const report = join(output, mode + "-attempts.log");
const facts = { mode, bundle: app, executableSHA256: digest(readFileSync(executable)), project, runtime, states: [] };
let pid;
let provisioned = false;
let release;
const pending = new Promise(resolve => { release = resolve; });
const requests = [];
let rejectNext = false;

function digest(data) { return createHash("sha256").update(data).digest("hex"); }
function note(message) {
  const line = new Date().toISOString() + " " + message.replaceAll(key, "[redacted]");
  appendFileSync(report, line + "\n");
  console.log(line);
}
function command(file, args, input) {
  try {
    return execFileSync(file, args, { encoding: "utf8", input, timeout: 6_000, stdio: ["pipe", "pipe", "pipe"] });
  } catch (error) {
    throw new Error((error.stderr || error.message).trim().replaceAll(key, "[redacted]"));
  }
}
function git(...args) {
  return command("/usr/bin/git", ["--no-optional-locks", "-C", project, ...args]);
}
function ax(operation, ...args) { return command(join(tools, "ax"), [operation, String(pid), ...args]); }
function geometry(action = "snapshot") { return command(join(tools, "inspect"), [String(pid), executable, action]); }
function tree() {
  const raw = ax("dump", "--values").split('  role="AXMenuBar"')[0];
  return raw.replace(/^( +)[^\n]*id="open-panel"[^\n]*\n(?:(?:\1 +[^\n]*)\n)*/m, "");
}
function has(id) { try { return ax("get", id); } catch { return ""; } }
async function until(check, description, timeout = 12_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      const value = check();
      if (value) return value;
    } catch { /* the window may still be settling */ }
    await delay(120);
  }
  throw new Error("Timeout: " + description);
}

function keychain(action, input) {
  command(executable, ["--workspace", workspace, action], input);
}

async function launch() {
  const options = ["--workspace", workspace, "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark"];
  if (mode === "render") options.push("--audit-bitmap-inbox", inbox);
  command("/usr/bin/open", ["-n", "-g", "-a", app, "--stdout", join(runtime, "app.out"),
    "--stderr", join(runtime, "app.err"), "--env", "SHELL=" + shell,
    "--env", "LANG=en_US.UTF-8", "--args", ...options]);
  pid = await until(() => {
    const exactPrefix = executable + " --workspace " + workspace + " ";
    const line = command("/bin/ps", ["-axo", "pid=,args="]).split("\n")
      .find(line => line.trim().replace(/^\d+\s+/, "").startsWith(exactPrefix));
    return line && Number(line.trim().split(/\s+/)[0]);
  }, "disposable Pi PID");
  await until(() => has("model-settings"), "Pi Workspace main window");
  let view = JSON.parse(geometry());
  note("PID " + pid + " AX window " + JSON.stringify(view.window.rect) + " content " + JSON.stringify(view.contentAX));
  if (view.contentAX?.slice(2).join("x") !== "1080x720") {
    note(geometry("resize").trim());
    view = await until(() => {
      const current = JSON.parse(geometry());
      return current.contentAX?.slice(2).join("x") === "1080x720" && current;
    }, "1080×720 AX content");
  }
}

async function quit() {
  const target = pid;
  if (!target) return;
  try { ax("press", "terminate:"); } catch { process.kill(target, "SIGTERM"); }
  await until(() => {
    try { process.kill(target, 0); return false; } catch { return true; }
  }, "PID " + target + " exit", 8000);
  note("Exited disposable PID " + target);
  pid = undefined;
}

async function snapshot(id, markers, expected) {
  await until(() => {
    const axText = tree();
    return expected.every(marker => axText.includes(marker));
  }, id + " AX markers " + expected.join(", "));
  await delay(220);
  const rawTree = tree();
  const details = JSON.parse(geometry());
  assert.equal(details.contentAX?.slice(2).join("x"), "1080x720");
  assert(expected.every(marker => rawTree.includes(marker)), id + " AX markers changed");
  assert(!rawTree.includes(key), "disposable key appeared in AX");
  const stem = id + "." + mode;
  writeFileSync(join(output, stem + ".ax.txt"), rawTree);
  Object.assign(details, { mode, markers, expected, contentPoints: [1080, 720] });
  if (mode === "render") {
    const temporary = join(inbox, "request-next");
    writeFileSync(temporary, id);
    renameSync(temporary, join(inbox, "request"));
    const result = join(inbox, id + ".json");
    await until(() => existsSync(result), "supplementary bitmap " + id);
    details.bitmap = JSON.parse(readFileSync(result));
    assert.deepEqual(details.bitmap.pixels, [1080, 720], JSON.stringify(details.bitmap));
    assert.equal(details.bitmap.appearance, "NSAppearanceNameDarkAqua");
    copyFileSync(join(inbox, id + ".png"), join(output, id + ".png"));
  }
  writeFileSync(join(output, stem + ".json"), JSON.stringify(details, null, 2) + "\n");
  facts.states.push({ id, markers, pid });
  note(id + " recorded, focused=" + JSON.stringify(details.focus ?? null));
}

async function field(id, value, preferTyping = false) {
  const displayed = () => ax("get", id, "--values").includes("value=" + JSON.stringify(value));
  const set = () => command(join(tools, "ax"), ["set", String(pid), id], value);
  const type = () => command(join(tools, "ax"), ["type", String(pid), id, "--replace"], value);
  const methods = preferTyping ? [type, set, type] : [set, type];
  for (const apply of methods) {
    try {
      apply();
      await until(displayed, id + " value", 1200);
      if (id !== "composer" || has("send-message").includes("enabled=true")) return;
    } catch (error) { note(id + " input fallback: " + error.message); }
  }
  throw new Error(id + " did not accept fixture text");
}

async function openProject() {
  ax("press", "open-project");
  await snapshot("02-open-project", ["T3-03-add-project", "T3-04-local-folder", "SRC-S36"],
    ['id="project-path"', 'id="confirm-project"', 'id="browse-project"']);
  if (mode === "installed") {
    try {
      ax("press", "browse-project");
      const panel = await until(() => {
        const capture = JSON.parse(geometry("panel"));
        return capture.nodes.filter(node => node.role === "AXSheet" || node.subrole === "AXDialog").length >= 2 && capture;
      }, "nested system folder picker exposed by target PID", 2600);
      writeFileSync(join(output, "02-native-browse.installed.restricted.json"), JSON.stringify(panel, null, 2) + "\n");
      note("Browse… presented a nested panel on the target PID. Restricted AX roles saved.");
    } catch (error) {
      note("Browse… attempt: " + error.message);
      const panel = JSON.parse(geometry("panel"));
      writeFileSync(join(output, "02-native-browse.installed.restricted.json"), JSON.stringify(panel, null, 2) + "\n");
    }
    try { ax("key", "53"); } catch (error) { note("PID-targeted Escape: " + error.message); }
    await delay(450);
    if (!has("project-path")) ax("press", "open-project");
    await until(() => has("project-path"), "return to Pi native Add project sheet");
  }
  await field("project-path", join(runtime, "missing-folder"));
  ax("press", "confirm-project");
  await snapshot("03-invalid-project", ["T3-04-local-folder", "SRC-S36"],
    ['id="project-path-error"', "Choose an existing folder."]);
  await field("project-path", project);
  ax("press", "confirm-project");
  await until(() => !has("project-path") && tree().includes("Audit Project"), "project added through the sheet");
  const savedPath = readWorkspace().projects[0].path;
  assert.equal(realpathSync(savedPath), project);
  facts.savedProjectPath = savedPath;
  note("Add Project accepted the exact Audit Project folder through the app's native SwiftUI sheet.");
}

function readWorkspace() { return JSON.parse(readFileSync(join(workspace, "workspace.json"))); }
async function send(prompt) {
  const displayed = () => ax("get", "composer", "--values").includes("value=" + JSON.stringify(prompt));
  if (!displayed()) await field("composer", prompt, true);
  await until(() => has("send-message").includes("enabled=true"), "enabled Send");
  ax("press", "send-message");
}

const server = createServer(async (request, response) => {
  try {
    const authorization = Buffer.from(request.headers.authorization ?? "");
    if (authorization.length !== expectedAuthorization.length || !timingSafeEqual(authorization, expectedAuthorization)) {
      response.writeHead(401).end();
      return;
    }
    assert.equal(request.method, "POST");
    assert.equal(request.url, "/v1/chat/completions");
    const body = JSON.parse(await new Response(request).text());
    const entry = { body, deltas: [], completed: false };
    requests.push(entry);
    if (rejectNext) {
      entry.status = 401;
      response.writeHead(401, { "Content-Type": "application/json" }).end(JSON.stringify({
        error: { message: "Fixture provider rejected the request. Bearer " + key },
      }));
      return;
    }
    entry.status = 200;
    response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache" });
    const chunks = requests.length === 1
      ? ["Fixture stream started. ", "Second delta. ", "Fixture complete."]
      : ["Fixture thread resumed."];
    function frame(delta, finish_reason = null) {
      response.write("data: " + JSON.stringify({
        id: "fixture-" + requests.length, object: "chat.completion.chunk", created: 1795658400,
        model: body.model, choices: [{ index: 0, delta, finish_reason }],
      }) + "\n\n");
    }
    frame({ role: "assistant" });
    for (const token of chunks) {
      frame({ content: token });
      entry.deltas.push(token);
      if (requests.length === 1 && entry.deltas.length === 1) await pending;
      await delay(150);
    }
    frame({}, "stop");
    response.end("data: [DONE]\n\n");
    entry.completed = true;
  } catch (error) {
    note("Responder failure: " + error.message);
    response.destroy();
  }
});

try {
  for (const path of [workspace, inbox, output]) mkdirSync(path, { mode: 0o700, recursive: true });
  appendFileSync(report, "\n");
  assert(existsSync(join(project, ".git")));
  const originalDiff = git("diff", "--", "README.md");
  assert(originalDiff.includes("Uncommitted fixture line."));
  const originalReadme = digest(readFileSync(join(project, "README.md")));
  const desktopAppearance = command("/usr/bin/defaults", ["read", "-g", "AppleInterfaceStyle"]).trim();
  assert.equal(desktopAppearance, "Dark");
  facts.desktopAppearance = desktopAppearance;
  note(command(join(tools, "preflight"), []).trim());
  note("macOS appearance " + desktopAppearance + ", per-process language en and appearance Dark, with no Screen Recording request.");
  writeFileSync(shell, '#!/bin/sh\nprintf "Audit terminal ready\\n"\npwd -P\nexec /bin/sh -i\n', { mode: 0o700 });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const endpoint = "http://127.0.0.1:" + server.address().port + "/v1";
  writeFileSync(join(workspace, "workspace.json"), JSON.stringify({
    projects: [], model: { provider: "local", endpoint, model: "smollm2:135m", contextWindow: 8192 },
  }), { mode: 0o600 });
  keychain("--set-api-key-from-stdin", key);
  provisioned = true;
  facts.keychainService = "dev.piworkspace.model-key." + digest(workspace);
  await launch();
  await snapshot("01-empty", ["T3-02-empty", "SRC-S01"], ['id="empty-open-project"', "Add Project"]);
  await openProject();
  ax("press", "new-conversation");
  await until(() => has("composer") && !tree().includes("Opening thread…"), "Pi draft ready");
  await snapshot("04-draft", ["T3-05-draft", "SRC-S02"], ['id="composer"', "Audit Project", "New Thread"]);
  await field("composer", baselinePrompt, true);
  await snapshot("05-prompt", ["T3-16-prompt", "SRC-S20"], ['id="composer"', baselinePrompt, 'id="send-message"']);
  await send(baselinePrompt);
  await until(() => requests[0]?.deltas.length === 1 && has("streaming-reply"), "visible held first streaming delta");
  assert.equal(requests[0].completed, false);
  await snapshot("06-running", ["T3-17-first-send", "T3-27-running", "SRC-S22", "SRC-S23"],
    ["Fixture stream started.", 'id="streaming-reply"', 'id="stop-message"']);
  assert.equal(requests[0].completed, false);
  release();
  await until(() => requests[0].completed && has("send-message"), "settled first turn");
  await snapshot("07-completed", ["T3-18-first-result", "SRC-S23"], [baselinePrompt, fullReply, 'id="send-message"']);
  const thread = readWorkspace().projects[0].selectedConversation;
  facts.threadID = thread;
  const firstPID = pid;
  await quit();
  await launch();
  assert.notEqual(pid, firstPID);
  assert.equal(thread, readWorkspace().projects[0].selectedConversation);
  await snapshot("08-restored-history", ["T3-46-relaunch", "T3-47-reopened", "SRC-S03"], [baselinePrompt, fullReply]);
  await send("fixture resume");
  await until(() => requests[1]?.completed && has("send-message"), "settled resumed turn");
  const restored = requests[1].body.messages;
  assert(restored.some(message => message.role === "user" && JSON.stringify(message.content).includes(baselinePrompt)));
  assert(restored.some(message => message.role === "assistant" && JSON.stringify(message.content).includes(fullReply)));
  await snapshot("09-resumed-turn", ["T3-48-resumed", "SRC-S03", "SRC-S23"], [fullReply, "Fixture thread resumed."]);
  rejectNext = true;
  await send("fixture fail");
  await until(() => requests[2]?.status === 401 && tree().includes("[API key removed]") && has("send-message"), "redacted provider error settled");
  await snapshot("10-failure", ["T3-29-failed", "SRC-S35"], ["Fixture provider rejected the request.", "[API key removed]"]);
  facts.error = tree().split("\n").find(line => line.includes("Fixture provider rejected"));
  assert(!facts.error.includes(key));
  ax("press", "model-settings");
  await snapshot("11-model-settings", ["T3-30-settings-launch", "T3-S-providers", "SRC-S48"],
    ["Model Settings", "Local OpenAI-compatible", 'id="model-id"', 'id="endpoint"', 'id="remove-api-key"']);
  ax("press", "save-settings");
  await until(() => !has("save-settings"), "settings dismissed");
  ax("press", "toggle-changes");
  await until(() => has("git-file-README.md"), "README.md in Changes");
  ax("press", "git-file-README.md");
  await snapshot("12-changes", ["T3-39-git-diff", "T3-40-patch", "SRC-S13"],
    ["Changes", 'id="git-file-README.md"', 'id="git-patch"', "Uncommitted fixture line."]);
  ax("press", "toggle-changes");
  ax("press", "toggle-terminal");
  await until(() => has("thread-terminal") && tree().includes("Audit terminal ready"), "interactive shell ready");
  for (const code of ["35", "13", "2", "36"]) {
    ax("key", code);
    await delay(150);
  }
  const terminal = await until(() => {
    const text = ax("get", "thread-terminal", "--values");
    return text.includes("pwd") && (text.includes(project) || text.includes(facts.savedProjectPath)) && text;
  }, "interactive pwd output", 3000).catch(error => {
    note("Terminal keyboard receipt: " + error.message);
    return ax("get", "thread-terminal", "--values");
  });
  const terminalPath = terminal.includes(project) ? project : facts.savedProjectPath;
  assert(terminal.includes(terminalPath), "Terminal AX value has no fixture working directory");
  assert.equal(realpathSync(terminalPath), project);
  facts.terminal = { path: terminalPath, typedPwd: terminal.includes("pwd") };
  await snapshot("13-terminal", ["T3-42-terminal-drawer", "T3-43b-terminal-local", "SRC-S14"],
    ['id="thread-terminal"', "Audit terminal ready", terminalPath]);
  assert.equal(git("diff", "--", "README.md"), originalDiff);
  assert.equal(digest(readFileSync(join(project, "README.md"))), originalReadme);
  assert.equal(requests.length, 3);
  facts.requests = requests.map(({ status, deltas, completed, body }) => ({
    status, deltas, completed, model: body.model, conversationRoles: body.messages.map(item => item.role),
  }));
  facts.sessionFiles = readdirSync(workspace, { recursive: true }).filter(name => name.endsWith(".jsonl"));
  assert.equal(facts.sessionFiles.length, 1);
  note("Three authenticated SDK requests returned HTTP 200, 200 and 401. A new PID restored the same thread and sent prior user and assistant messages.");
  note("Verified README.md diff and content unchanged. Terminal shell working directory matched disposable project.");
  await quit();
  keychain("--remove-api-key");
  provisioned = false;
  for (const file of readdirSync(runtime, { recursive: true, withFileTypes: true })) {
    assert.notEqual(file.name, "auth.json");
    if (file.isFile()) assert(!readFileSync(join(file.parentPath, file.name)).includes(key), file.name + " contains disposable key");
  }
  facts.status = "passed";
  facts.keyRemoved = true;
  note("Removed workspace-scoped Keychain item. No plaintext fixture key or auth.json in run directory.");
} catch (error) {
  facts.status = "failed";
  facts.failure = error.message.replaceAll(key, "[redacted]");
  note("FAIL: " + facts.failure);
  if (pid) {
    try { writeFileSync(join(output, mode + "-failure.ax.txt"), tree().replaceAll(key, "[redacted]")); } catch {}
    try { await quit(); } catch (cleanupError) { note(cleanupError.message); }
  }
  if (provisioned) {
    try { keychain("--remove-api-key"); facts.keyRemoved = true; }
    catch (cleanupError) { note(cleanupError.message); }
  }
  process.exitCode = 1;
} finally {
  release();
  server.closeAllConnections();
  server.close();
  writeFileSync(join(output, mode + "-result.json"), JSON.stringify(facts, null, 2) + "\n");
}
