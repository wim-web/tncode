import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const model = { provider: "local", model: "unused-route-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 };
const uuid = () => randomUUID().toUpperCase();

export async function verifyStartupRetry(driver, { root, launch, quit, record, background = false }) {
  const { press, visible, value, until, setField } = driver;
  const projects = ["Current", "More recent"].map((title, i) => {
    const path = join(root, title), id = uuid(), threadID = uuid();
    mkdirSync(path, { recursive: true });
    const thread = { id: threadID, title: title + " thread", archived: false, isDraft: i === 1 };
    if (i === 1) thread.composerText = "Keep this other draft.";
    return { id, title, path, allowEdits: false, createdAt: i + 1, selectedConversation: threadID, conversations: [thread] };
  });
  const [current, recent] = projects;
  const indexPath = join(root, "workspace.json"), blocker = join(root, "workspace.previous.json");
  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  mkdirSync(blocker);
  writeFileSync(join(blocker, "obstruction"), "fixture", { mode: 0o600 });
  writeFileSync(indexPath, JSON.stringify({ welcomeCompleted: true, projects, selectedProject: current.id, model }), { mode: 0o600 });
  const original = readFileSync(indexPath);
  await launch("startup-draft-retry", root);
  assert(value("startup-draft-error").includes("Couldn’t start a new thread"));
  press("startup-draft-retry");
  await until(() => visible("startup-draft-retry").includes("enabled=true"), "failed draft is still retryable");
  assert.deepEqual(readFileSync(indexPath), original);
  renameSync(blocker, join(root, "repaired-blocker"));
  driver.dismiss("startup-draft-retry");
  await until(() => index().selectedProject === recent.id && visible("composer").includes(background ? "enabled=true" : "focused=true"),
    "repair opens an editable draft in the originally intended project");
  const selected = index().projects.find(project => project.id === recent.id);
  const newID = selected.selectedConversation;
  assert.notEqual(newID, recent.selectedConversation);
  assert.equal(selected.conversations.length, 2);
  assert.equal(selected.conversations.find(t => t.id === recent.selectedConversation).composerText, "Keep this other draft.");
  await setField("composer", "Typed after retry.");
  await quit();
  const saved = readFileSync(indexPath);
  await launch("composer", root);
  await until(() => value("composer").includes("Typed after retry."), "normal launch restores the repaired thread's text");
  assert.deepEqual(readFileSync(indexPath), saved);
  assert.equal(index().projects.find(p => p.id === recent.id).selectedConversation, newID);
  assert.equal(index().projects.find(p => p.id === current.id).selectedConversation, current.selectedConversation);
  await quit();
  record("Retry while the backup was blocked preserved every index byte. Repair opened exactly one draft in the newer project. Its UUID and edited text survived relaunch alongside the pre-existing drafts.");
}

export async function verifyNewThreadRoutes(driver, context) {
  const { launch, quit, record } = context;
  const { press, dismiss, focus, visible, tree, until, keyFor, setField, menuItem } = driver;
  const root = join(context.root, "shortcuts");
  const alpha = join(root, "Alpha"), beta = join(root, "Beta");
  for (const path of [alpha, beta]) mkdirSync(path, { recursive: true });
  const indexPath = join(root, "workspace.json");
  writeFileSync(indexPath, JSON.stringify({ welcomeCompleted: true, projects: [], model }), { mode: 0o600 });
  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const active = () => { const w = index(); return w.projects.find(p => p.id === w.selectedProject); };
  const focused = id => visible(id).includes("focused=true");
  const has = id => tree().includes('id="' + id + '"');
  const field = "command-palette-search";
  const regular = () => index().projects.filter(p => p.kind !== "scratch");
  const keyN = [45, "cmd"], keyChoose = [31, "cmd", "shift"], keyLocal = [45, "cmd", "shift"], keyScratch = [45, "cmd", "opt"];
  async function openFolder(path, viaNew = false) {
    press("open-project");
    if (viaNew) {
      press("project-source-new");
      await until(() => visible("project-source-existing"), "Add existing project on the New project form");
      press("project-source-existing");
    }
    await until(() => visible("project-source-local"), "select a project source");
    press("project-source-local");
    await setField("project-path", path);
    dismiss("confirm-project");
    await until(() => realpathSync(active().path) === realpathSync(path) && focused("composer"), "draft in the registered folder");
    return active().id;
  }
  async function openFromComposer(keys) {
    focus("composer");
    keyFor("composer", ...keys);
  }
  async function fill(text) {
    await setField("composer", text);
    await until(() => active().conversations.find(t => t.id === active().selectedConversation)?.composerText === text, "saved " + text);
  }
  await launch("empty-open-project", root);
  for (const keys of [keyN, keyChoose, keyLocal]) {
    if (!focused("thread-search")) focus("thread-search");
    keyFor("thread-search", ...keys);
    await until(() => focused(field) && visible("command-palette-no-project"), "No project choice on the empty workspace");
    keyFor(field, 53);
    await until(() => !has(field) && has("empty-open-project"), "Escape restored Home");
    assert.equal(index().projects.length, 0);
  }
  record("With no project, Command-N, Command-Shift-O and Command-Shift-N opened the chooser. Escape returned Home with no new thread.");
  const alphaID = await openFolder(alpha, true);
  const first = active().selectedConversation;
  await fill("Keep Alpha's first draft.");
  await openFromComposer(keyN);
  await until(() => active().id === alphaID && active().selectedConversation !== first && focused("composer"), "Command-N with one project");
  const second = active().selectedConversation;
  await openFromComposer(keyChoose);
  await until(() => focused("composer") && !has(field), "Command-Shift-O reuses the empty draft with one project");
  assert.equal(active().selectedConversation, second);
  assert.equal(await openFolder(alpha, true), alphaID);
  assert.equal(regular().length, 1);
  record("With one project the two chooser shortcuts used Alpha. Add existing project reopened the same registered ID.");
  const betaID = await openFolder(beta);
  const originalBeta = active().selectedConversation;
  await fill("Keep Beta's first draft.");
  const beforeCancel = readFileSync(indexPath);
  for (const keys of [keyN, keyChoose]) {
    await openFromComposer(keys);
    await until(() => focused(field) && visible("command-palette-new-thread-project-" + alphaID) &&
      visible("command-palette-new-thread-project-" + betaID), "both projects appear for the new-thread shortcut");
    keyFor(field, 53);
    await until(() => !has(field) && focused("composer"), "canceling returned focus to Beta's composer");
    assert.deepEqual(readFileSync(indexPath), beforeCancel);
  }
  record("With two projects, both shortcuts offered Alpha and Beta. Escape returned to the original composer with byte-identical saved state.");
  menuItem("New Thread");
  await until(() => focused(field), "File menu opens the project chooser");
  dismiss("command-palette-new-thread-project-" + alphaID);
  await until(() => active().id === alphaID && active().selectedConversation === second && focused("composer"), "File menu selected Alpha's draft");
  await fill("Keep the prior shortcut draft.");
  press("thread-project-new-thread");
  await until(() => active().id === alphaID && active().selectedConversation !== second && focused("composer"), "header starts a draft in Alpha");
  const header = active().selectedConversation;
  await fill("Keep the header draft.");
  await openFromComposer([40, "cmd"]);
  await until(() => visible("command-palette-new-thread-in-context-" + alphaID), "contextual Alpha action in the palette");
  dismiss("command-palette-new-thread-in-context-" + alphaID);
  await until(() => active().id === alphaID && active().selectedConversation !== header && focused("composer"), "palette opened a separate draft");
  const lastAlpha = active().selectedConversation;
  press("new-conversation");
  await until(() => visible("new-thread-project-" + alphaID), "sidebar New Thread sheet in the selected empty draft");
  dismiss("new-thread-project-" + alphaID);
  await until(() => !has("new-thread-project-" + alphaID) && active().selectedConversation === lastAlpha, "the sheet reused the same draft");
  await until(() => focused("composer"), "chosen composer owns keyboard focus after the sheet closed");
  keyFor("composer", 7);
  await until(() => driver.value("composer").includes('value="x"') &&
    active().conversations.find(t => t.id === lastAlpha)?.composerText === "x", "ordinary X reached the chosen draft without refocusing");
  assert.deepEqual(driver.selection("composer"), [1, 0]);
  const beforeUndo = index().projects.flatMap(p => p.conversations.map(t => t.id)).sort();
  keyFor("composer", 6, "cmd");
  await until(() => driver.value("composer").includes('value=""') && !active().conversations.find(t => t.id === lastAlpha)?.composerText,
    "Undo returned this same draft to its original contents");
  assert.deepEqual(index().projects.flatMap(p => p.conversations.map(t => t.id)).sort(), beforeUndo);
  record("The sidebar New Thread sheet reused the current project's empty draft. The composer reported keyboard focus after the sheet closed. A key sent to the app inserted x, placed the caret at 1, and saved it to the same draft. Undo restored the empty text.");
  await openFromComposer(keyScratch);
  await until(() => active().kind === "scratch" && focused("composer"), "Command-Option-N opened a private scratch");
  const scratchID = active().id;
  assert(realpathSync(active().path).startsWith(realpathSync(root) + "/"));
  await fill("Keep the private draft.");
  await openFromComposer(keyLocal);
  await until(() => active().id === alphaID && active().selectedConversation === lastAlpha && focused("composer"), "Command-Shift-N used the last registered project");
  const preserved = index();
  press("toggle-terminal");
  await until(() => focused("thread-terminal"), "the fixture terminal has keyboard focus");
  for (const keys of [keyN, keyChoose, keyLocal, keyScratch]) {
    keyFor("thread-terminal", ...keys);
    await until(() => focused("thread-terminal") && !has(field), "terminal retains its shortcut");
  }
  assert.deepEqual(index(), preserved);
  press("hide-terminal");
  menuItem("New Thread Without a Project");
  await until(() => active().kind === "scratch" && active().id !== scratchID, "File menu starts one more private scratch");
  const saved = index();
  assert.equal(saved.projects.filter(p => p.kind === "scratch").length, 2);
  assert.equal(saved.projects.find(p => p.id === scratchID).conversations[0].composerText, "Keep the private draft.");
  assert.equal(saved.projects.find(p => p.id === alphaID).conversations.find(t => t.id === first).composerText, "Keep Alpha's first draft.");
  assert.equal(saved.projects.find(p => p.id === betaID).conversations.find(t => t.id === originalBeta).composerText, "Keep Beta's first draft.");
  await quit();
  record("With zero, one and two projects the default keys chose the intended picker or local draft. Header, palette and File menu reused the right project. Scratch and last-used routing preserved existing text and IDs. The terminal retained all four shortcuts.");
  await verifyStartupRetry(driver, { ...context, root: join(context.root, "startup-retry") });
}
