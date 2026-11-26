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
const sdkPackage = "node_modules/@earendil-works/pi-coding-agent";
const locked = JSON.parse(readFileSync(join(sidecar, "package-lock.json"), "utf8")).packages[sdkPackage].version;
const manifest = join(sidecar, sdkPackage, "package.json");
const install = "Install the pinned SDK with npm --prefix PiWorkspace/Sidecar ci --ignore-scripts.";
assert(existsSync(manifest), install);
const installed = JSON.parse(readFileSync(manifest, "utf8")).version;
assert.equal(installed, locked, install);
const root = mkdtempSync(join(tmpdir(), "pi-sidecar-"));
const cwd = join(root, "work");
const agentDir = join(root, "config");
const sessionDir = join(root, "session");
for (const path of [cwd, agentDir, sessionDir]) mkdirSync(path, { mode: 0o700 });
const threadID = randomUUID().toUpperCase();
const key = randomBytes(32).toString("hex");
const invalidKey = randomBytes(32).toString("hex");
const model = "sidecar-fixture";
const requests = [];
let activeChild;
let fixtureError;

function assertRedacted(text, location) {
  assert(!text.includes(key) && !text.includes(invalidKey), `Found a fixture key in ${location}`);
}

function chunk(response, delta, finishReason = null) {
  response.write(`data: ${JSON.stringify({
    id: "fixture",
    object: "chat.completion.chunk",
    created: 1,
    model,
    choices: [{ index: 0, delta, finish_reason: finishReason }],
  })}\n\n`);
}

function complete(response) {
  chunk(response, {}, "stop");
  response.end("data: [DONE]\n\n");
}

const server = createServer(async (request, response) => {
  try {
    assert.equal(request.method, "POST");
    assert.equal(request.url, "/v1/chat/completions");
    const body = await new Response(request).json();
    assert.equal(body.model, model);
    assert.equal(body.stream, true);
    const messages = body.messages
      .filter(({ role }) => role === "user" || role === "assistant")
      .map(({ role, content }) => [role, typeof content === "string" ? content : content.map((part) => part.text).join("")]);
    requests.push({ messages, response });
    if (request.headers.authorization !== `Bearer ${key}`) {
      assert(request.headers.authorization === `Bearer ${invalidKey}`, "Unexpected bearer credential");
      response.writeHead(401, { "Content-Type": "application/json" }).end(JSON.stringify({
        error: { message: `Invalid fixture key ${invalidKey}` },
      }));
      return;
    }
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    chunk(response, { role: "assistant" });
    switch (messages.at(-1)?.[1]) {
      case "First prompt": chunk(response, { content: "First" }); break;
      case "Second prompt":
        chunk(response, { content: "Second answer." });
        complete(response);
        break;
      case "Stop prompt": chunk(response, { content: "Stopped text." }); break;
      case "Error prompt": chunk(response, { content: "Incomplete text." }); break;
      default: assert.fail("Unexpected fixture prompt");
    }
  } catch (error) {
    fixtureError = error;
    response.destroy();
  }
});

function send(child, command) {
  child.stdin.write(JSON.stringify(command) + "\n");
}

async function open() {
  const child = spawn(process.execPath, [join(sidecar, "worker.mjs")], {
    cwd,
    env: {
      PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      HOME: root,
      TMPDIR: root,
      PI_CODING_AGENT_DIR: agentDir,
      PI_OFFLINE: "1",
      PI_TELEMETRY: "0",
    },
    timeout: 30_000,
  });
  const closed = once(child, "close");
  activeChild = { child, closed };
  const output = createInterface({ input: child.stdout, crlfDelay: Infinity })[Symbol.asyncIterator]();
  child.stderr.setEncoding("utf8");
  let stderr = "";
  child.stderr.on("data", (text) => { stderr += text; });
  const worker = { child, output, closed, stderr: () => stderr };
  send(child, {
    type: "open", cwd, sessionDir, threadID, toolPermission: "readFiles",
    config: {
      provider: "local", model, contextWindow: 8192,
      endpoint: `http://127.0.0.1:${server.address().port}/v1`,
    },
  });
  const messages = (await receive(worker, "ready")).messages;
  return { ...worker, messages };
}

async function receive(worker, type, { credential, partial } = {}) {
  for (;;) {
    const { value: line, done } = await worker.output.next();
    if (fixtureError) throw fixtureError;
    if (done) break;
    assertRedacted(line, "worker stdout");
    const event = JSON.parse(line);
    if (event.type === "credential") {
      assert(["read", "exists"].includes(event.operation), "Unexpected credential operation");
      const reply = event.operation === "read" ? { key: credential } : { exists: Boolean(credential) };
      send(worker.child, { type: "credentialResult", requestID: event.requestID, ...reply });
    } else if (event.type === "partial") {
      partial?.(event.text);
    } else if (event.type === type) {
      return event;
    } else {
      assert.equal(event.type, "history", `Expected ${type}; received ${JSON.stringify(event)}`);
    }
  }
  assertRedacted(worker.stderr(), "worker stderr");
  assert.fail(`Worker exited before ${type}: ${worker.stderr()}`);
}

function finish(worker, text, credential = key, partial) {
  worker.turnID = randomUUID();
  send(worker.child, { type: "prompt", turnID: worker.turnID, text });
  return receive(worker, "finished", { credential, partial });
}

async function close(worker) {
  worker.child.stdin.end();
  for await (const line of worker.output) assertRedacted(line, "worker stdout");
  const [code, signal] = await worker.closed;
  activeChild = undefined;
  assertRedacted(worker.stderr(), "worker stderr");
  assert.equal(signal, null);
  assert.equal(code, 0, worker.stderr());
}

function transcript(messages) {
  for (const { id } of messages) assert.equal(typeof id, "string");
  assert.equal(new Set(messages.map(({ id }) => id)).size, messages.length);
  return messages.map(({ role, text }) => [role, text]);
}

try {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  console.log(`Pi SDK ${installed}`);

  const first = await open();
  assert.deepEqual(first.messages, []);
  const partials = [];
  const sent = await finish(first, "First prompt", key, (text) => {
    partials.push(text);
    if (partials.length === 1) {
      const { response } = requests.at(-1);
      chunk(response, { content: " answer." });
      complete(response);
    }
  });
  assert.deepEqual(partials, ["First", "First answer."]);
  assert.equal(sent.error, undefined);
  const expected = [["user", "First prompt"], ["assistant", "First answer."]];
  assert.deepEqual(transcript(sent.messages), expected);
  await close(first);
  console.log("PASS first send emitted two partial updates before completion");

  const resumed = await open();
  assert.notEqual(resumed.child.pid, first.child.pid);
  assert.deepEqual(resumed.messages, sent.messages);
  const second = await finish(resumed, "Second prompt");
  assert.equal(second.error, undefined);
  expected.push(["user", "Second prompt"]);
  assert.equal(requests.length, 2);
  assert.deepEqual(requests[1].messages, expected);
  expected.push(["assistant", "Second answer."]);
  assert.deepEqual(transcript(second.messages), expected);
  assert.deepEqual(second.messages.slice(0, 2), sent.messages);
  console.log("PASS restart returned the same message IDs and second send appended one turn");

  const missing = await finish(resumed, "Missing key prompt", null);
  assert.match(missing.error, /Save an API key/);
  assert.deepEqual(missing.messages, second.messages);
  assert.equal(requests.length, 2);
  console.log("PASS missing key reported a settings error without a model request");

  const rejected = await finish(resumed, "Invalid key prompt", invalidKey);
  assert.match(rejected.error, /401.*Invalid fixture key \[API key removed\]/s);
  assert.equal(requests.length, 3);
  expected.push(["user", "Invalid key prompt"]);
  assert.deepEqual(transcript(rejected.messages), expected);
  console.log("PASS invalid key reached the fixture and returned a redacted HTTP 401");

  let stoppedResponse;
  const stopped = await finish(resumed, "Stop prompt", key, (text) => {
    assert.equal(text, "Stopped text.");
    stoppedResponse = requests.at(-1).response;
    send(resumed.child, { type: "cancel", turnID: resumed.turnID });
  });
  assert(stoppedResponse, "Stop requires a partial update");
  if (!stoppedResponse.closed) {
    await once(stoppedResponse, "close", { signal: AbortSignal.timeout(5_000) });
  }
  assert.equal(stopped.error, undefined);
  expected.push(["user", "Stop prompt"], ["assistant", "Stopped text."]);
  assert.deepEqual(transcript(stopped.messages), expected);
  console.log("PASS Stop closed the active stream and kept the text already received");

  const errorPartials = [];
  const failed = await finish(resumed, "Error prompt", key, (text) => {
    errorPartials.push(text);
    requests.at(-1).response.end(`data: ${JSON.stringify({ error: { message: `Fixture stream failed with ${key}` } })}\n\n`);
  });
  assert.deepEqual(errorPartials, ["Incomplete text."]);
  assert.match(failed.error, /Fixture stream failed with \[API key removed\]/);
  expected.push(["user", "Error prompt"], ["assistant", "Incomplete text."]);
  assert.deepEqual(transcript(failed.messages), expected);
  assert.equal(requests.length, 5);
  await close(resumed);

  const reopened = await open();
  assert.deepEqual(reopened.messages, failed.messages);
  await close(reopened);
  console.log("PASS stream error retained partial text and the same history returned after restart");

  assert.equal(readdirSync(sessionDir).filter((name) => name.endsWith(".jsonl")).length, 1);
  for (const entry of readdirSync(root, { recursive: true, withFileTypes: true })) {
    assert.notEqual(entry.name, "auth.json");
    assert(!entry.isSymbolicLink(), "Unscanned symlink in fixture directory");
    if (entry.isFile()) assertRedacted(readFileSync(join(entry.parentPath, entry.name), "utf8"), entry.name);
  }
  console.log("PASS no plaintext fixture keys or auth.json persisted");
} finally {
  if (activeChild) activeChild.child.kill();
  server.closeAllConnections();
  server.close();
  if (activeChild) await activeChild.closed;
  rmSync(root, { recursive: true, force: true });
}
