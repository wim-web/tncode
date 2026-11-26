import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyDraftProjects(driver, { root, launch, quit }) {
  const { press, visible, value, tree, until, setField, keyFor } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const text = "Take the Beta note with this draft.";
  const blueNote = "Beta の記録\n";
  const newProject = join(root, "Registered during draft");
  const register = (name, draft) => {
    const id = uuid(), thread = uuid(), path = join(root, name);
    mkdirSync(path, { recursive: true });
    return { id, path, title: name, allowEdits: false, selectedConversation: thread,
      conversations: [{ id: thread, archived: false, title: name + " draft", isDraft: true, composerText: draft }] };
  };
  const alpha = register("Alpha", ""), beta = register("Café Beta", text);
  mkdirSync(newProject);
  const alphaNote = join(alpha.path, "notes.txt"), betaNote = join(beta.path, "notes.txt");
  writeFileSync(alphaNote, "Alpha notes\n");
  writeFileSync(betaNote, blueNote);
  const attachment = { id: uuid(), name: "notes.txt", payload: { data: readFileSync(betaNote).toString("base64"), mimeType: "text/plain" } };
  beta.conversations[0].composerAttachments = [attachment];
  const store = join(root, "workspace.json");
  writeFileSync(store, JSON.stringify({
    projects: [alpha, beta], selectedProject: beta.id, welcomeCompleted: true,
    model: { provider: "local", endpoint: "http://127.0.0.1:1/v1", model: "local-draft-fixture", contextWindow: 8192 },
  }), { mode: 0o600 });
  const index = () => JSON.parse(readFileSync(store, "utf8"));
  const selected = () => {
    const state = index();
    const project = state.projects.find(p => p.id === state.selectedProject);
    return { project, thread: project?.conversations.find(t => t.id === project.selectedConversation) };
  };
  const betaThread = beta.selectedConversation;
  const composer = expected => value("composer").includes("value=" + JSON.stringify(expected));
  async function newDraft(id) {
    press("new-conversation");
    await until(() => visible("new-thread-project-" + id), "new thread project options");
    press("new-thread-project-" + id);
    await until(() => selected().project.id === id && composer(""), "empty draft in selected project");
  }
  async function openChooser() {
    press("draft-project-trigger");
    await until(() => visible("draft-project-search").includes("focused=true"), "published draft project picker");
  }

  await launch("model-settings", root);
  await until(() => composer(text) && visible("remove-attachment-" + attachment.id), "selected Beta draft and saved note");
  await newDraft(beta.id);
  assert.notEqual(selected().thread.id, betaThread);
  await newDraft(alpha.id);
  const blank = selected().thread.id;
  await openChooser();
  await setField("draft-project-search", "not-a-fixture-project");
  await until(() => visible("draft-project-no-results"), "no matching projects");
  keyFor("draft-project-search", 53);
  await until(() => !tree().includes('id="draft-project-search"') && selected().thread.id === blank, "Escape without changing the blank draft");
  await openChooser();
  await setField("draft-project-search", "cafe beta");
  await until(() => visible("draft-project-" + beta.id), "accent-insensitive project match");
  keyFor("draft-project-search", 36);
  const sameDraft = () => {
    const { thread } = selected();
    return thread?.id === betaThread && thread.composerText === text && thread.composerAttachments?.[0]?.id === attachment.id &&
           Buffer.from(thread.composerAttachments[0].payload.data, "base64").toString() === blueNote;
  };
  await until(() => selected().project.id === beta.id && sameDraft() && composer(text), "existing populated Beta draft");
  await openChooser();
  press("draft-project-" + alpha.id);
  await until(() => selected().project.id === alpha.id && sameDraft() && composer(text), "populated draft moved to Alpha");
  await openChooser();
  press("draft-no-project");
  const scratch = await until(() => selected().project.kind === "scratch" && sameDraft() && selected().project, "same draft with no project");
  assert.equal(realpathSync(scratch.path), realpathSync(join(root, "scratch", scratch.id)));

  for (const cancel of [true, false]) {
    await openChooser();
    press("draft-add-project");
    await until(() => visible("project-source-local"), "add-project sources from the draft");
    press("project-source-local");
    await until(() => visible("project-path"), "local folder path");
    await setField("project-path", newProject);
    press(cancel ? "cancel-project" : "confirm-project");
    await until(() => !tree().includes('id="project-path"') && sameDraft() && visible("composer").includes("focused=true"),
                "focus and same draft after project registration or cancellation");
    assert.equal(index().projects.some(p => p.path === newProject), !cancel);
    assert.equal(selected().project.id, scratch.id);
  }
  await quit();
  await launch("model-settings", root);
  await until(() => composer(text) && selected().project.id === scratch.id && sameDraft(), "moved draft after relaunch");
  assert.equal(index().projects.flatMap(p => p.conversations).filter(t => t.id === betaThread).length, 1);
  assert.equal(readFileSync(alphaNote, "utf8"), "Alpha notes\n");
  assert.equal(readFileSync(betaNote, "utf8"), blueNote);
  await quit();
}
