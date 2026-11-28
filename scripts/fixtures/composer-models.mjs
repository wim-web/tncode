import assert from "node:assert/strict";
import { once } from "node:events";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

export async function withComposerModelFixture(node, worker, runTests) {
  const root = mkdtempSync(join(tmpdir(), "pi-composer-models-"));
  const expected = [
    ["fixture-alpha", "First selected draft"],
    ["fixture-beta", "Queued next turn"],
    ["fixture-alpha", "Switch back after the queue"],
  ];
  const requests = [];
  let fixtureError;
  const server = createServer(async (request, response) => {
    try {
      assert.equal(request.method, "POST");
      assert.equal(request.url, "/v1/chat/completions");
      assert.equal(request.headers.authorization, "Bearer composer-model-fixture-key");
      const body = await new Response(request).json();
      const turns = body.messages.filter(({ role }) => role === "user").map(({ content }) =>
        typeof content === "string" ? content : content.map(({ text }) => text).join(""));
      const index = requests.length;
      assert.deepEqual([body.model, turns.at(-1)], expected[index]);
      assert.deepEqual(turns, expected.slice(0, index + 1).map(([, text]) => text));
      requests.push(body.model);
      writeFileSync(join(root, `request-${index}`), body.model);
      if (index === 0) {
        while (!response.destroyed && !existsSync(join(root, "release-first"))) await delay(20);
        if (response.destroyed) return;
      }
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      for (const [delta, reason] of [[{ role: "assistant", content: `Reply from ${body.model}.` }, null], [{}, "stop"]]) {
        const chunk = {
          id: `fixture-${index}`, object: "chat.completion.chunk", created: 1, model: body.model,
          choices: [{ index: 0, delta, finish_reason: reason }],
        };
        response.write(`data: ${JSON.stringify(chunk)}\n\n`);
      }
      response.end("data: [DONE]\n\n");
    } catch (error) {
      fixtureError = error;
      response.destroy();
    }
  });

  try {
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    await runTests({
      PI_MODEL_PICKER_TEST_ROOT: root,
      PI_MODEL_PICKER_TEST_ENDPOINT: "http://127.0.0.1:" + server.address().port + "/v1",
      PI_MODEL_PICKER_TEST_NODE: node,
      PI_MODEL_PICKER_TEST_WORKER: worker,
    });
    if (fixtureError) throw fixtureError;
    assert.deepEqual(requests, expected.map(([model]) => model));
    console.log("Verified wire models " + requests.join(" → "));
  } finally {
    server.closeAllConnections();
    if (server.listening) await new Promise(resolve => server.close(resolve));
    rmSync(root, { recursive: true, force: true });
  }
}
