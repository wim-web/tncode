import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { once } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";

const sidecar = resolve(import.meta.dirname, "../Sidecar");
const sdk = "node_modules/@earendil-works/pi-coding-agent";
const installed = JSON.parse(readFileSync(join(sidecar, sdk, "package.json"), "utf8")).version;
assert.equal(installed, "1.6.1");
const root = mkdtempSync(join(tmpdir(), "pi-queue-"));
const cwd = join(root, "work");
const sessionDir = join(root, "history");
const threadID = randomUUID();
const key = randomBytes(32).toString("hex");
const model = "queue-fixture";
const target = join(cwd, "approval.txt");
mkdirSync(cwd);

const requests = [];
let child;
let fixtureError;
const server = createServer(async (request, response) => {
  try {
    assert.equal(request.url, "/v1/chat/completions");
    assert.equal(request.headers.authorization, `Bearer ${key}`);
    const body = await new Response(request).json();
    assert.equal(body.model, model);
    assert(!JSON.stringify(body).includes(key), "A credential reached the prompt");
    assert(!JSON.stringify(body).includes("workspaceQueuedID"));
    requests.push({ body, response });
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    chunk(response, { role: "assistant" });
    chunk(response, { content: "Fixture responding" });
  } catch (error) {
    fixtureError = error;
    response.destroy();
  }
});

function chunk(response, delta, reason = null, usage) {
  response.write(`data: ${JSON.stringify({
    id: "queue", object: "chat.completion.chunk", created: 1, model,
    choices: [{ index: 0, delta, finish_reason: reason }], usage,
  })}\n\n`);
}

function complete(reason = "stop", tokens = 100) {
  const { response } = requests.at(-1);
  chunk(response, {}, reason, { prompt_tokens: tokens, completion_tokens: 7, total_tokens: tokens + 7 });
  response.end("data: [DONE]\n\n");
}

function send(command) {
  child.stdin.write(JSON.stringify(command) + "\n");
}

let events;
let closed;
let stderr;
async function open(toolPermission) {
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
    type: "open", cwd, sessionDir, threadID, toolPermission,
    config: {
      provider: "local", model, contextWindow: 65_536, localTools: true,
      endpoint: `http://127.0.0.1:${server.address().port}/v1`,
    },
  });
  return await receive("ready");
}

async function receive(type, matches = () => true) {
  for (;;) {
    const { value, done } = await events.next();
    if (fixtureError) throw fixtureError;
    assert(!done, `Worker exited before ${type}: ${stderr}`);
    assert(!value.includes(key), "A credential reached worker stdout");
    const event = JSON.parse(value);
    if (event.type === "credential") {
      send({ type: "credentialResult", requestID: event.requestID, key, exists: true });
    } else if (event.type === type && matches(event)) {
      return event;
    } else {
      assert.notEqual(event.type, "fatal", event.error);
      assert.notEqual(event.type, "finished", `Turn finished before ${type}: ${event.error ?? "no error"}`);
    }
  }
}

async function close() {
  child.stdin.end();
  assert.deepEqual(await closed, [0, null], stderr);
  assert(!stderr.includes(key));
  child = undefined;
}

function prompt(text, queuedID, skipCompaction) {
  const turnID = randomUUID();
  send({ type: "prompt", turnID, text, queuedID, skipCompaction });
  return turnID;
}

function users() {
  return requests.at(-1).body.messages.filter(({ role }) => role === "user")
    .map(({ content }) => typeof content === "string" ? content : content.map((part) => part.text).join(""));
}

try {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  await open("supervised");
  const active = prompt("Active turn");
  await receive("partial");
  const steer = randomUUID();
  const stale = randomUUID();
  send({ type: "steer", turnID: randomUUID(), queuedID: stale, text: "Wrong turn" });
  assert.equal((await receive("queueRejected")).queuedID, stale);

  chunk(requests.at(-1).response, {
    tool_calls: [{
      index: 0, id: "call_write", type: "function",
      function: { name: "write", arguments: JSON.stringify({ path: target, content: key }) },
    }],
  });
  complete("tool_calls");
  const approval = await receive("toolApproval");
  assert.equal(approval.turnID, active);
  assert.equal(approval.threadID, threadID);
  assert.match(approval.details, /API key removed/);
  assert(!existsSync(target));
  send({ type: "steer", turnID: active, queuedID: steer, text: `Steer ${key}` });
  send({ ...approval, type: "toolApprovalResult", turnID: randomUUID(), decision: "approve" });
  send({ ...approval, type: "toolApprovalResult", decision: "decline" });
  await receive("partial");
  assert.deepEqual(users(), ["Active turn", "Steer [API key removed]"]);
  assert(!existsSync(target));
  complete();
  const steered = await receive("finished");
  assert.equal(steered.turnID, active);
  assert.equal(steered.error, undefined);
  assert.equal(steered.messages.filter((message) => message.queuedID === steer).length, 1);
  console.log("PASS CHAT-091/092 steering stayed in the active turn and preserved supervised approval");

  const stopped = prompt("Stop with a waiting steer");
  await receive("partial");
  const retry = randomUUID();
  send({ type: "steer", turnID: stopped, queuedID: retry, text: "Retry explicitly" });
  send({ type: "cancel", turnID: stopped });
  const interrupted = await receive("finished");
  assert.equal(interrupted.turnID, stopped);
  assert.equal(interrupted.messages.at(-1).text, "Fixture responding");
  assert(!interrupted.messages.some(({ queuedID }) => queuedID === retry));
  await close();

  const reopened = await open("readFiles");
  assert.deepEqual(reopened.messages, interrupted.messages);
  const followUp = prompt("Retry explicitly", retry);
  await receive("partial");
  assert.equal(users().filter((text) => text === "Retry explicitly").length, 1);
  assert.deepEqual(requests.at(-1).body.tools.map(({ function: tool }) => tool.name).sort(),
    ["ask_user_questions", "find", "grep", "ls", "read"]);
  complete();
  const followed = await receive("finished");
  assert.equal(followed.turnID, followUp);
  assert.equal(followed.messages.filter((message) => message.queuedID === retry).length, 1);
  console.log("PASS CHAT-090/093/100 stopped steering stayed unsent across restart, then a fresh prompt recorded its ID once");

  const compacting = prompt("Compaction trigger\n" + "context ".repeat(14_000));
  await receive("partial");
  complete("stop", 55_000);
  await receive("inputMode", ({ mode }) => mode === "compacting");
  const selected = randomUUID();
  send({ type: "skipCompaction", turnID: compacting, queuedID: selected });
  assert.equal((await receive("compactionSkipped")).queuedID, selected);
  assert.equal((await receive("finished")).turnID, compacting);
  const next = prompt("Skip compaction for this message", selected, true);
  await receive("partial");
  assert.equal(users().at(-1), "Skip compaction for this message");
  complete();
  const delivered = await receive("finished");
  assert.equal(delivered.turnID, next);
  assert.equal(delivered.error, undefined);
  assert.equal(delivered.messages.filter((message) => message.queuedID === selected).length, 1);
  await close();
  assert.deepEqual((await open("readFiles")).messages, delivered.messages);
  await close();
  for (const file of readdirSync(sessionDir)) {
    assert(!readFileSync(join(sessionDir, file), "utf8").includes(key));
  }
  console.log("PASS CHAT-094 aborted real Pi auto-compaction, then sent and restored the selected message");
} finally {
  child?.kill();
  server.closeAllConnections();
  server.close();
  if (child) await closed;
  rmSync(root, { recursive: true, force: true });
}
