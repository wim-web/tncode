import assert from "node:assert/strict";
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

assert.deepEqual(process.argv.slice(2), ["app-server", "--listen", "stdio://"]);
const mode = process.env.TEST_CODEX_MODE;
const id = "fixture-login-id";
const privateValue = "fixture-private-credential";
const log = process.env.TEST_CODEX_LOG;
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
const notify = (method, params) => send({ method, params });
const complete = (loginId, success) => notify("account/login/completed", { loginId, success, error: privateValue });
let initialized = false;
let testRequest;
let replies = [];

function send(value) {
  process.stdout.write(JSON.stringify(value) + "\n");
}

input.on("line", (line) => {
  const message = JSON.parse(line);
  const reply = (result) => send({ id: message.id, result });
  if (message.method && log) appendFileSync(log, message.method + "\n");
  switch (message.method) {
    case "initialize":
      assert.equal(message.params.capabilities.experimentalApi, true);
      assert.equal(message.params.clientInfo.name, "tncode");
      assert(!initialized);
      process.stderr.write(privateValue);
      return reply({});
    case "initialized":
      initialized = true;
      assert.equal(message.id, undefined);
      return;
    case undefined:
      replies.push(message);
      if (replies.length === 3) send({ id: testRequest, result: replies });
      return;
  }

  assert(initialized);
  switch (message.method) {
    case "fixture/inspect":
      return reply({
        cwd: process.cwd(), codexHome: process.env.CODEX_HOME, path: process.env.PATH, pid: process.pid,
      });
    case "fixture/roundTrip":
      testRequest = message.id;
      replies = [];
      notify("fixture/notification", { value: "☃" });
      send({ id: 1, method: "fixture/supported", params: { answer: 42 } });
      send({ id: "unknown", method: "fixture/unknown" });
      send({ id: "failed", method: "fixture/failing" });
      send({ id: "resolved", method: "fixture/supported" });
      return notify("serverRequest/resolved", { requestId: "resolved" });
    case "fixture/error":
      return send({ id: message.id, error: { code: -32000, message: privateValue, data: privateValue } });
    case "fixture/hang":
      return;
    case "fixture/malformed":
      return process.stdout.write("invalid " + privateValue + "\n");
    case "fixture/disconnect":
      return process.exit(2);
    case "account/read":
      assert.deepEqual(message.params, { refreshToken: false });
      return reply({
        account: mode === "saved" ? { type: "chatgpt", email: "private@example.test", token: privateValue } : null,
        requiresOpenaiAuth: mode !== "local",
      });
    case "account/login/start": {
      if (mode === "busy") {
        return send({ id: message.id, error: { code: -32603, message: "Address already in use " + privateValue } });
      }
      if (mode === "early") complete(id, true);
      const type = message.params.type;
      assert(["chatgpt", "chatgptDeviceCode"].includes(type));
      const browser = {
        authUrl: mode === "invalidUrl" ? `https://auth.openai.com/?access_token=${privateValue}`
          : "https://auth.openai.com/oauth/authorize?state=public-oauth-state",
      };
      const device = { verificationUrl: "https://auth.openai.com/codex/device", userCode: "ABC-DEF" };
      const result = { type, loginId: id, ...(type === "chatgpt" ? browser : device), token: privateValue };
      reply(result);
      complete("different-login-id", true);
      if (mode !== "cancel") setTimeout(() => complete(id, mode !== "failure"), 100);
      return;
    }
    case "account/login/cancel":
      assert.deepEqual(message.params, { loginId: id });
      return reply({ status: "canceled" });
    default:
      assert.fail("Unexpected fixture request");
  }
});
