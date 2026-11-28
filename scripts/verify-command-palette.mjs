import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyPaletteFiles(driver, { root, git, launch, quit, record }) {
  const { press, dismiss, keyFor, visible, value, until, setField, selectedText } = driver;
  const project = join(root, "Project"), linked = join(root, "Linked checkout"), relative = "src/log.txt";
  const alphaLine = "Main checkout: orbital lantern", betaLine = "Linked checkout: orbital lantern";
  const alpha = "Header\n\n" + alphaLine + "\n", beta = "Different context\n".repeat(163) + betaLine + "\n";
  mkdirSync(join(project, "src"), { recursive: true });
  git(project, "init", "--template=", "-b", "main");
  git(project, "config", "core.hooksPath", "/dev/null");
  writeFileSync(join(project, relative), alpha);
  git(project, "add", relative);
  git(project, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Search fixture");
  git(project, "worktree", "add", "-b", "linked-search", linked, "HEAD");
  writeFileSync(join(linked, relative), beta);
  const projectID = randomUUID().toUpperCase(), firstID = randomUUID().toUpperCase(), secondID = randomUUID().toUpperCase();
  const firstText = "Keep the main draft", secondText = "Keep the linked draft", index = join(root, "workspace.json");
  writeFileSync(index, JSON.stringify({ welcomeCompleted: true, selectedProject: projectID,
    projects: [{ id: projectID, path: project, title: "Search project", allowEdits: false, selectedConversation: firstID, conversations: [
      { id: firstID, title: "Main draft", isDraft: true, archived: false, composerText: firstText },
      { id: secondID, title: "Linked draft", isDraft: true, archived: false, composerText: secondText,
        location: { worktree: { path: linked, base: "main" } } },
    ] }], model: { provider: "local", model: "file-search", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 } }), { mode: 0o600 });
  const field = "command-palette-search", has = id => driver.tree().includes('id="' + id + '"');
  const shown = (id, text) => value(id).includes("value=" + JSON.stringify(text));
  async function open(query, command, mode) {
    driver.menuItem("Command Palette…");
    await until(() => visible(field).includes("focused=true"), "focused command palette");
    await setField(field, query, () => Boolean(visible(command)));
    keyFor(field, 36);
    await until(() => visible(mode) && shown(field, ""), "file-search child with its own empty query");
  }
  async function hit(line, marker) {
    const id = "command-palette-content-result-" + relative + ":" + line;
    await setField(field, "orbital lantern", () => Boolean(visible(id)));
    assert(driver.help(id).includes(marker));
    keyFor(field, 36);
    await until(() => selectedText("files-editor") === marker && !has(field), "selected match at " + relative + ":" + line);
  }
  const go = "command-palette-go-to-file", contents = "command-palette-search-project-contents";
  const fileRow = "command-palette-file-result-" + relative;
  await launch("composer", root);
  await open(">go to file", go, "project-file-picker");
  await setField(field, "log.txt", () => Boolean(visible(fileRow)));
  keyFor(field, 53);
  await until(() => shown(field, ">go to file") && visible(go), "Escape restored the parent file command");
  press(go);
  await setField(field, "log.txt", () => Boolean(visible(fileRow)));
  dismiss(fileRow);
  await until(() => shown("files-editor", alpha), "Go to file opened the main checkout");
  await open(">search project contents", contents, "project-content-search");
  await setField(field, "absent-fixture-word");
  keyFor(field, 53);
  await until(() => shown(field, ">search project contents") && visible(contents), "Escape restored the parent content command");
  press(contents);
  await hit(3, alphaLine);
  press("thread-row-" + secondID);
  await until(() => shown("composer", secondText), "linked draft");
  await open(">search project contents", contents, "project-content-search");
  await hit(164, betaLine);
  assert(shown("files-editor", beta));
  driver.focus("composer");
  keyFor("composer", 35, "cmd");
  await until(() => visible("project-file-picker") && shown(field, ""), "Command-P opened the file picker");
  await setField(field, "log.txt", () => Boolean(visible(fileRow)));
  keyFor(field, 3, "cmd", "shift");
  await until(() => visible("project-content-search") && shown(field, ""), "Command-Shift-F switched to a fresh content query");
  await hit(164, betaLine);
  driver.focus("files-editor");
  keyFor("files-editor", 3, "cmd", "shift");
  await until(() => visible("project-content-search") && visible(field).includes("focused=true"), "content search opened from the file editor");
  keyFor(field, 3, "cmd", "shift");
  await until(() => !has(field) && shown("files-editor", beta), "the same shortcut closed content search");
  driver.menuItem("Search Threads");
  await until(() => visible("thread-search").includes("focused=true"), "sidebar thread search still opens by menu");
  driver.sizeWindow(1600, 800);
  const initialWidth = driver.frame("composer")[2];
  driver.menuItem("Command Palette…");
  await until(() => visible(field).includes("focused=true"), "focused palette for a setting");
  await setField(field, "Chat width", () => Boolean(visible("command-palette-setting-appearance-chat-width")));
  keyFor(field, 36);
  await until(() => visible("settings-heading-appearance") && value("appearance-chat-width").includes("Comfortable"),
              "the palette opened the current Chat width setting");
  driver.pick("appearance-chat-width", "Full");
  dismiss("settings-close");
  await until(() => driver.frame("composer")[2] > initialWidth && shown("composer", secondText), "the same draft widened");
  driver.menuItem("Command Palette…");
  await until(() => visible(field).includes("focused=true"), "palette for scoped Model ID");
  await setField(field, "Model ID", () => Boolean(visible("command-palette-setting-model-id")));
  keyFor(field, 36);
  await until(() => visible("model-id").includes("focused=true") && shown("model-id", "file-search"),
              "the active project's Model ID field took focus");
  press("settings-nav-general");
  await until(() => visible("settings-close"), "General Settings");
  dismiss("settings-close");
  await until(() => shown("composer", secondText) && !has("settings-close"), "returned to the original linked draft");
  assert.equal(readFileSync(join(project, relative), "utf8"), alpha);
  assert.equal(readFileSync(join(linked, relative), "utf8"), beta);
  await quit();
  const threads = JSON.parse(readFileSync(index, "utf8")).projects[0].conversations;
  assert.equal(threads.find(t => t.id === firstID).composerText, firstText);
  assert.equal(threads.find(t => t.id === secondID).composerText, secondText);
  record("Go to file opened src/log.txt. Escape restored the parent command from both searches. Return on the same body-only query selected lines 3 and 164 in the two checkouts. Command-P opened the file picker, Command-Shift-F switched to a fresh content search, and the same shortcut closed it. Edit > Search Threads focused the sidebar. Both drafts and files retained their exact contents.");
  record("Return on the Chat width palette result opened Appearance. Selecting Full widened the linked draft's composer. The Model ID result focused the project model field, and closing Settings preserved the draft.");
}

export async function verifyPaletteMessage(driver, index, threadID, messageID, term) {
  const { press, visible, value, until, setField, keyFor } = driver;
  const other = index().projects.find(p => p.title === "Second Project");
  const draft = other.conversations.find(t => t.composerText);
  press("thread-row-" + draft.id);
  await until(() => value("composer").includes(JSON.stringify(draft.composerText)), "other project's unfinished draft");
  await setField("composer", draft.composerText);
  if (!visible("composer").includes("focused=true")) driver.focus("composer");
  keyFor("composer", 40, "cmd");
  await until(() => visible("command-palette-search").includes("focused=true"), "palette opened from a different thread");
  await setField("command-palette-search", term);
  const result = "command-palette-message-" + threadID + "-" + messageID;
  await until(() => visible("command-palette-in-messages") && visible(result), "Pi message result with its original entry ID");
  press(result);
  await until(() => value("thread-find-query").includes(JSON.stringify(term)) && value("thread-find-match-count").includes("1 of 1") &&
                    visible("transcript-message-" + messageID), "Find opened on the matching Pi message");
  assert.equal(index().projects.find(p => p.id === other.id).conversations.find(t => t.id === draft.id).composerText, draft.composerText);
  press("thread-find-close");
}

export async function verifyCommandPalette({ press, visible, value, setField, tree, until, menuItem, keyFor }, index, requestCount) {
  const before = index();
  const original = before.projects.find(project => project.id === before.selectedProject);
  const other = before.projects.find(project => project.title === "Second Project");
  const oldDraft = other.conversations.find(thread => thread.id === other.selectedConversation);
  const count = requestCount();
  const field = "command-palette-search";
  const opened = () => visible(field).includes("focused=true");
  const closed = () => !tree().includes('id="command-palette-search"');
  async function openMenu(action) {
    await until(() => {
      if (tree().includes('id="command-palette-search"')) return opened();
      menuItem("Command Palette…");
      return false;
    }, "open the palette for " + action);
  }
  await setField("composer", "Keep this palette test draft");
  keyFor("composer", 40, "cmd");
  await until(opened, "Command-K opens the palette");
  keyFor(field, 40, "cmd");
  await until(() => closed() && visible("composer").includes("focused=true"), "Command-K closes and restores composer focus");
  await openMenu("keyboard navigation");
  const chooserQuery = "New thread in...";
  await setField(field, chooserQuery);
  keyFor(field, 36);
  await until(() => visible("command-palette-back"), "project choices");
  keyFor(field, 51);
  await until(() => value(field).includes("value=" + JSON.stringify(chooserQuery)) && visible("command-palette-new-thread-in"), "empty Backspace restores the parent query");
  keyFor(field, 53);
  await until(() => closed() && value("composer").includes("Keep this palette test draft"), "Escape preserves the prior composer");
  assert.equal(index().selectedProject, original.id);
  await openMenu("the project chooser");
  press("command-palette-new-thread-in");
  await until(() => visible("command-palette-new-thread-project-" + other.id), "project in palette");
  await setField(field, other.title);
  keyFor(field, 125);
  keyFor(field, 126);
  keyFor(field, 36);
  await until(() => closed() && index().selectedProject === other.id && visible("composer").includes("focused=true"), "Return creates the chosen project's draft");
  const changed = index().projects.find(project => project.id === other.id);
  assert.equal(changed.conversations.length, other.conversations.length + 1);
  assert.equal(changed.conversations.find(thread => thread.id === oldDraft.id).composerText, oldDraft.composerText);
  assert.equal(requestCount(), count);
  await openMenu("Add project");
  press("command-palette-add-project");
  await until(() => visible("project-source-local"), "palette opens the project chooser");
  press("project-source-local");
  await until(() => visible("project-path").includes("focused=true"), "project picker focus");
  keyFor("project-path", 40, "cmd");
  assert(closed());
  assert(visible("project-path").includes("focused=true"));
  press("cancel-project");
  await until(() => !tree().includes('id="project-path"'), "cancel project picker");
  await openMenu("Go to home");
  press("command-palette-home");
  await until(() => index().selectedProject == null && tree().includes("What should we work on?"), "home from the palette");
  press("thread-row-" + original.selectedConversation);
  await until(() => index().selectedProject === original.id && value("composer").includes("Keep this palette test draft"), "return from Home to saved text");
  await openMenu("Search threads");
  press("command-palette-search-threads");
  await until(() => closed() && visible("thread-search").includes("focused=true"), "palette sends focus to sidebar search");
}
