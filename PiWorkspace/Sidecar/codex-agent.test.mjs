import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { fileURLToPath } from "node:url";

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "codex-agent-test-"));
  const cwd = join(root, "project");
  const sessionDir = join(root, "session");
  const home = join(root, "codex-home");
  const config = { provider: "codex-app-server", model: "auto", thinkingLevel: "high" };
  const open = { type: "open", cwd, sessionDir, threadID: randomUUID(), toolPermission: "supervised", config };
  const binary = join(root, "codex.mjs");
  const metadata = join(sessionDir, "codex-thread.json");
  copyFileSync(new URL("./fixtures/codex-conversation-server.mjs", import.meta.url), binary);
  chmodSync(binary, 0o700);
  for (const directory of [cwd, home, sessionDir]) mkdirSync(directory);
  const stops = [];
  t.after(async () => {
    await Promise.all(stops.map(stop => stop()));
    rmSync(root, { recursive: true, force: true });
  });

  function launch({ user = "user-1", command = open } = {}) {
    const agent = spawn(process.execPath, [fileURLToPath(new URL("./codex-agent.mjs", import.meta.url))], {
      env: { ...process.env, CODEX_HOME: home, PI_WORKSPACE_CODEX_BIN: binary, FIXTURE_USER: user },
      stdio: ["pipe", "pipe", "inherit"],
    });
    const send = message => agent.stdin.write(JSON.stringify(message) + "\n");
    const events = [];
    let closed = false;
    const reader = createInterface({ input: agent.stdout });
    reader.on("line", line => events.push(JSON.parse(line)));
    const exit = new Promise(resolve => agent.once("close", code => {
      closed = true;
      resolve(code);
    }));
    const stop = async () => {
      if (!closed) agent.stdin.end();
      return await exit;
    };
    stops.push(stop);
    send(command);
    return {
      send, stop, events,
      async take(type, predicate = () => true) {
        for (let tries = 0; tries < 300; tries++) {
          const found = events.findIndex(event => event.type === type && predicate(event));
          if (found !== -1) return events.splice(found, 1)[0];
          if (closed) break;
          await new Promise(resolve => setTimeout(resolve, 10));
        }
        assert.fail(`Expected ${type}. Events: ${JSON.stringify(events)}`);
      },
    };
  }

  const requests = () => JSON.parse(readFileSync(join(home, "fixture-requests.json"), "utf8"));
  return { launch, open, metadata, requests };
}

test("routes native turns and scoped approvals, then resumes receipts without sending the queue entry twice", async t => {
  const { launch, open, metadata, requests } = fixture(t);
  const agent = launch();
  assert.deepEqual((await agent.take("ready")).messages, []);
  await agent.take("codexCapabilities", event => event.webSearch === "live" && event.computerUse === true);
  assert.equal(existsSync(metadata), false);
  assert.equal(requests().some(({ method }) => method === "thread/start"), false);

  const queuedID = randomUUID();
  const attachment = { id: randomUUID(), name: "notes.txt",
    payload: { mimeType: "text/plain", data: Buffer.from("hello world").toString("base64") } };
  const prompt = { type: "prompt", turnID: randomUUID(), text: "analyze file", queuedID, attachments: [attachment] };
  agent.send(prompt);
  const { messages: [user] } = await agent.take("history");
  assert.equal(user.text, prompt.text);
  assert.equal(user.queuedID, queuedID);
  assert.equal(user.attachments[0].hasText, true);
  const saved = JSON.parse(readFileSync(metadata, "utf8"));
  assert.equal(saved.threadID, open.threadID);
  assert.equal(saved.runs[0].accepted, true);
  assert.equal(JSON.stringify(saved).includes("test-identity"), false);
  const start = requests().find(({ method }) => method === "turn/start").params;
  assert.equal(start.effort, "high");
  assert.match(start.input[0].text, /Attached text file "notes.txt":\nhello world$/);
  assert.equal(requests().find(({ method }) => method === "thread/start").params.model, undefined);

  function answer(card, decision = "approve", threadID = open.threadID) {
    agent.send({ type: "toolApprovalResult", requestID: card.requestID, turnID: prompt.turnID, threadID, decision });
  }
  const command = await agent.take("toolApproval");
  assert.match(command.details, /echo hello/);
  answer(command, "decline", randomUUID());
  answer(command);
  const patch = await agent.take("toolApproval");
  assert.match(patch.details, /\+hello/);
  answer(patch, "decline");
  const permissions = await agent.take("toolApproval");
  assert.match(permissions.details, /"scope": "turn"/);
  answer(permissions);
  const form = await agent.take("toolApproval");
  assert.equal(form.tool, "MCP cua_repl/js");
  answer(form);
  const appAccess = await agent.take("toolApproval");
  assert.match(appAccess.details, /Allow ChatGPT to use Safari/);
  answer(appAccess);
  assert.equal((await agent.take("activity", event => event.text.startsWith("Web search"))).text, "Web search: fixture search");
  assert.equal((await agent.take("partial")).text, "Partial answer");
  agent.send({ type: "cancel", turnID: prompt.turnID });
  const stopped = await agent.take("finished");
  assert.equal(stopped.turnID, prompt.turnID);
  assert.equal(stopped.messages[1].text, "Partial answer");
  assert.equal(stopped.messages[1].incompleteReply, "interrupted");
  assert.equal(await agent.stop(), 0);

  const reopened = launch({ command: { ...open, requireHistory: true } });
  assert.deepEqual((await reopened.take("ready")).messages, stopped.messages);
  reopened.send({ ...prompt, turnID: randomUUID() });
  assert.deepEqual((await reopened.take("finished")).messages, stopped.messages);
  assert.equal(requests().some(({ method }) => method === "thread/resume"), true);
  assert.equal(requests().some(({ method }) => method === "turn/start"), false);
  reopened.send({ type: "readSentFile", requestID: randomUUID(), messageID: user.id, attachmentID: attachment.id });
  assert.deepEqual((await reopened.take("sentFile")).file, attachment.payload);
  reopened.send({ type: "prompt", turnID: randomUUID(), text: "finish" });
  const completed = await reopened.take("finished");
  assert.equal(completed.messages.at(-1).text, "Full answer");
  assert.equal(completed.messages.at(-1).canFork, undefined);
});

test("reconciles a recorded submission after lost acknowledgement and rejects mismatched account ownership", async t => {
  const { launch, open, requests } = fixture(t);
  const agent = launch();
  await agent.take("ready");
  const prompt = { type: "prompt", turnID: randomUUID(), submissionID: randomUUID(), text: "lose connection" };
  agent.send(prompt);
  await agent.take("fatal");
  assert.equal(await agent.stop(), 1);

  const wrong = launch({ user: "wrong-user" });
  assert.match((await wrong.take("fatal")).error, /different Codex home or account/);
  assert.equal(await wrong.stop(), 1);

  const resumed = launch({ command: { ...open, requireHistory: true } });
  const { messages } = await resumed.take("ready");
  assert.equal(messages[0].submissionID, prompt.submissionID);
  resumed.send({ ...prompt, turnID: randomUUID() });
  await resumed.take("finished");
  assert.equal(requests().some(({ method }) => method === "turn/start"), false);
});

test("rejects inaccessible history and unsupported input before creating a native thread", async t => {
  const { launch, open, requests, metadata } = fixture(t);
  const missing = launch({ command: { ...open, requireHistory: true } });
  assert.match((await missing.take("fatal")).error, /history is missing/);
  await missing.stop();

  const agent = launch();
  await agent.take("ready");
  agent.send({ type: "prompt", turnID: randomUUID(), text: "image", attachments: [
    { id: randomUUID(), name: "image.png", payload: { mimeType: "image/png", data: "AAAA" } },
  ] });
  assert.match((await agent.take("finished")).error, /accepts text attachments only/);
  assert.equal(requests().some(({ method }) => method === "thread/start"), false);
  assert.equal(existsSync(metadata), false);
  await agent.stop();

  writeFileSync(join(open.sessionDir, "pi.jsonl"), "{}\n");
  const pi = launch();
  assert.match((await pi.take("fatal")).error, /Pi history/);
});
