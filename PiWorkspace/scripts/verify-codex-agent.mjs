import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { readFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { createInterface } from "node:readline";
import { setTimeout as delay } from "node:timers/promises";
import {
  first, loopbackSandbox, mcpNamespace, mcpToolName, resumed, searchQuery, stopped, toolTurn, withCodexAgentFixture,
} from "./fixtures/codex-agent-responses.mjs";

// CODEX_BINARY=/absolute/path/to/codex node PiWorkspace/scripts/verify-codex-agent.mjs [codex-agent.mjs]
const binary = process.env.CODEX_BINARY;
assert(binary && isAbsolute(binary), "Set CODEX_BINARY to the absolute path of the installed Codex executable.");
assert.equal(process.platform, "darwin", "This verifier uses macOS Seatbelt to restrict networking to loopback.");
const workerPath = resolve(process.argv[2] ?? process.env.PI_CODEX_WORKER ?? resolve(import.meta.dirname, "../Sidecar/codex-agent.mjs"));
const threadID = randomUUID().toUpperCase();

function isolatedArgs(executable, ...args) {
  return ["-p", loopbackSandbox, executable, ...args];
}

function startWorker({ cwd, sessionDir, environment }) {
  const child = spawn("/usr/bin/sandbox-exec", isolatedArgs(process.execPath, workerPath), {
    cwd, env: environment, timeout: 25_000, killSignal: "SIGKILL",
  });
  const closed = once(child, "close");
  const output = createInterface({ input: child.stdout, crlfDelay: Infinity });
  const events = output[Symbol.asyncIterator]();
  let stderr = "";
  let inputError;
  child.stderr.setEncoding("utf8").on("data", text => { stderr += text; });
  child.stdin.on("error", error => { inputError = error; });

  function send(command) {
    if (inputError) throw inputError;
    child.stdin.write(JSON.stringify(command) + "\n");
  }

  async function receive(type, observed = [], matches = () => true) {
    for (;;) {
      const { value, done } = await events.next();
      if (done) break;
      const event = JSON.parse(value);
      if (event.type === type && matches(event)) return event;
      assert(!["fatal", "credential", "toolApproval", "agentQuestion"].includes(event.type), JSON.stringify(event));
      observed.push(event);
    }
    const [code, signal] = await closed;
    assert.fail(`Expected Pi event ${type}. Worker exited (${code ?? signal}). ${stderr}`);
  }

  async function finish(turnID, observed) {
    const event = await receive("finished", observed);
    assert.equal(event.turnID, turnID);
    assert.equal(event.error ?? null, null);
    return event.messages;
  }

  async function close() {
    child.stdin.end();
    const [code, signal] = await closed;
    assert.equal(signal, null, stderr);
    assert.equal(code, 0, stderr);
  }

  send({
    type: "open", cwd, sessionDir, threadID, toolPermission: "supervised",
    config: { provider: "codex-app-server", model: "auto" },
  });
  return { send, receive, finish, close, closed, terminate: () => child.kill() };
}

function prompt(worker, text) {
  const turnID = randomUUID().toUpperCase();
  worker.send({ type: "prompt", turnID, text });
  return turnID;
}

function transcript(messages) {
  for (const { id } of messages) assert.equal(typeof id, "string");
  assert.equal(new Set(messages.map(({ id }) => id)).size, messages.length);
  return messages.map(({ role, text }) => [role, text]);
}

await withCodexAgentFixture(binary, async fixture => {
  const version = execFileSync("/usr/bin/sandbox-exec", isolatedArgs(binary, "--version"), {
    cwd: fixture.cwd, env: fixture.environment, encoding: "utf8", timeout: 5_000,
  }).trim();
  assert.match(version, /^codex-cli /);
  console.log(version);

  let worker = startWorker(fixture);
  try {
    const firstEvents = [];
    assert.deepEqual((await worker.receive("ready", firstEvents)).messages, []);
    const messages = await worker.finish(prompt(worker, first.prompt), firstEvents);
    const expected = [["user", first.prompt], ["assistant", first.answer]];
    assert.deepEqual(transcript(messages), expected);
    assert(firstEvents.some(event => event.type === "partial" && event.text === first.answer), "Expected streamed reply");
    assert(firstEvents.some(event => event.type === "activity" && event.text.includes(searchQuery)),
      "Expected a Pi activity event from the synthetic Codex web search");
    const hasComputerUse = event => event.computerUse === true;
    const capabilities = firstEvents.find(event => event.type === "codexCapabilities" && hasComputerUse(event)) ??
      await worker.receive("codexCapabilities", firstEvents, hasComputerUse);
    assert.equal(capabilities.webSearch, "live");

    const { tools } = fixture.requests[0].body;
    assert(tools.some(tool => tool.type === "web_search" && tool.external_web_access === true), "Missing Codex web_search tool");
    assert(tools.some(tool => tool.name === mcpNamespace && tool.tools?.some(entry => entry.name === mcpToolName)),
      "Missing the synthetic cua_repl/js inventory entry");
    console.log("PASS streamed reply, web_search advertisement and notification, synthetic cua_repl/js discovery");

    const turnID = prompt(worker, stopped.prompt);
    assert.equal((await worker.receive("partial", [], event => event.text !== "")).text, stopped.answer);
    worker.send({ type: "cancel", turnID });
    const interrupted = await worker.finish(turnID);
    const interruptedHistory = [...expected, ["user", stopped.prompt], ["assistant", stopped.answer]];
    assert.deepEqual(transcript(interrupted), interruptedHistory);
    assert.equal(interrupted.at(-1).incompleteReply, "interrupted");
    const dropped = await Promise.race([fixture.requests[1].closed, delay(5_000, undefined, { ref: false })]);
    assert.equal(dropped, true, "Codex should drop the open Responses stream on interrupt");
    await worker.close();

    worker = startWorker(fixture);
    const reopened = (await worker.receive("ready")).messages;
    assert.deepEqual(transcript(reopened), interruptedHistory);
    assert.deepEqual(reopened.map(({ id }) => id), interrupted.map(({ id }) => id));
    assert.equal(reopened.at(-1).incompleteReply, "interrupted");
    const afterReopen = await worker.finish(prompt(worker, resumed.prompt));
    assert.deepEqual(transcript(afterReopen), [...transcript(reopened), ["user", resumed.prompt], ["assistant", resumed.answer]]);
    await worker.close();

    assert.deepEqual(fixture.requests.map(({ prompt }) => prompt), [first.prompt, stopped.prompt, resumed.prompt]);
    const input = fixture.requests[2].body.input.flatMap(({ content }) => content?.map(({ text }) => text) ?? []);
    for (const text of [first.prompt, first.answer, stopped.prompt, resumed.prompt]) assert(input.includes(text));
    assert(input.some(text => text?.includes("<turn_aborted>")), "Expected Codex to retain its interrupted-turn marker");
    const mcpMethods = readFileSync(fixture.mcpLog, "utf8").trim().split("\n");
    assert(mcpMethods[0] === "tools/list" && mcpMethods.every(method => method === "tools/list"));
    console.log("PASS interrupt, process reopen and Codex history replay");
  } finally {
    worker.terminate();
    await worker.closed;
  }
});

await withCodexAgentFixture(binary, async fixture => {
  const worker = startWorker(fixture);
  try {
    await worker.receive("ready");
    const turnID = prompt(worker, toolTurn.prompt);
    for (const expected of [/run tool/, /inert fixture/]) {
      const card = await worker.receive("toolApproval");
      assert.equal(card.threadID, threadID);
      assert.equal(card.turnID, turnID);
      assert.equal(card.tool, "MCP cua_repl/js");
      assert.match(card.details, expected);
      worker.send({ type: "toolApprovalResult", threadID, turnID, requestID: card.requestID, decision: "approve" });
    }
    const messages = await worker.finish(turnID, []);
    assert.equal(messages.at(-1).text, toolTurn.answer);
    assert.equal(fixture.requests.length, 2);
    assert.match(JSON.stringify(fixture.requests[1].body.input), /fixture action confirmed/);
    const operations = readFileSync(fixture.mcpLog, "utf8").trim().split("\n").filter(line => line !== "tools/list");
    assert.deepEqual(operations, ["tools/call", "approved once"]);
    console.log("PASS real Codex called the inert MCP tool and returned its one-time consent result");
  } finally {
    await worker.close();
  }
});

if (process.env.PI_CODEX_XCTEST) {
  const bundle = resolve(process.env.PI_CODEX_XCTEST);
  await withCodexAgentFixture(binary, async ({ cwd, environment, requests, mcpLog }) => {
    const child = spawn("/usr/bin/sandbox-exec", isolatedArgs("/usr/bin/xcrun", "xctest",
      "-XCTest", "PiWorkspaceTests.CodexAgentTests", bundle), {
      cwd, stdio: "inherit", timeout: 60_000,
      env: { ...environment, PI_CODEX_NATIVE_CHECKOUT: cwd, PI_CODEX_NATIVE_AGENT: workerPath, PI_CODEX_NATIVE_NODE: process.execPath },
    });
    const [code, signal] = await once(child, "close");
    assert.equal(signal, null);
    assert.equal(code, 0, "Native Codex session checks failed.");
    assert.deepEqual(requests.map(request => request.prompt), [first.prompt]);
    assert(readFileSync(mcpLog, "utf8").trim().split("\n").every(method => method === "tools/list"));
    console.log("PASS native workspace selects Codex, sends a prompt and restores the same conversation");
  });
}
