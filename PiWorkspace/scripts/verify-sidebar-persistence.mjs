import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { verifyCheckLog, verifyPRCode } from "./verify-panels.mjs";

export async function verifySidebarPersistence(driver, { root, git, launch, quit, record, stateFile, logFile }) {
  const { until, press, dismiss, visible, value, tree, click, setField, keyFor, showMenu } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const projects = ["Alpha", "Beta", "Gamma"].map(title => {
    const id = uuid(), thread = uuid(), path = join(root, title);
    mkdirSync(path, { recursive: true });
    return { id, title, path, allowEdits: false, selectedConversation: thread,
      conversations: [{ id: thread, title: title + " draft", isDraft: true, archived: false, composerText: title + " unsent" }] };
  });
  const [alpha, beta, gamma] = projects;
  beta.conversations[0] = { id: beta.selectedConversation, title: "Beta thread", archived: false };
  const empty = { id: uuid(), title: "Empty", path: join(root, "Empty"), allowEdits: false, conversations: [] };
  mkdirSync(empty.path, { recursive: true });
  projects.push(empty);
  git(gamma.path, "init", "--template=", "-b", "main");
  git(gamma.path, "remote", "add", "origin", "https://github.com/fixture/workspace.git");
  const indexPath = join(root, "workspace.json");
  writeFileSync(indexPath, JSON.stringify({ selectedProject: gamma.id, projects, welcomeCompleted: true,
    model: { provider: "local", model: "sidebar-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 } }), { mode: 0o600 });
  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const has = id => tree().includes('id="' + id + '"');
  const row = project => "thread-row-" + project.selectedConversation;
  const choice = project => "project-filter-choice-" + project.id;
  const included = () => index().projects.filter(p => p.inSidebarScope).map(p => p.id);
  const scopedTo = (...expected) => included().sort().join() === expected.sort().join();
  const current = () => index().selectedProject === gamma.id && value("composer").includes("Gamma unsent");
  const search = "project-filter-search";
  async function filters() {
    press("thread-filters");
    await until(() => visible(choice(alpha)), "the project choices");
  }
  await launch("model-settings", root);
  await until(() => current() && visible(row(alpha)), "the original workspace and Gamma's draft");
  await filters();
  if (!/value=1\b/.test(value("group-threads-by-project"))) press("group-threads-by-project");
  click(choice(alpha));
  await until(() => !has(search) && scopedTo(alpha.id) && visible(row(alpha)) && !has(row(gamma)), "plain click selected one project and closed the picker");
  await filters();
  click(choice(beta), "shift");
  await until(() => scopedTo(alpha.id, beta.id) && visible("close-thread-filters"), "Shift-click added Beta to the open picker");
  click(choice(beta), "shift");
  await until(() => scopedTo(alpha.id) && visible("close-thread-filters"), "Shift-click removed just Beta");
  await setField(search, "no such project", () => has("project-filter-no-results"));
  keyFor(search, 36);
  await until(() => scopedTo(alpha.id) && visible("project-filter-no-results"), "Return on an unmatched query left the picker open");
  await setField(search, "a", () => has(choice(alpha)) && has(choice(beta)) && !has(choice(empty)));
  assert(!has("project-filter-all"));
  keyFor(search, 125);
  keyFor(search, 36, "shift");
  await until(() => scopedTo(alpha.id, beta.id) && value(search).includes('value="a"'), "Down and Shift-Return added Beta without changing the query");
  keyFor(search, 36, "shift");
  await until(() => scopedTo(alpha.id) && visible(search), "Shift-Return removed Beta and kept the picker open");
  press("project-filter-" + beta.id);
  dismiss("close-thread-filters");
  await until(() => visible(row(alpha)) && visible(row(beta)), "both selected folders");
  press("project-group-" + alpha.id);
  await until(() => !has(row(alpha)) && visible(row(beta)) && current(), "collapse kept the open draft in Gamma");
  await quit();
  await launch("model-settings", root);
  await until(() => !has(row(alpha)) && visible(row(beta)) && !has(row(gamma)) && current(), "scope and disclosure across process restart");
  assert(scopedTo(alpha.id, beta.id));
  await filters();
  press("project-filter-all");
  await until(() => !has(search) && scopedTo() && visible(row(gamma)) && !has(row(alpha)) && current(),
    "All Projects restored Gamma and preserved Alpha disclosure");
  await filters();
  await setField(search, "EMPTY", () => has(choice(empty)) && !has(choice(beta)));
  keyFor(search, 36);
  await until(() => !has(search) && scopedTo(empty.id) && visible("sidebar-clear-project-scope") && !has(row(gamma)) && current(),
    "Return selected the empty project and preserved Gamma's draft");
  press("sidebar-clear-project-scope");
  await until(() => scopedTo() && visible(row(gamma)) && !has(row(alpha)) && current(),
    "Show All Projects recovered the empty sidebar");
  press("project-group-" + alpha.id);
  await until(() => visible(row(alpha)) && scopedTo() && current(), "reset and expand restored every row");
  record("A plain click selected Alpha. Shift-click and Shift-Return each added and removed Beta in the open picker. Return on an unmatched query left the scope unchanged.");
  record("A checkbox added Beta. Relaunch restored the exact scope, Alpha's collapsed folder, and Gamma's unsent draft. All Projects cleared the scope.");
  record("Searching for Empty and pressing Return hid the thread list. Show All Projects brought the threads back, and expanding Alpha restored its row.");
  async function betaMenu(title) {
    await until(() => { showMenu(row(beta)); return true; }, "open Beta's thread menu");
    await until(() => visible("thread-project-scope").includes(title), title);
    dismiss("thread-project-scope");
  }
  await betaMenu("Filter by Beta");
  await until(() => scopedTo(beta.id) && !has(row(alpha)) && !has(row(gamma)) && current(), "Beta's thread menu applied its scope");
  await betaMenu("Show All Projects");
  await until(() => scopedTo() && visible(row(alpha)) && visible(row(gamma)) && current(), "Beta's thread menu cleared the scope");
  record("Beta's thread menu applied and cleared its project scope while Gamma's draft stayed active.");
  press("sidebar-home");
  await until(() => index().selectedProject == null && tree().includes("What should we work on?"), "sidebar brand opens home");
  press("workspace-history-back");
  await until(() => current() && visible("workspace-history-forward").includes("enabled=true"), "Back restored Gamma and its draft");
  press("workspace-history-forward");
  await until(() => index().selectedProject == null && tree().includes("What should we work on?"), "Forward restored Home");
  press(row(gamma));
  await until(() => current() && index().projects.find(p => p.id === gamma.id).selectedConversation === gamma.selectedConversation, "same draft after returning from Home");
  record("The sidebar brand opened Home. Back restored Gamma, Forward returned to Home, and reopening Gamma's row retained the same draft ID and unsent text.");
  writeFileSync(stateFile, "check-logs-denied\n");
  press("pull-requests");
  await until(() => visible("pr-row-42"), "pull request from Gamma's checkout");
  press("pr-row-42");
  await until(() => visible("pr-check-log-1"), "selected PR checks");
  await verifyCheckLog(driver, stateFile, logFile, gamma.path);
  await verifyPRCode(driver, stateFile, logFile, gamma.path);
  dismiss("pr-close");
  await until(() => current() && !has("pr-close"), "return from failed job logs to Gamma's draft");
  await quit();
  record("PR #42's second check reported a denied Actions log. Retry displayed ONLY-TESTS-61002 from job 61002 in Gamma's checkout. Back returned to its checks, and closing the panel restored the draft.");
  record("Code loaded PR #42's forge patch, the rename's old path and separate patch, and no prior text for a binary file. Paging loaded file 31. A changed head cleared the old patch until Refresh loaded seven current files.");
}
