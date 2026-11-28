import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { seedPaletteMessageHistory } from "./fixtures/palette-message-history.mjs";

export async function verifyArchivedThreads(driver, { root, app, git, launch, quit, record }) {
  const { until, visible, value, subtree, tree, press, dismiss, pick, setField, focus, selection, openSettingsLink } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const alpha = uuid(), beta = uuid(), detached = uuid();
  const active = uuid(), first = uuid(), second = uuid(), other = uuid(), noFolder = uuid(), hidden = uuid();
  const queued = { id: uuid(), text: "Original queued text 🌱" };
  const mainDraft = "Keep the active composer 🚲";
  const queueEdit = "Unsent queue edit with punctuation !";
  const repo = join(root, "Alpha");
  const one = join(root, "Checkout One");
  const two = join(root, "Checkout Two");
  const betaFolder = join(root, "Beta");
  const missing = join(root, "Missing checkout");
  const detachedFolder = join(root, "Detached");
  for (const path of [repo, betaFolder, detachedFolder]) mkdirSync(path, { recursive: true });
  git(repo, "init", "--template=", "-b", "main");
  git(repo, "config", "core.hooksPath", "/dev/null");
  git(repo, "-c", "user.name=Archive Fixture", "-c", "user.email=archive@example.invalid", "-c", "commit.gpgsign=false",
      "commit", "--allow-empty", "-m", "Initial fixture");
  git(repo, "worktree", "add", "-b", "worktree-one", one);
  git(repo, "worktree", "add", "-b", "worktree-two", two);
  const beforeTrees = git(repo, "worktree", "list", "--porcelain");
  assert(beforeTrees.includes(one) && beforeTrees.includes(two));

  const indexPath = join(root, "workspace.json");
  const previous = join(root, "workspace.previous.json");
  const archived = (id, path, title = "Same archived title") => ({
    id, title, archived: true, isDraft: false,
    ...(path ? { location: { worktree: { path } } } : {}),
  });
  writeFileSync(indexPath, JSON.stringify({
    selectedProject: alpha, welcomeCompleted: true,
    model: { provider: "local", model: "palette-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
    projects: [
      { id: alpha, path: repo, title: "Alpha", allowEdits: false, selectedConversation: active,
        conversations: [{ id: active, title: "Selected thread", archived: false, isDraft: false,
          composerText: mainDraft, queuedMessages: [queued] },
        archived(first, one), archived(second, two), archived(noFolder, missing, "Missing checkout thread")] },
      { id: beta, path: betaFolder, title: "Beta", allowEdits: false, conversations: [archived(other)] },
      { id: detached, path: detachedFolder, title: "Detached", detached: true, allowEdits: false, conversations: [archived(hidden)] },
    ],
  }), { mode: 0o600 });

  const sidecar = join(app, "Contents/Resources/Sidecar");
  const sdk = pathToFileURL(join(sidecar, "node_modules/@earendil-works/pi-coding-agent/dist/index.js"));
  const { SessionManager } = await import(sdk.href);
  const history = new Map();
  for (const fixture of [
    { projectID: alpha, threadID: active, cwd: repo, keyword: "active-fixture" },
    { projectID: alpha, threadID: first, cwd: one, keyword: "checkout-one-fixture" },
    { projectID: alpha, threadID: second, cwd: two, keyword: "checkout-two-fixture" },
    { projectID: beta, threadID: other, cwd: betaFolder, keyword: "beta-fixture" },
    { projectID: alpha, threadID: noFolder, cwd: missing, keyword: "missing-fixture" },
    { projectID: detached, threadID: hidden, cwd: detachedFolder, keyword: "detached-fixture" },
  ]) {
    const seeded = await seedPaletteMessageHistory({ sidecar, workspace: root, ...fixture, laterKeyword: fixture.keyword });
    const sessionRoot = join(root, "sessions", fixture.projectID, fixture.threadID);
    // Match the app's thinking level so opening the transcript leaves its history bytes intact.
    SessionManager.open(seeded.historyPath, sessionRoot, fixture.cwd).appendThinkingLevelChange("off");
    history.set(fixture.threadID, { ...seeded, bytes: readFileSync(seeded.historyPath) });
  }
  const restored = history.get(second);
  function checkHistory() {
    for (const [threadID, expected] of history) {
      assert(readFileSync(expected.historyPath).equals(expected.bytes), "Pi history changed for " + threadID);
    }
    assert.equal(git(repo, "worktree", "list", "--porcelain"), beforeTrees);
  }

  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const thread = id => index().projects.flatMap(project => project.conversations).find(entry => entry.id === id);
  const selected = () => {
    const state = index();
    return [state.selectedProject, state.projects.find(project => project.id === state.selectedProject)?.selectedConversation];
  };
  const has = id => tree().includes('id="' + id + '"');
  const composer = text => value("composer").includes("value=" + JSON.stringify(text));
  const row = id => "archive-row-" + id;
  const unarchive = id => "archive-unarchive-" + id;
  const sidebar = id => "thread-row-" + id;
  const message = id => "transcript-message-" + id;
  const archiveURL = "tncode://settings/archived";
  const anchorFocused = () => visible("archive").includes("focused=true");
  const allRows = () => visible(row(first)) && visible(row(second)) && visible(row(other));
  async function closeSettings() {
    dismiss("settings-close");
    await until(() => !has("settings"), "closed Settings");
  }
  async function openWorkspace() {
    await launch("composer", root, undefined, true);
    await until(() => composer(mainDraft) && visible(message(history.get(active).messageID)),
                "selected thread draft and Pi history");
  }
  async function openRestoredThread() {
    press(sidebar(second));
    await until(() => visible(message(restored.messageID)) && visible(message(restored.latestID)) &&
      selected()[1] === second, "the restored thread's saved Pi message IDs");
    assert.match(subtree(message(restored.messageID), 3), /checkout-two-fixture/);
    assert(!has(message(history.get(first).messageID)));
    assert.deepEqual(selected(), [alpha, second]);
    checkHistory();
  }

  await openWorkspace();
  assert(!has(sidebar(first)) && !has(sidebar(second)) && !has(sidebar(other)));
  press("model-settings");
  await until(() => visible("settings-nav-archived") && visible("settings-search").includes("focused=true"),
              "Settings navigation and focused search");
  await setField("settings-search", "archived threads");
  await until(() => visible("settings-result-archive"), "Archived threads search result");
  dismiss("settings-result-archive");
  await until(() => visible("settings-heading-archived") && anchorFocused() && allRows(),
              "Archive search opened the focused list");
  assert(!has(row(hidden)) && !has("archive-checkout"));

  pick("archive-project", "Beta");
  await until(() => visible(row(other)) && !has(row(first)) && !has(row(second)), "Beta archive scope");
  pick("archive-project", "Alpha");
  await until(() => visible("archive-checkout") && visible(row(first)) && visible(row(second)) && !has(row(other)),
              "Alpha archive scope");
  pick("archive-checkout", repo);
  await until(() => visible("archive-empty") && !has(row(first)) && !has(row(second)), "empty main checkout");
  pick("archive-checkout", two);
  await until(() => visible(unarchive(second)) && !has(row(first)) && !has(row(noFolder)), "exact linked checkout");
  press("settings-nav-general");
  await until(() => visible("settings-heading-general"), "General page");
  press("settings-nav-archived");
  await until(() => visible(unarchive(second)) && !has(row(first)), "Archive scope retained within Settings");
  await closeSettings();
  assert.deepEqual(selected(), [alpha, active]);
  assert(composer(mainDraft));
  record("Settings search focused Archive. Project and checkout filters selected the expected rows, including an empty checkout. Settings retained the filter across navigation and excluded the detached project.");

  pick("queue-item-actions-" + queued.id, "Edit in Composer");
  await until(() => visible("queue-update") && composer(queued.text), "edit the selected queued message");
  await setField("composer", queueEdit);
  focus("composer");
  const selectedEditText = "queue edit";
  const range = [queueEdit.indexOf(selectedEditText), selectedEditText.length];
  assert.deepEqual(selection("composer", ...range), range);
  openSettingsLink(archiveURL);
  await until(allRows, "direct local Archive URL");
  const before = readFileSync(indexPath);
  const savedPrevious = previous + ".fixture-backup";
  if (existsSync(previous)) renameSync(previous, savedPrevious);
  mkdirSync(previous);
  try {
    dismiss(unarchive(second));
    await until(() => visible("archive-error-" + second) && allRows(), "unarchive save error with all rows still listed");
    assert.deepEqual(readFileSync(indexPath), before);
    checkHistory();
    await closeSettings();
    await until(() => visible("queue-update") && composer(queueEdit), "unsent queue edit after the failure");
    focus("composer");
    assert.deepEqual(selection("composer"), range);
    assert.deepEqual(selected(), [alpha, active]);
    assert.deepEqual(thread(active).queuedMessages, [queued]);
    openSettingsLink(archiveURL + "#archive");
    await until(() => anchorFocused() && visible(unarchive(second)), "local Archive URL with the archive anchor");
  } finally {
    rmdirSync(previous);
    if (existsSync(savedPrevious)) renameSync(savedPrevious, previous);
  }
  dismiss(unarchive(second));
  await until(() => !has(row(second)) && visible(row(first)) && visible(row(other)) && thread(second).archived === false,
              "retry restored only the targeted archive row");
  assert.equal(thread(first).archived, true);
  assert.equal(thread(other).archived, true);
  assert.deepEqual(thread(active).queuedMessages, [queued]);
  checkHistory();
  await closeSettings();
  await until(() => visible("queue-update") && composer(queueEdit) && visible(sidebar(second)),
              "the original queue edit and restored sidebar row");
  assert.deepEqual(selected(), [alpha, active]);
  assert(!has(sidebar(first)) && !has(sidebar(other)));
  dismiss("queue-update");
  await until(() => !has("queue-update") && composer(mainDraft), "original composer after saving the queue edit");
  assert.deepEqual(thread(active).queuedMessages, [{ ...queued, text: queueEdit }]);
  record("A failed unarchive preserved the index, active thread, selected composer text, queued message, and Pi histories. Retry restored only the target, and Update saved the original queue ID and returned to the original draft.");

  await openRestoredThread();
  openSettingsLink(archiveURL);
  await until(() => visible(unarchive(noFolder)), "archived row with a missing checkout");
  dismiss(unarchive(noFolder));
  await until(() => !has(row(noFolder)) && visible(row(first)), "restored missing checkout metadata");
  await closeSettings();
  press(sidebar(noFolder));
  await until(() => tree().includes("workspace folder is no longer available"), "missing checkout recovery");
  assert.equal(thread(noFolder).location.worktree.path, missing);
  assert(!existsSync(missing));
  press(sidebar(active));
  await until(() => visible(message(history.get(active).messageID)), "return to the active thread");
  await quit();

  await openWorkspace();
  openSettingsLink(archiveURL);
  await until(() => visible(row(first)) && visible(row(other)) && !has(row(second)) && !has(row(hidden)),
              "persisted Archive rows after relaunch");
  assert.equal(thread(hidden).archived, true);
  await closeSettings();
  await openRestoredThread();
  await quit();
  record("The restored sidebar thread opened the same Pi message IDs before and after restart (" + restored.messageID +
    " and " + restored.latestID + "). The worktree list and history bytes were identical, and the missing checkout still opened recovery.");
}
