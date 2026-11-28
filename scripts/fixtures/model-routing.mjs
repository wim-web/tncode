import assert from "node:assert/strict";
import { once } from "node:events";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

export async function withModelRoutingFixture(node, worker, runTests) {
  const root = mkdtempSync(resolve(tmpdir(), "pi-routing-"));
  const release = resolve(root, "release-ordinary-turn");
  const expected = [
    ["route-a", "owner-history-marker", "owner-history-marker"],
    ["route-a", "compaction-marker", "owner-history-marker"],
    ["route-b", "skip-selected-marker", "owner-history-marker"],
    ["route-b", "queue-head-marker", "owner-history-marker"],
    ["route-a", "normal-active-marker", "normal-active-marker"],
    ["route-b", "normal-queued-marker", "normal-active-marker"],
  ];
  const inherited = [
    ["route-a", "inherited-first-marker", "inherited-first-marker"],
    ["route-b", "inherited-model-marker", "inherited-first-marker"],
    ["route-b", "inherited-resumed-marker", "inherited-first-marker"],
    ["route-b", "inherited-side-marker", "inherited-first-marker"],
  ];
  const promptLink = [["route-b", "prompt-link-marker", "prompt-link-marker"]];
  const markers = new Set([...expected, ...inherited, ...promptLink].map(([, marker]) => marker));
  const routes = [];
  const sideQuestion = "You are in a side chat beside the main thread. Answer the user's question without continuing the main thread's task.\n\ninherited-side-marker";
  let sideHistory;
  let selectedMarkerOnA = 0;
  let foreignRequests = 0;
  const foreign = createServer((request, response) => {
    foreignRequests++;
    response.writeHead(403).end();
  });
  const owner = createServer(async (request, response) => {
    const body = await new Response(request).json();
    const users = body.messages.filter(({ role }) => role === "user").map(({ content }) =>
      typeof content === "string" ? content : content.map(({ text }) => text).join(""));
    const latest = users.at(-1);
    const marker = latest === sideQuestion ? "inherited-side-marker" : latest?.split("\n")[0];
    if (latest === sideQuestion) sideHistory = users;
    if (body.model === "route-a" && JSON.stringify(body.messages).includes("skip-selected-marker")) selectedMarkerOnA++;
    if (!markers.has(marker)) {
      // Pi waits for this summary until the test selects the row and aborts compaction.
      return;
    }
    if (marker === "prompt-link-marker") assert.equal(request.headers.authorization, "Bearer routing-fixture-key");
    routes.push([body.model, marker, users[0]]);
    if (marker === "normal-active-marker") {
      while (!response.destroyed && !existsSync(release)) await delay(20);
      if (response.destroyed) return;
    }
    const usage = { prompt_tokens: marker === "compaction-marker" ? 55_000 : 100, completion_tokens: 5 };
    usage.total_tokens = usage.prompt_tokens + usage.completion_tokens;
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const [delta, finish_reason] of [[{ role: "assistant", content: "Fixture reply" }, null], [{}, "stop"]]) {
      response.write(`data: ${JSON.stringify({
        id: "fixture", object: "chat.completion.chunk", created: 1, model: body.model,
        choices: [{ index: 0, delta, finish_reason }], usage,
      })}\n\n`);
    }
    response.end("data: [DONE]\n\n");
  });

  async function listen(server) {
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    return `http://127.0.0.1:${server.address().port}/v1`;
  }

  try {
    await runTests({
      PI_ROUTING_OWNER: await listen(owner), PI_ROUTING_OTHER: await listen(foreign),
      PI_ROUTING_RELEASE: release, PI_ROUTING_WORKER: worker, PI_ROUTING_NODE: node,
    });
    assert.equal(foreignRequests, 0);
    assert.equal(selectedMarkerOnA, 0);
    assert.deepEqual(sideHistory, ["inherited-first-marker", "inherited-model-marker", "inherited-resumed-marker", sideQuestion]);
    for (const sequence of [expected, inherited, promptLink]) {
      assert.deepEqual(routes.filter(([, marker]) => sequence.some(([, text]) => text === marker)), sequence);
    }
    console.log("Verified eleven requests across queue delivery, settings reset, relaunch, side chat and prompt links. Zero foreign requests.");
  } finally {
    for (const server of [owner, foreign]) {
      server.closeAllConnections();
      if (server.listening) await new Promise(resolve => server.close(resolve));
    }
    rmSync(root, { recursive: true, force: true });
  }
}
