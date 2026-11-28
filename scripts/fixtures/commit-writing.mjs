import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

const inheritedKey = "private-inherited-writer-fixture-key";
const overrideKey = "private-override-writer-fixture-key";
const responses = [
  { subject: "  Describe the selected change...\nIgnore this line", body: "" },
  { subject: "  Document the selected change. ", body: " \n- First detail\n- Second detail\n " },
  { status: 403 },
  { subject: "Broken response", body: 1 },
  { hold: true },
  { subject: "fix(git): Preserve the excluded staging.", body: "" },
  { subject: "Describe the selected change " + "🌱".repeat(30) + ".", body: "" },
];

export async function withCommitWritingFixture(node, worker, run, evidenceRoot) {
  const root = evidenceRoot ?? realpathSync(mkdtempSync(join(tmpdir(), "pi-commit-writing-")));
  let requestCount = 0;
  const server = createServer(async (request, response) => {
    const expectedKey = request.url === "/inherited/v1/chat/completions" ? inheritedKey :
      request.url === "/override/v1/chat/completions" ? overrideKey : undefined;
    if (!expectedKey || request.method !== "POST" || request.headers.authorization !== "Bearer " + expectedKey) {
      response.writeHead(401).end();
      return;
    }
    const body = await new Response(request).json();
    const index = requestCount++;
    const reply = responses[index];
    writeFileSync(join(root, "request-" + index), JSON.stringify({ route: request.url, ...body }, null, 2));
    response.once("close", () => writeFileSync(join(root, "closed-" + index), ""));
    if (reply?.hold) return;
    if (!reply || reply.status) {
      response.writeHead(reply?.status ?? 500, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ error: { message: "fixture denied the writer" } }));
      return;
    }
    const chunk = (delta, finish_reason) => "data: " + JSON.stringify({
      id: "fixture", object: "chat.completion.chunk", created: 1, model: body.model,
      choices: [{ index: 0, delta, finish_reason }],
    }) + "\n\n";
    const content = index === 0 ? "```json\n" + JSON.stringify(reply) + "\n```" : JSON.stringify(reply);
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    response.end(chunk({ role: "assistant", content }, null) + chunk({}, "stop") + "data: [DONE]\n\n");
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    await run({
      PI_COMMIT_WRITING_ROOT: root,
      PI_COMMIT_WRITING_ORIGIN: "http://127.0.0.1:" + server.address().port,
      PI_COMMIT_WRITING_NODE: node,
      PI_COMMIT_WRITING_WORKER: worker,
    });
    assert.equal(requestCount, responses.length);
    console.log("Verified seven explicit writer requests, commit subjects and bodies, and a manual commit with no model request.");
  } finally {
    server.closeAllConnections();
    server.close();
    if (!evidenceRoot) rmSync(root, { recursive: true, force: true });
  }
}
