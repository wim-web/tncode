import assert from "node:assert/strict";
import { randomBytes, randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";

async function localAccount(model) {
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
    turns.push({ model: body.model, prompts });
    const reply = "Reply from " + model + " turn " + turns.length;
    const chunk = (delta, reason) => "data: " + JSON.stringify({ id: "account-fixture-" + turns.length,
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

export async function verifyModelAccount(driver, { root, launch, quit, record, credential, removeFixtureCredential }) {
  const { press, dismiss, tree, visible, value, until } = driver;
  const owners = [];
  try {
    owners.push(await localAccount("model-owner"));
    owners.push(await localAccount("model-default"));
    const [owner, other] = owners;
    const path = join(root, "project"), indexPath = join(root, "workspace.json");
    mkdirSync(path, { recursive: true });
    const uuid = () => randomUUID().toUpperCase();
    const threadID = uuid(), projectID = uuid(), stashID = uuid();
    const first = "First private fixture turn", second = "Second private fixture turn";
    const thread = { id: threadID, title: "Fixed model account", archived: false, isDraft: true, composerText: first };
    const state = { welcomeCompleted: true, selectedProject: projectID, model: other.settings, projects: [
      { id: projectID, title: "Account fixture", path, allowEdits: false, selectedConversation: threadID, conversations: [thread] },
    ], stashedPrompts: [{ id: stashID, createdAt: 1, prompt: second, attachments: [] }] };
    for (const account of [other, owner]) {
      thread.modelSelection = account.settings;
      writeFileSync(indexPath, JSON.stringify(state), { mode: 0o600 });
      credential("--set-api-key-from-stdin", account.key, root);
    }
    const defaultID = "composer-model-local-" + other.settings.model;
    const defaultAction = "composer-model-default";
    const openPicker = async () => {
      await until(() => visible("active-model").includes("enabled=true"), "available model picker");
      press("active-model");
      await until(() => visible(defaultID) && visible("composer-model-close"), "both accounts in the picker");
    };
    const requireAccountLock = async () => {
      await openPicker();
      assert(visible(defaultID).includes("enabled=false"), "The other account was selectable on a submitted thread.");
      assert(!tree().includes('id="' + defaultAction + '"') || visible(defaultAction).includes("enabled=false"),
        "Use Default was available for a different account after the thread recorded its first user message.");
      dismiss("composer-model-close");
    };
    async function send(turn) {
      await until(() => visible("send-message").includes("enabled=true"), "send an existing filled draft");
      press("send-message");
      await until(() => owner.turns.length === turn && tree().includes("Reply from model-owner turn " + turn) &&
        !tree().includes('id="stop-message"'), "the owner endpoint finished turn " + turn);
    }
    await launch("composer", root);
    await openPicker();
    assert(visible(defaultID).includes("enabled=true"));
    assert(visible(defaultAction).includes("enabled=true"));
    dismiss("composer-model-close");
    await send(1);
    await requireAccountLock();
    press("open-composer-stash");
    await until(() => visible("restore-stashed-prompt-" + stashID), "saved next turn");
    dismiss("restore-stashed-prompt-" + stashID);
    await until(() => value("composer").includes(second), "restored prompt for relaunch");
    await quit();
    await launch("composer", root);
    await until(() => value("composer").includes(second) && tree().includes("Reply from model-owner turn 1"), "same draft and owner history");
    await requireAccountLock();
    await send(2);
    await quit();
    assert.deepEqual(owner.turns, [{ model: "model-owner", prompts: [first] }, { model: "model-owner", prompts: [first, second] }]);
    assert.deepEqual(other.turns, []);
    const saved = JSON.parse(readFileSync(indexPath, "utf8"));
    assert.equal(saved.projects[0].selectedConversation, threadID);
    assert.equal(saved.projects[0].conversations.find(t => t.id === threadID).modelSelection.endpoint, owner.settings.endpoint);
    record("Use Default was available on the unsent draft. After its first reply, neither the other account nor Use Default could switch that history, including after relaunch. Only the owner endpoint received the two turns. The other endpoint received zero requests.");
  } finally {
    for (const account of owners) {
      removeFixtureCredential(root, "local:" + account.settings.endpoint);
      account.server.closeAllConnections();
      await new Promise(resolve => account.server.close(resolve));
    }
  }
}
