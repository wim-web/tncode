import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { setTimeout as delay } from "node:timers/promises";
import { createServer } from "node:http";
import { resolve } from "node:path";

const workspace = resolve(import.meta.dirname, "..");
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
const routes = [];
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
  const marker = users.at(-1)?.split("\n")[0];
  if (body.model === "route-a" && JSON.stringify(body.messages).includes("skip-selected-marker")) selectedMarkerOnA++;
  if (!expected.some(([, text]) => text === marker)) {
    // Pi waits for this summary until the test selects the row and aborts compaction.
    return;
  }
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
  const child = spawn("swift", ["test", "--disable-sandbox", "--filter", "ModelRoutingWireTests", ...process.argv.slice(2)], {
    cwd: workspace, stdio: "inherit",
    env: {
      ...process.env, PI_ROUTING_OWNER: await listen(owner), PI_ROUTING_OTHER: await listen(foreign),
      PI_ROUTING_RELEASE: release, PI_ROUTING_WORKER: resolve(workspace, "Sidecar/worker.mjs"), PI_ROUTING_NODE: process.execPath,
    },
  });
  const [status] = await once(child, "close");
  console.log("Provider routes", routes, "foreign requests", foreignRequests, "selected marker on A", selectedMarkerOnA);
  assert.equal(status, 0);
  assert.equal(foreignRequests, 0);
  assert.equal(selectedMarkerOnA, 0);
  assert.deepEqual(routes, expected);
} finally {
  for (const server of [owner, foreign]) {
    server.closeAllConnections();
    server.close();
  }
  rmSync(root, { recursive: true, force: true });
}
