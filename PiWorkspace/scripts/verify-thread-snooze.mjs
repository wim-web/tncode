import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyThreadSnooze(driver, { root, launch, quit, record }) {
  const { press, dismiss, until, visible, value, tree, showMenu, segment, setField } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const projectID = uuid(), draftID = uuid(), pinned = uuid(), expired = uuid();
  const path = join(root, "Project");
  mkdirSync(path, { recursive: true });
  const indexPath = join(root, "workspace.json");
  const now = () => (Date.now() - Date.UTC(2001, 0, 1)) / 1000;
  writeFileSync(indexPath, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
    projects: [{ id: projectID, title: "Snooze", path, allowEdits: false, selectedConversation: draftID, conversations: [
      { id: draftID, title: "Editing", isDraft: true, archived: false, composerText: "Keep me here." },
      { id: pinned, title: "Pinned conversation", isDraft: false, archived: false, shelf: "pinned" },
      { id: expired, title: "Earlier reminder", isDraft: false, archived: false, snoozedUntil: now() - 120 },
    ] }], model: { provider: "local", model: "snooze-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
  }), { mode: 0o600 });
  const project = () => JSON.parse(readFileSync(indexPath, "utf8")).projects[0];
  const thread = id => project().conversations.find(t => t.id === id);
  const current = () => project().selectedConversation === draftID && value("composer").includes("Keep me here.");
  const has = id => tree().includes('id="' + id + '"');
  async function choices() {
    await until(() => { showMenu("thread-row-" + pinned); return true; }, "pinned row context menu");
    await until(() => visible("snooze-thread"), "Snooze submenu");
    press("snooze-thread");
    await until(() => visible("snooze-preset-one-hour"), "the one-hour preset");
  }
  await launch("model-settings", root);
  await until(() => current() && visible("dismiss-woke-" + expired), "expired deadline shows Woke in the original draft");
  dismiss("dismiss-woke-" + expired);
  await until(() => thread(expired).snoozedUntil == null && !has("dismiss-woke-" + expired), "dismissed Woke");
  await choices();
  const begin = now();
  dismiss("snooze-preset-one-hour");
  await until(() => thread(pinned).snoozedUntil > begin + 3590 && visible("undo-snooze") && current(), "an hour in the future without leaving the draft");
  dismiss("undo-snooze");
  await until(() => thread(pinned).snoozedUntil == null && thread(pinned).shelf === "pinned", "Undo restores the pinned thread");
  await choices();
  dismiss("open-custom-snooze");
  await until(() => visible("snooze-schedule-type"), "custom schedule");
  segment("snooze-schedule-type", "Duration");
  await setField("snooze-duration", "0");
  press("confirm-custom-snooze");
  await until(() => visible("snooze-validation-error") && thread(pinned).snoozedUntil == null, "invalid duration kept the thread awake");
  await setField("snooze-duration", "2");
  driver.pick("snooze-duration-unit", "Hours");
  const chosen = now();
  dismiss("confirm-custom-snooze");
  const deadline = await until(() => thread(pinned).snoozedUntil >= chosen + 7198 && thread(pinned).snoozedUntil, "two-hour custom snooze");
  assert(deadline < now() + 7210);
  await quit();
  await launch("model-settings", root);
  await until(() => visible("snoozed-shelf") && current(), "relaunch retained the future deadline and selected draft");
  assert.equal(thread(pinned).snoozedUntil, deadline);
  assert(!has("dismiss-woke-" + expired));
  if (!has("wake-snoozed-thread-" + pinned)) press("snoozed-shelf");
  await until(() => visible("wake-snoozed-thread-" + pinned), "pending reminder in the Snoozed shelf");
  dismiss("wake-snoozed-thread-" + pinned);
  await until(() => thread(pinned).snoozedUntil == null && thread(pinned).shelf === "pinned" && current(), "Wake restored the prior placement");
  await quit();
  record("The one-hour snooze and its Undo preserved the pinned placement and selected draft. Custom Duration rejected zero and stored two hours. Relaunch kept the exact deadline. Wake restored the pinned thread, and a dismissed expired Woke stayed dismissed.");
}
