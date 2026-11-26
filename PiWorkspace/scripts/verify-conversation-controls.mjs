import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { seedPaletteMessageHistory } from "./fixtures/palette-message-history.mjs";

export async function verifyConversationControls(driver, { root, app, credential, key, launch, quit, record }) {
  const { until, visible, value, tree, press, setField, focus, keyFor } = driver;
  const projectID = randomUUID().toUpperCase();
  const findThread = randomUUID().toUpperCase();
  const questionThread = randomUUID().toUpperCase();
  const project = join(root, "Project");
  mkdirSync(project, { recursive: true });
  const provider = spawn(process.execPath, [join(import.meta.dirname, "fixtures/agent-questions.mjs"), root], {
    env: { ...process.env, QUESTION_FIXTURE_KEY: key }, stdio: ["pipe", "ignore", "ignore"],
  });
  const closed = once(provider, "close");
  let installed = false;
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
    const draft = "Keep this draft when Find closes.";
    writeFileSync(join(root, "workspace.json"), JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
      projects: [{ id: projectID, path: project, title: "Find and questions", allowEdits: false,
        selectedConversation: findThread, conversations: [
          { id: findThread, title: "Find fixture", archived: false, isDraft: false, composerText: draft },
          { id: questionThread, title: "Question fixture", archived: false, isDraft: true, composerText: "Question fixture draft." },
        ] }], model: { provider: "local", model: "question-fixture", endpoint, contextWindow: 8192, localTools: true },
    }), { mode: 0o600 });
    const history = await seedPaletteMessageHistory({ sidecar: join(app, "Contents/Resources/Sidecar"), workspace: root,
      projectID, threadID: findThread, cwd: project, keyword: "orbital lantern", laterKeyword: "orbital lantern", paddingTurns: 30 });
    credential("--set-api-key-from-stdin", key, root);
    installed = true;
    await launch("model-settings", root);
    await until(() => visible("transcript-message-" + history.latestID) && is("composer", draft), "selected Pi history and unfinished text");
    focus("composer");
    keyFor("composer", 3, "cmd");
    await until(() => focusIs("thread-find-query"), "Command-F opens thread Find");
    await setField("thread-find-query", "ORBITAL lantern");
    await until(() => is("thread-find-match-count", "1 of 2") && visible("transcript-message-" + history.messageID), "first saved match");
    keyFor("thread-find-query", 36);
    await until(() => is("thread-find-match-count", "2 of 2") && visible("transcript-message-" + history.latestID), "Return finds the later reply");
    press("thread-find-next");
    await until(() => is("thread-find-match-count", "1 of 2"), "next wraps");
    press("thread-find-previous");
    await until(() => is("thread-find-match-count", "2 of 2"), "previous wraps");
    await setField("thread-find-query", "palette-abandoned-branch-marker");
    await until(() => is("thread-find-match-count", "0 matches"), "abandoned branch excluded");
    const duplicate = join(dirname(history.historyPath), "second-fixture.jsonl");
    writeFileSync(duplicate, "{}\n", { flag: "wx" });
    try {
      await setField("thread-find-query", "orbital lantern");
      await until(() => is("thread-find-match-count", "Search failed") && visible("thread-find-retry"), "unavailable history reported");
    } finally { unlinkSync(duplicate); }
    press("thread-find-retry");
    await until(() => is("thread-find-match-count", "1 of 2") && is("thread-find-query", "orbital lantern"), "successful retry of the same search");
    focus("thread-find-query");
    keyFor("thread-find-query", 53);
    await until(() => !has("thread-find-query") && focusIs("composer") && is("composer", draft), "Escape restores the composer");
    press("conversation-title");
    await until(() => visible("find-in-thread"), "Find in the selected thread menu");
    press("find-in-thread");
    await until(() => focusIs("thread-find-query"), "open Find again from the menu");
    await setField("thread-find-query", "orbital lantern");
    await until(() => is("thread-find-match-count", "1 of 2"), "same results after reopening Find");
    press("thread-find-close");
    await until(() => !has("thread-find-query") && focusIs("composer") && is("composer", draft), "close Find via its button");
    record("Find opened with Command-F and from the thread menu. It found two messages thirty turns apart and wrapped in both directions, excluding the abandoned branch. Repair and Retry restored the query. Both Escape and Close returned to the unfinished draft.");

    press("thread-row-" + questionThread);
    await until(() => is("composer", "Question fixture draft."), "separate question thread");
    press("tool-permissions");
    await until(() => visible("tool-mode-supervised"), "Supervised permission");
    press("tool-mode-supervised");
    await until(() => visible("tool-permissions").includes("Supervised"), "questions and individually approved writes");
    await ask("Answer questions");
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
      if (installed) credential("--remove-api-key", undefined, root);
    } finally {
      provider.stdin.end();
      const timeout = setTimeout(() => provider.kill("SIGTERM"), 3_000);
      try { await closed; } finally { clearTimeout(timeout); }
    }
  }
}
