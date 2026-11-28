import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { localAccount } from "./fixtures/local-pi-account.mjs";

export async function verifySideChatPanel(driver, { root, launch, quit, credential, removeFixtureCredential, record }) {
  const { press, dismiss, value, visible, until, tree } = driver;
  const held = Promise.withResolvers();
  const account = await localAccount("side-fixture", turn => turn === 1 ? held.promise : undefined);
  const uuid = () => randomUUID().toUpperCase();
  const projectID = uuid(), threadID = uuid(), questionID = uuid(), followupID = uuid();
  const first = "Parent first turn", question = "Can the side chat answer first?", followup = "Keep the side answer";
  const project = join(root, "Project"), indexPath = join(root, "workspace.json");
  const parentDirectory = join(root, "sessions", projectID, threadID);
  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const parent = () => index().projects[0].conversations.find(t => t.id === threadID);
  const has = id => tree().includes('id="' + id + '"');
  const enabled = id => visible(id).includes("enabled=true");
  async function restore(id) {
    press("open-composer-stash");
    await until(() => enabled("restore-stashed-prompt-" + id), "saved prompt can be restored");
    dismiss("restore-stashed-prompt-" + id);
  }
  function history(path) {
    const files = readdirSync(path).filter(name => name.endsWith(".jsonl"));
    assert.equal(files.length, 1);
    return readFileSync(join(path, files[0]));
  }
  try {
    mkdirSync(project, { recursive: true });
    const thread = { id: threadID, title: "Parent thread", isDraft: true, archived: false, composerText: first };
    writeFileSync(indexPath, JSON.stringify({ selectedProject: projectID, model: account.settings, welcomeCompleted: true,
      projects: [{ id: projectID, path: project, title: "Fixture", allowEdits: false, selectedConversation: threadID, conversations: [thread] }],
      stashedPrompts: [{ id: questionID, createdAt: 2, prompt: "/btw " + question, attachments: [] },
        { id: followupID, createdAt: 1, prompt: followup, attachments: [] }] }), { mode: 0o600 });
    credential("--set-api-key-from-stdin", account.key, root);
    await launch("composer", root);
    await until(() => enabled("send-message"), "parent ready");
    press("send-message");
    await until(() => account.turns.length === 1 && parent().isDraft === false && enabled("stop-message"), "first parent request is pending");
    await restore(questionID);
    await until(() => value("composer").includes(question) && enabled("send-message"), "side command available during the first turn");
    press("send-message");
    const child = await until(() => {
      const saved = parent().sideChats?.[0];
      return saved?.hasStarted && enabled("add-side-chat-to-chat") && driver.subtree("side-chat-transcript", 7).includes("Reply from side-fixture turn 2") && saved;
    }, "child answered before the parent");
    assert.equal(child.cutoff ?? null, null);
    assert.equal(child.model.endpoint, account.settings.endpoint);
    assert(enabled("stop-message"));
    const framing = "You are in a side chat beside the main thread. Answer the user's question without continuing the main thread's task.";
    assert.deepEqual(account.turns.map(t => t.prompts), [[first],
      [framing + "\n\nMain thread activity since this side chat's starting point:\nUser: " + first + "\n\n" + question]]);
    press("add-side-chat-to-chat");
    const attachment = await until(() => parent().composerAttachments?.find(file => file.id === child.id), "the child snapshot is attached to the parent");
    const snapshot = "User: " + question + "\n\nAssistant: Reply from side-fixture turn 2";
    assert.equal(Buffer.from(attachment.payload.data, "base64").toString("utf8"), snapshot);
    held.resolve();
    await until(() => !has("stop-message") && tree().includes("Reply from side-fixture turn 1"), "first parent reply finished");
    dismiss("open-side-chat-parent");
    await restore(followupID);
    await until(() => parent().composerText === followup, "parent draft saved before quitting");
    const before = history(parentDirectory);
    const childDirectory = join(parentDirectory, "side-chats", child.id), childBefore = history(childDirectory);
    assert(!before.includes(Buffer.from(question)));
    await quit();
    await launch("composer", root);
    assert.equal(index().projects[0].selectedConversation, threadID);
    assert.equal(parent().composerText, followup);
    assert.deepEqual(parent().composerAttachments, [attachment]);
    assert.deepEqual(history(parentDirectory), before);
    press("thread-details");
    await until(() => enabled("open-side-chat-" + child.id), "existing child in details");
    dismiss("open-side-chat-" + child.id);
    await until(() => driver.subtree("side-chat-transcript", 7).includes("Reply from side-fixture turn 2"), "child restored");
    assert.deepEqual(history(childDirectory), childBefore);
    press("delete-side-chat");
    dismiss("cancel-side-chat-delete");
    assert.deepEqual(history(childDirectory), childBefore);
    press("delete-side-chat");
    dismiss("confirm-side-chat-delete");
    await until(() => !parent().sideChats?.length && !existsSync(childDirectory), "only the child was deleted");
    assert.deepEqual(history(parentDirectory), before);
    assert.deepEqual(parent().composerAttachments, [attachment]);
    await until(() => enabled("send-message"), "restored parent ready");
    press("send-message");
    await until(() => account.turns.length === 3 && tree().includes("Reply from side-fixture turn 3") && !has("stop-message"), "parent received the snapshot once");
    assert.deepEqual(account.turns[2], { model: account.settings.model, prompts: [first,
      followup + '\n\nAttached text file "' + attachment.name + '":\n' + snapshot] });
    await quit();
    record("The side chat answered while the parent's first reply was held. It had no fork cutoff and received one digest of the pending parent input. Relaunch and canceling deletion retained both histories. Deleting the child kept the parent's saved snapshot, which the model received exactly once.");
  } finally {
    held.resolve();
    removeFixtureCredential(root, "local:" + account.settings.endpoint);
    account.server.closeAllConnections();
    await new Promise(resolve => account.server.close(resolve));
  }
}
