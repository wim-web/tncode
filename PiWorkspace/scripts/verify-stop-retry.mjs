// Usage: node verify-stop-retry.mjs "/path/to/Pi Workspace.app" /path/to/trusted/ax
import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const [packagePath, driverPath] = process.argv.slice(2);
assert(packagePath && driverPath, "Pass the signed app bundle and compiled macOS AX driver.");
const packagedApp = realpathSync(packagePath);
const ax = realpathSync(driverPath);
const run = (file, args, options = {}) =>
  execFileSync(file, args, { encoding: "utf8", timeout: 5_000, stdio: ["pipe", "pipe", "pipe"], ...options }).trimEnd();
assert.match(run(ax, ["trust"]), /accessibility=true/);
const root = mkdtempSync("/private/tmp/pi-stop-retry-");
const app = join(root, "Pi Workspace.app");
const executable = join(app, "Contents/MacOS/PiWorkspace");
const node = join(app, "Contents/Helpers/node");
const worker = join(app, "Contents/Resources/Sidecar/worker.mjs");
const watchdog = join(root, "stop-retry-watchdog");
const workspace = run(ax, ["workspace-path", join(root, "workspace")]);
const project = join(root, "project");
const pasteboard = "dev.piworkspace.verification." + randomUUID();
const codesign = "/usr/bin/codesign";
const verifySignatures = path => {
  run(codesign, ["--verify", "--deep", "--strict", path], { timeout: 30_000 });
  run(codesign, ["--verify", "--strict", join(path, "Contents/Helpers/node")]);
};
verifySignatures(packagedApp);
run("/usr/bin/ditto", [packagedApp, app], { timeout: 60_000 });
verifySignatures(app);
for (const binary of [app, node]) {
  const signature = spawnSync(codesign, ["--display", "--verbose=4", binary], { encoding: "utf8" });
  assert.equal(signature.status, 0);
  console.log(signature.stderr.split("\n").filter(line => /^(Identifier|CDHash|Signature|TeamIdentifier)=/.test(line)).join(" "));
}
run("/usr/bin/swiftc", ["-module-cache-path", join(root, "module-cache"),
  join(import.meta.dirname, "fixtures/stop-retry-watchdog.swift"), "-o", watchdog], { timeout: 60_000 });
for (const path of [workspace, project]) mkdirSync(path, { mode: 0o700 });
console.log("Fixture and app logs " + root);

const [projectID, threadID] = [randomUUID(), randomUUID()].map(id => id.toUpperCase());
const prompt = "Start the held reply.";
const first = { id: randomUUID().toUpperCase(), text: prompt };
const waiting = { id: randomUUID().toUpperCase(), text: "Keep this queued after Stop." };
const partial = "Partial reply from the bundled worker.";
const key = randomBytes(32).toString("hex");
const model = "stop-retry-fixture";
const index = join(workspace, "workspace.json");
const savedQueue = () => JSON.parse(readFileSync(index, "utf8")).projects.find(p => p.id === projectID)
  .conversations.find(thread => thread.id === threadID).queuedMessages ?? [];

let requests = 0;
let closedStreams = 0;
let rejection;
const server = createServer(async (request, response) => {
  requests++;
  try {
    assert.equal(request.method, "POST");
    assert.equal(request.url, "/v1/chat/completions");
    assert(request.headers.authorization === "Bearer " + key, "Wrong generated credential.");
    assert.equal(requests, 1, "A second request reached the provider.");
    const json = JSON.parse(await new Response(request).text());
    assert.equal(json.model, model);
    assert.equal(json.stream, true);
    const users = json.messages.filter(({ role }) => role === "user");
    assert.equal(users.length, 1);
    assert(JSON.stringify(users[0].content).includes(prompt));
    response.on("close", () => { closedStreams++; });
    // Leave the completion open. Only the bundled worker's cancellation should close it.
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    response.write("data: " + JSON.stringify({
      id: "stop-retry", object: "chat.completion.chunk", created: 1, model,
      choices: [{ index: 0, delta: { role: "assistant", content: partial }, finish_reason: null }],
    }) + "\n\n");
  } catch (error) {
    rejection = error;
    response.writeHead(400).end();
  }
});
server.listen(0, "127.0.0.1");
await once(server, "listening");
const endpoint = "http://127.0.0.1:" + server.address().port + "/v1";
const service = "dev.piworkspace.model-key." + createHash("sha256").update(workspace).digest("hex");
const keyCommand = (flag, input) => run(executable, ["--workspace", workspace, flag], {
  input, env: { ...process.env, PI_WORKSPACE_TEST_PASTEBOARD: pasteboard },
});
const ps = () => run("/bin/ps", ["-axww", "-o", "pid=,ppid=,command="]).split("\n").flatMap(line => {
  const row = /^\s*(\d+)\s+(\d+)\s+(.+)$/.exec(line);
  return row ? [{ pid: Number(row[1]), parent: Number(row[2]), command: row[3] }] : [];
});
const launchArgs = ["--workspace", workspace, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)"];
const isPrivateApp = row => row.command === [executable, ...launchArgs].join(" ");
const isPrivateWorker = row => row.parent === pid && [node, node.replace("/private/tmp/", "/tmp/")]
  .some(path => row.command === path + " " + worker);
let pid;
let workerPID;
let hold;
let holdClosed;
let holdOutput = "";
let credentialAttempted = false;

async function until(check, what, timeout = 15_000) {
  const deadline = performance.now() + timeout;
  while (performance.now() < deadline) {
    const result = check();
    if (result) return result;
    await delay(120);
  }
  throw new Error("Timed out waiting for " + what);
}
const checkBackground = () => run(watchdog, ["check", root, String(pid)]);
const drive = (action, args, options) => run(ax, [action, String(pid), ...args], options);
const tree = () => drive("dump", ["--values"]).split('  role="AXMenuBar"')[0];
const line = (snapshot, id) => snapshot.split("\n").find(text => text.includes('id="' + id + '"')) ?? "";
const enabled = (snapshot, id) => line(snapshot, id).includes("enabled=true");
const press = id => {
  checkBackground();
  drive("press", [id, "--no-activate"]);
};
const stopped = snapshot => line(snapshot, "stop-message").includes("enabled=false") && snapshot.includes("Stopping…");
const recordedMessages = () => {
  const session = join(workspace, "sessions", projectID, threadID);
  const files = readdirSync(session).filter(name => name.endsWith(".jsonl"));
  assert.equal(files.length, 1);
  return readFileSync(join(session, files[0]), "utf8").trimEnd().split("\n")
    .map(text => JSON.parse(text).message).filter(Boolean);
};

try {
  writeFileSync(index, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
    model: { provider: "local", model, endpoint, contextWindow: 8192 },
    projects: [{ id: projectID, title: "Stop retry", path: project, allowEdits: false, selectedConversation: threadID,
      conversations: [{ id: threadID, title: "Held reply", archived: false, isDraft: false, queuedMessages: [first, waiting] }],
    }],
  }), { mode: 0o600 });
  credentialAttempted = true;
  keyCommand("--set-api-key-from-stdin", key);
  run("/usr/bin/open", ["-g", "-j", "-n", "-a", app, "--stdout", join(root, "app.out"), "--stderr", join(root, "app.err"),
    "--env", "PI_WORKSPACE_TEST_PASTEBOARD=" + pasteboard, "--args", ...launchArgs]);
  pid = await until(() => {
    const matches = ps().filter(isPrivateApp);
    assert(matches.length <= 1, "More than one copy of the private app is running.");
    return matches[0]?.pid;
  }, "the unique background Launch Services app");
  await until(() => {
    try { return enabled(tree(), "resume-queue"); }
    catch (error) { if (!String(error.stderr).includes("AX error -252")) throw error; }
  }, "Resume Queue in the background composer");
  press("resume-queue");
  await until(() => {
    if (rejection) throw rejection;
    const snapshot = tree();
    return requests === 1 && enabled(snapshot, "stop-message") && line(snapshot, "streaming-reply").includes(partial);
  }, "the streamed partial reply and enabled Stop");
  await until(() => {
    const snapshot = tree();
    return line(snapshot, "queue-count").includes("1 queued message")
      && line(snapshot, "queued-message-" + waiting.id).includes(waiting.text);
  }, "the second queued item visible while the first is in flight");
  console.log("Resume Queue started the first item. The partial reply appeared, Stop was enabled, and the second item stayed queued.");

  const children = ps().filter(isPrivateWorker);
  assert.equal(children.length, 1, "Expected one bundled Pi child under the private app.");
  workerPID = children[0].pid;
  hold = spawn(watchdog, ["hold", root, String(pid), String(workerPID)], { detached: true, stdio: ["pipe", "pipe", "inherit"] });
  hold.stdin.on("error", () => {}); // A dead watchdog is detected via its exit status and receipts.
  hold.stdout.setEncoding("utf8").on("data", chunk => { holdOutput += chunk; });
  holdClosed = once(hold, "close");
  await until(() => {
    assert.equal(hold.exitCode, null, "The watchdog exited before suspending the worker.");
    return holdOutput.includes("held " + workerPID + "\n");
  }, "watchdog confirmation of the exact suspended child", 3_000);
  console.log("Verified and suspended bundled worker PID " + workerPID + " under background app PID " + pid + ".");

  checkBackground();
  const firstPress = performance.now();
  drive("press", ["stop-message", "--no-activate"]);
  const firstPressReturned = performance.now();
  await until(() => stopped(tree()), "Stop disabled with Stopping…", 3_000);
  let lastDisabled = performance.now();
  const readyAt = await until(() => {
    assert.equal(hold.exitCode, null, "Watchdog released the worker before the retry.");
    assert.equal(closedStreams, 0, "The provider stream closed before watchdog release.");
    const snapshot = tree();
    assert(line(snapshot, "streaming-reply").includes(partial), "The partial reply disappeared during Stop.");
    if (enabled(snapshot, "stop-message")) {
      const observed = performance.now();
      assert(observed - firstPress >= 10_000, "Retry became available before ten real seconds.");
      return snapshot.includes("Pi hasn’t confirmed. Try Stop again.") && observed;
    }
    if (stopped(snapshot)) lastDisabled = performance.now();
    else assert(performance.now() - firstPress >= 10_000, "Stop lost its pending state before the timeout.");
    return false;
  }, "Stop re-enabled with the retry notice", 13_000);
  const elapsed = value => ((value - firstPress) / 1_000).toFixed(3) + " s";
  const pressDuration = ((firstPressReturned - firstPress) / 1_000).toFixed(3) + " s";
  console.log("Stop stayed disabled through " + elapsed(lastDisabled) + " and was observed enabled at " +
    elapsed(readyAt) + " from the first AX press, which returned in " + pressDuration + ".");

  press("stop-message");
  await until(() => stopped(tree()), "the second Stop press disables it again", 3_000);
  assert.equal(closedStreams, 0);
  hold.stdin.end("R");
  assert.deepEqual(await holdClosed, [0, null]);
  assert.match(holdOutput, /resumed on request/);
  const settled = await until(() => {
    const snapshot = tree();
    return closedStreams === 1 && line(snapshot, "send-message") && enabled(snapshot, "resume-queue")
      && !line(snapshot, "stop-message") && !line(snapshot, "streaming-reply") && snapshot;
  }, "matching finish, idle composer, and enabled Resume Queue");
  checkBackground();
  assert(ps().some(row => row.pid === workerPID && isPrivateWorker(row)));
  assert(!line(settled, "reconnect-thread") && !line(settled, "composer-error"));
  assert(line(settled, "queue-count").includes("1 queued message"));
  assert.deepEqual(savedQueue(), [waiting]);
  const messages = recordedMessages().filter(({ role }) => role !== "system");
  assert.deepEqual(messages.map(({ role }) => role), ["user", "assistant"]);
  assert.equal(messages[0].workspaceQueuedID.toUpperCase(), first.id);
  assert(messages[0].content.some(({ text }) => text === prompt));
  assert.equal(messages[1].stopReason, "aborted");
  assert(messages[1].content.some(({ text }) => text === partial));
  assert(settled.includes(partial) && settled.includes("Pi skips this interrupted reply in future model requests."));
  await delay(500);
  if (rejection) throw rejection;
  assert.equal(requests, 1);
  assert.equal(closedStreams, 1);
  console.log("Second Stop disabled again. The same worker finished the turn. History has one user and one aborted assistant message.");
  console.log("One queued message remained paused with the same ID and text. Provider saw one request and one cancelled stream.");
} catch (error) {
  console.error(error.message);
  if (pid) {
    try { console.error(tree().split("\n").filter(text => /composer|stop-message|queue|streaming-reply|reconnect-thread/.test(text)).join("\n")); }
    catch {}
  }
  throw error;
} finally {
  if (hold) {
    if (!hold.stdin.writableEnded) hold.stdin.end();
    await holdClosed;
  }
  try {
    if (pid && ps().some(row => row.pid === pid && isPrivateApp(row))) {
      try { drive("press", ["terminate:", "--no-activate"]); }
      catch (error) { if (!/AX error -2520[045]/.test(String(error.stderr))) throw error; }
      await until(() => !ps().some(row => row.pid === pid || row.pid === workerPID), "application and bundled worker exit");
      console.log("The private app and bundled worker exited.");
    }
  } finally {
    try {
      if (credentialAttempted) {
        const scope = ["-s", service, "-a", "local:" + endpoint];
        const remove = spawnSync("/usr/bin/security", ["delete-generic-password", ...scope], { stdio: "ignore" });
        assert([0, 44].includes(remove.status), "Could not remove the scoped fixture credential.");
        const check = spawnSync("/usr/bin/security", ["find-generic-password", ...scope], { stdio: "ignore" });
        assert.equal(check.status, 44, "The scoped fixture credential still exists.");
      }
      run(ax, ["release-test-pasteboard", pasteboard]);
    } finally {
      server.closeAllConnections();
      server.close();
    }
  }
}
