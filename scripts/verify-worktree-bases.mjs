import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export async function verifyWorktreeBases(driver, { root, git, endpoint, credential, removeFixtureCredential, key, launch, quit, send, targets, record }) {
  const { press, visible, value, tree, until, setField } = driver;
  const workspace = join(root, "workspace"), origin = join(root, "origin.git");
  const seed = join(root, "Upstream"), project = join(root, "Project");
  for (const path of [workspace, origin, seed]) mkdirSync(path, { recursive: true });
  function identity(path) {
    git(path, "config", "user.name", "Worktree fixture");
    git(path, "config", "user.email", "worktree@example.invalid");
    git(path, "config", "core.hooksPath", "/dev/null");
    git(path, "config", "commit.gpgsign", "false");
  }
  git(origin, "init", "--bare", "--template=", "-b", "main");
  git(seed, "init", "--template=", "-b", "main");
  identity(seed);
  writeFileSync(join(seed, "README.md"), "Original root\n");
  git(seed, "add", "README.md");
  git(seed, "commit", "-m", "Common commit");
  const url = pathToFileURL(origin).href;
  git(seed, "remote", "add", "origin", url);
  git(seed, "push", "origin", "HEAD:main", "HEAD:stable");
  git(root, "clone", "--template=", "--", url, project);
  identity(project);
  const common = git(project, "rev-parse", "HEAD");
  git(project, "switch", "-c", "stable", "--track", "origin/stable");
  writeFileSync(join(project, "marker.txt"), "Local revision\n");
  git(project, "add", "marker.txt");
  git(project, "commit", "-m", "Local stable");
  const local = git(project, "rev-parse", "HEAD");
  git(project, "branch", "only-local", local);
  git(project, "switch", "main");
  writeFileSync(join(project, "README.md"), "Preserve the dirty parent\n");
  const dirty = git(project, "diff", "--", "README.md");
  git(seed, "switch", "-c", "stable");
  writeFileSync(join(seed, "marker.txt"), "Remote revision\n");
  git(seed, "add", "marker.txt");
  git(seed, "commit", "-m", "Remote stable");
  const remote = git(seed, "rev-parse", "HEAD");
  git(seed, "push", "origin", "HEAD:stable");
  assert.equal(new Set([common, local, remote]).size, 3);
  assert.equal(git(project, "rev-parse", "origin/stable"), common);

  const projectID = randomUUID().toUpperCase(), first = randomUUID().toUpperCase();
  const store = join(workspace, "workspace.json");
  writeFileSync(store, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
    projects: [{ id: projectID, title: "Ref fixture", path: project, allowEdits: false, selectedConversation: first,
      conversations: [{ id: first, archived: false, isDraft: true, title: "First draft", composerText: "Choose local stable." }] }],
    model: { provider: "local", endpoint, model: "fixture-model", contextWindow: 8192 },
  }), { mode: 0o600 });
  const index = () => JSON.parse(readFileSync(store, "utf8"));
  const thread = () => {
    const p = index().projects[0];
    return p.conversations.find(t => t.id === p.selectedConversation);
  };
  const enabled = id => /value=1\b/.test(value(id));
  async function settings() {
    press("model-settings");
    await until(() => visible("settings-nav-worktrees"), "Worktrees settings");
    press("settings-nav-worktrees");
    await until(() => visible("start-from-origin"), "default remote base setting");
  }
  async function draft() {
    const original = thread().id;
    press("new-conversation");
    await until(() => thread().id !== original || tree().includes('id="new-thread-project-' + projectID + '"'), "new branch draft");
    if (thread().id === original) press("new-thread-project-" + projectID);
    await until(() => thread().id !== original && visible("composer"), "new draft ready");
  }
  async function choose(name, ref, fromRemote) {
    press("choose-workspace");
    await until(() => visible("worktree-branch"), "new worktree form");
    await setField("worktree-branch", name);
    press("create-worktree");
    await until(() => thread().location?.newWorktree?.branch === name && visible("composer-branch"), "planned worktree " + name);
    press("composer-branch");
    await until(() => visible("git-start-from-remote"), "per-draft remote toggle");
    assert.equal(enabled("git-start-from-remote"), fromRemote);
    if (fromRemote) {
      press("git-start-from-remote");
      await until(() => thread().worktreeStartsFromRemote === false, "disabled for this draft");
      press("git-start-from-remote");
      await until(() => thread().worktreeStartsFromRemote === true, "reenabled for this draft");
    }
    await setField("git-branch-search", "absent-branch-fixture");
    await until(() => visible("git-branch-empty"), "branch search with no matches");
    await setField("git-branch-search", ref);
    const id = "refs/heads/" + ref;
    await until(() => visible("git-branch-ref-" + id), "resolved local ref " + ref);
    press("git-branch-ref-" + id);
    await until(() => thread().location?.newWorktree?.base === id && !tree().includes('id="git-branch-search"'), "pinned base branch");
    const label = "From " + ref + (fromRemote ? " (remote)" : "");
    await until(() => visible("composer-branch").includes(JSON.stringify(label)), "visible base " + label);
  }
  async function run(prompt, head, marker) {
    const id = thread().id, count = targets.length;
    await send(prompt);
    await until(() => targets.length === count + 1 && targets.at(-1).completed && visible("send-message"), "one turn for " + prompt);
    assert.equal(thread().id, id);
    const checkout = thread().location.worktree.path;
    assert.equal(git(checkout, "rev-parse", "HEAD"), head);
    assert.equal(readFileSync(join(checkout, "marker.txt"), "utf8"), marker + "\n");
    const sessions = join(workspace, "sessions", projectID, id);
    const histories = readdirSync(sessions).filter(name => name.endsWith(".jsonl"));
    assert.equal(histories.length, 1);
    const header = JSON.parse(readFileSync(join(sessions, histories[0]), "utf8").split("\n", 1)[0]);
    assert.equal(realpathSync(header.cwd), realpathSync(checkout));
    assert(targets.at(-1).body.messages.some(m => m.role === "system" && JSON.stringify(m.content).includes(header.cwd)));
    assert.equal(git(project, "rev-parse", "HEAD"), common);
    assert.equal(git(project, "diff", "--", "README.md"), dirty);
  }

  credential("--set-api-key-from-stdin", key, workspace);
  try {
    await launch("model-settings", workspace);
    await settings();
    assert(enabled("start-from-origin"));
    press("start-from-origin");
    await until(() => index().newWorktreesStartFromRemote === false, "local default for new worktrees");
    press("settings-close");
    await choose("local-proof", "stable", false);
    await run("Choose local stable.", local, "Local revision");
    assert.equal(git(project, "rev-parse", "origin/stable"), common);
    await settings();
    press("reset-start-from-origin");
    await until(() => index().newWorktreesStartFromRemote == null && enabled("start-from-origin"), "restored remote default");
    press("settings-close");
    await draft();
    await choose("remote-proof", "stable", true);
    await setField("composer", "Fetch remote stable.");
    await quit();
    await launch("model-settings", workspace);
    assert.equal(thread().location.newWorktree.base, "refs/heads/stable");
    assert.equal(thread().worktreeStartsFromRemote, true);
    assert.equal(git(project, "rev-parse", "origin/stable"), common);
    await run("Fetch remote stable.", remote, "Remote revision");
    assert.equal(git(project, "rev-parse", "origin/stable"), remote);
    await draft();
    await choose("missing-remote-proof", "only-local", true);
    await run("Use the available local ref.", local, "Local revision");
    assert.equal(git(project, "worktree", "list", "--porcelain").split("\n").filter(line => line.startsWith("worktree ")).length, 4);
    await quit();
    record("Three Pi turns ran in the chosen worktrees. With remote start off, stable used its local commit. Enabling it and relaunching fetched the distinct upstream commit from the bare file remote. A missing remote branch used its local commit. The parent retained its HEAD and dirty README.");
  } finally {
    removeFixtureCredential(workspace, "local:" + endpoint);
  }
}
