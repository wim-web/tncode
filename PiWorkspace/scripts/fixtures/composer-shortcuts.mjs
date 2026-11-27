import assert from "node:assert/strict";
import { once } from "node:events";
import { appendFileSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

export async function withComposerShortcutFixture(node, worker, verify) {
  const key = "composer-shortcut-fixture-key";
  const root = mkdtempSync(join(tmpdir(), "pi-composer-shortcuts-"));
  let failure;
  let requestCount = 0;
  const server = createServer(async (request, response) => {
    try {
      assert.equal(request.method, "POST");
      assert.equal(request.url, "/v1/chat/completions");
      assert.equal(request.headers.authorization, "Bearer " + key);
      const { model, messages } = await new Response(request).json();
      assert.equal(model, "composer-shortcut-fixture");
      const messagesOnWire = messages.filter(({ role }) => role === "user").map(({ content }) =>
        typeof content === "string" ? content : content.map(({ text }) => text).join(""));
      appendFileSync(join(root, "requests.jsonl"), JSON.stringify(messagesOnWire) + "\n");

      const id = "fixture-" + ++requestCount;
      const chunk = (delta, finish_reason = null) => "data: " + JSON.stringify({
        id, object: "chat.completion.chunk", created: 1, model,
        choices: [{ index: 0, delta, finish_reason }],
      }) + "\n\n";
      const gate = requestCount === 1 ? "release"
        : messagesOnWire.at(-1) === "Reopened with command send\nsecond line" ? "release-reopened" : null;
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.write(chunk({ role: "assistant", content: gate ? "Held composer turn." : "Fixture reply." }));
      if (gate) {
        while (!response.destroyed && !existsSync(join(root, gate))) await delay(20);
      }
      if (!response.destroyed) response.end(chunk({}, "stop") + "data: [DONE]\n\n");
    } catch (error) {
      failure = error;
      response.destroy();
    }
  });

  try {
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    await verify({
      PI_COMPOSER_SHORTCUT_ROOT: root,
      PI_COMPOSER_SHORTCUT_ENDPOINT: "http://127.0.0.1:" + server.address().port + "/v1",
      PI_COMPOSER_SHORTCUT_NODE: node,
      PI_COMPOSER_SHORTCUT_WORKER: worker,
      PI_COMPOSER_SHORTCUT_KEY: key,
    });
    if (failure) throw failure;
    assert(requestCount > 1, "Pi replay must send and drain the held queue");
    console.log("Verified configured send and follow-up shortcuts against the held Pi turn and saved queue.");
  } finally {
    server.closeAllConnections();
    if (server.listening) await new Promise(resolve => server.close(resolve));
    rmSync(root, { recursive: true, force: true });
  }
}
