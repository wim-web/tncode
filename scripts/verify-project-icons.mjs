import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, renameSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { images } from "./fixtures/attachments.mjs";

export async function verifyProjectIcons(driver, { root, git, launch, quit, record }) {
  const { until, visible, value, tree, press, dismiss, segment, selectPath } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const model = name => ({ provider: "local", model: name, endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 });
  const project = name => {
    const path = join(root, name, "Same name");
    mkdirSync(path, { recursive: true });
    const draft = { id: uuid(), isDraft: true, title: name, archived: false, composerText: "Keep " + name };
    return { id: uuid(), title: "Same name", path, allowEdits: false, modelOverride: model(name),
      selectedConversation: draft.id, conversations: [draft] };
  };
  const [first, second] = ["First", "Second"].map(project);
  const checkout = join(root, "Linked checkout");
  git(second.path, "init", "--template=", "-b", "main");
  git(second.path, "config", "core.hooksPath", "/dev/null");
  git(second.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
      "commit", "--allow-empty", "-m", "Fixture");
  git(second.path, "worktree", "add", "-b", "topic", checkout);
  second.conversations[0].location = { worktree: { path: checkout, base: "main" } };
  const generated = join(second.path, "Generated.png");
  const broken = join(second.path, "Broken.png");
  const png = Buffer.from(images.blue, "base64");
  writeFileSync(generated, png);
  writeFileSync(broken, "invalid fixture image");
  const indexPath = join(root, "workspace.json");
  const previous = join(root, "workspace.previous.json");
  const baseline = { projects: [first, second], selectedProject: second.id, welcomeCompleted: true,
    model: model("Workspace"), worktreesDirectory: root, newWorktreesStartFromRemote: false };
  writeFileSync(indexPath, JSON.stringify(baseline), { mode: 0o600 });

  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const icon = project => index().projects.find(saved => saved.id === project.id).icon;
  const row = project => "project-group-" + project.id;
  const preview = () => value("project-settings-icon-preview");
  const absent = id => !tree().includes('id="' + id + '"');
  const gone = id => until(() => absent(id), "dismissed " + id);
  const composerUnchanged = () => value("composer").includes('value="Keep Second"');
  async function overview(project) {
    press("project-group-settings-" + project.id);
    await until(() => value("project-settings-path").includes(project.path), "Overview for " + project.path);
  }
  async function closeOverview() {
    dismiss("settings-close");
    await until(() => absent("settings") && composerUnchanged(), "return to the selected draft");
  }
  async function chooseIcon(type) {
    press("project-settings-choose-icon");
    await until(() => visible("project-icon-save"), "project icon picker");
    if (type) segment("project-icon-type", type);
  }
  async function saveIcon(summary) {
    dismiss("project-icon-save");
    await until(() => absent("project-icon-save") && preview().includes(summary), "saved " + summary);
  }
  async function openFilePicker() {
    press("project-settings-choose-icon-file");
    await until(() => visible("open-panel"), "native icon file picker");
  }
  async function importFile(path) {
    await openFilePicker();
    await until(() => { selectPath(path); return true; }, "select " + path + " in the native picker");
    await until(() => visible("OKButton").includes("enabled=true"), "selected file can be opened");
    dismiss("OKButton");
    await gone("open-panel");
  }

  await launch("model-settings", root, undefined, true);
  press("thread-filters");
  await until(() => visible("group-threads-by-project"), "thread filters");
  if (value("group-threads-by-project").includes("value=0")) press("group-threads-by-project");
  dismiss("close-thread-filters");
  await until(() => visible(row(first)) && visible(row(second)), "both same-name project groups");
  await overview(first);
  await chooseIcon();
  press("project-icon-symbol-globe");
  press("project-icon-color-blue");
  await saveIcon("Globe, Blue");
  assert.deepEqual(icon(first), { symbol: { _0: "globe", _1: "blue" } });
  assert.equal(icon(second), undefined);
  assert.equal(index().selectedProject, second.id);

  await chooseIcon("Monogram");
  await until(() => value("project-icon-letters").includes('value="SA"'), "suggested letters for Same name");
  press("project-icon-color-purple");
  await saveIcon("SA, Purple");
  assert.deepEqual(icon(first), { monogram: { _0: "SA", _1: "purple" } });

  await chooseIcon("Emoji");
  await until(() => visible("project-icon-emoji-🚀"), "rocket emoji");
  press("project-icon-emoji-🚀");
  await saveIcon("🚀");
  assert.deepEqual(icon(first), { emoji: { _0: "🚀" } });
  record("Project Overview saved a symbol, the suggested monogram, and an emoji to the clicked same-name project UUID.");

  const before = readFileSync(indexPath);
  await chooseIcon("Monogram");
  await until(() => visible("project-icon-letters"), "monogram mode before Cancel");
  dismiss("project-icon-cancel");
  await gone("project-icon-save");
  assert.deepEqual(readFileSync(indexPath), before);
  assert.match(preview(), /🚀/);

  const savedPrevious = previous + ".fixture-backup";
  renameSync(previous, savedPrevious);
  mkdirSync(previous);
  try {
    press("project-settings-reset-icon");
    await until(() => visible("project-settings-icon-error"), "failed icon save");
    assert.deepEqual(readFileSync(indexPath), before);
    assert.match(preview(), /🚀/);
  } finally {
    rmdirSync(previous);
    renameSync(savedPrevious, previous);
  }
  await closeOverview();
  await overview(second);
  await openFilePicker();
  dismiss("CancelButton");
  await gone("open-panel");
  assert.deepEqual(readFileSync(indexPath), before);
  assert.match(preview(), /Default project icon/);
  await importFile(broken);
  await until(() => visible("project-settings-icon-error"), "invalid image error");
  assert.deepEqual(readFileSync(indexPath), before);
  assert.match(preview(), /Default project icon/);
  record("Cancel in both pickers, invalid image import, and a failed store write preserved the previous icons and index bytes.");

  await importFile(generated);
  await until(() => preview().includes("Imported image") && icon(second)?.image?.png, "imported fixture PNG");
  const imported = icon(second);
  const normalized = Buffer.from(imported.image.png, "base64");
  assert.deepEqual(normalized.subarray(0, 8), png.subarray(0, 8));
  assert.deepEqual(normalized.subarray(16, 24), png.subarray(16, 24));
  unlinkSync(generated);
  await closeOverview();
  await until(() => value(row(second)).includes("Imported image"), "imported icon in the sidebar");
  await quit();
  await launch("model-settings", root, undefined, true);
  await until(() => value(row(first)).includes("🚀") && value(row(second)).includes("Imported image") &&
    composerUnchanged(), "both persisted icons and the selected draft without the source PNG");

  await overview(first);
  press("project-settings-reset-icon");
  await until(() => preview().includes("Default project icon") && icon(first) === undefined, "reset the first project's icon");
  await closeOverview();
  await quit();
  await launch("model-settings", root, undefined, true);
  await until(() => visible(row(first)) && value(row(second)).includes("Imported image") && composerUnchanged(),
              "reset and imported icons after relaunch");
  await overview(first);
  assert.match(preview(), /Default project icon/);
  assert(absent("project-settings-reset-icon"));
  const saved = index();
  assert.equal(saved.selectedProject, second.id);
  assert.equal(icon(first), undefined);
  assert.deepEqual(icon(second), imported);
  for (const project of [first, second]) {
    const stored = saved.projects.find(entry => entry.id === project.id);
    assert.equal(stored.selectedConversation, project.selectedConversation);
    assert.deepEqual(stored.conversations, project.conversations);
    assert.equal(stored.modelOverride.model, project.modelOverride.model);
  }
  assert.equal(saved.model.model, baseline.model.model);
  assert.equal(saved.worktreesDirectory, baseline.worktreesDirectory);
  assert.equal(saved.newWorktreesStartFromRemote, false);
  await closeOverview();
  await quit();
  record("The system picker imported the generated PNG and the icon survived relaunch without the source. Reset persisted on the other project, with both drafts, model choices, checkout settings, and selection preserved.");
}
