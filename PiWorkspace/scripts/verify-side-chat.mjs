import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const workspace = join(import.meta.dirname, "..");
const app = resolve(process.argv[2] ?? join(workspace, "dist", "Pi Workspace.app"));
const sidecar = join(app, "Contents", "Resources", "Sidecar");
const node = join(app, "Contents", "Helpers", "node");
const installed = JSON.parse(readFileSync(join(sidecar, "node_modules/@earendil-works/pi-coding-agent/package.json")));
assert.equal(installed.version, "1.6.1");

const root = mkdtempSync(join(tmpdir(), "pi-side-chat-"));
const project = join(root, "project");
const checkout = join(root, "checkout");
const requests = [];
let fixtureError;
const server = createServer(async (request, response) => {
  try {
    assert.equal(request.method, "POST");
    assert.equal(request.url, "/v1/chat/completions");
    assert.equal(request.headers.authorization, "Bearer side-chat-fixture-key");
    const { model, messages } = await new Response(request).json();
    const turns = messages.filter(({ role }) => role === "user" || role === "assistant").map(({ role, content }) =>
      [role, typeof content === "string" ? content : content.map(part => part.text ?? "").join("")]);
    const index = requests.length;
    requests.push({ model, turns });
    writeFileSync(join(root, `request-${index}`), JSON.stringify({ model, turns }));
    if (index === 2) {
      while (!response.destroyed && !existsSync(join(root, "release-parent"))) await delay(15);
      if (response.destroyed) return;
    }
    if (index === 5) {
      response.writeHead(400, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ error: { message: "Fixture rejected the side turn.", type: "invalid_request_error" } }));
      return;
    }
    const reply = ["Parent context reply.", "Side answer to attach.", "Busy parent reply.", "Slash answer only.", "Parent received attachment."][index];
    assert.ok(reply, "unexpected model request");
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    for (const [delta, reason] of [[{ role: "assistant", content: reply }, null], [{}, "stop"]]) {
      const chunk = {
        id: `side-fixture-${index}`, object: "chat.completion.chunk", created: 1, model,
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
  const git = (...args) => execFileSync("/usr/bin/git", args, {
    stdio: "pipe",
    env: { PATH: "/usr/bin:/bin", GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" },
  });
  git("init", "--initial-branch=main", project);
  git("-C", project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
      "commit", "--allow-empty", "-m", "Fixture");
  git("-C", project, "worktree", "add", "-b", "parent-checkout", checkout);

  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const run = spawn("swift", ["test", "--disable-sandbox", "--filter", "SideChatWorkflowTests", ...process.argv.slice(3)], {
    cwd: workspace,
    env: {
      ...process.env,
      SWIFTPM_MODULECACHE_OVERRIDE: process.env.SWIFTPM_MODULECACHE_OVERRIDE ?? join(workspace, ".build/module-cache"),
      PI_SIDE_CHAT_TEST_ROOT: root,
      PI_SIDE_CHAT_TEST_ENDPOINT: `http://127.0.0.1:${server.address().port}/v1`,
      PI_SIDE_CHAT_TEST_NODE: node,
      PI_SIDE_CHAT_TEST_WORKER: join(sidecar, "worker.mjs"),
    },
    stdio: "inherit",
  });
  const [exitCode] = await once(run, "exit");
  if (fixtureError) throw fixtureError;
  assert.equal(exitCode, 0, `Native workflow failed after ${requests.length} provider requests.`);
  const framing = "You are in a side chat beside the main thread. Answer the user's question without continuing the main thread's task.";
  const seed = [["user", "Parent starting question."], ["assistant", "Parent context reply."]];
  const busy = ["user", "Parent work in progress."];
  const busyAnswered = [...seed, busy, ["assistant", "Busy parent reply."]];
  const file = 'Attached text file "pasted-text.txt":\nUnrelated fixture file.';
  const wire = requests.map(({ model, turns }) => {
    assert.equal(model, "parent-fixture-model");
    return turns;
  });
  assert.deepEqual(wire, [
    seed.slice(0, 1),
    [...seed, ["user", framing + "\n\nSide question from pane."]],
    [...seed, busy],
    [...seed, ["user", framing + "\n\nMain thread activity since this side chat's starting point:\nUser: Parent work in progress.\n\nSlash question while parent is busy.\n\n" + file]],
    [...busyAnswered, ["user", "Parent follow-up.\n\n" + file +
      '\n\nAttached text file "Side chat: Side question from pane.":\nUser: Side question from pane.\n\nAssistant: Side answer to attach.']],
    [...busyAnswered, ["user", wire[4]?.at(-1)?.[1]], ["assistant", "Parent received attachment."],
      ["user", framing + "\n\nSlash provider error."]],
  ]);
  console.log("Pi 1.6.1 verified six exact parent and child wire histories, including one provider failure.");
} finally {
  server.closeAllConnections();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  rmSync(root, { recursive: true, force: true });
}
