import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";

const fixture = new URL("./fixtures/codex-app-server.mjs", import.meta.url);
const helper = new URL("./codex-login.mjs", import.meta.url).pathname;
const transport = new URL("./codex-rpc.mjs", import.meta.url).href;

function setup(t) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-codex-rpc-")));
  const cwd = join(root, "project");
  const codexHome = join(root, "codex-home");
  const bin = join(root, "codex");
  const log = join(root, "calls");
  mkdirSync(cwd);
  mkdirSync(codexHome);
  writeFileSync(bin, `#!${process.execPath}\nimport ${JSON.stringify(fixture.href)};\n`, { mode: 0o700 });
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return { cwd, bin, codexHome, log };
}

function runNode(t, args, options, mode, env = {}) {
  const child = spawn(process.execPath, args, {
    cwd: options.cwd,
    env: {
      HOME: process.env.HOME,
      PATH: "/usr/bin:/bin",
      PI_WORKSPACE_CODEX_BIN: options.bin,
      CODEX_HOME: options.codexHome,
      TEST_CODEX_MODE: mode,
      TEST_CODEX_LOG: options.log,
      ...env,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const exited = once(child, "close");
  t.after(() => child.kill("SIGTERM"));
  return {
    send(command) { child.stdin.write(JSON.stringify(command) + "\n"); },
    end() { child.stdin.end(); },
    async receive() {
      const { value, done } = await lines.next();
      assert.equal(done, false, stderr);
      assert.doesNotMatch(value, /fixture-private|private@example|fixture-login-id/);
      return JSON.parse(value);
    },
    async finish() {
      assert.deepEqual(await exited, [0, null], stderr);
      assert.equal((await lines.next()).done, true);
      assert.equal(stderr, "");
    },
    methods: () => existsSync(options.log) ? readFileSync(options.log, "utf8").trim().split("\n") : [],
  };
}

test("RPC multiplexes requests, notifications, errors and cancellation", { timeout: 5_000 }, async (t) => {
  const options = setup(t);
  const script = `
    import assert from "node:assert/strict";
    import { CodexRPC } from ${JSON.stringify(transport)};
    const notifications = [];
    const closed = [];
    let finishRequest;
    const lateAnswer = new Promise(resolve => { finishRequest = resolve; });
    const rpc = new CodexRPC({
      cwd: process.cwd(),
      onNotification(method, params) {
        notifications.push([method, params]);
        if (method === "serverRequest/resolved") finishRequest("too late");
      },
      async onRequest(method, params) {
        if (method === "fixture/failing") throw new Error("private callback exception");
        if (method === "fixture/supported") return params ?? lateAnswer;
      },
      onClose(error) { closed.push(error); },
    });
    try {
      assert.equal(rpc.start(), rpc.start());
      await rpc.start();
      const [details, replies] = await Promise.all([rpc.call("fixture/inspect"), rpc.call("fixture/roundTrip")]);
      assert.equal(details.cwd, process.cwd());
      assert.equal(details.codexHome, process.env.CODEX_HOME);
      assert(!details.path.includes("project/bin"));
      assert.deepEqual(replies.find(reply => reply.id === 1), {id:1,result:{answer:42}});
      assert.equal(replies.find(reply => reply.id === "unknown").error.code, -32601);
      assert.deepEqual(replies.find(reply => reply.id === "failed").error, {
        code:-32603, message:"Could not handle the server request.",
      });
      assert.equal(notifications[0][1].value, "☃");
      await assert.rejects(rpc.call("fixture/error"), {
        code:"codex_rpc_error", rpcCode:-32000, message:"Codex rejected the request.",
      });
      const controller = new AbortController();
      const cancelled = assert.rejects(rpc.call("fixture/hang", {}, {signal:controller.signal}), {code:"codex_cancelled"});
      controller.abort("private abort reason");
      await cancelled;
      await assert.rejects(rpc.call("fixture/hang", {}, {timeoutMs:10}), {code:"codex_timeout"});
      const pending = assert.rejects(rpc.call("fixture/hang"), {code:"codex_closed"});
      await rpc.close();
      await pending;
      assert.throws(() => process.kill(details.pid, 0), {code:"ESRCH"});
      assert.deepEqual(closed, [undefined]);
    } finally {
      await rpc.close();
    }
  `;
  mkdirSync(join(options.cwd, "bin"));
  const child = runNode(t, ["--input-type=module", "-e", script], options, "", {
    PATH: `bin:${join(options.cwd, "bin")}:/usr/bin:/bin`,
  });
  child.end();
  await child.finish();
});

test("RPC rejects project and relative executable overrides", { timeout: 5_000 }, async (t) => {
  const options = setup(t);
  const link = join(options.cwd, "codex");
  symlinkSync(options.bin, link);
  const script = `
    import assert from "node:assert/strict";
    import { CodexRPC } from ${JSON.stringify(transport)};
    const rpc = new CodexRPC({cwd:process.cwd()});
    await assert.rejects(rpc.start(), {code:"codex_invalid_executable"});
    await rpc.close();
  `;
  for (const path of [link, "./codex"]) {
    const child = runNode(t, ["--input-type=module", "-e", script], options, "", { PI_WORKSPACE_CODEX_BIN: path });
    child.end();
    await child.finish();
    assert.deepEqual(child.methods(), []);
  }
});

test("Malformed data and server exit settle in-flight calls without leaking bytes", { timeout: 5_000 }, async (t) => {
  const options = setup(t);
  const script = `
    import assert from "node:assert/strict";
    import { CodexRPC } from ${JSON.stringify(transport)};
    for (const [method, code] of [
      ["fixture/malformed","codex_protocol_error"], ["fixture/disconnect","codex_unavailable"],
    ]) {
      const closed = [];
      const rpc = new CodexRPC({cwd:process.cwd(), onClose:error => closed.push(error)});
      try {
        await rpc.start();
        await assert.rejects(rpc.call(method), {code});
        assert.equal(closed.length, 1);
        assert.doesNotMatch(closed[0].message, /fixture-private/);
      } finally {
        await rpc.close();
      }
    }
  `;
  const child = runNode(t, ["--input-type=module", "-e", script], options, "");
  child.end();
  await child.finish();
});

for (const [mode, state, accountType] of [
  ["saved", "ready", "chatgpt"],
  ["local", "ready"],
  ["unsigned", "loginRequired"],
]) {
  test(`One-shot account status for ${mode}`, { timeout: 5_000 }, async (t) => {
    const child = runNode(t, [helper], setup(t), mode);
    child.send({ type: "status" });
    child.end();
    assert.deepEqual(await child.receive(), { type: "codexStatus", state, ...(accountType && { accountType }) });
    await child.finish();
    assert.deepEqual(child.methods(), ["initialize", "initialized", "account/read"]);
  });
}

test("One-shot status reports an unusable executable", { timeout: 5_000 }, async (t) => {
  const child = runNode(t, [helper], setup(t), "", { PI_WORKSPACE_CODEX_BIN: "./codex" });
  child.send({ type: "status" });
  child.end();
  assert.deepEqual(await child.receive(), { type: "codexStatus", state: "unavailable" });
  await child.finish();
});

for (const mode of ["saved", "local"]) {
  test(`Login reuses the ${mode} Codex configuration without starting OAuth`, { timeout: 5_000 }, async (t) => {
    const child = runNode(t, [helper], setup(t), mode);
    child.send({ type: "login", provider: "codex-app-server" });
    assert.deepEqual(await child.receive(), { type: "login", step: "complete" });
    await child.finish();
    assert.deepEqual(child.methods(), ["initialize", "initialized", "account/read"]);
  });
}

for (const [method, step, fields] of [
  ["browser", "browser", { url: "https://auth.openai.com/oauth/authorize?state=public-oauth-state" }],
  ["code", "device", { url: "https://auth.openai.com/codex/device", code: "ABC-DEF" }],
]) {
  test(`Login shows ${method} instructions and waits for the matching completion`, { timeout: 5_000 }, async (t) => {
    const child = runNode(t, [helper], setup(t), "unsigned");
    child.send({ type: "login", provider: "codex-app-server", method });
    assert.deepEqual(await child.receive(), { type: "login", step, ...fields });
    assert.deepEqual(await child.receive(), { type: "login", step: "complete" });
    await child.finish();
    assert.deepEqual(child.methods(), ["initialize", "initialized", "account/read", "account/login/start"]);
  });
}

for (const [mode, message] of [
  ["failure", "login_failed"],
  ["busy", "callback_unavailable"],
  ["invalidUrl", "login_failed"],
]) {
  test(`Login maps ${mode} to a safe error`, { timeout: 5_000 }, async (t) => {
    const child = runNode(t, [helper], setup(t), mode);
    child.send({ type: "login", provider: "codex-app-server" });
    if (mode === "failure") assert.equal((await child.receive()).step, "browser");
    assert.deepEqual(await child.receive(), { type: "login", step: "error", message });
    await child.finish();
  });
}

test("Login accepts completion emitted before the start reply", { timeout: 5_000 }, async (t) => {
  const child = runNode(t, [helper], setup(t), "early");
  child.send({ type: "login", provider: "codex-app-server" });
  assert.deepEqual(await child.receive(), { type: "login", step: "complete" });
  await child.finish();
});

test("Cancel asks Codex to cancel its sign-in before shutdown", { timeout: 5_000 }, async (t) => {
  const child = runNode(t, [helper], setup(t), "cancel");
  child.send({ type: "login", provider: "codex-app-server" });
  assert.equal((await child.receive()).step, "browser");
  child.send({ type: "cancel" });
  child.end();
  assert.deepEqual(await child.receive(), { type: "login", step: "error", message: "cancelled" });
  await child.finish();
  assert.equal(child.methods().at(-1), "account/login/cancel");
});
