import assert from "node:assert/strict";
import { readFileSync, renameSync } from "node:fs";
import { dirname, join } from "node:path";

export async function verifyUsage({ press, pick, segment, menuItem, visible, value, tree, until, focus, keyFor }, fixture, relaunch) {
  const index = () => JSON.parse(readFileSync(fixture.workspaceFile, "utf8"));
  const before = index();
  const expected = (id, text) => value(id).includes("value=" + JSON.stringify(text));
  const total = (text, id = "usage-total") => until(() => expected(id, text), id + " to show " + text);
  async function project(name, tokens) {
    pick("usage-project", name);
    await total(tokens);
  }
  focus("composer");
  keyFor("composer", 32, "cmd");
  const heading = "settings-heading-usage";
  await until(() => visible(heading).includes("focused=true") && expected("usage-total", "480 tokens + unreported"),
              "Command-U opens the Usage controls");
  for (const [code, tokens] of [[18, 310], [19, 350], [21, 720], [20, 480]]) {
    keyFor(heading, code, "cmd", "shift");
    await total(tokens + " tokens + unreported");
  }
  keyFor(heading, 8);
  await until(() => value("usage-total").includes("0.0082 + unreported"), "C chooses cost");
  keyFor(heading, 37);
  await until(() => visible("usage-limits-unavailable"), "L chooses limits");
  keyFor(heading, 18, "cmd", "shift");
  keyFor(heading, 17);
  await total("480 tokens + unreported");
  keyFor(heading, 3, "cmd");
  await until(() => visible("settings-search").includes("focused=true"), "focus the settings search field");
  keyFor("settings-search", 8);
  await until(() => expected("settings-search", "c") && expected("usage-total", "480 tokens + unreported"), "C edits a focused text field");
  keyFor("settings-search", 53);
  press("settings-nav-usage");
  await until(() => visible(heading).includes("focused=true"), "return focus to usage");
  keyFor(heading, 32, "cmd");
  await until(() => !tree().includes('id="settings-search"') && expected("composer", "Preserve this usage fixture draft."),
              "Command-U closes Usage");
  press("model-settings");
  await until(() => visible("settings-nav-usage"), "Usage in Settings navigation");
  press("settings-nav-usage");
  await total("480 tokens + unreported");
  for (const [label, tokens] of [["Past 24h", 310], ["7 days", 350], ["90 days", 720], ["30 days", 480]]) {
    segment("usage-period", label);
    await total(tokens + " tokens + unreported");
  }
  segment("usage-metric", "Cost");
  await until(() => /0\.0082 \+ unreported/.test(value("usage-total")) && visible("usage-cost-basis"), "saved USD cost and missing costs");
  segment("usage-metric", "Limits");
  await until(() => visible("usage-limits-unavailable"), "limits availability for the local workspace");
  segment("usage-metric", "Tokens");
  await project("Usage Alpha", "330 tokens");
  await project("Usage Beta", "150 tokens + unreported");
  await project("All projects", "480 tokens + unreported");
  press("usage-providers");
  await until(() => visible("usage-provider-local"), "local provider choice");
  press("usage-provider-local");
  await total("340 tokens");
  press("usage-providers");
  press("usage-provider-all");
  await total("480 tokens + unreported");
  press("usage-model-openai-usage-shared-model");
  await total("200 tokens", "usage-detail-total");
  assert(visible("usage-model-heading").includes('description="usage-shared-model"'));
  for (const [kind, amount] of [["input", 125], ["output", 55], ["cacheRead", 15], ["cacheWrite", 5]]) {
    assert(expected("usage-detail-" + kind, amount + " tokens"));
  }
  assert(value("usage-detail-cost").includes("0.0037"));
  press("usage-model-back");
  segment("usage-breakdown", "Day");
  await until(() => /id="usage-time-\d+"/.test(tree()), "daily token totals");
  await fixture.appendUsage();
  assert(expected("usage-total", "480 tokens + unreported"));
  press("usage-refresh");
  await total("503 tokens + unreported");
  const heldFork = join(dirname(fixture.workspaceFile), "held-fork.jsonl");
  renameSync(fixture.forkFile, heldFork);
  try {
    press("usage-refresh");
    await total("443 tokens + unreported");
    assert(visible("usage-incomplete-histories"));
  } finally {
    renameSync(heldFork, fixture.forkFile);
  }
  press("usage-refresh");
  await total("503 tokens + unreported");
  assert(!tree().includes('id="usage-incomplete-histories"'));
  segment("usage-period", "7 days");
  await total("373 tokens + unreported");
  segment("usage-metric", "Cost");
  const weekCost = () => value("usage-total").includes("0.0037 + unreported");
  await until(weekCost, "seven-day saved cost");
  press("settings-close");
  await until(() => expected("composer", "Preserve this usage fixture draft."), "original unsent draft after settings");
  await relaunch();
  menuItem("Usage…");
  await until(weekCost, "period and metric after relaunch");
  press("settings-close");
  await until(() => expected("composer", "Preserve this usage fixture draft."), "restored draft after reopening Usage");
  const after = index();
  assert.equal(after.selectedProject, before.selectedProject);
  const selected = workspace => workspace.projects.find(p => p.id === before.selectedProject);
  assert.equal(selected(after).selectedConversation, selected(before).selectedConversation);
  assert.deepEqual(selected(after).modelOverride, selected(before).modelOverride);
}
