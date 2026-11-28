import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const first = { prompt: "Codex fixture first prompt", answer: "Codex fixture first reply." };
export const stopped = { prompt: "Codex fixture stop prompt", answer: "Codex fixture interrupted reply." };
export const resumed = { prompt: "Codex fixture resumed prompt", answer: "Codex fixture resumed reply." };
export const toolTurn = { prompt: "Ask the inert MCP fixture for confirmation.", answer: "Fixture completed." };
export const searchQuery = "pi-codex-fixture-web-search";
export const mcpNamespace = "mcp__cua_repl";
export const mcpToolName = "js";
export const model = "pi-codex-fixture-model";
export const loopbackSandbox = '(version 1) (allow default) (deny network*) (allow network-outbound (remote ip "localhost:*")) (allow network-bind network-inbound (local ip "localhost:*"))';

function reply(response, answer, { search, hold, callTool }) {
  const id = randomUUID();
  const content = { type: "output_text", text: answer, annotations: [] };
  const message = { type: "message", id: `msg_${id}`, role: "assistant", content: [content], status: "completed" };
  const responseInfo = { id: `resp_${id}`, object: "response", model };
  const webSearch = {
    type: "web_search_call", id: `ws_${id}`, status: "completed", action: { type: "search", query: searchQuery },
  };
  let sequence_number = 0;
  const emit = (type, data) => {
    response.write(`event: ${type}\ndata: ${JSON.stringify({ type, sequence_number: sequence_number++, ...data })}\n\n`);
  };

  response.writeHead(200, { "Content-Type": "text/event-stream" });
  emit("response.created", { response: { ...responseInfo, status: "in_progress", output: [] } });
  if (callTool) {
    const call = { type: "function_call", id: `fc_${id}`, call_id: `call_${id}`,
      namespace: mcpNamespace, name: mcpToolName, arguments: JSON.stringify({ code: "fixture-noop" }), status: "completed" };
    emit("response.output_item.added", { output_index: 0, item: { ...call, status: "in_progress", arguments: "" } });
    emit("response.output_item.done", { output_index: 0, item: call });
    emit("response.completed", { response: { ...responseInfo, status: "completed", output: [call],
      usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 } } });
    response.end();
    return;
  }
  if (search) {
    emit("response.output_item.added", { output_index: 0, item: { ...webSearch, status: "in_progress" } });
    emit("response.output_item.done", { output_index: 0, item: webSearch });
  }
  const location = { item_id: message.id, output_index: search ? 1 : 0, content_index: 0 };
  emit("response.output_item.added", { output_index: location.output_index, item: { ...message, status: "in_progress", content: [] } });
  emit("response.content_part.added", { ...location, part: { ...content, text: "" } });
  emit("response.output_text.delta", { ...location, delta: answer });
  if (hold) return;

  emit("response.output_text.done", { ...location, text: answer });
  emit("response.content_part.done", { ...location, part: content });
  emit("response.output_item.done", { output_index: location.output_index, item: message });
  emit("response.completed", { response: {
    ...responseInfo,
    status: "completed",
    output: search ? [webSearch, message] : [message],
    usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 },
  } });
  response.end();
}

export async function withCodexAgentFixture(codexBinary, run) {
  const root = mkdtempSync(join(tmpdir(), "pi-codex-agent-"));
  const cwd = join(root, "work");
  const codexHome = join(root, "codex");
  const agentDir = join(root, "pi");
  const sessionDir = join(root, "session");
  const requests = [];
  const mcpLog = join(root, "mcp.log");
  const key = "codex-fixture-key";
  let failure;
  const server = createServer(async (request, response) => {
    try {
      assert.equal(request.method, "POST");
      assert.equal(request.url, "/v1/responses");
      assert.equal(request.headers.authorization, `Bearer ${key}`);
      const body = await new Response(request).json();
      assert.equal(body.model, model);
      assert.equal(body.stream, true);
      const prompt = body.input.findLast(({ role }) => role === "user")?.content.map(({ text }) => text).join("");
      const match = [first, stopped, resumed, toolTurn].find(turn => turn.prompt === prompt);
      assert(match, `Unexpected latest user prompt ${JSON.stringify(prompt)}`);
      const closed = new Promise(resolve => response.once("close", () => resolve(!response.writableEnded)));
      const capture = { body, prompt, closed };
      requests.push(capture);
      reply(response, match.answer, { search: match === first, hold: match === stopped,
        callTool: match === toolTurn && requests.filter(item => item.prompt === prompt).length === 1 });
    } catch (error) {
      failure ??= error;
      response.writeHead(400, { "Content-Type": "application/json" }).end(JSON.stringify({ error: { message: error.message } }));
    }
  });

  try {
    for (const dir of [cwd, codexHome, agentDir, sessionDir]) mkdirSync(dir, { mode: 0o700 });
    writeFileSync(mcpLog, "", { mode: 0o600 });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const endpoint = `http://127.0.0.1:${server.address().port}/v1`;
    const mcp = fileURLToPath(new URL("./codex-agent-mcp.mjs", import.meta.url));
    writeFileSync(join(codexHome, "config.toml"), `model = ${JSON.stringify(model)}
model_provider = "fixture"
web_search = "live"
cli_auth_credentials_store = "file"
check_for_update_on_startup = false

[analytics]
enabled = false

[feedback]
enabled = false

[features]
apps = false
plugins = false

[model_providers.fixture]
name = "Loopback Responses fixture"
base_url = ${JSON.stringify(endpoint)}
wire_api = "responses"
env_key = "PI_CODEX_FIXTURE_KEY"
request_max_retries = 0
stream_max_retries = 0

[mcp_servers.cua_repl]
command = ${JSON.stringify(process.execPath)}
args = ${JSON.stringify([mcp, mcpLog])}
enabled_tools = ["js"]
required = true
`, { mode: 0o600 });

    const result = await run({
      cwd, sessionDir, mcpLog, requests,
      environment: {
        HOME: root,
        TMPDIR: root,
        PATH: `${dirname(process.execPath)}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`,
        CODEX_HOME: codexHome,
        PI_WORKSPACE_CODEX_BIN: codexBinary,
        PI_CODING_AGENT_DIR: agentDir,
        PI_OFFLINE: "1",
        PI_TELEMETRY: "0",
        PI_CODEX_FIXTURE_KEY: key,
      },
    });
    if (failure) throw failure;
    return result;
  } catch (error) {
    throw failure ?? error;
  } finally {
    server.closeAllConnections();
    if (server.listening) await new Promise(resolve => server.close(resolve));
    rmSync(root, { recursive: true, force: true });
  }
}
