import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";

const sidecar = resolve(process.argv[2] ?? join(import.meta.dirname, "../Sidecar"));
const sdk = join(sidecar, "node_modules/@earendil-works/pi-coding-agent");
assert.equal(JSON.parse(readFileSync(join(sdk, "package.json"), "utf8")).version, "1.6.1");
const { SessionManager } = await import(join(sdk, "dist/index.js"));
const root = mkdtempSync(join(tmpdir(), "pi-conversation-fork-"));
const cwd = join(root, "checkout");
const sessions = join(root, "sessions");
const parentID = randomUUID().toUpperCase();
const childID = randomUUID().toUpperCase();
const receipt = randomUUID();
const key = randomUUID();
const model = "fork-fixture";
const requests = [];
let heldReply;
let fixtureFailure;
let child;

const server = createServer(async (request, response) => {
  try {
    assert.equal(request.url, "/v1/chat/completions");
    assert.equal(request.headers.authorization, `Bearer ${key}`);
    const body = await new Response(request).json();
    assert.equal(body.model, model);
    assert(!JSON.stringify(body).includes(key));
    requests.push(body.messages);
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    writeChunk(response, { role: "assistant", content: `Reply ${requests.length}` });
    if (requests.length === 3) heldReply = response;
    else finishReply(response);
  } catch (error) {
    fixtureFailure = error;
    response.destroy();
  }
});

function writeChunk(response, delta, reason = null) {
  response.write(`data: ${JSON.stringify({
    id: "fork", object: "chat.completion.chunk", created: 1, model,
    choices: [{ index: 0, delta, finish_reason: reason }],
  })}\n\n`);
}

function finishReply(response) {
  writeChunk(response, {}, "stop");
  response.end("data: [DONE]\n\n");
}

function send(command) {
  child.stdin.write(JSON.stringify(command) + "\n");
}

let closed;
let events;
let stderr;
function open(threadID, forkMessageID) {
  child = spawn(process.execPath, [join(sidecar, "worker.mjs")], {
    cwd,
    env: {
      PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      HOME: root,
      TMPDIR: root,
      PI_CODING_AGENT_DIR: join(root, "config"),
      PI_OFFLINE: "1",
      PI_TELEMETRY: "0",
    },
    timeout: 30_000,
  });
  closed = once(child, "close");
  events = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  stderr = "";
  child.stderr.setEncoding("utf8").on("data", (text) => { stderr += text; });
  send({
    type: "open", cwd, sessionDir: join(sessions, threadID), threadID, forkMessageID,
    toolPermission: "readFiles",
    config: {
      provider: "local", model, contextWindow: 8192, endpoint: `http://127.0.0.1:${server.address().port}/v1`,
    },
  });
}

async function receive(type) {
  for (;;) {
    const { value, done } = await events.next();
    if (fixtureFailure) throw fixtureFailure;
    assert(!done, `Worker exited before ${type}: ${stderr}`);
    assert(!value.includes(key), "A credential reached stdout");
    const event = JSON.parse(value);
    if (event.type === type) return event;
    assert.notEqual(event.type, "fatal", event.error);
    if (event.type === "credential") {
      send({ type: "credentialResult", requestID: event.requestID, key, exists: true });
    }
  }
}

async function close(code = 0) {
  child.stdin.end();
  assert.deepEqual(await closed, [code, null], stderr);
  assert(!stderr.includes(key));
  child = undefined;
}

function prompt(text, queuedID) {
  const turnID = randomUUID();
  send({ type: "prompt", turnID, text, queuedID });
  return turnID;
}

async function completed(turnID) {
  const event = await receive("finished");
  assert.equal(event.turnID, turnID);
  assert.equal(event.error, undefined);
  return event.messages;
}

async function fork(threadID, messageID) {
  send({ type: "fork", threadID, messageID });
  const event = await receive("forked");
  assert.equal(event.threadID, threadID);
  return event;
}

function reserve(threadID = randomUUID()) {
  const directory = join(sessions, threadID);
  mkdirSync(directory);
  return { threadID, file: join(directory, threadID + ".jsonl") };
}

try {
  mkdirSync(cwd);
  mkdirSync(sessions);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  open(parentID);
  assert.deepEqual((await receive("ready")).messages, []);
  await completed(prompt("Question 1"));
  const prefix = await completed(prompt(`Question 2 ${key}`, receipt));
  assert.equal(prefix[2].queuedID, receipt);
  const firstReply = prefix[1];
  const cutoff = prefix[3];
  assert.equal(cutoff.canFork, true);

  const third = prompt("Question 3");
  await receive("partial");
  const destination = reserve(childID);
  assert.match((await fork(childID, cutoff.id)).error, /current turn/);
  assert(!existsSync(destination.file));
  finishReply(heldReply);
  const parent = await completed(third);
  assert.deepEqual(parent.map(({ text }) => text), [
    "Question 1", "Reply 1", "Question 2 [API key removed]", "Reply 2", "Question 3", "Reply 3",
  ]);
  await close();

  const parentDir = join(sessions, parentID);
  const [parentFileName] = readdirSync(parentDir);
  const parentFile = join(parentDir, parentFileName);
  const manager = SessionManager.open(parentFile, parentDir, cwd);
  const currentLeaf = manager.getLeafId();
  manager.branch(firstReply.id);
  manager.appendMessage({ role: "user", content: "Stale branch question", timestamp: Date.now() });
  const stale = manager.appendMessage({
    ...manager.getEntry(firstReply.id).message, content: [{ type: "text", text: "Stale branch response" }],
  });
  manager.branch(currentLeaf);
  manager.appendSessionInfo("Active branch");
  const source = readFileSync(parentFile, "utf8");

  open(parentID);
  assert.deepEqual((await receive("ready")).messages, parent);
  assert.match((await fork(childID, stale)).error, /active conversation branch/);
  assert.match((await fork(childID, prefix[2].id)).error, /active conversation branch/);
  assert(!existsSync(destination.file));

  const moved = parentFile + ".moved";
  renameSync(parentFile, moved);
  assert.match((await fork(childID, cutoff.id)).error, /history is missing/);
  renameSync(moved, parentFile);
  const collision = reserve();
  writeFileSync(collision.file, "Keep existing file");
  assert.match((await fork(collision.threadID, cutoff.id)).error, /save the fork history/);
  assert.equal(readFileSync(collision.file, "utf8"), "Keep existing file");

  assert.equal((await fork(childID, cutoff.id)).error, undefined);
  assert.equal(requests.length, 3);
  const inherited = prefix.map(({ queuedID, ...message }) => message);
  const copied = readFileSync(destination.file, "utf8");
  assert(!copied.includes(key) && !copied.includes(receipt) && !copied.includes(stale));
  const childManager = SessionManager.open(destination.file, join(sessions, childID), cwd);
  assert.equal(childManager.getHeader().id, childID);
  assert.equal(childManager.getHeader().cwd, cwd);
  assert.equal(childManager.getHeader().parentSession, parentFile);
  assert.deepEqual(childManager.getBranch().map(({ id }) => id), manager.getBranch(cutoff.id).map(({ id }) => id));
  assert.equal(readFileSync(parentFile, "utf8"), source);
  await close();

  open(childID, cutoff.id);
  assert.deepEqual((await receive("ready")).messages, inherited);
  const continued = await completed(prompt("Child continuation"));
  assert.deepEqual(continued.slice(0, 4), inherited);
  assert.deepEqual(continued.slice(4).map(({ text }) => text), ["Child continuation", "Reply 4"]);
  assert.equal(requests.length, 4);
  const context = requests[3].filter(({ role }) => role === "user" || role === "assistant");
  assert.deepEqual(context.map(({ role, content }) => ({
    role, text: typeof content === "string" ? content : content.map(({ text }) => text).join(""),
  })), [...inherited.map(({ role, text }) => ({ role, text })), { role: "user", text: "Child continuation" }]);
  await close();

  open(parentID);
  assert.deepEqual((await receive("ready")).messages, parent);
  assert.equal(readFileSync(parentFile, "utf8"), source);
  await close();
  open(childID, cutoff.id);
  assert.deepEqual((await receive("ready")).messages, continued);
  await close();
  assert.equal(requests.length, 4);

  const missing = reserve();
  open(missing.threadID, cutoff.id);
  assert.match((await receive("fatal")).error, /fork history is missing/);
  await close(1);
  assert(!existsSync(missing.file));
  console.log("PASS selected Pi prefix, active-branch checks, separate durable histories, and one child continuation");
} finally {
  if (child) {
    child.kill();
    await closed;
  }
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
  rmSync(root, { recursive: true, force: true });
}
