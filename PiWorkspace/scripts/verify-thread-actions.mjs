import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, renameSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { seedPaletteMessageHistory } from "./fixtures/palette-message-history.mjs";

export async function verifyOfflineQueueEdit(driver, { root, launch, quit, endpoint, record }) {
  const { press, dismiss, setField, visible, value, tree, until } = driver;
  const id = () => randomUUID().toUpperCase();
  const attachment = content => ({ id: id(), name: "same.txt",
    payload: { data: Buffer.from(content).toString("base64"), mimeType: "text/plain" } });
  const draftNote = attachment("普通の下書き"), keep = attachment("残すメモ\n"), remove = attachment("外すメモ\n");
  const item = { id: id(), text: "Old queued prompt", attachments: [remove, keep] };
  const projectID = id(), threadID = id(), indexPath = join(root, "workspace.json"), path = join(root, "Project");
  const ordinary = "Unsent draft beside the queue", updated = "Updated while signed out";
  mkdirSync(path, { recursive: true });
  writeFileSync(indexPath, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
    model: { provider: "local", model: "queue-fixture", endpoint, contextWindow: 8192 },
    projects: [{ id: projectID, title: "Queue fixture", path, allowEdits: false, selectedConversation: threadID,
      conversations: [{ id: threadID, title: "Waiting for follow-up", isDraft: false, archived: false,
        composerText: ordinary, composerAttachments: [draftNote], queuedMessages: [item] }] }],
  }), { mode: 0o600 });
  const editorShows = expected => value("composer").includes("value=" + JSON.stringify(expected));
  const removeID = file => "remove-attachment-" + file.id;
  const has = identifier => tree().includes('id="' + identifier + '"');
  const checkSaved = () => {
    const state = JSON.parse(readFileSync(indexPath, "utf8"));
    assert.equal(state.selectedProject, projectID);
    assert.equal(state.projects[0].selectedConversation, threadID);
    const thread = state.projects[0].conversations.find(t => t.id === threadID);
    assert.equal(thread.composerText, ordinary);
    assert.deepEqual(thread.composerAttachments, [draftNote]);
    assert.deepEqual(thread.queuedMessages, [{ ...item, text: updated, attachments: [keep] }]);
  };
  await launch("resume-queue", root);
  press("queue-item-actions-" + item.id);
  await until(() => visible("queue-edit-" + item.id), "the queued item's Edit in Composer action");
  dismiss("queue-edit-" + item.id);
  await until(() => editorShows(item.text) && visible(removeID(keep)) && visible(removeID(remove)), "both same-named queued files");
  press(removeID(remove));
  await until(() => visible(removeID(keep)) && !has(removeID(remove)), "removal of the selected file");
  await setField("composer", updated);
  press("queue-update");
  await until(() => editorShows(ordinary) && visible(removeID(draftNote)) && !has("key-input"), "return to the ordinary draft after Update");
  checkSaved();
  await quit();
  await launch("resume-queue", root);
  await until(() => editorShows(ordinary) && visible(removeID(draftNote)), "saved draft and queue after relaunch");
  checkSaved();
  press("resume-queue");
  await until(() => visible("key-input") && !has("stop-message"), "credential entry on delivery");
  checkSaved();
  press("settings-nav-general");
  await until(() => visible("settings-close"), "Settings Done button");
  dismiss("settings-close");
  await until(() => editorShows(ordinary) && !has("settings-close"), "the same draft after closing Settings");
  await quit();
  record("Without a stored key, Update saved the new text and the remaining same.txt bytes under the original queue ID. The draft and its own same.txt survived relaunch. Resume Queue opened credential entry.");
}

export async function verifyThreadActions(driver, { root, app, git, launch, quit, record }) {
  const { until, visible, value, tree, press, dismiss, setField, keyFor, focus, showMenu, checkCopy } = driver;
  const titleField = "sheet-field=Thread title";
  const project = join(root, "Project"), checkout = join(root, "Linked checkout");
  mkdirSync(project, { recursive: true });
  const file = join(project, "shortcut.txt");
  writeFileSync(file, "old file\n");
  git(project, "init", "--template=", "-b", "main");
  git(project, "config", "core.hooksPath", "/dev/null");
  git(project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Start");
  git(project, "worktree", "add", "-b", "topic/keep-edits", checkout, "HEAD");
  const uuid = () => randomUUID().toUpperCase();
  const projectID = uuid(), draftID = uuid(), mainID = uuid(), linkedID = uuid();
  const note = { id: uuid(), name: "notes.txt", payload: { data: Buffer.from("日本語のメモ\n").toString("base64"), mimeType: "text/plain" } };
  const queuedNote = { id: uuid(), name: "queue.txt", payload: { data: Buffer.from("Queued bytes").toString("base64"), mimeType: "text/plain" } };
  const queueID = uuid();
  const seed = "  First draft 🌱  ", prefix = "Waiting on review", joined = prefix + "\n\n" + seed.trim();
  const indexPath = join(root, "workspace.json");
  writeFileSync(indexPath, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
    projects: [{ id: projectID, title: "Thread actions", path: project, allowEdits: false, selectedConversation: draftID, conversations: [
      { id: draftID, title: "Unsent draft", isDraft: true, archived: false, composerText: seed, composerAttachments: [note] },
      { id: mainID, title: "Main conversation", isDraft: false, archived: false },
      { id: linkedID, title: "Linked conversation", isDraft: false, archived: false, location: { worktree: { path: checkout, base: "main" } },
        queuedMessages: [{ id: queueID, text: "Before editing", attachments: [queuedNote] }] },
    ] }], model: { provider: "local", model: "thread-action-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
  }), { mode: 0o600 });
  const seedHistory = (threadID, cwd) => seedPaletteMessageHistory({
    sidecar: join(app, "Contents/Resources/Sidecar"), workspace: root, projectID, threadID, cwd, keyword: "thread action fixture",
  });
  const mainHistory = await seedHistory(mainID, project);
  const linkedHistory = await seedHistory(linkedID, checkout);
  const mainHistoryBytes = readFileSync(mainHistory.historyPath);
  const historyBytes = readFileSync(linkedHistory.historyPath);
  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const selected = () => index().projects[0].selectedConversation;
  const thread = id => index().projects[0].conversations.find(t => t.id === id);
  const entries = () => index().stashedPrompts ?? [];
  const composer = text => value("composer").includes("value=" + JSON.stringify(text));
  const has = id => tree().includes('id="' + id + '"');
  const row = id => "thread-row-" + id;
  async function context(id, action) {
    const original = selected();
    for (let attempt = 0; attempt < 2; attempt++) {
      await until(() => { showMenu(row(id)); return true; }, "right-click the target thread");
      try {
        await until(() => visible(action), "thread context menu " + action, 4000);
        return;
      } catch (error) {
        if (attempt || selected() !== original || tree().includes('role="AXMenu"')) throw error;
      }
    }
  }
  async function copy(id, field, expected) {
    await context(id, "thread-copy");
    press("thread-copy");
    await until(() => visible("thread-copy-" + field), "copy submenu " + field);
    dismiss("thread-copy-" + field);
    await until(() => checkCopy(expected), "copied value of " + field);
    assert.equal(selected(), draftID);
  }
  async function openRename() {
    await context(linkedID, "rename-thread");
    for (let attempt = 0; attempt < 2; attempt++) {
      dismiss("rename-thread");
      try {
        await until(() => value(titleField).includes("Linked conversation") && visible("cancel-rename"), "rename the targeted thread", 3000);
        return;
      } catch (error) {
        if (attempt || !has("rename-thread")) throw error;
      }
    }
  }
  async function stash(count) {
    focus("composer");
    keyFor("composer", 1, "cmd");
    return await until(() => entries().length === count && composer("") && entries()[0], "persisted stash and emptied composer");
  }
  async function toggleArchive() {
    press("thread-filters");
    await until(() => visible("show-thread-archive"), "archive filter");
    press("show-thread-archive");
    dismiss("close-thread-filters");
  }
  async function archiveResponse(title, buttonID) {
    await until(() => tree().includes(JSON.stringify('Archive thread "' + title + '"?')) &&
      visible(buttonID), "archive confirmation for " + title);
    dismiss(buttonID);
  }

  await launch("model-settings", root);
  await until(() => composer(seed) && visible("remove-attachment-" + note.id), "saved draft with its note");
  press("toggle-files");
  await until(() => visible("files-row-shortcut.txt"), "workspace file beside the chat draft");
  press("files-row-shortcut.txt");
  await setField("files-editor", "Saved from Files.");
  keyFor("files-editor", 1, "cmd");
  await until(() => readFileSync(file, "utf8") === "Saved from Files." && composer(seed) && entries().length === 0,
              "Command-S saved the focused file and preserved the other draft");
  dismiss("files-close");
  await until(() => !has("files-editor") && composer(seed), "return from Files to the same draft");
  record("Command-S in the Files editor wrote shortcut.txt and left the chat draft, attachment and stash untouched.");
  const first = await stash(1);
  assert.equal(first.prompt, seed.trim());
  assert.deepEqual(first.attachments, [note]);
  await setField("composer", "Store this separately");
  const second = await stash(2);
  assert.deepEqual(entries().map(e => e.id), [second.id, first.id]);
  await setField("composer", prefix);
  driver.openSettingsLink("pi-workspace://settings/general#archive-confirmation");
  await until(() => value("archive-confirmation").includes("value=0"), "default archive preference");
  press("archive-confirmation");
  await until(() => index().confirmThreadArchive === true && visible("reset-archive-confirmation"), "saved archive confirmation preference");
  dismiss("settings-close");
  await until(() => composer(prefix) && !has("settings-close"), "returned from General");
  await quit();
  await launch("model-settings", root);
  await until(() => selected() === draftID && composer(prefix), "draft and stash after relaunch");
  press("open-composer-stash");
  await until(() => visible("restore-stashed-prompt-" + first.id), "original stash entry");
  dismiss("close-composer-stash");
  await until(() => !has("composer-stash"), "closed stash without consuming either entry");
  assert.equal(entries().length, 2);
  press("open-composer-stash");
  dismiss("restore-stashed-prompt-" + first.id);
  await until(() => composer(joined) && visible("remove-attachment-" + note.id) && entries().length === 1, "restore the chosen text and file");
  assert.deepEqual(thread(draftID).composerAttachments, [note]);
  press("open-composer-stash");
  const backup = join(root, "workspace.previous.json");
  renameSync(backup, backup + ".saved");
  try {
    mkdirSync(backup);
    writeFileSync(join(backup, "fixture-blocker"), "", { flag: "wx" });
    dismiss("delete-stashed-prompt-" + second.id);
    await until(() => visible("composer-error") && visible("delete-stashed-prompt-" + second.id), "failed deletion kept the entry and reported the save failure");
    assert.deepEqual(entries().map(entry => entry.id), [second.id]);
  } finally {
    unlinkSync(join(backup, "fixture-blocker"));
    rmdirSync(backup);
    renameSync(backup + ".saved", backup);
  }
  dismiss("delete-stashed-prompt-" + second.id);
  await until(() => !entries().length && !has("open-composer-stash"), "delete the remaining entry");
  await quit();
  await launch("model-settings", root);
  await until(() => composer(joined) && visible("remove-attachment-" + note.id), "restored draft survives quit");
  assert.deepEqual(entries(), []);
  const only = await stash(1);
  focus("composer");
  keyFor("composer", 1, "cmd");
  await until(() => composer(joined) && !entries().length && visible("remove-attachment-" + note.id), "empty composer restored the sole entry via Command-S");
  assert.deepEqual(only.attachments, [note]);
  record("Command-S stashed two prompts by ID. After relaunch Restore appended the selected trimmed text after two newlines and restored the exact note bytes. A blocked save preserved the entry, retry deleted it across relaunch, and Command-S in an empty composer restored the sole entry.");

  await copy(mainID, "path", project);
  await copy(mainID, "branch", "main");
  await copy(linkedID, "path", checkout);
  await copy(linkedID, "branch", "topic/keep-edits");
  await copy(linkedID, "id", linkedID);
  await context(linkedID, "thread-copy");
  press("thread-copy");
  await until(() => visible("thread-copy-reference"), "Copy Thread in the linked row menu");
  dismiss("thread-copy-reference");
  focus("composer");
  driver.selection("composer", joined.length, 0);
  keyFor("composer", 9, "cmd");
  const link = await until(() => {
    const text = thread(draftID).composerText ?? "";
    if (!text.startsWith(joined)) return false;
    const actual = text.slice(joined.length);
    return /^pi-workspace:\/\/thread\/v1\/[0-9a-f]{64}\//.test(actual) && actual.endsWith("/" + projectID + "/" + linkedID) && actual;
  }, "paste the actual copied URL at the draft caret");
  assert(checkCopy(link));
  keyFor("composer", 6, "cmd");
  await until(() => composer(joined), "undo the temporary link paste");
  driver.menuItem("Open Thread Link from Clipboard");
  await until(() => selected() === linkedID && visible("transcript-message-" + linkedHistory.latestID), "open the copied thread link from Edit");
  press(row(draftID));
  await until(() => composer(joined), "return to the original draft after opening a link");
  driver.openThreadLink(link.slice(0, -linkedID.length) + uuid());
  await until(() => visible("thread-link-error") && selected() === draftID && composer(joined), "unknown thread link kept the draft");
  driver.openThreadLink(link);
  await until(() => selected() === linkedID && visible("transcript-message-" + linkedHistory.latestID) && !has("thread-link-error"), "Launch Services reopened the matching Pi thread");
  press("fork-from-response-" + linkedHistory.latestID);
  const child = await until(() => {
    const item = index().projects[0].conversations.find(t => t.forkOrigin?.threadID === linkedID && t.forkOrigin?.messageID === linkedHistory.latestID);
    return item && selected() === item.id && visible("open-source-conversation") && item;
  }, "real Pi fork of the selected response");
  press("conversation-title");
  await until(() => visible("thread-copy"), "copy link for the fork");
  press("thread-copy");
  await until(() => visible("thread-copy-reference"), "fork link in Copy submenu");
  dismiss("thread-copy-reference");
  await until(() => checkCopy(link.slice(0, -linkedID.length) + child.id), "fork link on the private clipboard");
  press("open-source-conversation");
  await until(() => selected() === linkedID && visible("composer"), "the fork's source conversation");
  const dirty = "Keep this draft when opening an incomplete fork.";
  await setField("composer", dirty);
  const childDirectory = join(root, "sessions", projectID, child.id);
  const histories = readdirSync(childDirectory).filter(name => name.endsWith(".jsonl"));
  assert.equal(histories.length, 1);
  const childPath = join(childDirectory, histories[0]), childBytes = readFileSync(childPath);
  const firstLine = childBytes.indexOf(10);
  assert(firstLine > 0 && firstLine < childBytes.length - 1);
  try {
    writeFileSync(childPath, childBytes.subarray(0, firstLine + 1));
    driver.menuItem("Open Thread Link from Clipboard");
    await until(() => value("thread-link-error").includes("fork history is incomplete") && selected() === linkedID && composer(dirty),
                "invalid fork left the source and its draft selected");
  } finally { writeFileSync(childPath, childBytes); }
  driver.menuItem("Open Thread Link from Clipboard");
  await until(() => selected() === child.id && visible("transcript-message-" + linkedHistory.latestID) && !has("thread-link-error"), "same link reopened the repaired fork");
  press(row(draftID));
  await until(() => composer(joined) && visible("remove-attachment-" + note.id), "original draft intact after both URL opens");
  record("Edit and macOS Launch Services reopened the copied URL at its original Pi message. Unknown IDs and a real fork truncated to its genuine header preserved the selected draft. Restoring the fork history made the very same link usable.");
  await openRename();
  await setField(titleField, "Cancel this rename");
  dismiss("cancel-rename");
  await until(() => !has("cancel-rename") && visible(row(linkedID)).includes("Linked conversation"), "cancel left the title unchanged");
  await openRename();
  await setField(titleField, "Renamed linked branch");
  dismiss("save-rename");
  await until(() => thread(linkedID).title === "Renamed linked branch" && visible(row(linkedID)).includes("Renamed linked branch"), "saved title on the original row");
  assert.equal(selected(), draftID);
  press(row(linkedID));
  await until(() => visible("transcript-message-" + linkedHistory.latestID) && visible("conversation-title").includes("Renamed linked branch"), "renamed thread, same Pi history");
  const followUp = "Do another review on this checkout.";
  await setField("composer", followUp);
  press("queue-item-actions-" + queueID);
  await until(() => visible("queue-edit-" + queueID), "edit the paused queue item");
  dismiss("queue-edit-" + queueID);
  await until(() => composer("Before editing") && visible("remove-attachment-" + queuedNote.id), "editable queued text and file");
  await setField("composer", "Updated queued follow-up");
  press("conversation-title");
  await until(() => visible("archive-thread").includes("enabled=false"), "active thread archive disabled while editing its queue");
  driver.cancelMenu("conversation-title");
  await until(() => !has("archive-thread") && composer("Updated queued follow-up"), "queue edit survived closing menu");
  await context(mainID, "archive-thread");
  assert(visible("archive-thread").includes("enabled=true"));
  const beforeArchive = readFileSync(indexPath);
  dismiss("archive-thread");
  await archiveResponse("Main conversation", "cancel-archive-thread");
  await until(() => !tree().includes(JSON.stringify('Archive thread "Main conversation"?')) && composer("Updated queued follow-up"),
    "cancelled archive kept the queue editor");
  assert.deepEqual(readFileSync(indexPath), beforeArchive);
  await context(mainID, "archive-thread");
  dismiss("archive-thread");
  renameSync(backup, backup + ".saved");
  try {
    mkdirSync(backup);
    writeFileSync(join(backup, "fixture-blocker"), "", { flag: "wx" });
    await archiveResponse("Main conversation", "confirm-archive-thread");
    await until(() => visible("retry-archive-thread") && value("archive-thread-error").includes("Main conversation"), "archive failure identified the clicked thread");
    assert.deepEqual(readFileSync(indexPath), beforeArchive);
    assert.equal(thread(mainID).archived, false);
  } finally {
    unlinkSync(join(backup, "fixture-blocker"));
    rmdirSync(backup);
    renameSync(backup + ".saved", backup);
  }
  dismiss("retry-archive-thread");
  await until(() => thread(mainID).archived && selected() === linkedID && composer("Updated queued follow-up"), "archiving another thread preserved the active edit");
  press("queue-update");
  await until(() => composer(followUp) && thread(linkedID).queuedMessages[0].text === "Updated queued follow-up", "queue update preserved the ordinary draft");
  assert.deepEqual(thread(linkedID).queuedMessages[0].attachments, [queuedNote]);
  driver.openSettingsLink("pi-workspace://settings/general#archive-confirmation");
  await until(() => value("archive-confirmation").includes("value=1"), "archive confirmation survived relaunch");
  press("reset-archive-confirmation");
  await until(() => !index().confirmThreadArchive && value("archive-confirmation").includes("value=0"), "archive reset to its default");
  dismiss("settings-close");
  await until(() => !has("settings-close") && composer(followUp), "returned from archive settings to the same thread");
  press("conversation-title");
  await until(() => visible("archive-thread"), "archive open conversation");
  dismiss("archive-thread");
  await until(() => thread(linkedID).archived && selected() !== linkedID && !has(row(linkedID)), "archive removed the active row and opened a draft");
  await toggleArchive();
  await until(() => visible(row(linkedID)), "archived thread row");
  press(row(linkedID));
  await until(() => visible("restore-open-thread") && visible("transcript-message-" + linkedHistory.latestID), "archive retained its history");
  dismiss("restore-open-thread");
  await until(() => visible(row(linkedID)) && composer(followUp) && !thread(linkedID).archived, "restore returned to the existing draft text");
  await quit();
  await launch("model-settings", root);
  await until(() => selected() === linkedID && composer(followUp) && visible("transcript-message-" + linkedHistory.latestID), "restored conversation after relaunch");
  assert.equal(thread(linkedID).location.worktree.path, checkout);
  const reopened = readFileSync(linkedHistory.historyPath);
  assert(reopened.subarray(0, historyBytes.length).equals(historyBytes), "The original Pi records changed.");
  const appended = reopened.subarray(historyBytes.length).toString().trim();
  if (appended) {
    const change = JSON.parse(appended);
    assert.equal(change.type, "thinking_level_change");
    assert.equal(change.thinkingLevel, "off");
  }
  assert.deepEqual(thread(draftID).composerAttachments, [note]);
  assert.equal(thread(draftID).composerText, joined);
  assert.equal(thread(mainID).title, "Main conversation");
  assert.deepEqual(thread(linkedID).queuedMessages, [{ id: queueID, text: "Updated queued follow-up", attachments: [queuedNote] }]);
  assert(readFileSync(mainHistory.historyPath).equals(mainHistoryBytes), "The other thread's history changed.");
  await quit();
  record("The saved archive preference named the clicked thread after relaunch. Cancel and a refused save left the index byte-identical, with another thread’s queue edit still open. Retry archived only the clicked thread. Reset restored immediate archiving in the title menu.");
  record("Right-click Copy returned each row's own Git path and branch plus the linked thread ID while the draft stayed selected. Rename, archive, restore and relaunch preserved the original Pi record bytes, unsent follow-up, checkout and the other draft. Pi's first-open thinking-level record was the only permitted append.");
}
