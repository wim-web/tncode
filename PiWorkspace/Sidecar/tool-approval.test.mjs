import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";

const edit = { name: "edit", args: { path: "edit.txt", edits: [{ oldText: "before", newText: "after" }] } };
const write = (path) => ({ name: "write", args: { path, content: "approved\n" } });
const calls = {
  "deny edit": [edit],
  "approve edit": [edit],
  "approve one command": [
    { name: "bash", args: { command: "printf '%s\\n' once >> shell.txt" } },
    { name: "bash", args: { command: "printf '%s\\n' twice >> shell.txt" } },
  ],
  "stop write": [write("stopped.txt")],
  "disconnect write": [write("disconnected.txt")],
};

function chunk(delta, finish_reason = null) {
  return "data: " + JSON.stringify({
    id: "fixture",
    object: "chat.completion.chunk",
    created: 1,
    model: "approval-fixture",
    choices: [{ index: 0, delta, finish_reason }],
  }) + "\n\n";
}

async function fixture() {
  const requests = new Map();
  const server = createServer(async (request, response) => {
    const body = await new Response(request).json();
    const user = body.messages.findLast(({ role }) => role === "user");
    const prompt = typeof user.content === "string" ? user.content : user.content[0].text;
    const bodies = requests.get(prompt) ?? [];
    bodies.push(body);
    requests.set(prompt, bodies);
    const toolCalls = bodies.length === 1 ? calls[prompt] : undefined;
    const delta = toolCalls ? {
      tool_calls: toolCalls.map(({ name, args }, index) => ({
        index,
        id: "call_fixture_" + index,
        type: "function",
        function: { name, arguments: JSON.stringify(args) },
      })),
    } : { content: "Fixture complete." };
    response.writeHead(200, { "Content-Type": "text/event-stream" }).end(
      chunk({ role: "assistant", ...delta }) + chunk({}, toolCalls ? "tool_calls" : "stop") + "data: [DONE]\n\n",
    );
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return { server, requests, endpoint: "http://127.0.0.1:" + server.address().port + "/v1" };
}

async function openWorker(t, directory, endpoint, toolPermission, localTools = true) {
  mkdirSync(directory);
  const agentDir = join(directory, "agent");
  mkdirSync(agentDir);
  const threadID = randomUUID().toUpperCase();
  const child = spawn(process.execPath, [join(import.meta.dirname, "worker.mjs")], {
    cwd: directory,
    env: {
      HOME: directory,
      PATH: "/usr/bin:/bin",
      PI_CODING_AGENT_DIR: agentDir,
      PI_OFFLINE: "1",
      PI_TELEMETRY: "0",
      SHELL: "/bin/sh",
    },
    stdio: ["pipe", "pipe", "inherit"],
  });
  t.after(() => child.kill());
  const exit = once(child, "close");
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const send = (...messages) => child.stdin.write(messages.map((message) => JSON.stringify(message) + "\n").join(""));
  async function receive(type) {
    for (;;) {
      const { value, done } = await lines.next();
      assert(!done, "Worker closed while waiting for " + type);
      const event = JSON.parse(value);
      switch (event.type) {
        case "credential":
          send({ type: "credentialResult", requestID: event.requestID, key: "fixture-key", exists: true });
          break;
        case "fatal":
          assert.fail(event.error);
          break;
        case "finished":
          assert.equal(event.error, undefined);
          assert.equal(type, event.type);
          return event;
        case "toolApproval":
          assert.equal(type, event.type);
          assert.equal(event.threadID, threadID);
          return event;
        default:
          if (event.type === type) return event;
      }
    }
  }
  send({
    type: "open",
    cwd: directory,
    sessionDir: join(directory, "session"),
    threadID,
    toolPermission,
    config: { provider: "local", endpoint, model: "approval-fixture", contextWindow: 64_000, localTools },
  });
  await receive("ready");
  return {
    child, exit, send, receive,
    prompt(text) {
      const turnID = randomUUID().toUpperCase();
      send({ type: "prompt", turnID, text });
      return turnID;
    },
  };
}

function reply({ threadID, turnID, requestID }, decision) {
  return { type: "toolApprovalResult", threadID, turnID, requestID, decision };
}

test("Supervised waits for each tool decision and drops pending work on stop or disconnect", { timeout: 20_000 }, async (t) => {
  const directory = mkdtempSync(join(tmpdir(), "pi-approval-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const { server, requests, endpoint } = await fixture();
  t.after(() => { server.closeAllConnections(); server.close(); });
  const project = join(directory, "project");
  const worker = await openWorker(t, project, endpoint, "supervised");
  const file = join(project, "edit.txt");
  writeFileSync(file, "before\n");

  const denyTurn = worker.prompt("deny edit");
  const denied = await worker.receive("toolApproval");
  assert.equal(denied.turnID, denyTurn);
  assert.equal(denied.tool, "edit");
  assert.deepEqual(JSON.parse(denied.details), edit.args);
  assert.equal(readFileSync(file, "utf8"), "before\n");
  worker.send(reply(denied, "decline"), reply(denied, "approve"));
  await worker.receive("finished");
  assert.equal(readFileSync(file, "utf8"), "before\n");
  const deniedResult = requests.get("deny edit").at(-1).messages.at(-1);
  assert.equal(deniedResult.role, "tool");
  assert.match(deniedResult.content, /declined this tool call/);

  worker.prompt("approve edit");
  const approved = await worker.receive("toolApproval");
  assert.notEqual(approved.requestID, denied.requestID);
  assert.equal(readFileSync(file, "utf8"), "before\n");
  worker.send(reply(approved, "approve"), reply(approved, "approve"));
  await worker.receive("finished");
  assert.equal(readFileSync(file, "utf8"), "after\n");

  const shellPath = join(project, "shell.txt");
  worker.prompt("approve one command");
  const first = await worker.receive("toolApproval");
  assert.equal(first.tool, "bash");
  assert.equal(existsSync(shellPath), false);
  worker.send(reply(first, "approve"), reply(first, "approve"));
  const second = await worker.receive("toolApproval");
  assert.equal(readFileSync(shellPath, "utf8"), "once\n");
  worker.send(
    reply(first, "approve"),
    reply(approved, "approve"),
    reply({ ...second, turnID: approved.turnID }, "approve"),
    reply({ ...second, threadID: randomUUID() }, "approve"),
    reply(second, "yes"),
    reply(second, "decline"),
  );
  await worker.receive("finished");
  assert.equal(readFileSync(shellPath, "utf8"), "once\n");

  const stopTurn = worker.prompt("stop write");
  const stopped = await worker.receive("toolApproval");
  assert.equal(stopped.tool, "write");
  assert.equal(existsSync(join(project, "stopped.txt")), false);
  worker.send({ type: "cancel", turnID: stopTurn }, reply(stopped, "approve"));
  await worker.receive("finished");
  assert.equal(existsSync(join(project, "stopped.txt")), false);

  worker.prompt("disconnect write");
  const disconnected = await worker.receive("toolApproval");
  assert.deepEqual(JSON.parse(disconnected.details), write("disconnected.txt").args);
  assert.equal(existsSync(join(project, "disconnected.txt")), false);
  worker.child.stdin.end();
  assert.deepEqual(await worker.exit, [0, null]);
  assert.equal(existsSync(join(project, "disconnected.txt")), false);
  const session = join(project, "session");
  const history = readFileSync(join(session, readdirSync(session).find((name) => name.endsWith(".jsonl"))), "utf8");
  const result = history.trimEnd().split("\n").map((line) => JSON.parse(line).message)
    .findLast((message) => message?.role === "toolResult");
  assert.equal(result?.toolName, "write");
  assert.equal(result?.isError, true);
  assert.match(result.content[0].text, /aborted/i);
});

test("Read files and Shell and edits retain their tool sets and local tools stay opt-in", { timeout: 20_000 }, async (t) => {
  const directory = mkdtempSync(join(tmpdir(), "pi-tool-modes-"));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const { server, requests, endpoint } = await fixture();
  t.after(() => { server.closeAllConnections(); server.close(); });
  const modes = [
    ["readFiles", true, ["find", "grep", "ls", "read"]],
    ["shellAndEdits", true, ["bash", "edit", "read", "write"]],
    ["supervised", false, []],
  ];
  for (const [permission, localTools, expected] of modes) {
    const worker = await openWorker(t, join(directory, permission), endpoint, permission, localTools);
    worker.prompt(permission);
    await worker.receive("finished");
    const tools = requests.get(permission)[0].tools ?? [];
    assert.deepEqual(tools.map(({ function: tool }) => tool.name).sort(), expected);
    worker.child.stdin.end();
    assert.deepEqual(await worker.exit, [0, null]);
  }
});
