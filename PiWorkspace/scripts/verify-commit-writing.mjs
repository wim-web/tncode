import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";

const workspace = join(import.meta.dirname, "..");
const sidecar = join(workspace, "Sidecar");
const sdk = "node_modules/@earendil-works/pi-coding-agent";
const modules = resolve(process.env.PI_TEST_NODE_MODULES ?? join(sidecar, "node_modules"));
const lock = JSON.parse(readFileSync(join(sidecar, "package-lock.json"), "utf8"));
const pi = JSON.parse(readFileSync(join(modules, "@earendil-works/pi-coding-agent/package.json"), "utf8"));
assert.equal(pi.version, lock.packages[sdk].version);

const root = realpathSync(mkdtempSync("/private/tmp/pi-commit-writing-"));
const worker = join(root, "sidecar", "worker.mjs");
mkdirSync(join(root, "sidecar"));
for (const path of ["worker.mjs", "agent-questions.mjs", "tool-approval.mjs"]) {
  copyFileSync(join(sidecar, path), join(root, "sidecar", path));
}
symlinkSync(modules, join(root, "sidecar", "node_modules"));
console.log(`Pi ${pi.version} evidence in ${root}`);

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
  const run = spawn("swift", ["test", "--disable-sandbox", "--filter", "CommitWritingTests", ...process.argv.slice(2)], {
    cwd: workspace,
    env: {
      ...Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_"))),
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
      PI_COMMIT_WRITING_ROOT: root,
      PI_COMMIT_WRITING_ORIGIN: "http://127.0.0.1:" + server.address().port,
      PI_COMMIT_WRITING_NODE: process.execPath,
      PI_COMMIT_WRITING_WORKER: worker,
    },
    stdio: "inherit",
  });
  const [exitCode, signal] = await once(run, "close");
  assert.equal(signal, null);
  assert.equal(exitCode, 0);
  assert.equal(requestCount, responses.length);
} finally {
  server.closeAllConnections();
  server.close();
}
