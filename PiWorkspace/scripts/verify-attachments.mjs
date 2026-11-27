import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { images, note } from "./fixtures/attachments.mjs";
import { withCommitWritingFixture } from "./fixtures/commit-writing.mjs";
import { withComposerModelFixture } from "./fixtures/composer-models.mjs";
import { withComposerShortcutFixture } from "./fixtures/composer-shortcuts.mjs";
import { withModelRoutingFixture } from "./fixtures/model-routing.mjs";
import { withSideChatFixture } from "./fixtures/side-chat.mjs";

const workspace = resolve(import.meta.dirname, "..");
const { values, positionals } = parseArgs({ options: { "release-suite": { type: "boolean" } }, allowPositionals: true });
assert(positionals.length <= 1, "Pass at most one app bundle.");
const app = positionals[0] && resolve(positionals[0], "Contents");
const sidecar = app ? join(app, "Resources/Sidecar") : join(workspace, "Sidecar");
const sdk = "node_modules/@earendil-works/pi-coding-agent";
const lock = JSON.parse(readFileSync(join(workspace, "Sidecar/package-lock.json"), "utf8"));
const installed = JSON.parse(readFileSync(join(sidecar, sdk, "package.json"), "utf8"));
assert.equal(installed.version, lock.packages[sdk].version);

const root = mkdtempSync(join(tmpdir(), "pi-attachments-"));
const requests = [];
const textFileRequests = [];
let fixtureError;
const server = createServer(async (request, response) => {
  try {
    assert.equal(request.url, "/v1/chat/completions");
    assert.equal(request.method, "POST");
    assert.equal(request.headers.authorization, "Bearer attachment-fixture-key");
    const body = await new Response(request).json();
    const message = body.messages.findLast(({ role }) => role === "user");
    const text = message.content.filter(({ type }) => type === "text").map(({ text }) => text).join("");
    const urls = message.content.filter(({ type }) => type === "image_url").map(({ image_url }) => image_url.url);
    if (body.model === "attachment-file-fixture") {
      textFileRequests.push(text);
      const first = '\uFEFF  First 日本語 👩🏽‍💻 e\u0301\r\nLast line\n\n';
      const second = 'Second file\r\n\n  Tail';
      assert.deepEqual(urls, []);
      assert.equal(text, textFileRequests.length === 1
        ? `Attached text file "same.txt":\n${first}\n\nAttached text file "same.txt":\n${second}`
        : `Second owner\n\nAttached text file "same.txt":\n${first}`);
    } else if (requests.length === 0) {
      assert.equal(body.model, "attachment-fixture");
      requests.push(message.content);
      assert.equal(text, `Attached text file "note.txt":\n${note}`);
      assert.deepEqual(urls, [images.blue, images.red].map((image) => `data:image/png;base64,${image}`));
    } else {
      assert.equal(body.model, "attachment-fixture");
      requests.push(message.content);
      const run = requests.length - 1;
      const largeText = "\uFEFF" + "  日本語 👩🏽‍💻 e\u0301\r\n".repeat(1300);
      assert.ok(Buffer.byteLength(largeText) >= 32 * 1024);
      assert.equal(text, `Large paste ${run}\n\nAttached text file "pasted-text.txt":\n${largeText}`);
      const png = readFileSync(join(root, `normalized-${run}.png`));
      assert.ok(png.length <= 4 * 1024 * 1024);
      assert.deepEqual(urls, [`data:image/png;base64,${png.toString("base64")}`]);
    }
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const [delta, reason] of [[{ role: "assistant", content: "Attachment fixture received." }, null], [{}, "stop"]]) {
      const chunk = {
        id: "attachment-fixture", object: "chat.completion.chunk", created: 1, model: body.model,
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

const node = app ? join(app, "Helpers/node") : process.execPath;
const worker = join(sidecar, "worker.mjs");

async function runSwiftTests(environment) {
  const tests = values["release-suite"] ? ["-c", "release"] : ["--filter", "ComposerAttachmentTests"];
  const run = spawn("swift", ["test", "--disable-sandbox", ...tests], {
    cwd: workspace,
    env: {
      ...process.env, ...environment,
      CLANG_MODULE_CACHE_PATH: join(workspace, ".build/local-clang-cache"),
      SWIFTPM_MODULECACHE_OVERRIDE: join(workspace, ".build/module-cache"),
      PI_WORKSPACE_QUESTION_NODE: node,
      PI_PALETTE_NODE: node,
      ...(app ? { PI_PROMPT_LINK_TEST_APP: resolve(app, "..") } : {}),
      PI_ATTACHMENT_TEST_ENDPOINT: `http://127.0.0.1:${server.address().port}/v1`,
      PI_ATTACHMENT_TEST_NODE: node,
      PI_ATTACHMENT_TEST_WORKER: worker,
      PI_ATTACHMENT_TEST_FIXTURES: root,
    },
    stdio: "inherit",
  });
  const [code, signal] = await once(run, "close");
  if (fixtureError) throw fixtureError;
  assert.equal(signal, null);
  assert.equal(code, 0);
}

async function runReleaseSuite(fixtures, environment = {}) {
  const [fixture, ...remaining] = fixtures;
  if (!fixture) return runSwiftTests(environment);
  return fixture(node, worker, additions => runReleaseSuite(remaining, { ...environment, ...additions }));
}

try {
  for (const [color, image] of Object.entries(images)) {
    mkdirSync(join(root, color));
    writeFileSync(join(root, color, "same.png"), Buffer.from(image, "base64"));
  }
  writeFileSync(join(root, "note.txt"), note);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  if (values["release-suite"]) {
    await runReleaseSuite([withComposerModelFixture, withComposerShortcutFixture, withModelRoutingFixture, withSideChatFixture, withCommitWritingFixture]);
  } else {
    await runSwiftTests({});
  }
  assert.equal(requests.length, 3);
  assert.equal(textFileRequests.length, 2);
  console.log(`PASS Pi SDK ${installed.version} sent exact PNG bytes and complete UTF-8 text across three turns.`);
  console.log("PASS reopened Pi text attachments with matching names preserved preview text and exported bytes by owner.");
} finally {
  server.close();
  rmSync(root, { recursive: true, force: true });
}
