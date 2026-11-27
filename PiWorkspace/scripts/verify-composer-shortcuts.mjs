import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { appendFileSync, existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const workspace = join(import.meta.dirname, "..");
const sidecar = join(workspace, "Sidecar");
const sdk = "node_modules/@earendil-works/pi-coding-agent";
const readJSON = path => JSON.parse(readFileSync(path, "utf8"));
assert.equal(readJSON(join(sidecar, sdk, "package.json")).version,
             readJSON(join(sidecar, "package-lock.json")).packages[sdk].version);

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
  const run = spawn("swift", ["test", "--disable-sandbox", "--filter", "ComposerShortcutTests", ...process.argv.slice(2)], {
    cwd: workspace,
    env: {
      ...process.env,
      CLANG_MODULE_CACHE_PATH: process.env.CLANG_MODULE_CACHE_PATH ?? join(workspace, ".build/local-clang-cache"),
      SWIFTPM_MODULECACHE_OVERRIDE: process.env.SWIFTPM_MODULECACHE_OVERRIDE ?? join(workspace, ".build/module-cache"),
      PI_COMPOSER_SHORTCUT_ROOT: root,
      PI_COMPOSER_SHORTCUT_ENDPOINT: "http://127.0.0.1:" + server.address().port + "/v1",
      PI_COMPOSER_SHORTCUT_NODE: process.execPath,
      PI_COMPOSER_SHORTCUT_WORKER: join(sidecar, "worker.mjs"),
      PI_COMPOSER_SHORTCUT_KEY: key,
    },
    stdio: "inherit",
  });
  const [exitCode, signal] = await once(run, "close");
  if (failure) throw failure;
  assert.equal(signal, null);
  assert.equal(exitCode, 0);
  assert(requestCount > 1, "Pi replay must send and drain the held queue");
} finally {
  server.closeAllConnections();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  rmSync(root, { recursive: true, force: true });
}
