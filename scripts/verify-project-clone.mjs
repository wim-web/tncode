import assert from "node:assert/strict";
import { mkdirSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { verifyMovedFileDraft } from "./verify-moved-file-draft.mjs";

export async function verifyProjectClone(driver, { directory, git, index, quit, launch, requestCount, verifyMoves = false }) {
  const { press, value, visible, tree, setField, until } = driver;
  const source = join(directory, "Clone upstream");
  const remote = join(directory, "Sample remote.git");
  const occupied = join(directory, "Occupied clone");
  const destination = join(directory, "New parent", "New child", "Cloned project");
  for (const path of [source, occupied]) mkdirSync(path);
  writeFileSync(join(occupied, "keep.txt"), "Keep this directory\n");
  git(source, "init", "--template=", "-b", "fixture-main");
  writeFileSync(join(source, "README.md"), "Clone this exact revision.\n");
  git(source, "add", "--", "README.md");
  git(source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
      "-c", "core.hooksPath=/dev/null", "commit", "-m", "Fixture revision");
  git(directory, "clone", "--bare", "--no-local", "--template=", "--", source, remote);
  const remoteURL = pathToFileURL(remote).href;
  const expectedHead = git(source, "rev-parse", "HEAD");
  const previous = index();
  const origin = previous.projects.find(p => p.id === previous.selectedProject);
  const count = requestCount();
  async function openCloneDialog() {
    press("open-project");
    await until(() => visible("project-source-clone"), "Git URL project source");
    press("project-source-clone");
    await until(() => visible("project-clone-url"), "Git URL field");
    await setField("project-clone-url", remoteURL);
    press("confirm-project");
    await until(() => value("project-clone-destination").includes("Sample remote"), "suggested clone name");
  }
  async function finishClone(folder) {
    await setField("project-clone-destination", folder);
    press("confirm-project");
    return until(() => {
      const state = index();
      const project = state.projects.find(p => p.id === state.selectedProject);
      return project && realpathSync(project.path) === realpathSync(folder) &&
             !tree().includes('id="project-clone-destination"') && visible("composer").includes("focused=true") && project;
    }, "cloned project and focused draft");
  }
  await openCloneDialog();
  press("back-project-source");
  await until(() => value("project-clone-url").includes(remoteURL), "Back retains the repository URL");
  press("confirm-project");
  await setField("project-clone-destination", occupied);
  press("confirm-project");
  await until(() => visible("project-path-error"), "existing clone destination rejected");
  assert.equal(readFileSync(join(occupied, "keep.txt"), "utf8"), "Keep this directory\n");
  assert.equal(index().selectedProject, origin.id);
  assert.equal(index().projects.length, previous.projects.length);
  const added = await finishClone(destination);
  assert.equal(index().selectedProject, added.id);
  assert.equal(git(destination, "rev-parse", "HEAD"), expectedHead);
  assert.equal(git(destination, "branch", "--show-current"), "fixture-main");
  assert.equal(git(destination, "remote", "get-url", "origin"), remoteURL);
  assert.equal(readFileSync(join(destination, "README.md"), "utf8"), "Clone this exact revision.\n");
  assert(!readdirSync(directory).some(n => n.startsWith(".tncode-")));
  const draft = "Keep the cloned project draft";
  await setField("composer", draft);
  await until(() => index().projects.find(p => p.id === added.id).conversations.some(t => t.id === added.selectedConversation &&
                     t.composerText === draft), "saved cloned project draft");
  await quit();
  await launch();
  await until(() => value("composer").includes(draft), "cloned project draft after relaunch");
  const restored = index().projects.find(p => p.id === index().selectedProject);
  assert.equal(restored.id, added.id);
  assert.equal(restored.selectedConversation, added.selectedConversation);
  assert.equal(requestCount(), count);
  if (verifyMoves) {
    const conversation = () => index().projects.find(p => p.id === added.id).conversations.find(t => t.id === added.selectedConversation);
    await verifyMovedFileDraft(driver, { directory, repository: destination, git, conversation });
  }
  const prepared = join(directory, "Already registered empty folder");
  mkdirSync(prepared, { mode: 0o750 });
  const before = statSync(prepared, { bigint: true });
  press("open-project");
  await until(() => visible("project-source-local"), "local registration of the empty folder");
  press("project-source-local");
  await until(() => visible("project-path"), "empty project path field");
  await setField("project-path", prepared);
  press("confirm-project");
  const existing = await until(() => index().projects.find(p => realpathSync(p.path) === realpathSync(prepared)) &&
                               visible("composer").includes("focused=true") && index().selectedProject, "registered empty project");
  const earlier = "Existing project draft before cloning";
  await setField("composer", earlier);
  const priorID = await until(() => index().projects.find(p => p.id === existing).conversations.find(t => t.composerText === earlier)?.id,
                              "draft of pre-existing empty folder");
  assert.deepEqual(readdirSync(prepared), []);
  press("thread-row-" + origin.selectedConversation);
  await until(() => index().selectedProject === origin.id, "original project before cloning into another registered folder");
  await openCloneDialog();
  const reused = await finishClone(prepared);
  assert.equal(reused.id, existing);
  assert.equal(reused.conversations.find(t => t.id === priorID)?.composerText, earlier);
  assert.equal(index().projects.length, previous.projects.length + 2);
  assert.equal(statSync(prepared, { bigint: true }).ino, before.ino);
  assert.equal(statSync(prepared, { bigint: true }).mode, before.mode);
  assert.equal(git(prepared, "rev-parse", "HEAD"), expectedHead);
  assert.equal(readFileSync(join(prepared, "README.md"), "utf8"), "Clone this exact revision.\n");
  assert.equal(requestCount(), count);
  press("thread-row-" + origin.selectedConversation);
  await until(() => index().selectedProject === origin.id, "return to original project");
}
