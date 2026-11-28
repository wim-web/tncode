import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyIssueEdits(driver, { root, forge, stateFile, git, launch, quit, record }) {
  const { press, dismiss, visible, value, setField, tree, until } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const path = join(root, "Project"), checkout = join(root, "Linked worktree");
  mkdirSync(path, { recursive: true });
  git(path, "init", "--template=", "-b", "main");
  git(path, "config", "core.hooksPath", "/dev/null");
  git(path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
    "commit", "--allow-empty", "-m", "Issue fixture");
  git(path, "worktree", "add", "-b", "issue-checkout", checkout, "HEAD");
  git(path, "remote", "add", "origin", "https://github.com/fixture/workspace.git");
  const projectID = uuid(), threadID = uuid(), otherID = uuid();
  const original = "Keep this chat draft.", other = "Other pending draft", title = "Revised fixture issue";
  const issue = "https://github.com/fixture/workspace/issues/71", db = join(forge, "issues.json"), log = join(forge, "issue-requests.jsonl");
  const indexPath = join(root, "workspace.json");
  writeFileSync(indexPath, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
    projects: [{ id: projectID, path, title: "Issue fixture", allowEdits: false, selectedConversation: threadID, conversations: [
      { id: threadID, title: "Issue conversation", isDraft: false, archived: false, composerText: original,
        linkedIssues: [{ reference: issue, title: "Fix a fixture issue" }], location: { worktree: { path: checkout, base: "main" } } },
      { id: otherID, title: "Other", isDraft: true, archived: false, composerText: other },
    ] }], model: { provider: "local", model: "fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
  }), { mode: 0o600 });
  const requests = () => existsSync(log) ? readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line)) : [];
  const writes = () => requests().filter(entry => entry.kind === "write");
  const remote = () => JSON.parse(readFileSync(db, "utf8"))["fixture/workspace/71"];
  const mode = selected => writeFileSync(stateFile, selected + "\n");
  const has = identifier => tree().includes('id="' + identifier + '"');
  const matches = (identifier, text) => value(identifier).includes("value=" + JSON.stringify(text));
  async function openLinked() {
    press("github-tab-linked-items");
    await until(() => visible("linked-issue-row-fixture/workspace-71"), "linked issue in the selected checkout");
    press("linked-issue-row-fixture/workspace-71");
    await until(() => visible("issue-comment-editor") && value("issue-detail-title").includes("#71"), "linked issue detail");
  }
  mkdirSync(forge, { recursive: true });
  mode("initial");
  await launch("pull-requests", root);
  press("pull-requests");
  await until(() => visible("github-tab-issues"), "Issues tab");
  press("github-tab-issues");
  await until(() => visible("issue-row-71"), "issue 71 in the listing");
  press("issue-row-71");
  await until(() => value("issue-comment-body-previous-1").includes("Repeated text") && visible("issue-edit-title"),
    "mock issue activity and editable title");
  assert(requests().some(entry => entry.kind === "snapshot" && entry.cwd === realpathSync(checkout) &&
    entry.repo === "fixture/workspace" && entry.number === 71));
  assert.equal(writes().length, 0);

  press("issue-edit-title");
  await setField("issue-title-editor", title);
  mode("write-forbidden");
  press("issue-title-save");
  await until(() => visible("issue-write-error") && matches("issue-title-editor", title) && writes().length === 1,
    "permission failure retained the uncommitted title");
  mode("initial");
  dismiss("issue-title-save");
  await until(() => remote().title === title && value("issue-detail-title").includes(title), "retried edit reached issue 71");
  assert.deepEqual(writes().map(entry => entry.method), ["PATCH", "PATCH"]);
  dismiss("issue-edit-description");
  await until(() => visible("issue-description-editor"), "the editable issue description");
  await setField("issue-description-editor", "Discard this issue body edit.");
  dismiss("issue-description-cancel");
  await until(() => !has("issue-description-editor"), "cancelled description edit");
  assert.equal(remote().body, "Original issue 71 body");
  await setField("issue-comment-editor", "Repeated text");
  await openLinked();
  await until(() => matches("issue-comment-editor", "Repeated text"), "comment draft shared with the linked detail");
  mode("lost-pending");
  press("issue-comment-submit");
  await until(() => visible("issue-write-check") && visible("issue-comment-submit").includes("enabled=false") &&
    remote().pending?.body === "Repeated text", "accepted write with an uncertain acknowledgement");
  press("issue-write-check");
  await until(() => visible("issue-write-check") && value("issue-write-error").includes("has not confirmed"), "unconfirmed readback");
  assert.equal(remote().comments.length, 1);
  dismiss("pr-close");
  await quit();
  await launch("pull-requests", root);
  press("pull-requests");
  await until(() => visible("github-tab-linked-items"), "return to Linked items after quitting with a pending receipt");
  await openLinked();
  await until(() => visible("issue-write-check") && visible("issue-comment-submit").includes("enabled=false") &&
    matches("issue-comment-editor", "Repeated text"), "unconfirmed comment and disabled Submit survived relaunch");
  assert.deepEqual(writes().map(entry => entry.method), ["PATCH", "PATCH", "POST"]);
  mode("reveal");
  dismiss("issue-write-check");
  await until(() => value("issue-comment-body-posted-2").includes("Repeated text") && !has("issue-write-check") &&
    matches("issue-comment-editor", ""), "readback of the new comment");
  assert.deepEqual(writes().map(entry => entry.method), ["PATCH", "PATCH", "POST"]);
  assert(writes().every(entry => entry.cwd === realpathSync(checkout) && entry.repo === "fixture/workspace" && entry.number === 71));
  assert.deepEqual(remote().comments.map(comment => comment.id), ["previous-1", "posted-2"]);
  dismiss("pr-close");
  await until(() => matches("composer", original), "return to the original chat draft");
  await quit();
  await launch("pull-requests", root);
  press("pull-requests");
  await until(() => visible("github-tab-linked-items"), "linked items after relaunch");
  const requestCount = requests().length;
  await openLinked();
  await until(() => value("issue-detail-title").includes(title) && visible("issue-comment-body-posted-2"), "saved title and comment after relaunch");
  assert(requests().slice(requestCount).some(entry => entry.kind === "snapshot" && entry.cwd === realpathSync(checkout) &&
    entry.repo === "fixture/workspace" && entry.number === 71));
  dismiss("pr-close");
  await until(() => matches("composer", original), "restored composer");
  await quit();
  const saved = JSON.parse(readFileSync(indexPath, "utf8")).projects[0];
  assert.equal(saved.selectedConversation, threadID);
  assert.equal(realpathSync(saved.conversations.find(t => t.id === threadID).location.worktree.path), realpathSync(checkout));
  assert.equal(saved.conversations.find(t => t.id === otherID).composerText, other);
  assert.equal(writes().length, 3);
  record("With a private mock GitHub CLI, a denied title edit kept the text and retry updated issue #71. Cancelling description edits left its body intact. One comment POST lost its acknowledgement. After quitting and reopening, Submit remained disabled and Check result found the new ID among two identical comments. A second relaunch retained the title, comment, selected checkout and chat drafts.");
}
