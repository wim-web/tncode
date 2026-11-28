import assert from "node:assert/strict";
import { appendFileSync, writeFileSync } from "node:fs";
import { Server } from "node:net";
import { basename } from "node:path";
import { setTimeout } from "node:timers/promises";

export const codexModel = "gpt-5.6-luna";
export const authorizationCode = "fixture-authorization-code";
export const rejection = "fixture-private-token-response";
export const codexDeviceCode = "FCDE-X1234";
export const copilotDeviceCode = "FGHB-1234";
export const copilotDeviceToken = "fixture-private-device-token";
export const openaiClient = "fixture-openai-registration";

export function codexCredential() {
  // Match the saved-login upstream fixture so its first-message path accepts this sign-in.
  const accountId = "fixture-codex-account";
  const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: accountId } }));
  return {
    type: "oauth", accountId, access: "fixture." + payload.toString("base64") + ".fresh",
    refresh: "fixture-refresh-fresh", expires: Date.now() + 3_600_000,
  };
}

export function callbackURL(authorizationUrl) {
  const authorize = new URL(authorizationUrl);
  const callback = new URL(authorize.searchParams.get("redirect_uri"));
  callback.searchParams.set("state", authorize.searchParams.get("state"));
  callback.searchParams.set("code", authorizationCode);
  if (authorize.pathname === "/api/accounts/authorize") callback.searchParams.set("client_id", openaiClient);
  return callback;
}

function install() {
  let listener;
  const listen = Server.prototype.listen;
  Server.prototype.listen = function (port, host, ...args) {
    assert.equal(typeof port, "number");
    assert(["localhost", "127.0.0.1"].includes(host));
    listener = this;
    return listen.call(this, 0, "127.0.0.1", ...args);
  };
  const callbackFile = process.env.PI_WORKSPACE_LOGIN_FIXTURE_CALLBACK_FILE;
  if (callbackFile) {
    const write = process.stdout.write;
    process.stdout.write = function (chunk, ...args) {
      const event = JSON.parse(String(chunk));
      if (event.step === "browser" && listener?.address()) {
        const callback = callbackURL(event.url);
        callback.hostname = "127.0.0.1";
        callback.port = String(listener.address().port);
        writeFileSync(callbackFile, callback.href, { mode: 0o600 });
      }
      return write.call(this, chunk, ...args);
    };
  }

  const log = process.env.PI_WORKSPACE_OAUTH_FIXTURE_LOG;
  const record = (name) => { if (log) appendFileSync(log, name + "\n"); };
  globalThis.fetch = async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : input);
    switch (url.href) {
      case "https://auth.openai.com/api/accounts/deviceauth/usercode":
        return Response.json({ device_auth_id: copilotDeviceToken, user_code: codexDeviceCode, interval: 0 });
      case "https://auth.openai.com/api/accounts/deviceauth/token":
        assert.equal(JSON.parse(init.body).device_auth_id, copilotDeviceToken);
        return Response.json({ authorization_code: authorizationCode, code_verifier: "fixture-pkce" });
      case "https://auth.openai.com/oauth/token": {
        record("login-codex");
        assert.equal(init.method, "POST");
        assert.equal(init.body.get("grant_type"), "authorization_code");
        assert.equal(init.body.get("code"), authorizationCode);
        assert(init.body.get("code_verifier"));
        if (process.env.PI_WORKSPACE_LOGIN_FIXTURE_MODE === "reject") {
          return Response.json({ error: "invalid_grant", error_description: rejection }, { status: 401 });
        }
        if (process.env.PI_WORKSPACE_LOGIN_FIXTURE_MODE === "late-token") await setTimeout(1_000);
        const { access, refresh } = codexCredential();
        return Response.json({ access_token: access, refresh_token: refresh, expires_in: 3600 });
      }
      case "https://auth.openai.com/api/accounts/oauth/token":
        assert.equal(init.body.get("code"), authorizationCode);
        assert.equal(init.body.get("client_id"), openaiClient);
        return Response.json({
          access_token: "fixture-openai-access", refresh_token: "fixture-openai-refresh",
          id_token: "fixture-openai-id", expires_in: 3600, scope: "chatgpt.tokens.use.direct",
        });
      case "https://platform.claude.com/v1/oauth/token": {
        const body = JSON.parse(init.body);
        assert.equal(body.code, authorizationCode);
        assert.equal(body.state, body.code_verifier);
        return Response.json({ access_token: "fixture-claude-access", refresh_token: "fixture-claude-refresh", expires_in: 3600 });
      }
      case "https://github.com/login/device/code":
        return Response.json({
          device_code: copilotDeviceToken, user_code: copilotDeviceCode,
          verification_uri: "https://github.com/login/device", interval: 0, expires_in: 900,
        });
      case "https://github.com/login/oauth/access_token":
        assert.equal(init.body.get("device_code"), copilotDeviceToken);
        return Response.json({ access_token: "fixture-github-access" });
      case "https://api.github.com/copilot_internal/v2/token":
        assert.equal(new Headers(init.headers).get("authorization"), "Bearer fixture-github-access");
        return Response.json({ token: "fixture-copilot-access", expires_at: Date.now() / 1000 + 3600 });
      case "https://api.individual.githubcopilot.com/models":
        assert.equal(new Headers(init.headers).get("authorization"), "Bearer fixture-copilot-access");
        return Response.json({ data: [] });
      default:
        record("unexpected fetch");
        throw new Error("Unexpected fetch in login fixture");
    }
  };
}

if (process.argv[1] && basename(process.argv[1]) === "login.mjs") install();
