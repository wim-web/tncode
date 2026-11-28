import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";

const archive = "sample.zip";
const folder = "資料";
const binary = Buffer.from([0x00, 0x41, 0xff, 0x10]);
const uuid = () => randomUUID().toUpperCase();
const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");

function writeArchive(destination, entries) {
  const source = mkdtempSync(join(dirname(destination), "zip-source-"));
  try {
    for (const [name, bytes] of entries) {
      const path = join(source, name);
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, bytes);
    }
    execFileSync("/usr/bin/zip", ["-q", "-X", destination, ...entries.map(([name]) => name)], { cwd: source });
  } finally {
    rmSync(source, { recursive: true });
  }
}

function checkoutSnapshot(checkout, git) {
  const files = new Map(readdirSync(checkout, { recursive: true, withFileTypes: true }).map(entry => {
    const path = join(entry.parentPath, entry.name);
    return [relative(checkout, path), entry.isFile() ? sha256(readFileSync(path)) : null];
  }));
  const indexPath = git(checkout, "rev-parse", "--path-format=absolute", "--git-path", "index");
  return {
    files,
    index: sha256(readFileSync(indexPath)),
    head: git(checkout, "rev-parse", "HEAD"),
    staged: git(checkout, "ls-files", "--stage"),
    status: git(checkout, "--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=all"),
  };
}

export async function verifyArchiveFiles(driver, { root, app, git, launch, quit, record }) {
  const { dismiss, press, tree, until, value, visible } = driver;
  execFileSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", app]);

  const repo = join(root, "Repo");
  mkdirSync(repo, { recursive: true });
  git(repo, "init", "--template=", "-b", "main");
  git(repo, "config", "core.hooksPath", "/dev/null");
  writeFileSync(join(repo, "tracked.txt"), "Committed baseline\n");
  git(repo, "add", "--", "tracked.txt");
  git(repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
      "commit", "-m", "Archive fixture");

  const fixtures = [
    { branch: "tokyo", member: "東京.txt", text: "東京の記録 café\nSecond line.\n" },
    { branch: "osaka", member: "大阪.txt", text: "大阪の記録 🍊\nDifferent second line.\n" },
  ].map(fixture => {
    const checkout = join(root, fixture.branch);
    git(repo, "worktree", "add", "-b", fixture.branch, checkout, "HEAD");
    const tracked = join(checkout, "tracked.txt");
    writeFileSync(tracked, "Staged " + fixture.branch + "\n");
    git(checkout, "add", "--", "tracked.txt");
    writeFileSync(tracked, "Unstaged " + fixture.branch + "\n");
    writeFileSync(join(checkout, "ordinary.bin"), binary);
    writeArchive(join(checkout, archive), [[folder + "/" + fixture.member, fixture.text], ["member.bin", binary]]);
    const conversation = {
      id: uuid(), title: fixture.branch, isDraft: true, archived: false,
      composerText: "Keep " + fixture.branch + " draft",
      queuedMessages: [{ id: uuid(), text: "Keep " + fixture.branch + " queued message" }],
      location: { worktree: { path: checkout, base: "main" } },
    };
    return { ...fixture, checkout, conversation };
  });
  const [first, second] = fixtures;
  const projectID = uuid();
  const statePath = join(root, "workspace.json");
  writeFileSync(statePath, JSON.stringify({
    welcomeCompleted: true, selectedProject: projectID,
    projects: [{ id: projectID, path: repo, title: "Archive previews", allowEdits: false,
      selectedConversation: first.conversation.id, conversations: fixtures.map(fixture => fixture.conversation) }],
    model: { provider: "local", model: "archive-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
  }), { mode: 0o600 });

  const before = fixtures.map(({ checkout }) => checkoutSnapshot(checkout, git));
  const worktrees = git(repo, "worktree", "list", "--porcelain");
  const has = id => tree().includes('id="' + id + '"');
  const displays = (id, text) => value(id).includes("value=" + JSON.stringify(text));
  function row(name) {
    const labelPrefix = JSON.stringify(name + ", ").slice(0, -1);
    const line = tree().split("\n").find(line => line.includes('id="files-archive-row-') && line.includes(labelPrefix));
    return line?.match(/id="(files-archive-row-[^"]+)"/)?.[1];
  }
  const waitForRow = name => until(() => row(name), "archive row " + name);
  const choose = async name => dismiss(await waitForRow(name));
  const archivePath = path => displays("files-archive-path", path);

  async function showComposer({ conversation }) {
    const [queued] = conversation.queuedMessages;
    await until(() => displays("composer", conversation.composerText) &&
      displays("queued-message-" + queued.id, queued.text), conversation.title + " draft and queued message");
  }

  async function showFiles() {
    if (!has("hide-right-panel")) dismiss("toggle-right-panel");
    await until(() => visible("add-panel-surface"), "Add Panel Surface in the right panel");
    dismiss("add-panel-surface");
    await until(() => visible("add-panel-files").includes("enabled=true"), "Files in Add Panel Surface");
    dismiss("add-panel-files");
  }

  async function openFile(name) {
    if (!has("files-search")) await showFiles();
    const id = "files-row-" + name;
    await until(() => visible(id), name + " in Files");
    dismiss(id);
  }

  async function readMember(memberFolder, member, text) {
    await choose(memberFolder);
    await until(() => archivePath(memberFolder + "/"), "archive folder " + memberFolder);
    await choose(member);
    await until(() => archivePath(memberFolder + "/" + member) && displays("files-archive-text", text),
                "full path and exact text of " + member);
    assert(value("files-archive-entry-metadata").includes(Buffer.byteLength(text) + " B"));
    assert(!has("files-editor") && !has("files-save"), "archive text is read-only");
  }

  await launch("composer", root, undefined, true);
  for (const fixture of fixtures) {
    if (fixture !== first) press("thread-row-" + fixture.conversation.id);
    await showComposer(fixture);
    await openFile(archive);
    await until(() => visible("files-archive-entries") && visible("files-archive-back").includes("enabled=false"),
                "archive root in " + fixture.branch);
    await readMember(folder, fixture.member, fixture.text);
    dismiss("files-archive-back");
    await until(() => archivePath(folder + "/") && row(fixture.member), "return to the member's folder");
    dismiss("files-archive-back");
    await waitForRow(folder);
  }
  record("Files showed the exact Unicode member path, text and UTF-8 size in each linked checkout at sample.zip. Back returned to the folder and archive root.");

  await choose("member.bin");
  await until(() => value("files-archive-error").includes("Only UTF-8 text and images"), "unsupported binary archive member");
  await openFile("ordinary.bin");
  await until(() => visible("files-binary-preview") && value("files-contents").includes("00 41 FF 10") &&
    !has("files-archive-preview"), "ordinary binary hex preview");
  await openFile(archive);
  await waitForRow(folder);
  for (const [i, { checkout }] of fixtures.entries()) {
    assert.deepEqual(checkoutSnapshot(checkout, git), before[i], "preview changed " + checkout);
  }

  const target = join(second.checkout, archive);
  const replacement = join(root, "replacement.zip");
  const malformed = Buffer.from("PK\x03\x04\x00truncated ZIP");
  writeFileSync(replacement, malformed);
  renameSync(replacement, target);
  await choose(folder);
  await until(() => value("files-archive-error").includes("changed on disk") && !has("files-archive-entries"),
              "archive invalidation after a malformed replacement");
  dismiss("files-preview-retry");
  await until(() => value("files-preview-error").includes("unreadable or damaged"),
              "Retry reports the malformed archive");
  assert.deepEqual(readFileSync(target), malformed);

  const repaired = { folder: "修復", member: "再試行.txt", text: "Reopened archive 日本語\n" };
  writeArchive(replacement, [[repaired.folder + "/" + repaired.member, repaired.text]]);
  const repairedHash = sha256(readFileSync(replacement));
  renameSync(replacement, target);
  dismiss("files-preview-retry");
  await readMember(repaired.folder, repaired.member, repaired.text);
  await showComposer(second);
  press("thread-row-" + first.conversation.id);
  await showComposer(first);
  await quit();

  before[1].files.set(archive, repairedHash);
  const { projects } = JSON.parse(readFileSync(statePath, "utf8"));
  for (const [i, { checkout, conversation }] of fixtures.entries()) {
    assert.deepEqual(checkoutSnapshot(checkout, git), before[i], "Retry changed " + checkout);
    const saved = projects.find(project => project.id === projectID).conversations.find(thread => thread.id === conversation.id);
    assert.equal(saved.composerText, conversation.composerText);
    assert.deepEqual(saved.queuedMessages, conversation.queuedMessages);
  }
  assert.equal(git(repo, "worktree", "list", "--porcelain"), worktrees);
  const memberNames = [folder, repaired.folder, first.member, second.member, repaired.member, "member.bin"];
  const exported = readdirSync(root, { recursive: true, withFileTypes: true })
    .filter(entry => memberNames.includes(entry.name))
    .map(entry => join(entry.parentPath, entry.name));
  assert.deepEqual(exported, [], "archive members left on disk under the fixture root");
  record("A binary archive member was refused. An ordinary binary showed its hex bytes. A malformed replacement invalidated the listing, and Retry surfaced the error and then opened the repaired archive.");
  record("Both drafts, queues, Git indexes, staged entries, status and checkout paths survived. The checkout bytes matched after accounting for the intentional archive replacement. No exported members remained under the fixture root.");
}
