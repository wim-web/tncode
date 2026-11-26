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
