import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { localAccount } from "./fixtures/local-pi-account.mjs";

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

export async function verifyInheritedAccount(driver, { root, launch, quit, record, credential, removeFixtureCredential }) {
  const { press, dismiss, tree, visible, value, until, openModelSettings, closeSettings } = driver;
  const accounts = [];
  try {
    accounts.push(await localAccount("inherited-owner"));
    accounts.push(await localAccount("new-default"));
    const [owner, other] = accounts;
    const uuid = () => randomUUID().toUpperCase();
    const projectID = uuid(), threadID = uuid(), siblingID = uuid(), stashID = uuid();
    const first = "First inherited conversation", next = "Continue the inherited conversation", sibling = "A separate new draft";
    const project = { id: projectID, title: "Reset fixture", path: join(root, "Project"), allowEdits: false,
      selectedConversation: threadID, conversations: [
        { id: threadID, title: "Original", archived: false, isDraft: true, composerText: first },
        { id: siblingID, title: "Sibling", archived: false, isDraft: true, composerText: sibling },
      ] };
    const state = { welcomeCompleted: true, selectedProject: projectID, projects: [project], model: other.settings,
      stashedPrompts: [{ id: stashID, createdAt: 1, prompt: next, attachments: [] }] };
    const path = join(root, "workspace.json");
    const current = () => JSON.parse(readFileSync(path, "utf8")).projects[0];
    mkdirSync(project.path, { recursive: true });
    writeFileSync(path, JSON.stringify(state), { mode: 0o600 });
    credential("--set-api-key-from-stdin", other.key, root);
    project.modelOverride = owner.settings;
    writeFileSync(path, JSON.stringify(state), { mode: 0o600 });
    credential("--set-api-key-from-stdin", owner.key, root);
    async function send(account, count) {
      await until(() => value("active-model").includes(account.settings.model) && visible("send-message").includes("enabled=true"), "correct route before sending");
      press("send-message");
      await until(() => account.turns.length === count && tree().includes("Reply from " + account.settings.model + " turn " + count) &&
        !tree().includes('id="stop-message"'), "expected model replied");
    }
    await launch("composer", root);
    await send(owner, 1);
    press("thread-row-" + siblingID);
    await until(() => current().selectedConversation === siblingID && value("composer").includes(sibling), "sibling draft selected");
    await openModelSettings();
    await until(() => visible("reset-model-override"), "project override");
    press("reset-model-override");
    await until(() => value("model-settings-source").includes("Inherits Workspace default"), "project now inherits the default");
    await closeSettings();
    await quit();
    await launch("composer", root);
    assert.equal(current().selectedConversation, siblingID);
    assert.equal(current().modelOverride, undefined);
    assert(value("composer").includes(sibling));
    await send(other, 1);
    press("thread-row-" + threadID);
    await until(() => current().selectedConversation === threadID && tree().includes("Reply from inherited-owner turn 1"), "original conversation restored");
    const retained = current().conversations.find(t => t.id === threadID);
    assert.equal(retained.modelSelection, undefined);
    assert.equal(retained.historyModel.endpoint, owner.settings.endpoint);
    press("open-composer-stash");
    await until(() => visible("restore-stashed-prompt-" + stashID), "original follow-up");
    dismiss("restore-stashed-prompt-" + stashID);
    await send(owner, 2);
    await quit();
    assert.deepEqual(owner.turns.map(t => t.prompts), [[first], [first, next]]);
    assert.deepEqual(other.turns.map(t => t.prompts), [[sibling]]);
    record("After resetting the project model from a sibling draft and relaunching, only the sibling's standalone text reached the new default. The original inherited thread kept its ID and had both of its turns delivered to its original endpoint.");
  } finally {
    for (const account of accounts) {
      removeFixtureCredential(root, "local:" + account.settings.endpoint);
      account.server.closeAllConnections();
      await new Promise(resolve => account.server.close(resolve));
    }
  }
}
