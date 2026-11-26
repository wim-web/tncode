import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { seedPaletteMessageHistory } from "./fixtures/palette-message-history.mjs";

const [ax, builtApp = resolve(import.meta.dirname, "../dist/Pi Workspace.app"), mode] = process.argv.slice(2);
assert(ax && (!mode || mode === "--baseline"), "Usage: node verify-draft-links.mjs AX_BINARY [PI_WORKSPACE_APP] [--baseline]");
assert.match(execFileSync(ax, ["trust"], { encoding: "utf8" }), /accessibility=true/);
process.umask(0o077);
const root = mkdtempSync("/private/tmp/pi-workspace-verification-");
const app = join(mkdtempSync(join(root, "pi-workspace-test-app-")), "Pi Workspace.app");
const workspace = join(root, "workspace"), indexPath = join(workspace, "workspace.json");
const repo = join(root, "Project"), board = "dev.piworkspace.verification." + randomUUID();
const writer = join(root, "write-pasteboard");
const uuid = () => randomUUID().toUpperCase();
const projectID = uuid(), draftID = uuid(), submittedID = uuid(), scratchID = uuid(), scratchProject = uuid();
const scratch = join(workspace, "scratch", scratchProject);
const queued = { id: uuid(), text: "Queued follow-up" };
const attachment = name => ({ id: uuid(), name, payload: {
  mimeType: "text/plain", data: Buffer.from("Private fixture bytes for " + name + " 🌱").toString("base64"),
} });
const projectDraft = { id: draftID, title: "Planned draft", archived: false, isDraft: true,
  composerText: "Plan a local checkout 🌱", composerAttachments: [attachment("plan.txt")],
  location: { newWorktree: { branch: "topic/draft-link", base: "refs/heads/main" } },
};
const scratchDraft = { id: scratchID, title: "Scratch draft", archived: false, isDraft: true,
  composerText: "Keep this scratch draft", composerAttachments: [attachment("scratch.txt")],
};
const git = (...args) => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" });
const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
const selected = () => {
  const state = index();
  const project = state.projects.find(project => project.id === state.selectedProject);
  return [project?.id, project?.selectedConversation];
};
const thread = id => index().projects.flatMap(project => project.conversations).find(thread => thread.id === id);
const ids = () => index().projects.flatMap(project => project.conversations.map(thread => thread.id)).sort();
const standardized = path => execFileSync(ax, ["workspace-path", path], { encoding: "utf8" }).trim();
const scope = (id, path = standardized(workspace)) => createHash("sha256").update(id + "/" + path).digest("hex");
const link = id => "pi-workspace://draft/v1/" + scope(index().threadLinkID) + "/" + id;
const put = text => execFileSync(writer, [board, "text"], { input: text });
const checkCopy = text => execFileSync(ax, ["check-copy", board], { input: text, stdio: ["pipe", "pipe", "pipe"] });
const binary = join(app, "Contents/MacOS/PiWorkspace");
const launchArgs = ["--workspace", workspace, "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)"];
let pid, attempt = 0, succeeded = false;

async function until(check, description) {
  const stop = Date.now() + 15_000;
  let failure;
  while (Date.now() < stop) {
    try { if (check()) return; } catch (error) { failure = error; }
    await delay(100);
  }
  throw new Error("Timed out waiting for " + description, { cause: failure });
}
const drive = (action, ...args) => execFileSync(ax, [action, String(pid), ...args], {
  encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], timeout: 5000,
});
const value = id => drive("get", id, "--values");
const has = id => { try { value(id); return true; } catch { return false; } };
const composer = text => value("composer").includes("value=" + JSON.stringify(text));
const press = id => drive("press", id, "--no-activate");
const row = id => "thread-row-" + id;
const openURL = url => drive("open-thread-link", url, "--no-activate");
const openClipboard = () => drive("menu-item", "Open Thread Link from Clipboard", "--no-activate");
async function launch() {
  execFileSync("/usr/bin/open", ["-g", "-n", "-a", app, "--stdout", join(root, "launch-" + ++attempt + ".out"),
    "--stderr", join(root, "launch-" + attempt + ".err"), "--env", "PI_WORKSPACE_TEST_PASTEBOARD=" + board, "--args", ...launchArgs]);
  await until(() => {
    const processes = execFileSync("/bin/ps", ["-axo", "pid=,args="], { encoding: "utf8" });
    const process = processes.split("\n").find(line => line.includes(binary + " --workspace " + workspace + " "));
    if (process) pid = Number(process.trim().split(/\s+/)[0]);
    return pid && has("composer");
  }, "the background workspace");
}
async function quit() {
  const exiting = pid;
  press("terminate:");
  await until(() => {
    try { process.kill(exiting, 0); return false; } catch (error) { return error.code === "ESRCH"; }
  }, "the background app to quit");
  pid = undefined;
}
async function showCopy() {
  press("conversation-title");
  await until(() => has("draft-copy"), "the draft title’s Copy submenu");
  press("draft-copy");
  await until(() => has("draft-copy-path"), "the Copy submenu items");
}
async function copyDraft(id) {
  await showCopy();
  press("draft-copy-link");
  await until(() => { checkCopy(link(id)); return true; }, "the exact private draft URL");
  return link(id);
}
async function expectDraft(project, draft) {
  await until(() => selected()[1] === draft.id && composer(draft.composerText) &&
    has("remove-attachment-" + draft.composerAttachments[0].id), "the intended draft and attachment");
  assert.deepEqual(selected(), [project, draft.id]);
  assert.deepEqual(thread(draft.id), draft);
}
async function rejectURL(url, message) {
  const before = readFileSync(indexPath);
  openURL(url);
  await until(() => value("thread-link-error").includes(message), "the rejected link banner");
  assert(readFileSync(indexPath).equals(before), "A rejected link changed the workspace file.");
}

try {
  execFileSync("codesign", ["--verify", "--deep", "--strict", builtApp]);
  cpSync(builtApp, app, { recursive: true, verbatimSymlinks: true });
  execFileSync("xcrun", ["swiftc", "-module-cache-path", join(root, "module-cache"),
    join(import.meta.dirname, "fixtures/write-pasteboard.swift"), "-o", writer]);
  mkdirSync(repo);
  mkdirSync(scratch, { recursive: true });
  git("init", "--template=", "-b", "main");
  git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
    "commit", "--allow-empty", "-m", "Initial");
  const worktrees = git("worktree", "list", "--porcelain");

  writeFileSync(indexPath, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
    projects: [
      { id: projectID, title: "Draft link project", path: repo, allowEdits: false, selectedConversation: draftID,
        conversations: [projectDraft, { id: submittedID, title: "Submitted", isDraft: false, archived: false,
          composerText: "Keep the ordinary follow-up", queuedMessages: [queued] }] },
      { id: scratchProject, kind: "scratch", title: "No project", path: scratch, allowEdits: false,
        selectedConversation: scratchID, conversations: [scratchDraft] },
    ],
    model: { provider: "local", model: "draft-link-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
  }));
  const sidecar = join(app, "Contents/Resources/Sidecar");
  const history = await seedPaletteMessageHistory({
    sidecar, workspace, projectID, threadID: submittedID, cwd: repo, keyword: "submitted fixture",
  });
  await launch();
  await expectDraft(projectID, projectDraft);

  if (mode === "--baseline") {
    await showCopy();
    assert(!has("draft-copy-link"), "Baseline already offers a native draft link.");
    press("draft-copy-path");
    await until(() => { checkCopy(repo); return true; }, "the baseline’s copied project path");
    put("pi-workspace://draft/v1/" + scope(uuid()) + "/" + draftID);
    openClipboard();
    await until(() => value("thread-link-error").includes("Enter a Pi Workspace thread link"), "baseline rejection of the draft URL");
    await expectDraft(projectID, projectDraft);
    await quit();
    console.log("Baseline: the draft Copy submenu has no Draft Link, and the draft URL is rejected.");
  } else {
    const originalIDs = ids();
    const projectURL = await copyDraft(draftID);
    press(row(scratchID));
    await expectDraft(scratchProject, scratchDraft);
    const scratchURL = await copyDraft(scratchID);
    press(row(submittedID));
    await until(() => has("transcript-message-" + history.latestID), "the submitted Pi history");
    press("queue-item-actions-" + queued.id);
    await until(() => has("queue-edit-" + queued.id), "the queued message actions");
    press("queue-edit-" + queued.id);
    await until(() => composer(queued.text) && has("queue-update"), "an active queue edit");
    await rejectURL(projectURL, "queued message edit");
    assert(composer(queued.text) && has("queue-update"));
    press("queue-cancel-edit");
    await until(() => composer("Keep the ordinary follow-up"), "the submitted thread’s ordinary draft");

    openClipboard();
    await expectDraft(scratchProject, scratchDraft);
    await quit();
    await launch();
    openURL(projectURL);
    await expectDraft(projectID, projectDraft);
    assert.deepEqual(ids(), originalIDs);
    assert.equal(git("worktree", "list", "--porcelain"), worktrees);
    await rejectURL(link(uuid()), "linked draft is unavailable");
    const workspaceID = index().threadLinkID;
    const foreignScope = scope(workspaceID, standardized(workspace) + "-copy");
    await rejectURL(scratchURL.replace(scope(workspaceID), foreignScope), "different Pi Workspace");
    const moved = scratch + ".moved";
    renameSync(scratch, moved);
    try { await rejectURL(scratchURL, "checkout is unavailable"); } finally { renameSync(moved, scratch); }
    openURL(scratchURL);
    await expectDraft(scratchProject, scratchDraft);
    assert.deepEqual(ids(), originalIDs);
    console.log("Draft Copy, Edit, and macOS URL opening preserved UUIDs, both scopes, attachment bytes, and the checkout plan across relaunch. Unknown, foreign, missing-folder, and queue-edit attempts kept selection and draft count.");

    await quit();
    const accepted = await seedPaletteMessageHistory({ sidecar, workspace, projectID: scratchProject,
      threadID: scratchID, cwd: scratch, keyword: "draft promotion" });
    // Replay a first prompt accepted by Pi just before the client recorded the submission.
    const state = index();
    const pending = state.projects.find(project => project.id === scratchProject).conversations[0];
    pending.composerText = "What happened later?";
    pending.composerSubmission = { previousUserMessageID: accepted.messageID };
    writeFileSync(indexPath, JSON.stringify(state));
    await launch();
    const promotedReply = "transcript-message-" + accepted.latestID;
    await until(() => thread(scratchID).isDraft === false && has(promotedReply), "Pi history confirming the first submission");
    openURL(projectURL);
    await expectDraft(projectID, projectDraft);
    openURL(scratchURL);
    await until(() => selected()[1] === scratchID && has(promotedReply), "the same-session promoted draft link");
    openURL(projectURL);
    await expectDraft(projectID, projectDraft);
    await quit();
    await launch();
    await rejectURL(scratchURL, "linked draft is unavailable");
    assert.deepEqual(ids(), originalIDs);
    press(row(scratchID));
    await until(() => has(promotedReply), "Pi history still available from the submitted row");
    openURL(projectURL);
    await expectDraft(projectID, projectDraft);
    await until(() => !has("thread-link-error"), "the error banner to clear after a valid link");
    press("thread-project-new-thread");
    await until(() => {
      const [project, draft] = selected();
      return project === projectID && draft && !originalIDs.includes(draft);
    }, "a fresh draft from the project’s New Thread button");
    const withNewDraft = ids();
    assert.equal(withNewDraft.length, originalIDs.length + 1);
    openURL(projectURL);
    await expectDraft(projectID, projectDraft);
    assert.deepEqual(ids(), withNewDraft);
    press("conversation-title");
    await until(() => has("discard-draft"), "the draft’s Discard action");
    press("discard-draft");
    await until(() => !thread(draftID), "the linked draft was discarded");
    await rejectURL(projectURL, "linked draft is unavailable");
    console.log("The original scratch link followed its Pi thread during the launch that submitted it. Across relaunch it became stale, and a deleted draft link preserved the current selection.");
    await quit();
  }
  succeeded = true;
} catch (error) {
  if (pid) {
    try { writeFileSync(join(root, "failure-ui.txt"), drive("dump", "--values")); } catch {}
  }
  console.error("Private replay diagnostics are in " + root);
  throw error;
} finally {
  if (pid) { try { process.kill(pid); } catch {} }
  execFileSync(ax, ["release-test-pasteboard", board]);
  if (succeeded) rmSync(root, { recursive: true, force: true });
}
