import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyProjectSettings(driver, { root, git, launch, quit, record }) {
  const { until, press, dismiss, visible, value, tree, showMenu, checkCopy, setField, menuItem } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const model = name => ({ provider: "local", model: name, endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 });
  const makeProject = (folder, name, composerText) => {
    const path = join(root, folder, "Project");
    mkdirSync(path, { recursive: true });
    const draft = { id: uuid(), title: name, isDraft: true, archived: false, composerText };
    return { id: uuid(), title: "Project", path, modelOverride: model(name),
      selectedConversation: draft.id, conversations: [draft] };
  };
  const alpha = makeProject("first", "first-model", "Other unsent draft");
  const beta = makeProject("second", "second-model", "Keep the linked draft");
  const checkout = join(root, "Linked checkout");
  git(beta.path, "init", "--template=", "-b", "main");
  git(beta.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
      "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Fixture");
  git(beta.path, "worktree", "add", "-b", "topic/linked", checkout);
  beta.conversations[0].location = { worktree: { path: checkout, base: "main" } };
  const indexPath = join(root, "workspace.json");
  writeFileSync(indexPath, JSON.stringify({ selectedProject: beta.id, welcomeCompleted: true,
    model: model("workspace-model"), projects: [alpha, beta] }), { mode: 0o600 });
  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const current = () => index().selectedProject === beta.id &&
    index().projects.find(p => p.id === beta.id).selectedConversation === beta.selectedConversation &&
    value("composer").includes('value="Keep the linked draft"');
  const has = id => tree().includes('id="' + id + '"');
  const folder = project => "project-group-" + project.id;
  const overview = async project => {
    await until(() => visible("settings-heading-project") && value("project-settings-path").includes(project.path),
                "overview for " + project.path);
  };
  const context = async (row, action) => {
    await until(() => { showMenu(row); return true; }, "open the target context menu");
    await until(() => visible(action), action);
    dismiss(action);
  };
  const done = async () => {
    dismiss("settings-close");
    await until(() => !has("settings-search") && current(), "same selected draft after settings");
  };

  await launch("model-settings", root);
  await until(current, "active draft in the linked checkout");
  press("thread-filters");
  await until(() => visible("group-threads-by-project"), "thread filters");
  if (value("group-threads-by-project").includes("value=0")) press("group-threads-by-project");
  dismiss("close-thread-filters");
  await until(() => visible(folder(alpha)) && visible(folder(beta)), "both same-name project folders");

  for (const project of [alpha, beta]) {
    await context(folder(project), "project-copy-path");
    await until(() => checkCopy(project.path) && current(), "copied the folder's registered path");
  }
  await context(folder(beta), "project-settings");
  await overview(beta);
  await until(() => visible("project-settings-checkout-" + checkout), "registered linked Git checkout");
  await done();
  await context(folder(alpha), "project-settings");
  await overview(alpha);
  await done();

  await context("thread-row-" + alpha.selectedConversation, "draft-project-settings");
  await overview(alpha);
  press("project-settings-model");
  await until(() => value("model-id").includes("first-model"), "scoped model of the clicked draft");
  await setField("model-id", "updated-first-model");
  press("settings-nav-project");
  await overview(alpha);
  press("project-settings-model");
  await until(() => value("model-id").includes("updated-first-model"), "unsaved edit survived overview navigation");
  dismiss("save-settings");
  await until(() => !has("settings-search") && current(), "model save returned to the selected draft");
  const saved = index();
  assert.equal(saved.projects[0].modelOverride.model, "updated-first-model");
  assert.equal(saved.projects[0].conversations[0].composerText, "Other unsent draft");
  assert.equal(saved.projects[1].modelOverride.model, "second-model");
  assert.equal(saved.model.model, "workspace-model");

  press("thread-filters");
  const gear = "project-filter-settings-" + alpha.id;
  await until(() => visible(gear), "settings for the other folder in the filter");
  press(gear);
  await overview(alpha);
  await done();
  assert(!index().projects.some(p => p.inSidebarScope));
  await until(() => { menuItem("Command Palette…"); return true; }, "open Command Palette");
  await until(() => visible("command-palette-search"), "command palette search");
  await setField("command-palette-search", "Project settings");
  const palette = "command-palette-project-settings-" + beta.id;
  await until(() => visible(palette), "settings for the active project in the palette");
  dismiss(palette);
  await overview(beta);
  await done();

  renameSync(alpha.path, alpha.path + " unavailable");
  await context(folder(alpha), "project-copy-path");
  await until(() => tree().includes("The project folder is no longer available.") && checkCopy(beta.path),
              "missing folder reported without replacing the previous copy");
  await context(folder(alpha), "project-settings");
  await overview(alpha);
  await until(() => visible("project-settings-folder-unavailable"), "unavailable folder remains identifiable");
  await done();
  await quit();
  record("Both same-name folders copied their own registered path. The sidebar, a nonactive draft, the filter and the palette reached the expected overview. A linked checkout stayed selected with its unsent text while an edit to the other project's model survived pane navigation and saved to that project only. An unavailable folder kept the previous copy.");
}
