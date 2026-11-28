import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { setTimeout } from "node:timers/promises";
import {
  authorizationCode, callbackURL, codexCredential, codexDeviceCode, copilotDeviceCode, copilotDeviceToken, openaiClient, rejection,
} from "./fixtures/login-upstream.mjs";

const deviceID = "27EC1D81-E169-442D-8E5C-7A9BC0CFA3A1";
const existing = { "other-provider": { type: "api_key", key: "fixture-existing-key" } };

function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), "pi-native-login-"));
  const loginDir = join(root, "login");
  const agentDir = join(root, "agent");
  const authPath = join(loginDir, "auth.json");
  const callbackFile = join(root, "callback");
  const requests = join(root, "requests");
  t.after(() => {
    assert(!existsSync(agentDir), "The helper touched the inherited agent directory");
    rmSync(root, { recursive: true, force: true });
  });

  function start(provider, { method, env, id = deviceID } = {}) {
    const child = spawn(process.execPath, ["--import", "./fixtures/login-upstream.mjs", "./login.mjs"], {
      cwd: import.meta.dirname,
      env: {
        HOME: root, TMPDIR: root, PI_TELEMETRY: "0", PI_CODING_AGENT_DIR: agentDir,
        TNCODE_LOGIN_DIR: loginDir, TNCODE_OAUTH_FIXTURE_LOG: requests,
        TNCODE_LOGIN_FIXTURE_CALLBACK_FILE: callbackFile, ...env,
      },
      timeout: 8_000,
      killSignal: "SIGKILL",
    });
    const closed = once(child, "close");
    child.stdin.on("error", () => {});
    t.after(async () => {
      child.kill("SIGKILL");
      await closed;
    });
    const events = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    let stderr = "";
    child.stderr.setEncoding("utf8").on("data", (line) => { stderr += line; });
    function send(command) { child.stdin.write(JSON.stringify(command) + "\n"); }
    async function receive(step) {
      const { value, done } = await events.next();
      assert(!done, `Expected login step ${step}. ${stderr}`);
      for (const secret of [authorizationCode, codexCredential().access, codexCredential().refresh,
        rejection, copilotDeviceToken, "fixture-existing-key", "fixture-openai-access", "fixture-openai-refresh",
        "fixture-claude-access", "fixture-claude-refresh", "fixture-copilot-access", "fixture-github-access"]) {
        assert(!value.includes(secret), "A private login value crossed IPC");
      }
      const event = JSON.parse(value);
      assert.equal(event.type, "login");
      assert.equal(event.step, step, JSON.stringify(event));
      return event;
    }
    async function finish(message) {
      const event = await receive(message ? "error" : "complete");
      assert.equal(event.message, message);
      assert.deepEqual(await closed, [0, null]);
      assert.equal(stderr, "");
      assert((await events.next()).done, "Unexpected IPC after terminal login event");
    }
    send({ type: "login", provider, deviceID: id, method });
    return { receive, finish, send, eof: () => child.stdin.end() };
  }

  return {
    start, authPath, loginDir, callbackFile, requests,
    seed(data) {
      mkdirSync(loginDir, { mode: 0o700 });
      writeFileSync(authPath, JSON.stringify(data), { mode: 0o600 });
    },
    auth: () => JSON.parse(readFileSync(authPath, "utf8")),
  };
}

function loopback(callback) {
  assert(["localhost", "127.0.0.1"].includes(callback.hostname));
  callback.hostname = "127.0.0.1";
  return fetch(callback, { signal: AbortSignal.timeout(3_000), redirect: "error" });
}

test("Codex defaults to browser login and saves only its provider after the SDK callback", async (t) => {
  const pi = fixture(t);
  pi.seed(existing);
  const child = pi.start("openai-codex");
  const { url } = await child.receive("browser");
  const authorize = new URL(url);
  assert.equal(authorize.origin, "https://auth.openai.com");
  assert.equal(authorize.searchParams.get("originator"), "tncode");
  const prompt = await child.receive("prompt");
  assert.equal(prompt.kind, "manual_code");
  child.send({ type: "answer", id: prompt.id + 1, value: "stale-response" });
  const callback = new URL(readFileSync(pi.callbackFile, "utf8"));
  assert.equal(callback.pathname, callbackURL(url).pathname);
  assert.equal(callback.search, callbackURL(url).search);
  const wrong = new URL(callback);
  wrong.searchParams.set("state", "wrong");
  assert.equal((await loopback(wrong)).status, 400);
  const response = await loopback(callback);
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Authentication successful/);
  assert.equal((await child.receive("dismissPrompt")).id, prompt.id);
  await child.finish();
  const credential = codexCredential();
  const { expires, ...saved } = pi.auth()["openai-codex"];
  assert.deepEqual(saved, { type: "oauth", accountId: credential.accountId, access: credential.access, refresh: credential.refresh });
  assert(expires > Date.now());
  assert.deepEqual(pi.auth()["other-provider"], existing["other-provider"]);
});

test("OpenAI passes the stable installation ID and accepts a full manual redirect URL", async (t) => {
  const pi = fixture(t);
  const child = pi.start("openai");
  const { url } = await child.receive("browser");
  const authorize = new URL(url);
  assert.equal(authorize.searchParams.get("agent_name_hint"), "tncode");
  assert.equal(authorize.searchParams.get("ext_agent_host_id"), `urn:uuid:${deviceID.toLowerCase()}`);
  const { id, kind } = await child.receive("prompt");
  assert.equal(kind, "manual_code");
  child.send({ type: "answer", id, value: callbackURL(url).href });
  assert.equal((await child.receive("dismissPrompt")).id, id);
  await child.receive("progress");
  await child.finish();
  assert.equal(pi.auth().openai.clientId, openaiClient);
  assert.equal(statSync(pi.authPath).mode & 0o777, 0o600);
  assert.equal(statSync(pi.loginDir).mode & 0o777, 0o700);
});

test("Claude browser sign-in completes on the default path without entering a code", async (t) => {
  const pi = fixture(t);
  const child = pi.start("anthropic");
  const { url } = await child.receive("browser");
  assert.equal(new URL(url).origin, "https://claude.ai");
  const prompt = await child.receive("prompt");
  const callback = new URL(readFileSync(pi.callbackFile, "utf8"));
  assert.equal(callback.searchParams.get("state"), new URL(url).searchParams.get("state"));
  assert.equal((await loopback(callback)).status, 200);
  assert.equal((await child.receive("dismissPrompt")).id, prompt.id);
  await child.receive("progress");
  await child.finish();
  assert.equal(pi.auth().anthropic.access, "fixture-claude-access");
});

test("Anthropic uses its copy-code flow when requested", async (t) => {
  const pi = fixture(t);
  const child = pi.start("anthropic", { method: "code" });
  const { url } = await child.receive("browser");
  const params = new URL(url).searchParams;
  assert.equal(params.get("redirect_uri"), "https://platform.claude.com/oauth/code/callback");
  const { id, kind } = await child.receive("prompt");
  assert.equal(kind, "manual_code");
  child.send({ type: "answer", id, value: `${authorizationCode}#${params.get("state")}` });
  assert.equal((await child.receive("dismissPrompt")).id, id);
  await child.receive("progress");
  await child.finish();
  assert.equal(pi.auth().anthropic.access, "fixture-claude-access");
});

test("GitHub Copilot prompts for an enterprise domain and emits only the public device details", async (t) => {
  const pi = fixture(t);
  const child = pi.start("github-copilot");
  const { id, kind, message } = await child.receive("prompt");
  assert.equal(kind, "text");
  assert.match(message, /GitHub Enterprise/);
  child.send({ type: "answer", id, value: "" });
  assert.equal((await child.receive("dismissPrompt")).id, id);
  assert.deepEqual(await child.receive("device"), {
    type: "login", step: "device", url: "https://github.com/login/device", code: copilotDeviceCode,
  });
  await child.finish();
  assert.equal(pi.auth()["github-copilot"].refresh, "fixture-github-access");
});

test("Codex cancellation during token exchange preserves the file and permits a device-code retry", async (t) => {
  const pi = fixture(t);
  const previous = { ...existing, "openai-codex": codexCredential() };
  pi.seed(previous);
  const child = pi.start("openai-codex", { env: { TNCODE_LOGIN_FIXTURE_MODE: "late-token" } });
  const { url } = await child.receive("browser");
  const { id } = await child.receive("prompt");
  child.send({ type: "answer", id, value: callbackURL(url).href });
  assert.equal((await child.receive("dismissPrompt")).id, id);
  for (let i = 0; i < 100 && !existsSync(pi.requests); i++) await setTimeout(10);
  assert.equal(readFileSync(pi.requests, "utf8"), "login-codex\n");
  child.send({ type: "cancel" });
  await child.finish("cancelled");
  assert.deepEqual(pi.auth(), previous);
  const retry = pi.start("openai-codex", { method: "code" });
  assert.deepEqual(await retry.receive("device"), {
    type: "login", step: "device", url: "https://auth.openai.com/codex/device", code: codexDeviceCode,
  });
  await retry.finish();
  assert.equal(pi.auth()["openai-codex"].access, codexCredential().access);
});

test("EOF dismisses a pending prompt without creating a credential store", async (t) => {
  const pi = fixture(t);
  const child = pi.start("github-copilot");
  const { id } = await child.receive("prompt");
  child.eof();
  assert.equal((await child.receive("dismissPrompt")).id, id);
  await child.finish("cancelled");
  assert(!existsSync(pi.loginDir));
});

test("Token exchange failures are sanitized and leave the existing credentials intact", async (t) => {
  const pi = fixture(t);
  pi.seed(existing);
  const child = pi.start("openai-codex", { env: { TNCODE_LOGIN_FIXTURE_MODE: "reject" } });
  const { url } = await child.receive("browser");
  const { id } = await child.receive("prompt");
  child.send({ type: "answer", id, value: callbackURL(url).href });
  await child.receive("dismissPrompt");
  await child.finish("login_failed");
  assert.deepEqual(pi.auth(), existing);
});

test("Unknown providers and untrusted login paths fail before initiating OAuth", async (t) => {
  const pi = fixture(t);
  await pi.start("radius").finish("unsupported_provider");
  await pi.start("openai-codex", { env: { TNCODE_LOGIN_DIR: "relative" } }).finish("missing_login_directory");
  await pi.start("openai", { id: "invalid" }).finish("invalid_request");
  assert(!existsSync(pi.loginDir));
  assert(!existsSync(pi.requests));
});
