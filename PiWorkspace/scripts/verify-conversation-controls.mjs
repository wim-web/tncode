import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { seedPaletteMessageHistory } from "./fixtures/palette-message-history.mjs";

export async function verifyConversationControls(driver, { root, app, credential, removeFixtureCredential, key, launch, quit, record }) {
  const { until, visible, value, tree, press, dismiss: pressChangingUI, setField, focus, keyFor, selection } = driver;
  const projectID = randomUUID().toUpperCase();
  const findThread = randomUUID().toUpperCase();
  const questionThread = randomUUID().toUpperCase();
  const project = join(root, "Project");
  mkdirSync(project, { recursive: true });
  const provider = spawn(process.execPath, [join(import.meta.dirname, "fixtures/agent-questions.mjs"), root], {
    env: { ...process.env, QUESTION_FIXTURE_KEY: key }, stdio: ["pipe", "ignore", "ignore"],
  });
  const closed = once(provider, "close");
  let installedAccount;
  const has = id => tree().includes('id="' + id + '"');
  const is = (id, text) => value(id).includes("value=" + JSON.stringify(text));
  const focusIs = id => visible(id).includes("focused=true");
  const requests = () => existsSync(join(root, "requests"))
    ? readFileSync(join(root, "requests"), "utf8").trim().split("\n").map(line => JSON.parse(line)) : [];
  const prompt = async text => {
    await setField("composer", text);
    await until(() => visible("send-message").includes("enabled=true"), "send " + text);
    press("send-message");
    await until(() => requests().some(r => r.prompt === text) || existsSync(join(root, "provider-error")), "provider received " + text);
    assert(!existsSync(join(root, "provider-error")), "The question provider rejected the request.");
  };
  const ask = async text => {
    await prompt(text);
    await until(() => visible("agent-question") && is("agent-question-prompt", "Choose two targets."), "first question for " + text);
  };

  try {
    const endpoint = await until(() => readFileSync(join(root, "endpoint"), "utf8") || false, "local question provider");
    const phrase = "選択👩🏽‍💻";
    const draft = "Keep this draft. " + phrase;
    writeFileSync(join(root, "workspace.json"), JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
      projects: [{ id: projectID, path: project, title: "Find and questions", allowEdits: false,
        selectedConversation: findThread, conversations: [
          { id: findThread, title: "Find fixture", archived: false, isDraft: false, composerText: draft },
          { id: questionThread, title: "Question fixture", archived: false, isDraft: true, composerText: "Question fixture draft." },
        ] }], model: { provider: "local", model: "question-fixture", endpoint, contextWindow: 8192, localTools: true },
    }), { mode: 0o600 });
    const history = await seedPaletteMessageHistory({ sidecar: join(app, "Contents/Resources/Sidecar"), workspace: root,
      projectID, threadID: findThread, cwd: project, keyword: "orbital lantern", laterKeyword: "orbital lantern", paddingTurns: 30, findOccurrences: true });
    credential("--set-api-key-from-stdin", key, root);
    installedAccount = "local:" + endpoint;
    await launch("model-settings", root);
    await until(() => visible("transcript-message-" + history.latestID) && is("composer", draft), "selected Pi history and unfinished text");
    const selected = () => driver.selectedText("thread-find-selected-text");
    focus("composer");
    keyFor("composer", 3, "cmd", "shift");
    await until(() => focusIs("thread-search"), "sidebar search focused");
    await setField("thread-search", "Question fixture");
    await until(() => visible("thread-row-" + questionThread) && !has("thread-row-" + findThread), "distinct title finds the draft without Pi history");
    await setField("thread-search", "buriedattachment");
    await until(() => tree().includes("No matching threads"), "hidden attachment excluded from sidebar results");
    await setField("thread-search", "caption");
    const captionResult = "message-search-result-" + findThread + "-" + history.captionID;
    await until(() => visible(captionResult), "visible Pi attachment caption");
    pressChangingUI(captionResult);
    await until(() => is("thread-find-match-count", "1 of 1") && selected() === "caption", "sidebar opened at the caption range");
    pressChangingUI("thread-find-close");
    await until(() => !has("thread-find-query"), "close the sidebar match");
    press("thread-row-" + questionThread);
    await until(() => is("composer", "Question fixture draft."), "open another thread before searching from the palette");
    focus("composer");
    keyFor("composer", 40, "cmd");
    await until(() => focusIs("command-palette-search"), "palette search focused");
    await setField("command-palette-search", "doublemark");
    const paletteResult = "command-palette-message-" + findThread + "-" + history.latestID;
    await until(() => visible(paletteResult), "palette found repeated text in the original Pi reply");
    pressChangingUI(paletteResult);
    await until(() => is("thread-find-match-count", "1 of 2") && selected() === "doublemark", "palette opened at first occurrence");
    keyFor("thread-find-query", 36);
    await until(() => is("thread-find-match-count", "2 of 2") && selected() === "DOUBLEMARK", "Return selected the second exact range");
    keyFor("thread-find-query", 36, "shift");
    await until(() => is("thread-find-match-count", "1 of 2") && selected() === "doublemark", "Shift-Return selected the first range again");
    pressChangingUI("thread-find-close");
    await until(() => !has("thread-find-query") && is("composer", draft), "returned to the original Find thread");
    record("The sidebar found the unsent draft by its distinct title, excluded buriedattachment and opened on caption. From another thread the palette opened at doublemark, 1 of 2. Return selected DOUBLEMARK, 2 of 2, and Shift-Return selected doublemark again.");

    focus("composer");
    assert.deepEqual(selection("composer", 4, 0), [4, 0]);
    keyFor("composer", 3, "cmd");
    await until(() => focusIs("thread-find-query"), "Command-F opens thread Find");
    await setField("thread-find-query", "ORBITAL lantern");
    await until(() => is("thread-find-match-count", "1 of 2") && visible("transcript-message-" + history.messageID), "first saved match");
    keyFor("thread-find-query", 36);
    await until(() => is("thread-find-match-count", "2 of 2") && visible("transcript-message-" + history.latestID), "Return finds the later reply");
    pressChangingUI("thread-find-next");
    await until(() => is("thread-find-match-count", "1 of 2"), "next wraps");
    pressChangingUI("thread-find-previous");
    await until(() => is("thread-find-match-count", "2 of 2"), "previous wraps");
    await setField("thread-find-query", "palette-abandoned-branch-marker");
    await until(() => is("thread-find-match-count", "0 matches"), "abandoned branch excluded");
    const duplicate = join(dirname(history.historyPath), "second-fixture.jsonl");
    writeFileSync(duplicate, "{}\n", { flag: "wx" });
    try {
      await setField("thread-find-query", "orbital lantern");
      await until(() => is("thread-find-match-count", "Search failed") && visible("thread-find-retry"), "unavailable history reported");
    } finally { unlinkSync(duplicate); }
    pressChangingUI("thread-find-retry");
    await until(() => is("thread-find-match-count", "1 of 2") && is("thread-find-query", "orbital lantern"), "successful retry of the same search");
    focus("thread-find-query");
    keyFor("thread-find-query", 53);
    await until(() => !has("thread-find-query") && focusIs("composer") && is("composer", draft), "Escape restores the composer");
    assert.deepEqual(selection("composer"), [4, 0]);
    keyFor("composer", 7);
    const edited = draft.slice(0, 4) + "x" + draft.slice(4);
    await until(() => is("composer", edited), "input after Find inserts at the original caret");
    const range = [edited.indexOf(phrase), phrase.length];
    assert.deepEqual(selection("composer", ...range), range);
    keyFor("composer", 3, "cmd");
    await until(() => focusIs("thread-find-query"), "reopen Find with an active Unicode selection");
    pressChangingUI("thread-find-close");
    await until(() => focusIs("composer"), "return from Find to the selected phrase");
    assert.deepEqual(selection("composer"), range);
    press("conversation-title");
    await until(() => visible("find-in-thread"), "Find in the selected thread menu");
    press("find-in-thread");
    await until(() => focusIs("thread-find-query"), "open Find again from the menu");
    await setField("thread-find-query", "orbital lantern");
    await until(() => is("thread-find-match-count", "1 of 2"), "same results after reopening Find");
    pressChangingUI("thread-find-close");
    await until(() => !has("thread-find-query") && focusIs("composer") && is("composer", edited), "close Find via its button");
    record("Find opened with Command-F and from the thread menu. It found two messages thirty turns apart and wrapped in both directions, excluding the abandoned branch. Repair and Retry restored the query. Both Escape and Close returned to the unfinished draft.");
    record("After Escape, typing x at the restored offset 4 produced Keepx this draft. The Close button restored the exact UTF-16 selection over 選択👩🏽‍💻.");

    press("thread-row-" + questionThread);
    await until(() => is("composer", "Question fixture draft."), "separate question thread");
    press("tool-permissions");
    await until(() => visible("tool-mode-supervised"), "Supervised permission");
    press("tool-mode-supervised");
    await until(() => visible("tool-permissions").includes("Supervised"), "questions and individually approved writes");
    const gate = join(root, "hold-first-question");
    writeFileSync(gate, "", { flag: "wx" });
    let queued;
    try {
      await prompt("Answer questions");
      await until(() => visible("queue-message"), "composer during the pending model response");
      await setField("composer", "Keep this queued instruction.");
      press("queue-message");
      queued = await until(() => {
        const state = JSON.parse(readFileSync(join(root, "workspace.json"), "utf8"));
        return state.projects[0].conversations.find(t => t.id === questionThread).queuedMessages?.[0];
      }, "queued message before the question arrives");
    } finally { unlinkSync(gate); }
    await until(() => visible("agent-question"), "question over the composer");
    press("queue-item-actions-" + queued.id);
    await until(() => visible("queue-edit-" + queued.id).includes("enabled=false") &&
                visible("queue-remove-" + queued.id).includes("enabled=true"), "a hidden composer cannot start an edit");
    press("queue-remove-" + queued.id);
    await until(() => !has("queued-message-" + queued.id) && has("agent-question"), "removed the item with the question still open");
    record("While the question occupied the composer, Edit in Composer was disabled for the queued item and Remove still worked.");
    assert(visible("agent-question-next").includes("enabled=false"));
    press("agent-question-option-0");
    press("agent-question-option-2");
    press("agent-question-toggle");
    await until(() => !has("agent-question-prompt") && has("agent-question"), "collapsed question");
    press("agent-question-toggle");
    await until(() => visible("agent-question-next").includes("enabled=true"), "restored question selections");
    press("agent-question-next");
    await until(() => is("agent-question-prompt", "What should we call the test?"), "second question");
    await setField("agent-question-answer", "Night shift");
    press("agent-question-previous");
    await until(() => visible("agent-question-next"), "earlier question");
    press("agent-question-next");
    await until(() => is("agent-question-answer", "Night shift"), "the typed answer is retained");
    press("agent-question-submit");
    await until(() => visible("approve-tool"), "separate approval after answers reached Pi");
    assert(!existsSync(join(project, "approved.txt")));
    press("approve-tool");
    await until(() => readFileSync(join(project, "approved.txt"), "utf8") === "one write\n" && visible("send-message"), "one approved write");
    await ask("Dismiss questions");
    press("agent-question-dismiss");
    await until(() => tree().includes("Questions dismissed.") && !has("agent-question"), "dismissal returned to Pi");
    await ask("Stop questions");
    press("stop-message");
    await until(() => !has("agent-question") && visible("send-message"), "stopped unanswered turn");
    assert(!existsSync(join(project, "stopped.txt")));
    await ask("Restart with question");
    await quit();
    await launch("model-settings", root);
    press("thread-row-" + questionThread);
    await until(() => !has("agent-question") && visible("composer"), "old request cleared after relaunch");
    await prompt("Continue the thread");
    await until(() => tree().includes("Same Pi thread continued.") && visible("send-message"), "one continuation in the same history");
    assert(!existsSync(join(project, "restarted.txt")) && !existsSync(join(project, "stopped.txt")));
    assert(!existsSync(join(root, "provider-error")));
    assert.deepEqual(requests().map(r => r.prompt), [
      "Answer questions", "Answer questions", "Answer questions", "Dismiss questions", "Dismiss questions",
      "Stop questions", "Restart with question", "Continue the thread",
    ]);
    await quit();
    record("The question card retained North and West and the typed answer Night shift across pages. Pi received the exact answers and requested a separate write approval. Dismiss, Stop and relaunch cleared pending requests. The same thread continued once, without either pending write.");
  } finally {
    try {
      if (installedAccount) removeFixtureCredential(root, installedAccount);
    } finally {
      provider.stdin.end();
      const timeout = setTimeout(() => provider.kill("SIGTERM"), 3_000);
      try { await closed; } finally { clearTimeout(timeout); }
    }
  }
}
