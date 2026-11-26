import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { closeTerminalPane, verifyInteractiveShell } from "./verify-terminal-panes.mjs";

export async function setWorktreeLocation({ press, setField, visible, tree, until, keyFor }, index, location) {
  press("model-settings");
  await until(() => visible("settings-nav-worktrees"), "Worktrees settings");
  press("settings-nav-worktrees");
  await until(() => visible("storage-worktrees-location"), "worktree storage path field");
  if (location) {
    await setField("storage-worktrees-location", location);
    keyFor("storage-worktrees-location", 36);
  } else {
    press("reset-worktree-location");
  }
  await until(() => (index().worktreesDirectory ?? "") === location, "updated worktree storage preference");
  press("settings-close");
  await until(() => !tree().includes('id="settings-search"'), "closed Worktrees settings");
}

export function createWorkspaceControlsFixture(root, git) {
  const project = join(root, "Main Project");
  const linked = join(root, "Linked");
  const initial = join(root, "Start Here");
  const child = join(initial, "Browse marker");
  for (const path of [project, child]) mkdirSync(path, { recursive: true });
  const shell = join(root, "verification-shell");
  writeFileSync(shell, '#!/bin/sh\nprintf "Fixture terminal PID %s\\n" "$$"\nexec /bin/sh -i\n', { mode: 0o700 });
  git(project, "init", "--template=", "-b", "main");
  git(project, "config", "core.hooksPath", "/dev/null");
  git(project, "config", "commit.gpgsign", "false");
  git(project, "config", "user.name", "Workspace fixture");
  git(project, "config", "user.email", "workspace@example.invalid");
  const note = join(project, "note.txt");
  writeFileSync(note, "main\n");
  git(project, "add", "note.txt");
  git(project, "commit", "-m", "main contents");
  git(project, "switch", "-c", "alternate");
  writeFileSync(note, "alternate\n");
  git(project, "commit", "-am", "alternate contents");
  git(project, "switch", "main");
  git(project, "worktree", "add", "-b", "already-in-use", linked, "alternate");
  writeFileSync(note, "keep the local edit\n");
  writeFileSync(join(project, "staged.txt"), "keep the staged entry\n");
  git(project, "add", "staged.txt");
  const projectID = randomUUID().toUpperCase(), threadID = randomUUID().toUpperCase();
  const draft = "Keep this draft while choosing a checkout.";
  writeFileSync(join(root, "workspace.json"), JSON.stringify({
    welcomeCompleted: true, selectedProject: projectID,
    projects: [{ id: projectID, title: "Main Project", path: project, allowEdits: false, selectedConversation: threadID,
      conversations: [{ id: threadID, title: "Checkout fixture", archived: false, isDraft: true, composerText: draft }] }],
    model: { provider: "local", model: "fixture-model", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
  }));
  return { root, project, linked, initial, child, projectID, threadID, draft, note, shell };
}

export async function verifyWorkspaceControls(driver, fixture, git, record, relaunch) {
  const { press, dismiss, menuItem, showMenu, pick, setField, visible, value, tree, until, keyFor, focus, selectPath, checkCopy } = driver;
  const { root, project, linked, initial, child, projectID, threadID, draft, note } = fixture;
  const index = () => JSON.parse(readFileSync(join(root, "workspace.json"), "utf8"));
  const displayed = (id, contents) => value(id).includes("value=" + JSON.stringify(contents));
  const sameDraft = () => index().selectedProject === projectID && index().projects[0].selectedConversation === threadID &&
                          displayed("composer", draft);
  const focused = id => visible(id).includes("focused=true");

  await until(sameDraft, "the prepared project draft");
  press("model-settings");
  await until(() => visible("add-project-starts-in"), "folder preference");
  assert(displayed("add-project-starts-in", ""));
  await setField("add-project-starts-in", initial);
  keyFor("add-project-starts-in", 36);
  await until(() => index().addProjectBaseDirectory === initial, "saved initial folder");
  press("settings-close");
  await until(() => !tree().includes('id="settings-search"'), "close General");
  await relaunch();
  menuItem("Show Welcome");
  await until(() => visible("welcome-close") && visible("welcome-title"), "Welcome from Help");
  press("welcome-add-project");
  await until(() => visible("project-source-local"), "sources from Welcome");
  press("project-source-local");
  await until(() => displayed("project-path", initial + "/") && focused("project-path"), "configured folder with input focus");
  press("browse-project");
  await until(() => visible("open-panel"), "native folder browser");
  await until(() => { selectPath(child); return true; }, "select the unique child visible in the configured folder");
  dismiss("CancelButton");
  await until(() => !tree().includes('id="open-panel"') && displayed("project-path", initial + "/"), "unchanged folder after Browse cancellation");
  press("back-project-source");
  await until(() => visible("project-source-clone"), "Git URL source");
  press("project-source-clone");
  await setField("project-clone-url", "https://example.invalid/team/seed.git");
  press("confirm-project");
  await until(() => displayed("project-clone-destination", join(initial, "seed")), "suggested clone destination");
  press("cancel-project");
  await until(() => visible("welcome-close"), "back to Welcome");
  press("welcome-close");
  await until(() => sameDraft() && focused("composer"), "Help returned to the selected draft");
  press("model-settings");
  await setField("settings-search", "Welcome page");
  await until(() => visible("settings-result-welcome-page"), "Welcome settings result");
  press("settings-result-welcome-page");
  press("welcome-page");
  await until(() => visible("welcome-close"), "Welcome from About settings");
  press("welcome-close");
  await until(() => sameDraft() && focused("composer"), "About returned to the draft");
  press("model-settings");
  await until(() => visible("reset-add-project-starts-in"), "reset initial folder");
  press("reset-add-project-starts-in");
  await until(() => index().addProjectBaseDirectory == null && displayed("add-project-starts-in", ""), "default initial folder");
  press("settings-close");
  record("Help and About settings reopened Welcome and restored the original draft. The configured initial folder reached the native Browse panel and the Git URL destination. Reset restored the default.");

  focus("composer");
  keyFor("composer", 7, "cmd", "shift");
  await until(() => visible("use-project-workspace"), "Command-Shift-X opens the workspace picker");
  press("use-project-workspace");
  await until(() => sameDraft() && visible("composer-branch").includes("main"), "draft using the project checkout");
  press("toggle-terminal");
  await until(() => focused("thread-terminal"), "active terminal for shortcut exclusion");
  for (const code of [7, 5]) {
    keyFor("thread-terminal", code, "cmd", "shift");
    assert(focused("thread-terminal"));
    assert(!/id="(?:git-branch-search|use-project-workspace)"/.test(tree()));
  }
  await closeTerminalPane(driver);
  await until(() => !tree().includes('id="thread-terminal"') && visible("composer-branch"), "terminal close returned to the draft");
  record("Command-Shift-X opened the workspace picker from the draft. The focused terminal retained both Command-Shift-X and Command-Shift-G.");
  await until(() => { showMenu("composer-branch"); return true; }, "right-click the exposed branch button");
  await until(() => visible("git-copy-branch"), "Copy branch name in the context menu");
  dismiss("git-copy-branch");
  await until(() => checkCopy("main"), "copied branch name from the context menu");
  focus("composer");
  keyFor("composer", 5, "cmd", "shift");
  await until(() => focused("git-branch-search"), "Command-Shift-G opens branch search");
  press("git-copy-branch-in-picker");
  await until(() => checkCopy("main"), "exact branch in the fixture pasteboard");
  const before = git(project, "status", "--porcelain=v1");
  await setField("git-branch-search", "no such ref");
  await until(() => visible("git-branch-empty"), "empty branch search");
  await setField("git-branch-search", "alternate");
  await until(() => visible("git-branch-ref-refs/heads/alternate"), "matching branch");
  showMenu("git-branch-ref-refs/heads/alternate");
  await until(() => visible("git-copy-ref-refs/heads/alternate"), "Copy on the candidate branch");
  dismiss("git-copy-ref-refs/heads/alternate");
  await until(() => checkCopy("alternate"), "copied the candidate rather than the checked-out branch");
  assert.equal(git(project, "branch", "--show-current"), "main");
  focus("git-branch-search");
  keyFor("git-branch-search", 36);
  await until(() => visible("git-branch-error"), "Git blocked a conflicting change");
  assert.equal(git(project, "branch", "--show-current"), "main");
  assert.equal(git(project, "status", "--porcelain=v1"), before);
  assert.equal(readFileSync(note, "utf8"), "keep the local edit\n");
  assert.equal(git(project, "show", ":staged.txt"), "keep the staged entry");
  record("Command-Shift-G opened branch search. Right-click Copy on the checked-out branch returned main. Right-click Copy on the alternate candidate returned alternate without switching. Git refused a conflicting checkout without changing HEAD, staged bytes or the working file.");
  writeFileSync(note, "main\n");
  press("git-branch-ref-refs/heads/alternate");
  await until(() => git(project, "branch", "--show-current") === "alternate" && visible("composer-branch").includes("alternate"),
              "switch to an existing branch after resolving the conflict");
  press("composer-branch");
  await until(() => visible("git-branch-ref-refs/heads/main"), "original branch");
  press("git-branch-ref-refs/heads/main");
  await until(() => git(project, "branch", "--show-current") === "main" && visible("composer-branch").includes("main"),
              "return to main with staged work retained");
  press("composer-branch");
  await until(() => visible("git-new-branch"), "new branch action");
  press("git-new-branch");
  await setField("git-new-branch-name", "main");
  press("git-create-and-switch");
  await until(() => visible("git-branch-error") && git(project, "branch", "--show-current") === "main", "duplicate branch name rejected");
  await setField("git-new-branch-name", "fixture/selected-base");
  pick("git-new-branch-base", "alternate");
  await until(() => displayed("git-new-branch-base", "alternate"), "selected alternate base before creating the branch");
  press("git-create-and-switch");
  await until(() => git(project, "branch", "--show-current") === "fixture/selected-base" &&
              !tree().includes('id="git-branch-picker"'), "created branch at selected base");
  assert.equal(git(project, "rev-parse", "HEAD"), git(project, "rev-parse", "alternate"));
  assert.equal(readFileSync(note, "utf8"), "alternate\n");
  const checkouts = git(project, "worktree", "list", "--porcelain");
  press("composer-branch");
  await until(() => visible("git-branch-ref-refs/heads/already-in-use"), "branch in the linked checkout");
  press("git-branch-ref-refs/heads/already-in-use");
  await until(() => {
    const location = index().projects[0].conversations[0].location?.worktree;
    return location && realpathSync(location.path) === realpathSync(linked) && sameDraft();
  }, "the same thread selected the linked worktree");
  assert.equal(git(linked, "branch", "--show-current"), "already-in-use");
  assert.equal(git(project, "branch", "--show-current"), "fixture/selected-base");
  assert.equal(git(project, "show", ":staged.txt"), "keep the staged entry");
  assert.equal(git(project, "worktree", "list", "--porcelain"), checkouts);
  press("toggle-terminal");
  await until(() => focused("thread-terminal"), "linked checkout terminal");
  await verifyInteractiveShell(driver, linked);
  await closeTerminalPane(driver);
}
