import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import { createAgentQuestions } from "./agent-questions.mjs";

test("expired and aborted questions cannot consume late replies", async () => {
  const events = [];
  let turnID = randomUUID();
  let stopped = 0;
  const controller = new AbortController();
  const { tool, respond } = createAgentQuestions({
    threadID: randomUUID(),
    currentTurn: () => turnID,
    emit: (event) => events.push(event),
    redact: (text) => text,
    stopTurn: () => { stopped++; turnID = undefined; },
    timeout: 10,
  });
  const ask = (signal) => tool.execute("call", {
    questions: [{ header: "Where", prompt: "Where should we start?" }],
  }, signal).then((result) => JSON.parse(result.content[0].text));
  const answer = (scope, text) => respond({
    scope, decision: "answer", answers: [{ questionID: "1", kind: "text", text }],
  });

  const expired = ask();
  const expiredScope = events[0].scope;
  // Simulate a reply received after the deadline but before its timer can run.
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 11);
  answer(expiredScope, "late");
  assert.deepEqual(await expired, { status: "cancelled" });
  assert.equal(stopped, 1);
  assert.deepEqual(events[1], { type: "agentQuestionEnded", scope: expiredScope, status: "expired" });

  turnID = randomUUID();
  const aborted = ask(controller.signal);
  const abortedScope = events.at(-1).scope;
  controller.abort();
  answer(abortedScope, "late");
  assert.deepEqual(await aborted, { status: "cancelled" });

  turnID = randomUUID();
  const retried = ask();
  const retryScope = events.at(-1).scope;
  answer(expiredScope, "stale");
  answer(abortedScope, "stale");
  answer({ ...retryScope, threadID: randomUUID() }, "wrong thread");
  answer(retryScope, " ");
  assert.deepEqual(events.at(-1), { type: "agentQuestionRejected", scope: retryScope });
  answer(retryScope, "current");
  answer(retryScope, "duplicate");
  assert.deepEqual(await retried, { status: "answered", answers: [{ questionID: "1", text: "current" }] });
});
