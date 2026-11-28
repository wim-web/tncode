import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifySnoozeOptions(driver, { root, launch, quit, record }) {
  const { press, dismiss, visible, value, tree, setField, until } = driver;
  const uuid = () => randomUUID().toUpperCase();
  const now = () => (Date.now() - Date.UTC(2001, 0, 1)) / 1000;
  const projectID = uuid(), currentID = uuid(), otherID = uuid(), queueID = uuid();
  const oldDeadline = now() + 172800, text = "Keep the active follow-up";
  const path = join(root, "Project"), indexPath = join(root, "workspace.json");
  mkdirSync(path, { recursive: true });
  writeFileSync(indexPath, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
    projects: [{ id: projectID, title: "Snooze options", path, allowEdits: false, selectedConversation: currentID,
      conversations: [
        { id: currentID, title: "Open thread", isDraft: false, archived: false, composerText: text,
          queuedMessages: [{ id: queueID, text: "Keep the queue" }] },
        { id: otherID, title: "Tomorrow", isDraft: false, archived: false, snoozedUntil: oldDeadline },
      ] }], model: { provider: "local", model: "snooze-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
  }), { mode: 0o600 });
  const index = () => JSON.parse(readFileSync(indexPath, "utf8"));
  const options = () => index().snoozeOptions;
  const thread = id => index().projects[0].conversations.find(conversation => conversation.id === id);
  const has = id => tree().includes('id="' + id + '"');
  const draftIntact = () => value("composer").includes(text) && index().projects[0].selectedConversation === currentID;
  async function menu() {
    press("conversation-title");
    await until(() => visible("snooze-thread"), "Snooze in the selected thread's menu");
    press("snooze-thread");
    await until(() => visible("open-custom-snooze"), "Custom in the Snooze submenu");
  }
  async function editOptions() {
    dismiss("open-custom-snooze");
    await until(() => visible("edit-snooze-options"), "Edit snooze options in the custom sheet");
    dismiss("edit-snooze-options");
    await until(() => visible("settings-heading-threads") && visible("add-snooze-option"), "Threads settings from Custom");
  }
  async function closeSettings() {
    dismiss("settings-close");
    await until(() => !has("settings-heading-threads") && draftIntact(), "return to the same draft");
  }
  async function add(count) {
    press("add-snooze-option");
    await until(() => options()?.length === count, "saved snooze option " + count);
  }
  function matchingRow(kind, expected) {
    for (let number = 1; number <= options().length; number++) {
      const id = "snooze-option-" + kind + "-" + number;
      try { if (value(id).includes("value=" + JSON.stringify(expected))) return number; } catch {}
    }
    return false;
  }
  await launch("resume-queue", root);
  await menu();
  await editOptions();
  await add(6);
  const amount = await until(() => matchingRow("amount", "30"), "new 30-minute option");
  await setField("snooze-option-amount-" + amount, "31");
  driver.focus("settings-search");
  await until(() => options().some(option => option.after?.minutes === 31), "persisted 31-minute option");
  await add(7);
  const secondAmount = await until(() => matchingRow("amount", "30"), "second duration option");
  driver.pick("snooze-option-unit-" + secondAmount, "Hours");
  await until(() => options().some(option => option.after?.minutes === 1800), "saved 30 hours");
  const hourly = await until(() => matchingRow("amount", "30"), "30-hour row after resorting");
  driver.pick("snooze-option-when-" + hourly, "Wednesday");
  const weekday = await until(() => matchingRow("when", "Wednesday"), "new weekly schedule");
  await setField("snooze-option-time-" + weekday, "13:37");
  driver.focus("settings-search");
  await until(() => options().some(option => option.at?.day === "wednesday" && option.at.time === "13:37"), "saved Wednesday at 13:37");
  await add(8);
  assert(visible("add-snooze-option").includes("enabled=false"));
  await closeSettings();
  await quit();
  await launch("resume-queue", root);
  await menu();
  await until(() => visible("snooze-preset-at-wednesday-13:37"), "weekly option after relaunch");
  const wednesday = new Date();
  wednesday.setDate(wednesday.getDate() + ((3 - wednesday.getDay() + 7) % 7 || 7));
  wednesday.setHours(13, 37, 0, 0);
  dismiss("snooze-preset-at-wednesday-13:37");
  await until(() => thread(currentID).snoozedUntil === (wednesday.getTime() - Date.UTC(2001, 0, 1)) / 1000,
              "stored deadline for next Wednesday at 13:37 local time");
  press("conversation-title");
  await until(() => visible("wake-thread"), "Wake after the weekday check");
  dismiss("wake-thread");
  await until(() => thread(currentID).snoozedUntil == null, "wake after checking the weekday");
  await menu();
  await until(() => visible("snooze-preset-after-31").includes("31 minutes"), "31 minutes in the reopened menu");
  const before = now();
  dismiss("snooze-preset-after-31");
  const deadline = await until(() => thread(currentID).snoozedUntil, "saved custom deadline");
  assert(deadline >= before + 1860 && deadline <= now() + 1860);
  assert.equal(thread(otherID).snoozedUntil, oldDeadline);
  press("model-settings");
  await until(() => visible("settings-nav-threads"), "Threads navigation");
  press("settings-nav-threads");
  await until(() => visible("reset-snooze-options"), "saved options in Threads settings");
  for (let remaining = 7; remaining >= 0; remaining--) {
    press("remove-snooze-option-1");
    await until(() => options()?.length === remaining, "saved " + remaining + " snooze options");
  }
  assert(value("snooze-options-menu-preview").includes("only Custom"));
  await closeSettings();
  press("conversation-title");
  await until(() => visible("wake-thread"), "Wake in the selected thread's menu");
  dismiss("wake-thread");
  await until(() => thread(currentID).snoozedUntil == null, "wake the selected thread");
  await menu();
  assert(!tree().includes('id="snooze-preset-'));
  await editOptions();
  press("reset-snooze-options");
  await until(() => options() == null && !has("reset-snooze-options"), "reset to the default options");
  await closeSettings();
  await menu();
  await until(() => visible("snooze-preset-one-hour") && visible("snooze-preset-three-hours"), "restored defaults in the thread menu");
  assert(!has("snooze-preset-after-31"));
  dismiss("open-custom-snooze");
  await until(() => visible("cancel-custom-snooze"), "Cancel the custom sheet");
  dismiss("cancel-custom-snooze");
  await until(draftIntact, "the same selected thread and composer text");
  assert.deepEqual(thread(currentID).queuedMessages, [{ id: queueID, text: "Keep the queue" }]);
  assert.equal(thread(otherID).snoozedUntil, oldDeadline);
  await quit();
  record("Custom opened Threads settings. The unit picker saved 30 hours. After relaunch the 31-minute and Wednesday 13:37 options set the expected deadlines. Add stopped at eight options. Removing all left only Custom, and Reset restored the defaults. The other deadline, selection, draft and queue remained intact.");
}

export async function verifyThreadSnooze(driver, { root, launch, relaunch = launch, quit, record }) {
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
  await relaunch("model-settings", root);
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
