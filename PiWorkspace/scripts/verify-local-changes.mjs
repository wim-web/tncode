import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyLocalChanges(driver, { root, git, launch, quit, record }) {
  const { press, visible, value, until, tree } = driver;
  const project = join(root, "Project"), checkout = join(root, "Topic checkout");
  mkdirSync(project, { recursive: true });
  git(project, "init", "--template=", "-b", "main");
  const write = (cwd, name, text) => writeFileSync(join(cwd, name), text + "\n");
  function commit(cwd, name, text) {
    write(cwd, name, text);
    git(cwd, "add", "--", name);
    git(cwd, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
        "-c", "core.hooksPath=/dev/null", "commit", "-m", text);
    return git(cwd, "rev-parse", "HEAD");
  }
  commit(project, "tracked.txt", "base-marker");
  git(project, "worktree", "add", "-b", "topic", checkout, "main");
  git(project, "config", "branch.topic.t3-merge-base-ref", "refs/heads/main");
  const first = commit(checkout, "one.txt", "topic-first-marker");
  git(checkout, "branch", "comparison", first);
  git(checkout, "update-ref", "refs/remotes/origin/comparison", first);
  const last = commit(checkout, "two.txt", "topic-second-marker");
  write(checkout, "tracked.txt", "staged-marker");
  git(checkout, "add", "--", "tracked.txt");
  write(checkout, "tracked.txt", "worktree-marker");
  write(checkout, "new.txt", "untracked-marker");
  write(project, "tracked.txt", "parent-checkout-marker");
  const gitState = () => [project, checkout].map(cwd => [git(cwd, "rev-parse", "HEAD"), git(cwd, "diff"), git(cwd, "diff", "--cached")]);
  const before = gitState();
  const uuid = () => randomUUID().toUpperCase();
  const p = uuid(), parent = uuid(), topic = uuid(), index = join(root, "workspace.json");
  writeFileSync(index, JSON.stringify({ selectedProject: p, welcomeCompleted: true, projects: [
    { id: p, title: "Changes", path: project, allowEdits: false, selectedConversation: topic, conversations: [
      { id: topic, title: "Topic draft", isDraft: true, archived: false, composerText: "Keep the topic draft.", location: { worktree: { path: checkout, base: "main" } } },
      { id: parent, title: "Parent draft", isDraft: true, archived: false, composerText: "Keep the parent draft." },
    ] }], model: { provider: "local", model: "unused-comparison-model", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 } }), { mode: 0o600 });
  const has = id => tree().includes('id="' + id + '"');
  const patchLines = () => driver.subtree("git-patch", 2);
  const patch = text => until(() => patchLines().includes("value=" + JSON.stringify(text)), "patch " + text);
  async function choose(picker, option) {
    press(picker);
    await until(() => visible(option), "choice " + option);
    driver.dismiss(option);
  }
  await launch("toggle-changes", root);
  press("toggle-changes");
  await until(() => value("git-review-base").includes("Automatic (main)") && visible("git-review-file-one.txt"), "topic compared with main");
  press("git-review-file-one.txt");
  await patch("+topic-first-marker");
  await choose("git-review-base", "git-review-base-refs/heads/comparison");
  await until(() => !has("git-review-file-one.txt") && visible("git-review-file-two.txt"), "new merge base excludes the earlier commit");
  press("git-review-file-two.txt");
  await patch("+topic-second-marker");
  await choose("git-review-base", "git-review-base-automatic");
  await until(() => visible("git-review-file-one.txt"), "Automatic restored the first file");
  await choose("git-review-base", "git-review-base-refs/remotes/origin/comparison");
  await until(() => !has("git-review-file-one.txt") && visible("git-review-file-two.txt"), "remote-tracking base");
  await choose("git-review-base", "git-review-base-automatic");
  const gitfile = join(checkout, ".git");
  const mode = statSync(gitfile).mode & 0o777;
  try {
    chmodSync(gitfile, 0);
    press("git-refresh");
    await until(() => visible("git-review-error") && !has("git-patch"), "unreadable checkout hides the old patch");
  } finally {
    chmodSync(gitfile, mode);
  }
  press("git-refresh");
  await until(() => visible("git-review-file-one.txt"), "repaired checkout refreshes from Git");
  await choose("git-review-scope", "git-review-scope-uncommitted");
  await until(() => visible("git-file-new.txt"), "uncommitted file list");
  press("git-file-tracked.txt");
  driver.segment("git-diff-mode", "Staged");
  await patch("+staged-marker");
  assert(!patchLines().includes("worktree-marker"));
  driver.segment("git-diff-mode", "Unstaged");
  await patch("+worktree-marker");
  await patch("-staged-marker");
  driver.segment("git-diff-mode", "All");
  press("git-file-new.txt");
  await patch("+untracked-marker");
  write(checkout, "new.txt", "refreshed-marker");
  press("git-refresh");
  await patch("+refreshed-marker");
  await choose("git-review-scope", "git-review-commit-" + first);
  await patch("+topic-first-marker");
  assert(!patchLines().includes("topic-second-marker"));
  await choose("git-review-scope", "git-review-commit-" + last);
  await patch("+topic-second-marker");
  assert(!patchLines().includes("topic-first-marker"));
  press("thread-row-" + parent);
  await until(() => value("composer").includes("Keep the parent draft."), "parent checkout selected");
  press("toggle-changes");
  await until(() => value("git-review-head").includes("main"), "parent branch");
  await choose("git-review-scope", "git-review-scope-uncommitted");
  press("git-file-tracked.txt");
  await patch("+parent-checkout-marker");
  assert(!patchLines().includes("worktree-marker"));
  await quit();
  assert.deepEqual(gitState(), before);
  const saved = JSON.parse(readFileSync(index, "utf8")).projects[0];
  assert.equal(saved.selectedConversation, parent);
  assert.equal(saved.conversations.find(t => t.id === topic).composerText, "Keep the topic draft.");
  record("Local and remote-tracking bases excluded the earlier commit. Refresh recovered after the Git file became readable. Staged and Unstaged showed different bytes from the same file. Refresh reread the untracked file. Each SHA displayed its own patch. Switching checkouts showed the parent's edit and kept both HEADs, staged and unstaged patches, and saved drafts.");
}
