import assert from "node:assert/strict";
import { appendFileSync } from "node:fs";
import { basename } from "node:path";
import { zstdDecompressSync } from "node:zlib";

export const codexModel = "gpt-5.6-luna";
export const replyText = "Saved Pi login reply.";
export const commitSubject = "fix: use saved pi login";
export const ambientKey = "fixture-ambient-api-key";
export const otherLoginRoutes = [
  { provider: "openai", model: "gpt-6.2-sol", endpoint: "https://api.openai.com/v1/responses", access: "fixture-chatgpt-login" },
  { provider: "anthropic", model: "claude-opus-5-5", endpoint: "https://api.anthropic.com/v1/messages", access: "sk-ant-oat-fixture" },
  { provider: "github-copilot", model: "gpt-6.1-sol", endpoint: "https://api.individual.githubcopilot.com/responses", access: "fixture-copilot-login" },
];

export function codexCredential({ accountId = "fixture-codex-account", state = "fresh" } = {}) {
  const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: accountId } }));
  return {
    type: "oauth",
    accountId,
    access: "fixture." + payload.toString("base64") + "." + state,
    refresh: "fixture-refresh-" + state,
    expires: Date.now() + (["fresh", "rotated"].includes(state) ? 3_600_000 : -60_000),
  };
}

function responses(text) {
  const item = { type: "message", role: "assistant", id: "msg_fixture", content: [] };
  const events = [
    { type: "response.output_item.added", output_index: 0, item },
    { type: "response.output_text.delta", output_index: 0, delta: text },
    {
      type: "response.output_item.done", output_index: 0,
      item: { ...item, content: [{ type: "output_text", text }] },
    },
    { type: "response.completed", response: { id: "resp_fixture", status: "completed", output: [] } },
  ];
  return new Response(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join(""), {
    headers: { "content-type": "text/event-stream" },
  });
}

function anthropicReply() {
  const events = [
    { type: "message_start", message: { type: "message", id: "msg_fixture", role: "assistant", content: [],
      model: "claude-opus-5-5", usage: { input_tokens: 1, output_tokens: 0 } } },
    { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: replyText } },
    { type: "content_block_stop", index: 0 },
    { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 3 } },
    { type: "message_stop" },
  ];
  return new Response(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(""), {
    headers: { "content-type": "text/event-stream" },
  });
}

function install() {
  globalThis.WebSocket = undefined;
  const log = process.env.TNCODE_OAUTH_FIXTURE_LOG;
  function record(name) {
    if (log) appendFileSync(log, name + "\n");
  }
  globalThis.fetch = async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : input);
    const headers = new Headers(init?.headers);
    const route = otherLoginRoutes.find(entry => entry.endpoint === url.origin + url.pathname);
    if (route) {
      assert.equal(headers.get("authorization"), "Bearer " + route.access);
      const body = JSON.parse(headers.get("content-encoding") === "zstd" ? zstdDecompressSync(init.body) : init.body);
      assert.equal(body.model, route.model);
      record(route.provider);
      return route.provider === "anthropic" ? anthropicReply() : responses(replyText);
    }
    if (url.href === "https://auth.openai.com/oauth/token") {
      record("refresh");
      const token = new URLSearchParams(init.body).get("refresh_token");
      if (token === codexCredential({ state: "revoked" }).refresh) {
        return Response.json({ error: "invalid_grant", error_description: token }, { status: 401 });
      }
      const switched = token === codexCredential({ state: "switched" }).refresh;
      const rotated = codexCredential({ state: "rotated", accountId: switched ? "different-account" : undefined });
      if (token === codexCredential({ state: "malformed" }).refresh) {
        return Response.json({ access_token: rotated.access });
      }
      assert(switched || token === codexCredential({ state: "expired" }).refresh, "Unexpected refresh credential");
      return Response.json({ access_token: rotated.access, refresh_token: rotated.refresh, expires_in: 3600 });
    }
    if (url.href === "https://chatgpt.com/backend-api/codex/responses") {
      record("codex");
      const auth = headers.get("authorization");
      assert([codexCredential(), codexCredential({ state: "rotated" })]
        .some(({ access }) => auth === "Bearer " + access), "Unexpected saved login bearer");
      assert.equal(headers.get("chatgpt-account-id"), codexCredential().accountId);
      const body = JSON.parse(headers.get("content-encoding") === "zstd" ? zstdDecompressSync(init.body) : init.body);
      assert.equal(body.model, process.env.TNCODE_OAUTH_FIXTURE_MODEL ?? codexModel);
      const user = body.input.findLast(({ role }) => role === "user");
      assert(user, "Expected a user message");
      if (JSON.stringify(body).includes("You write concise git commit messages.")) {
        return responses(JSON.stringify({ subject: commitSubject, body: "" }));
      }
      if (user.content.some(({ text }) => text === "Reject my login")) {
        return Response.json({ error: { message: "Token revoked: " + auth } }, { status: 401 });
      }
      return responses(replyText);
    }
    record("unexpected fetch");
    throw new Error("Unexpected fetch in the saved Pi login fixture.");
  };
}

if (process.argv[1] && basename(process.argv[1]) === "worker.mjs") install();
