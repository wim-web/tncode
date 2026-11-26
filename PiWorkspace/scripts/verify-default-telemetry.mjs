import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import { pathToFileURL } from "node:url";

// Run on macOS with an app built from this checkout. This launches the bundled Node helper.
// Usage: node PiWorkspace/scripts/verify-default-telemetry.mjs "/path/to/Pi Workspace.app"
const workspace = resolve(import.meta.dirname, "..");
const app = resolve(process.argv[2] ?? join(workspace, "dist", "Pi Workspace.app"));
const helper = join(app, "Contents/Helpers/node");
const sidecar = join(app, "Contents/Resources/Sidecar");
const worker = join(sidecar, "worker.mjs");
const observer = pathToFileURL(join(import.meta.dirname, "fixtures/observe-pi-network.mjs")).href;
const sdk = "node_modules/@earendil-works/pi-coding-agent";
const readJSON = (path) => JSON.parse(readFileSync(path, "utf8"));

for (const file of ["worker.mjs", "tool-approval.mjs"]) {
  assert(readFileSync(join(sidecar, file)).equals(readFileSync(join(workspace, "Sidecar", file))),
    `Bundle ${file} differs from this checkout. Rebuild the app.`);
}
const sdkVersion = readJSON(join(sidecar, sdk, "package.json")).version;
assert.equal(sdkVersion, readJSON(join(workspace, "Sidecar/package-lock.json")).packages[sdk].version,
  "Bundle SDK differs from this checkout. Rebuild the app.");

const swift = readFileSync(join(workspace, "Sources/PiWorkspace/PiProcess.swift"), "utf8");
const environment = swift.match(/^\s*child\.environment\s*=\s*\[\n([\s\S]+?)^\s*\]/m)?.[1];
assert(environment, "Update the verifier for the current PiProcess launch environment.");
const launchEnvironment = Object.fromEntries(environment.trim().split("\n").map((line) => {
  const entry = line.match(/^\s*"([^"]+)":\s*(?:"([^"\\]*)"|(config\.path)),?\s*$/);
  assert(entry, "Update the verifier for the current PiProcess launch environment.");
  return [entry[1], entry[2] ?? null];
}));
assert.equal(launchEnvironment.PI_CODING_AGENT_DIR, null);

const host = "127.0.0.1";
const idleMs = 3_000;
const model = "telemetry-fixture";
const prompt = "Reply to the loopback test.";
const answer = "The loopback turn finished.";
const key = randomBytes(32).toString("hex");
const root = mkdtempSync(join(tmpdir(), "pi-telemetry-"));
const scope = [
  "Bundled Node helper and Pi SDK. The worker receives the checkout's PiProcess environment, with a disposable HOME and TMPDIR.",
  "Node TCP socket connects (including HTTP, TLS, and fetch), DNS, UDP sends/connects, and child process launches.",
  "The macOS process sandbox denies other direct network traffic and Mach service lookups. The Node observer does not measure native or OS-delegated destinations.",
  "The Swift GUI, WebKit, Keychain, and live provider turns are outside this run.",
];
const results = {
  app, sdkVersion, idleMs, scope, passed: false,
  controls: {}, controlRequests: [], modelRequests: [], sessions: {},
};
let active;
let fixtureError;
let controlConnections = 0;
let modelConnections = 0;

const sink = createServer((request, response) => {
  results.controlRequests.push({ method: request.method, path: request.url });
  response.end("received");
});
sink.on("connection", () => { controlConnections++; });
const modelServer = createServer(async (request, response) => {
  results.modelRequests.push({ method: request.method, path: request.url });
  try {
    assert.equal(request.method, "POST");
    assert.equal(request.url, "/v1/chat/completions");
    assert(request.headers.authorization === `Bearer ${key}`, "Expected the generated fixture key");
    const body = await new Response(request).json();
    assert.equal(body.model, model);
    assert.equal(body.stream, true);
    const { role, content } = body.messages.at(-1);
    assert.equal(role, "user");
    assert.equal(typeof content === "string" ? content : content.map(({ text }) => text).join(""), prompt);
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const [delta, finish_reason] of [[{ content: answer }, null], [{}, "stop"]]) {
      const chunk = { id: "fixture", object: "chat.completion.chunk", created: 1, model,
        choices: [{ index: 0, delta, finish_reason }] };
      response.write(`data: ${JSON.stringify(chunk)}\n\n`);
    }
    response.end("data: [DONE]\n\n");
  } catch (error) {
    fixtureError = error;
    response.destroy();
  }
});
modelServer.on("connection", () => { modelConnections++; });

function start(args, { dir, allowedPort, result, instrument = true }) {
  const cwd = join(dir, "work");
  const agentDir = join(dir, "config");
  for (const path of [cwd, agentDir]) mkdirSync(path, { recursive: true, mode: 0o700 });
  const profile = [
    "(version 1)",
    "(allow default)",
    "(deny network*)",
    "(deny mach-lookup)",
  ];
  if (allowedPort) profile.push(`(allow network-outbound (remote tcp "localhost:${allowedPort}"))`);
  const preload = instrument ? ["--import", observer] : [];
  const child = spawn("/usr/bin/sandbox-exec", ["-p", profile.join("\n"), helper, ...preload, ...args], {
    cwd,
    env: { ...launchEnvironment, PI_CODING_AGENT_DIR: agentDir, HOME: dir, TMPDIR: dir,
      PI_VERIFY_LOOPBACK_PORT: allowedPort ? String(allowedPort) : "" },
    timeout: 30_000,
    killSignal: "SIGKILL",
  });
  const closed = once(child, "close");
  closed.catch(() => {});
  let stderr = "";
  child.stderr.setEncoding("utf8").on("data", (text) => { stderr += text; });
  child.stdin.on("error", (error) => { stderr += error.message; });
  const log = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const output = log[Symbol.asyncIterator]();
  const run = { child, closed, output, cwd, stderr: () => stderr.replaceAll(key, "[fixture key]") };
  log.on("line", (line) => {
    if (!line.startsWith('{"type":"networkObservation",')) return;
    const { node, api, host, port, allowed } = JSON.parse(line);
    if (node) result.observerNode = node;
    else result.attempts.push({ phase: result.phases?.at(-1) ?? "startup", api, host, port, allowed });
  });
  active = run;
  return run;
}

async function verifyExit(run, result) {
  const [code, signal] = await run.closed;
  active = undefined;
  result.exit = { code, signal };
  assert.deepEqual(result.exit, { code: 0, signal: null }, run.stderr());
}

const control = `
import assert from "node:assert/strict";
const [url, expected] = process.argv.slice(1);
if (expected === "received") {
  assert.equal(await (await fetch(url)).text(), expected);
} else {
  await assert.rejects(fetch(url), (error) => error.cause?.code === expected);
}
`;

async function checkControl(name, { scheme = "http", instrument, allowedPort, expected, attempts, connections }) {
  const result = results.controls[name] = { expected, attempts: [] };
  const port = sink.address().port;
  const args = ["--input-type=module", "--eval", control, `${scheme}://${host}:${port}/observer-control`, expected];
  const before = controlConnections;
  const run = start(args, { dir: join(root, name), result, instrument, allowedPort });
  await verifyExit(run, result);
  if (instrument) assert(result.observerNode, "Control did not load the Node observer.");
  result.connectionsAccepted = controlConnections - before;
  assert.deepEqual(result.attempts, attempts);
  assert.equal(result.connectionsAccepted, connections);
}

function send(run, command) {
  run.child.stdin.write(JSON.stringify(command) + "\n");
}

async function receive(run, type, result) {
  for (;;) {
    const { value: line, done } = await run.output.next();
    if (fixtureError) throw fixtureError;
    if (done) break;
    const event = JSON.parse(line);
    if (event.type === "credential") {
      assert(["exists", "read"].includes(event.operation));
      result.credentialOperations.push(event.operation);
      const credential = event.operation === "read" ? { key } : { exists: true };
      send(run, { type: "credentialResult", requestID: event.requestID, ...credential });
    } else if (event.type === type) {
      return event;
    } else {
      assert(["networkObservation", "history", "partial"].includes(event.type), JSON.stringify(event));
    }
  }
  assert.fail(`Worker exited before ${type}. ${run.stderr()}`);
}

async function exercise(name, config, { dir = join(root, name), threadID = randomUUID(), history = [], turn = false } = {}) {
  const result = results.sessions[name] = { phases: ["startup/open"], attempts: [], credentialOperations: [] };
  const allowedPort = turn ? modelServer.address().port : undefined;
  const run = start([worker], { dir, result, allowedPort });
  send(run, { type: "open", cwd: run.cwd, sessionDir: join(dir, "session"), threadID,
    config, toolPermission: "readFiles" });
  assert.deepEqual((await receive(run, "ready", result)).messages, history);
  assert(result.observerNode, "Worker did not load the Node observer.");

  result.phases.push("ready-idle");
  await delay(idleMs);
  if (turn) {
    result.phases.push("explicit-turn");
    send(run, { type: "prompt", turnID: randomUUID(), text: prompt });
    const finished = await receive(run, "finished", result);
    assert.equal(finished.error, undefined);
    assert.deepEqual(finished.messages.map(({ role, text }) => [role, text]),
      [["user", prompt], ["assistant", answer]]);
    history = finished.messages;
    assert(result.credentialOperations.includes("read"), "The worker did not request the fixture key.");
    result.phases.push("post-turn-idle");
    await delay(idleMs);
  }
  result.phases.push("exit");
  run.child.stdin.end();
  await verifyExit(run, result);
  const expected = turn ? [{ phase: "explicit-turn", api: "tcp.connect", host, port: allowedPort, allowed: true }] : [];
  assert.deepEqual(result.attempts, expected, `Unexpected destinations during ${name}`);
  return history;
}

try {
  for (const server of [sink, modelServer]) {
    server.listen(0, host);
    await once(server, "listening");
  }
  const port = sink.address().port;
  const tcp = { phase: "startup", api: "tcp.connect", host, port };
  await checkControl("loopback", { instrument: true, allowedPort: port, expected: "received",
    attempts: [{ ...tcp, allowed: true }], connections: 1 });
  await checkControl("blockedAtNode", { scheme: "https", instrument: true, expected: "PI_VERIFY_NETWORK_BLOCKED",
    attempts: [{ ...tcp, allowed: false }], connections: 0 });
  await checkControl("blockedAtSandbox", { instrument: false, expected: "EPERM",
    attempts: [], connections: 0 });

  await exercise("openai", { provider: "openai", model: "gpt-5-mini", contextWindow: 8192 });
  await exercise("anthropic", { provider: "anthropic", model: "claude-sonnet-4-6", contextWindow: 8192 });
  const local = { provider: "local", model, contextWindow: 8192,
    endpoint: `http://${host}:${modelServer.address().port}/v1` };
  const session = { dir: join(root, "local"), threadID: randomUUID() };
  const history = await exercise("local", local, { ...session, turn: true });
  await exercise("local-reopen", local, { ...session, history });
  assert.deepEqual(results.controlRequests, [{ method: "GET", path: "/observer-control" }]);
  assert.deepEqual(results.modelRequests, [{ method: "POST", path: "/v1/chat/completions" }]);
  results.modelConnections = modelConnections;
  assert.equal(modelConnections, 1);
  results.passed = true;
} finally {
  console.log(JSON.stringify(results, null, 2));
  if (active) {
    active.child.kill("SIGKILL");
    await active.closed.catch(() => {});
  }
  for (const server of [sink, modelServer]) {
    server.close();
    server.closeAllConnections();
  }
  rmSync(root, { recursive: true, force: true });
}
