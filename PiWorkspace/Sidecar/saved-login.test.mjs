import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { once } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { ambientKey, codexCredential, codexModel, commitSubject, otherLoginRoutes, replyText } from "./fixtures/saved-login-upstream.mjs";

const sdk = "node_modules/@earendil-works/pi-coding-agent";
const installed = JSON.parse(readFileSync(new URL(`./${sdk}/package.json`, import.meta.url)));
const lock = JSON.parse(readFileSync(new URL("./package-lock.json", import.meta.url)));
assert.equal(installed.version, lock.packages[sdk].version);

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "pi-saved-login-"));
  const loginDir = join(root, "login");
  const agentDir = join(root, "workspace-agent");
  const requests = join(root, "requests");
  const authPath = join(loginDir, "auth.json");
  const children = new Set();
  const rotated = codexCredential({ state: "rotated" });
  const secrets = new Set([ambientKey, rotated.access, rotated.refresh]);
  for (const directory of [loginDir, agentDir]) mkdirSync(directory, { mode: 0o700 });
  t.after(async () => {
    for (const worker of children) worker.child.kill();
    await Promise.all([...children].map(({ closed }) => closed));
    rmSync(root, { recursive: true, force: true });
  });

  const profile = (accountId = "") => createHash("sha256").update(loginDir + "\0" + accountId).digest("hex");
  function auth(credentials) {
    for (const { access, refresh } of Object.values(credentials)) {
      if (access) secrets.add(access);
      if (refresh) secrets.add(refresh);
    }
    writeFileSync(authPath, JSON.stringify(credentials), { mode: 0o600 });
  }
  function assertPrivate(text, location) {
    for (const secret of secrets) assert(!text.includes(secret), `Fixture credential in ${location}`);
  }
  function start(type, overrides = {}) {
    const threadID = randomUUID();
    const sessionDir = join(root, threadID);
    const child = spawn(process.execPath, [
      "--import", join(import.meta.dirname, "fixtures", "saved-login-upstream.mjs"),
      join(import.meta.dirname, "worker.mjs"),
    ], {
      cwd: root,
      env: {
        PATH: "/usr/bin:/bin",
        HOME: root,
        TMPDIR: root,
        PI_CODING_AGENT_DIR: agentDir,
        PI_WORKSPACE_LOGIN_DIR: loginDir,
        PI_WORKSPACE_OAUTH_FIXTURE_LOG: requests,
        PI_OFFLINE: "1",
        PI_TELEMETRY: "0",
        OPENAI_API_KEY: ambientKey,
        ANTHROPIC_API_KEY: ambientKey,
        COPILOT_GITHUB_TOKEN: ambientKey,
      },
      timeout: 10_000,
    });
    const closed = once(child, "close");
    const worker = { child, closed };
    children.add(worker);
    const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    let stderr = "";
    child.stderr.setEncoding("utf8").on("data", (text) => { stderr += text; });
    const send = (command) => child.stdin.write(JSON.stringify(command) + "\n");
    const decode = (line) => {
      assertPrivate(line, "worker stdout");
      const event = JSON.parse(line);
      assert.notEqual(event.type, "credential", "Saved Pi login requested Keychain IPC");
      return event;
    };
    async function receive(target) {
      for (;;) {
        const { value, done } = await lines.next();
        assert(!done, "Worker exited before " + target);
        const event = decode(value);
        if (event.type === target) return event;
        assert.notEqual(event.type, "fatal", event.error);
      }
    }
    async function close(expectedCode = 0) {
      child.stdin.end();
      for await (const line of lines) decode(line);
      const [code, signal] = await closed;
      children.delete(worker);
      assertPrivate(stderr, "worker stderr");
      assert.equal(signal, null);
      assert.equal(code, expectedCode, stderr);
      if (existsSync(sessionDir)) {
        for (const name of readdirSync(sessionDir)) {
          assertPrivate(readFileSync(join(sessionDir, name), "utf8"), "saved history");
        }
      }
    }
    send({
      type, cwd: root, threadID, sessionDir, toolPermission: "readFiles",
      config: {
        provider: "pi:openai-codex", model: codexModel, contextWindow: 8192,
        piLoginProfile: profile(codexCredential().accountId),
        ...overrides,
      },
      patch: "+use saved Pi login",
      style: "conventional_commits",
    });
    return {
      receive, close,
      prompt(text = "First saved-login message") {
        const turnID = randomUUID();
        send({ type: "prompt", turnID, text });
        return receive("finished");
      },
    };
  }
  return {
    auth, authPath, root, start, profile,
    requestLog: () => existsSync(requests) ? readFileSync(requests, "utf8").trim().split("\n") : [],
  };
}

test("Saved Pi login answers the first message and drafts a commit without Keychain IPC", { timeout: 15_000 }, async (t) => {
  const pi = fixture(t);
  pi.auth({ "openai-codex": codexCredential() });
  const worker = pi.start("open");
  assert.deepEqual((await worker.receive("ready")).messages, []);
  const finished = await worker.prompt();
  assert.equal(finished.error, undefined);
  assert.deepEqual(finished.messages.map(({ role, text }) => [role, text]), [
    ["user", "First saved-login message"],
    ["assistant", replyText],
  ]);
  const denied = await worker.prompt("Reject my login");
  assert.match(denied.error, /Token revoked: Bearer \[Pi login token removed\]/);
  await worker.close();

  const commit = pi.start("generateCommitMessage");
  assert.equal((await commit.receive("commitMessage")).text, commitSubject);
  await commit.close();
  assert.deepEqual(pi.requestLog(), ["codex", "codex", "codex"]);
});

for (const { provider, access, model } of otherLoginRoutes) {
  test(`Pi's saved ${provider} login sends the first message`, { timeout: 10_000 }, async (t) => {
    const pi = fixture(t);
    pi.auth({ [provider]: { type: "oauth", access, refresh: "fixture-refresh", expires: Date.now() + 3_600_000 } });
    const worker = pi.start("open", { provider: "pi:" + provider, model, piLoginProfile: pi.profile() });
    await worker.receive("ready");
    const result = await worker.prompt();
    assert.equal(result.error, undefined);
    assert.equal(result.messages.at(-1)?.text, replyText);
    assert.deepEqual(pi.requestLog(), [provider]);
    await worker.close();
  });
}

test("A legacy worker publishes all four saved-login model catalogs", { timeout: 10_000 }, async (t) => {
  const pi = fixture(t);
  const worker = pi.start("open", { provider: "openai", model: "gpt-5-mini" });
  const { models } = await worker.receive("modelCatalog");
  assert.deepEqual(models["pi:openai"], models.openai);
  assert.deepEqual(models["pi:anthropic"], models.anthropic);
  assert.equal(typeof models["pi:openai-codex"][codexModel], "string");
  for (const route of ["pi:openai", "pi:anthropic", "pi:github-copilot"]) {
    assert(Object.keys(models[route]).length > 0);
  }
  await worker.receive("ready");
  await worker.close();
  assert.deepEqual(pi.requestLog(), []);
  assert(!existsSync(pi.authPath));
});

test("Saved-login routes fail closed with a missing profile, wrong account or stored API key", { timeout: 15_000 }, async (t) => {
  const pi = fixture(t);
  const wrong = pi.start("open", { piLoginProfile: undefined });
  pi.auth({ "openai-codex": codexCredential() });
  await wrong.receive("ready");
  assert.match((await wrong.prompt()).error, /Sign in again in Model Settings/);
  await wrong.close();

  const worker = pi.start("open");
  await worker.receive("ready");
  pi.auth({ "openai-codex": codexCredential({ accountId: "different-account" }) });
  const finished = await worker.prompt();
  assert.match(finished.error, /Sign in again in Model Settings/);
  assert.deepEqual(finished.messages, []);
  await worker.close();

  const direct = pi.start("open", { provider: "pi:openai", model: "gpt-5-mini", piLoginProfile: pi.profile() });
  await direct.receive("ready");
  assert.match((await direct.prompt()).error, /Sign in again in Model Settings/);
  pi.auth({ openai: { type: "api_key", key: "!touch executed-auth-command" } });
  assert.match((await direct.prompt()).error, /Sign in again in Model Settings/);
  await direct.close();
  assert.deepEqual(pi.requestLog(), []);
  assert(!existsSync(join(pi.root, "executed-auth-command")));
});

test("SDK refresh persists a rotated credential and never sends with revoked or switched auth", { timeout: 15_000 }, async (t) => {
  const pi = fixture(t);
  const otherCredential = { type: "api_key", key: "fixture-unrelated-key" };
  for (const state of ["revoked", "malformed", "switched", "expired"]) {
    const saved = codexCredential({ state });
    pi.auth({ "openai-codex": saved, openai: otherCredential });
    const worker = pi.start("open");
    await worker.receive("ready");
    const result = await worker.prompt();
    await worker.close();
    const auth = JSON.parse(readFileSync(pi.authPath, "utf8"));
    assert.deepEqual(auth.openai, otherCredential);
    if (state === "expired") {
      assert.equal(result.error, undefined);
      assert.equal(result.messages.at(-1).text, replyText);
      assert.equal(auth["openai-codex"].access, codexCredential({ state: "rotated" }).access);
      assert.equal(auth["openai-codex"].refresh, codexCredential({ state: "rotated" }).refresh);
    } else {
      assert.match(result.error, /Sign in again in Model Settings/);
      assert.deepEqual(auth["openai-codex"], saved);
    }
  }
  assert.deepEqual(pi.requestLog(), ["refresh", "refresh", "refresh", "refresh", "codex"]);
});
