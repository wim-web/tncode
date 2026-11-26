import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { verifyCheckLog } from "./verify-panels.mjs";

export async function verifySidebarPersistence(driver, { root, git, launch, quit, record, stateFile, logFile }) {
  const { until, press, dismiss, visible, value, tree, click } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const projects = ["Alpha", "Beta", "Gamma"].map(title => {
    const id = uuid(), thread = uuid(), path = join(root, title);
    mkdirSync(path, { recursive: true });
    return { id, title, path, allowEdits: false, selectedConversation: thread,
      conversations: [{ id: thread, title: title + " draft", isDraft: true, archived: false, composerText: title + " unsent" }] };
  });
  const [alpha, beta, gamma] = projects;
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
  const current = () => index().selectedProject === gamma.id && value("composer").includes("Gamma unsent");
  async function filters() {
    press("thread-filters");
    await until(() => visible(choice(alpha)), "the project choices");
  }
  await launch("model-settings", root);
  await until(() => current() && visible(row(alpha)), "three drafts in the original workspace");
  await filters();
  press("group-threads-by-project");
  click(choice(alpha));
  await until(() => !has("close-thread-filters") && included().join() === alpha.id && visible(row(alpha)) && !has(row(gamma)), "plain click selected one project and closed the picker");
  await filters();
  click(choice(beta), "shift");
  await until(() => included().includes(beta.id) && visible("close-thread-filters"), "Shift-click added Beta to the open picker");
  click(choice(beta), "shift");
  await until(() => !included().includes(beta.id) && visible("close-thread-filters"), "Shift-click removed just Beta");
  press("project-filter-" + beta.id);
  dismiss("close-thread-filters");
  await until(() => visible(row(alpha)) && visible(row(beta)), "both selected folders");
  press("project-group-" + alpha.id);
  await until(() => !has(row(alpha)) && visible(row(beta)) && current(), "collapse kept the open draft in Gamma");
  await quit();
  await launch("model-settings", root);
  await until(() => !has(row(alpha)) && visible(row(beta)) && !has(row(gamma)) && current(), "scope and disclosure across process restart");
  assert.deepEqual(included().sort(), [alpha.id, beta.id].sort());
  await filters();
  press("project-filter-all");
  dismiss("close-thread-filters");
  await until(() => visible(row(gamma)) && !has(row(alpha)) && current(), "reset restored Gamma and preserved Alpha disclosure");
  press("project-group-" + alpha.id);
  await until(() => visible(row(alpha)) && !included().length && current(), "reset and expand restored every row");
  record("A plain project click selected only Alpha. Two Shift-clicks added and removed Beta with the picker still open. After a checkbox added Beta and Alpha was collapsed, relaunch restored both settings and Gamma's selected unsent draft. All Projects and expanding Alpha restored all three rows.");
  writeFileSync(stateFile, "check-logs-denied\n");
  press("pull-requests");
  await until(() => visible("pr-row-42"), "pull request from Gamma's checkout");
  press("pr-row-42");
  await until(() => visible("pr-check-log-1"), "selected PR checks");
  await verifyCheckLog(driver, stateFile, logFile, gamma.path);
  dismiss("pr-close");
  await until(() => current() && !has("pr-close"), "return from failed job logs to Gamma's draft");
  await quit();
  record("PR #42's second check reported a denied Actions log. Retry displayed ONLY-TESTS-61002 from job 61002 in Gamma's checkout. Back returned to its checks, and closing the panel restored the draft.");
}
