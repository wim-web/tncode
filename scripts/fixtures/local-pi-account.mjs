import { randomBytes } from "node:crypto";
import { once } from "node:events";
import { createServer } from "node:http";

export async function localAccount(model, beforeReply) {
  const key = randomBytes(32).toString("hex");
  const turns = [];
  const server = createServer(async (request, response) => {
    if (request.method !== "POST" || request.url !== "/v1/chat/completions" ||
        request.headers.authorization !== "Bearer " + key) {
      response.writeHead(401).end();
      return;
    }
    let body;
    try { body = await new Response(request).json(); } catch { response.writeHead(400).end(); return; }
    if (!Array.isArray(body.messages)) { response.writeHead(400).end(); return; }
    const prompts = body.messages.filter(m => m.role === "user").map(m =>
      typeof m.content === "string" ? m.content : m.content.map(part => part.text).join(""));
    const number = turns.push({ model: body.model, prompts });
    if (beforeReply) await beforeReply(number);
    if (response.destroyed) return;
    const reply = "Reply from " + model + " turn " + number;
    const chunk = (delta, reason) => "data: " + JSON.stringify({ id: "account-fixture-" + number,
      object: "chat.completion.chunk", created: 1, model,
      choices: [{ index: 0, delta, finish_reason: reason }] }) + "\n\n";
    response.writeHead(200, { "Content-Type": "text/event-stream" }).end(
      chunk({ role: "assistant", content: reply }, null) + chunk({}, "stop") + "data: [DONE]\n\n");
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return { server, key, turns, settings: { provider: "local", model, contextWindow: 8192,
    endpoint: "http://127.0.0.1:" + server.address().port + "/v1" } };
}
