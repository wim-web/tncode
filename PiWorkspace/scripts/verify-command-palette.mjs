import assert from "node:assert/strict";

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
