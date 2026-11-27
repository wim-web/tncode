import assert from "node:assert/strict";

const reference = "https://github.com/fixture/workspace/pull/42";
const row = "linked-pr-row-fixture/workspace-42";
const actions = "linked-pr-actions-fixture/workspace-42";

async function openLinks({ press, visible, until }) {
  press("pull-requests");
  await until(() => visible("github-tab-linked-items"), "Linked items tab");
  press("github-tab-linked-items");
  await until(() => visible("linked-pr-add"), "thread's linked pull requests");
}

async function closeLinks({ dismiss, until, tree }) {
  dismiss("pr-close");
  await until(() => !tree().includes('id="pr-close"'), "return to the thread");
}

export async function verifyIssueLinks(driver, { conversation, quit, launch }) {
  const { press, dismiss, visible, value, until, setField, checkCopy } = driver;
  const issue = number => "https://github.com/fixture/workspace/issues/" + number;
  const issueRow = number => "linked-issue-row-fixture/workspace-" + number;
  const savedIssues = () => (conversation().linkedIssues ?? []).map(item => item.reference);
  async function add(prefix, text) {
    press(prefix + "-add");
    await until(() => value(prefix + "-repository").includes("github.com/fixture/workspace"), "checkout repository for " + prefix);
    await setField(prefix + "-reference", text, () => visible(prefix + "-submit").includes("enabled=true"));
    dismiss(prefix + "-submit");
  }
  press("github-tab-issues");
  await until(() => visible("issue-row-71"), "issue in selected checkout");
  press("issue-row-71");
  await until(() => visible("issue-link-to-thread"), "link from issue details");
  press("issue-link-to-thread");
  await until(() => value("linked-issue-reference").includes(issue(71)) && visible("linked-issue-submit").includes("enabled=true"), "prefilled issue URL");
  dismiss("linked-issue-submit");
  await until(() => visible("issue-unlink-from-thread") && savedIssues().includes(issue(71)), "linked issue 71");
  press("github-tab-linked-items");
  await until(() => visible(issueRow(71)), "saved issue in Linked items");
  await add("linked-pr", "#42");
  await until(() => visible(row), "pull request independently linked");
  await add("linked-issue", "#42");
  await until(() => visible(issueRow(42)), "issue independently linked");
  await add("linked-issue", "https://github.com/fixture/other/issues/42");
  await until(() => value("linked-issue-link-error").includes("Enter an issue from that repository"), "unrelated repository rejected");
  await setField("linked-issue-reference", issue(42));
  press("linked-issue-submit");
  await until(() => value("linked-issue-link-error").includes("already linked"), "duplicate issue rejected");
  dismiss("linked-issue-cancel");
  assert.deepEqual(savedIssues().sort(), [issue(42), issue(71)]);
  await closeLinks(driver);
  await quit();
  await launch("pull-requests");
  await openLinks(driver);
  press(issueRow(42));
  await until(() => value("issue-detail-title").includes("#42 Issue sharing a pull request number"), "same issue details after relaunch");
  press("linked-issue-copy-link");
  await until(() => checkCopy(issue(42)), "private pasteboard contains the issue URL");
  press("linked-issue-unlink");
  await until(() => savedIssues().length === 1 && visible(row) && visible(issueRow(71)), "unlink kept the distinct issue and pull request");
  press(row);
  await until(() => value("pr-detail-title").includes("#42 Update checkout"), "the same-number fixture pull request still opens");
  assert.deepEqual(savedIssues(), [issue(71)]);
  assert.deepEqual(conversation().linkedPullRequests.map(item => item.reference), [reference]);
}

async function chooseAction({ press, visible, until }, item) {
  press(actions);
  await until(() => visible(item), "linked PR action " + item);
  press(item);
}

export async function linkFixturePullRequest(driver, conversation) {
  const { press, until, tree, visible, value, setField, checkCopy } = driver;
  await openLinks(driver);
  await until(() => visible("linked-pr-empty"), "initially unlinked thread");
  for (const input of ["#42", reference]) {
    press("linked-pr-add");
    await until(() => value("linked-pr-repository").includes("github.com/fixture/workspace"), "repository resolved from checkout");
    await setField("linked-pr-reference", input);
    press("linked-pr-submit");
    await until(() => !tree().includes('id="linked-pr-reference"') && visible(row), "saved link for " + input);
    assert.deepEqual(conversation().linkedPullRequests.map(l => l.reference), [reference]);
  }
  press(row);
  await until(() => value("pr-detail-title").includes("#42 Update checkout"), "linked PR detail");
  for (const [action, text] of [["linked-pr-copy-link", reference], ["linked-pr-copy-number", "#42"]]) {
    await chooseAction(driver, action);
    await until(() => checkCopy(text), "copied " + text + " to the fixture pasteboard");
  }
  await closeLinks(driver);
}

export async function verifyRestoredLink(driver, child, conversation) {
  const { press, visible, until, tree } = driver;
  press("open-fork-" + child);
  await until(() => visible("open-source-conversation"), "open separate child thread");
  await openLinks(driver);
  await until(() => visible("linked-pr-empty"), "child has no linked PR");
  await closeLinks(driver);
  press("open-source-conversation");
  await until(() => visible("open-fork-" + child), "return to parent thread");
  await openLinks(driver);
  await until(() => visible(row), "link restored after relaunch and switching threads");
  await chooseAction(driver, "linked-pr-unlink");
  await until(() => visible("linked-pr-empty") && !tree().includes('id="' + row + '"'), "unlinked PR");
  assert.deepEqual(conversation().linkedPullRequests ?? [], []);
  await closeLinks(driver);
}

export async function verifyLinkOnlyDraftMove(driver, index) {
  const { press, until, visible } = driver;
  const source = index().selectedProject;
  const other = index().projects.find(p => p.title === "Second Project").id;
  function current() {
    const state = index();
    const project = state.projects.find(p => p.id === state.selectedProject);
    return project.conversations.find(t => t.id === project.selectedConversation);
  }
  const id = current().id;
  assert(!current().composerText && !current().composerAttachments?.length);
  await linkFixturePullRequest(driver, current);
  for (const target of [other, source]) {
    press("thread-project");
    await until(() => visible("draft-project-picker"), "draft project submenu");
    press("draft-project-picker");
    await until(() => visible("draft-project-" + target), "destination for the linked draft");
    press("draft-project-" + target);
    await until(() => index().selectedProject === target && current().id === id, "the same PR-only draft moved to the chosen project");
    assert.deepEqual(current().linkedPullRequests.map(l => l.reference), [reference]);
    assert.equal(index().projects.flatMap(p => p.conversations).filter(t => t.id === id).length, 1);
  }
}
