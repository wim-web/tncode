import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";
import { seedPaletteMessageHistory } from "./fixtures/palette-message-history.mjs";

const [bundle, driver] = process.argv.slice(2).map(path => resolve(path));
assert(bundle && driver, "Usage: node verify-welcome-projects.mjs APP AX_DRIVER");
const exec = (file, args) => execFileSync(file, args, { encoding: "utf8", timeout: 10_000, stdio: "pipe" });
assert.match(exec(driver, ["trust"]), /accessibility=true/);
exec("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle]);

const root = exec(driver, ["workspace-path", mkdtempSync("/private/tmp/pi-welcome-ax-")]).trimEnd();
const workspace = join(root, "workspace");
const agent = join(root, "agent");
const alpha = join(root, "Alpha Fixture");
const beta = join(root, "Beta Fixture");
const moved = join(root, "Moved Beta");
const sessions = join(agent, "sessions");
const index = join(workspace, "workspace.json");
const sidecar = join(bundle, "Contents/Resources/Sidecar");
const sdk = join(sidecar, "node_modules/@earendil-works/pi-coding-agent");
assert.equal(JSON.parse(readFileSync(join(sdk, "package.json"))).version, "1.6.1");
for (const path of [workspace, agent, alpha, beta]) mkdirSync(path, { mode: 0o700 });
process.env.PI_CODING_AGENT_DIR = agent;
process.env.PI_OFFLINE = "1";
process.env.PI_TELEMETRY = "0";
const { SessionManager } = await import(pathToFileURL(join(sdk, "dist/index.js")).href);

function seed(cwd, name) {
  const session = SessionManager.create(cwd);
  session.appendSessionInfo(name);
  session.appendMessage({ role: "user", content: "Disposable fixture prompt.", timestamp: Date.now() });
  session.appendMessage({
    role: "assistant", content: [{ type: "text", text: "Disposable fixture reply." }],
    api: "openai-completions", provider: "local", model: "fixture", stopReason: "stop", timestamp: Date.now(),
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
  });
  return session.getSessionFile();
}

let pid;
let launchNumber = 0;
const readIndex = () => JSON.parse(readFileSync(index));
const ax = (operation, ...args) => exec(driver, [operation, String(pid), ...args]);
const get = (id, ...extra) => ax("get", id, "--values", ...extra);
const press = id => ax("press", id, "--no-activate");
async function until(description, predicate) {
  const end = Date.now() + 12_000;
  let lastError;
  do {
    try {
      const result = predicate();
      if (result) return result;
    } catch (error) { lastError = error; }
    await delay(100);
  } while (Date.now() < end);
  throw new Error(description, { cause: lastError });
}
async function expect(id, text, depth = "0") {
  return until(id + " exposes " + text, () => {
    const snapshot = get(id, "--depth", depth);
    if (snapshot.includes(text)) return snapshot;
  });
}
async function launch(expected) {
  launchNumber += 1;
  exec("/usr/bin/open", ["-gn", "-a", bundle, "--stdout", join(root, launchNumber + ".out"),
    "--stderr", join(root, launchNumber + ".err"), "--env", "PI_CODING_AGENT_DIR=" + agent,
    "--args", "-AppleLanguages", "(en)", "--workspace", workspace, "-ApplePersistenceIgnoreState", "YES"]);
  pid = await until("isolated Pi Workspace PID", () => Number(exec("/bin/ps", ["-axo", "pid=,args="])
    .split("\n").find(line => line.includes("/MacOS/PiWorkspace --workspace " + workspace + " "))
    ?.trim().split(/\s+/)[0]));
  await until(expected, () => get(expected));
}
async function quit() {
  try { press("terminate:"); }
  catch (error) { if (!/AX error -2520[045]/.test(String(error.stderr))) throw error; }
  await until("application quit", () => {
    try { process.kill(pid, 0); return false; } catch { return true; }
  });
  pid = undefined;
}
const welcome = () => ax("menu-item", "Show Welcome", "--no-activate");
const scanStatus = "welcome-pi-scan-status";
const select = path => "welcome-pi-select-" + path;
const open = path => "welcome-pi-open-" + path;
const selection = count => expect("welcome-pi-selection", count + " selected");
const draft = "Keep this active Pi Workspace draft.";

try {
  await launch("welcome-find-pi-projects");
  assert(!existsSync(index), "Welcome must not register projects at launch.");
  press("welcome-find-pi-projects");
  console.log((await expect(scanStatus, "No projects found")).trim());
  writeFileSync(sessions, "");
  press("welcome-pi-rescan");
  console.log((await expect("welcome-pi-scan-error", "Could not read the local Pi sessions folder")).trim());
  rmSync(sessions);
  const sourceFiles = [seed(alpha, "Named Alpha session"), seed(beta, "Named Beta session")];
  const sourceBytes = sourceFiles.map(path => readFileSync(path));

  press("welcome-pi-retry");
  await selection(0);
  press("welcome-pi-select-all");
  console.log((await selection(2)).trim());
  press("welcome-pi-select-none");
  console.log((await selection(0)).trim());
  press("welcome-pi-history-" + alpha);
  const namedSession = await until("Named SDK session in AX", () =>
    ax("dump", "--values", "--depth", "20").split("\n").find(line => line.includes("Named Alpha session")));
  console.log(namedSession.trim());
  press(select(alpha));
  console.log((await selection(1)).trim());
  press("welcome-pi-register");
  await expect("welcome-pi-registered", "Selected projects registered");
  assert.deepEqual(readIndex().projects.map(project => project.path), [alpha]);
  press(open(alpha));
  await until("opened project composer", () => get("composer"));
  await quit();

  const state = readIndex();
  const project = state.projects[0];
  const active = project.conversations.find(thread => thread.id === project.selectedConversation);
  active.composerText = draft;
  const historyID = randomUUID().toUpperCase();
  project.conversations.push({ id: historyID, title: "Saved conversation", archived: false, isDraft: false });
  const { historyPath, latestID } = await seedPaletteMessageHistory({
    sidecar, workspace, projectID: project.id, threadID: historyID, cwd: alpha, keyword: "Native fixture history",
  });
  const managedHistory = readFileSync(historyPath);
  writeFileSync(index, JSON.stringify(state));

  await launch("composer");
  await expect("composer", draft);
  welcome();
  await expect("welcome-find-pi-projects", "Find Pi Projects");
  press("welcome-find-pi-projects");
  await selection(0);
  press(select(beta));
  await selection(1);
  renameSync(beta, moved);
  press("welcome-pi-register");
  console.log((await expect("welcome-pi-action-error", "changed or is unavailable")).trim());
  assert.deepEqual(readIndex().projects.map(project => project.id), [project.id]);
  renameSync(moved, beta);
  press("welcome-pi-rescan");
  await selection(1);
  press("welcome-pi-register");
  await expect("welcome-pi-registered", "Selected projects registered");
  press(open(alpha));
  await expect("composer", draft);
  await quit();

  await launch("composer");
  await expect("composer", draft);
  const final = readIndex();
  assert.equal(final.selectedProject, project.id);
  assert.equal(final.projects[0].selectedConversation, active.id);
  assert.deepEqual(final.projects[0].conversations.map(thread => thread.id), [active.id, historyID]);
  assert.deepEqual(final.projects.map(project => project.path), [alpha, beta]);
  assert.deepEqual(readFileSync(historyPath), managedHistory);
  press("thread-row-" + historyID);
  await expect("transcript-message-" + latestID, "Latest active fixture reply.", "6");
  await quit();
  assert.deepEqual(readFileSync(historyPath).subarray(0, managedHistory.length), managedHistory);
  assert.deepEqual(sourceFiles.map(path => readFileSync(path)), sourceBytes);
  console.log("Passed background Welcome AX run. SDK titles, selection, retries, two launches, project and draft UUIDs, and original history bytes verified.");
} finally {
  if (pid) process.kill(pid, "SIGTERM");
  console.log("Private fixture", root);
}
