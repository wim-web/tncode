import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { seedPaletteMessageHistory } from "./fixtures/palette-message-history.mjs";

function setUpMirror(root, gitConfigHome, git, remote, bare) {
  mkdirSync(join(gitConfigHome, "git"), { recursive: true });
  const config = join(gitConfigHome, "git", "config");
  git(root, "config", "--file", config, "url." + pathToFileURL(bare).href + ".insteadOf", remote);
  git(root, "config", "--file", config, "http.proxy", "http://127.0.0.1:1");
  const resolved = execFileSync("/usr/bin/git", ["-C", root, "ls-remote", "--get-url", remote], {
    encoding: "utf8", env: { ...process.env, XDG_CONFIG_HOME: gitConfigHome },
  }).trim();
  assert.equal(resolved, pathToFileURL(bare).href);
}

export async function verifyPromptLinks(driver, { root, gitConfigHome, git, endpoint, key, credential, removeFixtureCredential, launch, quit, record }) {
  const { press, dismiss, openPromptLink, visible, value, setField, tree, until } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const project = (title, composerText) => {
    const path = join(root, title), id = uuid(), selectedConversation = uuid();
    mkdirSync(path, { recursive: true });
    git(path, "init", "--template=", "-b", "main");
    git(path, "config", "core.hooksPath", "/dev/null");
    return { id, title, path, allowEdits: false, selectedConversation, conversations: [
      { id: selectedConversation, title: title + " draft", isDraft: true, archived: false, composerText },
    ] };
  };
  const current = project("Current", "Keep the original 🌱"), match = project("Match", "Keep the other draft.");
  const slug = "fixture/shared-prompt", newSlug = "fixture/prompt-to-clone";
  git(current.path, "remote", "add", "origin", "https://github.com/other-owner/shared-prompt.git");
  git(match.path, "remote", "add", "origin", "https://github.com/" + slug + ".git");
  writeFileSync(join(match.path, "file.txt"), "local clone marker\n");
  git(match.path, "add", "file.txt");
  git(match.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Local marker");
  const remote = "https://github.com/" + newSlug + ".git", bare = join(root, "local-remote.git");
  git(root, "clone", "--bare", "--no-local", "--template=", "--", match.path, bare);
  setUpMirror(root, gitConfigHome, git, remote, bare);
  const indexPath = join(root, "workspace.json"), clone = join(root, "Chosen clone");
  writeFileSync(indexPath, JSON.stringify({ selectedProject: current.id, welcomeCompleted: true, addProjectBaseDirectory: root,
    projects: [current, match], model: { provider: "local", model: "prompt-link-fixture", endpoint, contextWindow: 8192 } }), { mode: 0o600 });
  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const active = () => { const state = index(); return state.projects.find(p => p.id === state.selectedProject); };
  const draft = () => { const p = active(); return p.conversations.find(t => t.id === p.selectedConversation); };
  const count = () => index().projects.reduce((n, p) => n + p.conversations.length, 0);
  const url = fields => "tncode://new/v1?" + new URLSearchParams(fields);
  const has = id => tree().includes('id="' + id + '"');
  const restored = id => !has("prompt-link-title") && !has("project-clone-destination") && draft().id === id;
  const text = "Compare the totals 🌱 + 1", link = url({ prompt: text, repo: slug });
  const cloneText = "Keep this draft in the clone.", cloneLink = url({ prompt: cloneText, repo: newSlug });
  async function beginClone() {
    openPromptLink(cloneLink);
    await until(() => visible("prompt-link-find-project"), "review the clone link");
    press("prompt-link-find-project");
    await until(() => visible("prompt-link-no-match") && visible("prompt-link-clone"), "no registered project with that remote");
    press("prompt-link-clone");
    await until(() => value("prompt-link-clone-remote").includes(remote), "prefilled repository in the clone form");
    await setField("project-clone-destination", clone);
  }
  async function findMatch() {
    openPromptLink(link);
    await until(() => visible("prompt-link-find-project"), "explicit matching action");
    press("prompt-link-find-project");
    await until(() => visible("prompt-link-project-" + match.id), "registered matching repository");
    assert(!has("prompt-link-project-" + current.id));
  }
  try {
    credential("--set-api-key-from-stdin", key, root);
    await launch("composer", root);
    await until(() => value("composer").includes(current.conversations[0].composerText), "original unsent draft");
    const before = readFileSync(indexPath);
    openPromptLink(link);
    await until(() => value("prompt-link-preview").includes(text), "accurate decoded prompt in the review sheet");
    openPromptLink(link);
    assert.deepEqual(readFileSync(indexPath), before);
    dismiss("cancel-prompt-link");
    await until(() => restored(current.selectedConversation), "cancelled review");
    openPromptLink(url({ repo: slug }));
    await until(() => value("thread-link-error").includes("has no prompt"), "missing prompt message");
    assert.deepEqual(readFileSync(indexPath), before);
    await findMatch();
    git(match.path, "remote", "set-url", "origin", "https://github.com/fixture/replaced.git");
    try {
      press("prompt-link-project-" + match.id);
      await until(() => draft().id !== current.selectedConversation || has("prompt-link-action-error") ||
        has("prompt-link-no-match"), "outcome of selecting a changed repository");
      assert.equal(draft().id, current.selectedConversation, "A stale repository choice created a draft in the changed checkout.");
      assert.deepEqual(readFileSync(indexPath), before);
    } finally {
      git(match.path, "remote", "set-url", "origin", "https://github.com/" + slug + ".git");
    }
    dismiss("cancel-prompt-link");
    await until(() => restored(current.selectedConversation), "return from the changed repository");
    await findMatch();
    press("prompt-link-project-" + match.id);
    await until(() => active().id === match.id && count() === 3 && value("composer").includes(text), "one new draft in Match");
    const matchedID = draft().id;
    openPromptLink(link);
    await until(() => visible("reopen-prompt-link") && count() === 3, "repeat delivery requires a choice");
    press("reopen-prompt-link");
    await until(() => visible("prompt-link-no-project"), "reopened review choices");
    press("prompt-link-no-project");
    await until(() => active().kind === "scratch" && count() === 4 && value("composer").includes(text), "separate scratch draft");
    const scratchID = draft().id, scratchBytes = readFileSync(indexPath);
    await beginClone();
    dismiss("cancel-project");
    await until(() => restored(scratchID), "cancelled clone retained the scratch draft");
    assert(!existsSync(clone));
    assert.deepEqual(readFileSync(indexPath), scratchBytes);
    await beginClone();
    dismiss("confirm-project");
    await until(() => existsSync(join(clone, ".git")) && realpathSync(active().path) === realpathSync(clone) &&
      value("composer").includes(cloneText) && draft().isDraft, "local clone with the shared prompt");
    assert.equal(git(clone, "rev-parse", "HEAD"), git(bare, "rev-parse", "HEAD"));
    assert.equal(git(clone, "config", "--get", "remote.origin.url"), remote);
    const cloneID = draft().id;
    await quit();
    await launch("composer", root);
    await until(() => restored(cloneID) && value("composer").includes(cloneText), "same cloned draft after relaunch");
    const clonedProject = active().id;
    openPromptLink(cloneLink);
    await until(() => visible("prompt-link-find-project"), "fresh review of the mirrored clone");
    press("prompt-link-find-project");
    await until(() => visible("prompt-link-project-" + clonedProject), "registered GitHub origin behind the local mirror");
    dismiss("cancel-prompt-link");
    await until(() => restored(cloneID), "cancel kept the cloned draft");
    const all = index().projects.flatMap(p => p.conversations);
    for (const [id, expected] of [[matchedID, text], [scratchID, text], [cloneID, cloneText],
      [current.selectedConversation, current.conversations[0].composerText], [match.selectedConversation, match.conversations[0].composerText]]) {
      assert.equal(all.find(t => t.id === id)?.composerText, expected);
    }
    assert.equal(count(), 5);
    await quit();
    record("Launch Services opened the decoded shared prompt. Duplicate delivery, Cancel, an invalid link and a changed origin kept the selected draft. Confirmation created separate project, scratch and cloned drafts. After relaunch Find matched the clone's configured GitHub origin behind its local mirror. Its HEAD and all five drafts matched.");
    const catalogWorkspace = index();
    catalogWorkspace.model = { ...catalogWorkspace.model, provider: "openai", model: "gpt-5-mini" };
    writeFileSync(indexPath, JSON.stringify(catalogWorkspace));
    try {
      credential("--set-api-key-from-stdin", key, root);
      await launch("composer", root);
      await until(() => visible("active-model").includes("enabled=true"), "catalog ready after launch");
      press("active-model");
      await until(() => visible("composer-model-search"), "composer with the offline Pi catalog");
      await setField("composer-model-search", "gpt-5");
      await until(() => visible("composer-model-openai-gpt-5").includes("enabled=true"), "selectable GPT-5 from the bundled catalog");
      dismiss("active-model");
      openPromptLink(url({ prompt: "Keep the requested model", provider: "openai", model: "gpt-5" }));
      await until(() => visible("prompt-link-no-project"), "review with a catalog model hint");
      dismiss("prompt-link-no-project");
      await until(() => draft().modelSelection?.model === "gpt-5" && draft().modelSelection.provider === "openai" &&
        value("composer").includes("Keep the requested model"), "exact hinted model saved with the new draft");
      openPromptLink(url({ prompt: "Use the inherited model", provider: "openai", model: "missing-fixture" }));
      await until(() => visible("prompt-link-no-project"), "review with an unrecognized model");
      dismiss("prompt-link-no-project");
      await until(() => draft().composerText === "Use the inherited model" && !draft().modelSelection &&
        value("active-model").includes("gpt-5-mini"), "unknown model inherited the configured default");
      await quit();
      record("The composer listed GPT-5 from the bundled catalog. A link requesting GPT-5 saved that exact model with its unsent draft. An unrecognized model inherited GPT-5-mini.");
    } finally { removeFixtureCredential(root, "openai"); }
  } finally { removeFixtureCredential(root, "local:" + endpoint); }
}

export async function verifyPRPromptLinks(driver, { root, gitConfigHome, git, headFile, stateFile, app, launch, quit, record }) {
  const { press, dismiss, openPromptLink, visible, value, setField, tree, until } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const original = join(root, "Original"), source = join(root, "Source"), clone = join(root, "Cloned project");
  const bare = join(root, "remote.git"), remote = "https://github.com/fixture/workspace.git", projectID = uuid(), draftID = uuid();
  const initial = "Keep my existing project draft", firstPrompt = "Review the proposed change.", replacement = "Use this amended review prompt.";
  const link = text => "tncode://new/v1?" + new URLSearchParams({ pr: "fixture/workspace/42", prompt: text });
  for (const folder of [original, source]) {
    mkdirSync(folder, { recursive: true });
    git(folder, "init", "--template=", "-b", "main");
    git(folder, "config", "core.hooksPath", "/dev/null");
  }
  const commit = text => {
    writeFileSync(join(source, "marker.txt"), text);
    git(source, "add", "marker.txt");
    git(source, "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", text);
    return git(source, "rev-parse", "HEAD");
  };
  const first = commit("first head"), second = commit("second head");
  git(root, "clone", "--bare", "--template=", "--", source, bare);
  setUpMirror(root, gitConfigHome, git, remote, bare);
  writeFileSync(headFile, first);
  writeFileSync(stateFile, "initial\n");
  const indexPath = join(root, "workspace.json");
  writeFileSync(indexPath, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true, addProjectBaseDirectory: root,
    projects: [{ id: projectID, title: "Unrelated project", path: original, allowEdits: false, selectedConversation: draftID,
      conversations: [{ id: draftID, title: "Draft", isDraft: true, archived: false, composerText: initial }] }],
    model: { provider: "local", model: "pr-link-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 } }), { mode: 0o600 });
  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const selected = () => {
    const state = index(), p = state.projects.find(p => p.id === state.selectedProject);
    return p.conversations.find(t => t.id === p.selectedConversation);
  };
  const count = () => index().projects.flatMap(p => p.conversations).length;
  const has = id => tree().includes('id="' + id + '"');
  const shownText = text => value("composer").includes("value=" + JSON.stringify(text));
  await launch("composer", root);
  await until(() => shownText(initial), "original draft before the PR link");
  openPromptLink(link(firstPrompt));
  await until(() => visible("prompt-link-clone"), "explicit Clone Repository choice for the missing PR project");
  assert(!existsSync(clone));
  press("prompt-link-clone");
  await until(() => value("prompt-link-clone-remote").includes(remote), "reviewed GitHub remote");
  await setField("project-clone-destination", clone);
  dismiss("confirm-project");
  await until(() => existsSync(join(clone, ".git")) && index().projects.length === 2 && !has("project-clone-destination"),
    "cloned project registered without a thread");
  assert.equal(selected().id, draftID);
  assert.equal(count(), 1);
  writeFileSync(join(clone, "marker.txt"), "local uncommitted edit");
  const before = git(clone, "status", "--porcelain=v1");
  openPromptLink(link(firstPrompt));
  await until(() => value("prompt-link-pr-head").includes(first) && value("prompt-link-pr-folder").includes(clone),
    "reopened PR link resolved the clone's configured GitHub origin");
  writeFileSync(headFile, second);
  press("prompt-link-pr-checkout");
  await until(() => value("prompt-link-pr-head").includes(second) && value("prompt-link-action-error").includes("head changed"),
    "fresh confirmation after the PR head changed");
  assert.equal(count(), 1);
  assert.equal(git(clone, "worktree", "list", "--porcelain").split("worktree ").length - 1, 1);
  dismiss("prompt-link-pr-checkout");
  await until(() => count() === 2 && selected()?.location?.worktree?.path && shownText(firstPrompt), "unsent draft in the pinned PR worktree");
  const created = selected(), checkout = created.location.worktree.path;
  assert.equal(git(checkout, "rev-parse", "HEAD"), second);
  assert.equal(readFileSync(join(checkout, "marker.txt"), "utf8"), "second head");
  assert.equal(git(clone, "status", "--porcelain=v1"), before);
  assert.equal(readFileSync(join(clone, "marker.txt"), "utf8"), "local uncommitted edit");
  assert.equal(created.linkedPullRequests[0].reference, "https://github.com/fixture/workspace/pull/42");
  await quit();
  await launch("composer", root);
  openPromptLink(link(replacement));
  await until(() => visible("prompt-link-pr-replace-draft") && visible("prompt-link-pr-open-thread"), "replacement requires a separate choice");
  dismiss("prompt-link-pr-open-thread");
  await until(() => !has("prompt-link-title") && selected().id === created.id && shownText(firstPrompt), "Open Thread kept the existing prompt");
  openPromptLink(link(replacement));
  await until(() => visible("reopen-prompt-link"), "explicit reopen of the same PR link");
  press("reopen-prompt-link");
  await until(() => visible("prompt-link-pr-replace-draft"), "replace action after reopening");
  dismiss("prompt-link-pr-replace-draft");
  await until(() => selected().id === created.id && shownText(replacement), "confirmed replacement in the same draft");
  assert.equal(count(), 2);
  assert.equal(index().projects.find(p => p.id === projectID).conversations[0].composerText, initial);
  assert.equal(git(clone, "worktree", "list", "--porcelain").split("worktree ").length - 1, 2);
  await quit();
  record("The PR link cloned a local mirror before creating a draft. Reopening it showed the commit and folder. A changed head required a second confirmation. The new draft used exactly that commit and preserved the clone's dirty file. After relaunch Open Thread kept the prompt, and Replace Draft and Open changed it in the same thread. The other draft and both worktrees survived.");

  const sourceID = uuid(), ordinary = "Keep this follow-up in the source.", queued = { id: uuid(), text: "Keep this queued item." };
  const withSource = index(), p = withSource.projects.find(p => p.id === withSource.selectedProject);
  p.conversations.push({ id: sourceID, title: "Follow-up", isDraft: false, archived: false, composerText: ordinary, queuedMessages: [queued] });
  p.selectedConversation = sourceID;
  const history = await seedPaletteMessageHistory({ sidecar: join(app, "Contents/Resources/Sidecar"), workspace: root,
    projectID: p.id, threadID: sourceID, cwd: clone, keyword: "PR link fork" });
  writeFileSync(indexPath, JSON.stringify(withSource));
  await launch("composer", root);
  await until(() => visible("fork-from-response-" + history.latestID), "completed Pi reply in the PR project");
  press("fork-from-response-" + history.latestID);
  const fork = await until(() => selected().forkOrigin?.messageID === history.latestID && visible("open-source-conversation") && selected(),
    "independent Pi fork of the saved reply");
  await quit();
  const prepared = index(), owner = prepared.projects.find(item => item.id === p.id);
  const child = owner.conversations.find(t => t.id === fork.id);
  child.composerText = "Keep this draft in the fork.";
  child.linkedPullRequests = [{ reference: "https://github.com/fixture/workspace/pull/43", title: "PR for the fork" }];
  owner.selectedConversation = sourceID;
  writeFileSync(indexPath, JSON.stringify(prepared));
  const forkDir = join(root, "sessions", p.id, child.id);
  const histories = readdirSync(forkDir).filter(name => name.endsWith(".jsonl"));
  assert.equal(histories.length, 1);
  const file = join(forkDir, histories[0]), full = readFileSync(file), newline = full.indexOf(10);
  assert(newline > 0 && newline < full.length - 1);
  const header = full.subarray(0, newline + 1);
  const prompt = "Replace only after opening this fork.";
  const forkLink = "tncode://new/v1?" + new URLSearchParams({ pr: "fixture/workspace/43", prompt });
  await launch("composer", root);
  await until(() => shownText(ordinary) && visible("transcript-message-" + history.latestID), "original thread ready with its follow-up");
  const beforeIndex = readFileSync(indexPath), sourceHistory = readFileSync(history.historyPath);
  writeFileSync(file, header);
  try {
    for (const action of ["prompt-link-pr-open-thread", "prompt-link-pr-replace-draft"]) {
      openPromptLink(forkLink);
      await until(() => visible(action), "linked fork and its existing draft");
      dismiss(action);
      await until(() => selected().id !== sourceID || value("prompt-link-action-error").includes("fork history is incomplete"),
        "result of opening a damaged fork");
      assert.equal(selected().id, sourceID, "A broken PR fork replaced the selected thread.");
      assert.deepEqual(readFileSync(indexPath), beforeIndex);
      assert.deepEqual(readFileSync(history.historyPath), sourceHistory);
      assert.deepEqual(readFileSync(file), header);
      dismiss("cancel-prompt-link");
      await until(() => !has("prompt-link-title") && shownText(ordinary), "source preserved after rejecting the broken fork");
    }
  } finally { writeFileSync(file, full); }
  openPromptLink(forkLink);
  await until(() => visible("prompt-link-pr-replace-draft"), "the same repaired fork can be opened");
  dismiss("prompt-link-pr-replace-draft");
  await until(() => selected().id === child.id && shownText(prompt) && visible("transcript-message-" + history.latestID),
    "explicit replacement after Pi opened the repaired fork");
  const savedSource = index().projects.find(project => project.id === p.id).conversations.find(t => t.id === sourceID);
  assert.equal(savedSource.composerText, ordinary);
  assert.deepEqual(savedSource.queuedMessages, [queued]);
  await quit();
  record("A real fork linked to PR #43 was reduced to its Pi header. Open Thread and Replace Draft and Open both kept the source selected, its queue and unsent text intact, and both histories and the index byte-identical. Restoring the fork allowed the same link to open and replace its draft.");
}
