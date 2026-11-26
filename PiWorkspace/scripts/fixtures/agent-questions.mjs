import assert from "node:assert/strict";
import { appendFileSync, existsSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const root = process.argv[2];
const model = "question-fixture";
const key = process.env.QUESTION_FIXTURE_KEY;
const requests = new Map();
let nextCallID = 0;

function chunk(delta, finish_reason = null) {
  return `data: ${JSON.stringify({
    id: "fixture", object: "chat.completion.chunk", created: 1, model,
    choices: [{ index: 0, delta, finish_reason }],
  })}\n\n`;
}

const ask = {
  name: "ask_user_questions",
  args: {
    questions: [
      {
        header: "First question", prompt: "Choose two targets.",
        options: [{ label: "North", description: "The first target." }, { label: "South" }, { label: "West" }],
        multiSelect: true,
      },
      { header: "Second question", prompt: "What should we call the test?" },
    ],
  },
};
const write = (path) => ({ name: "write", args: { path, content: "one write\n" } });

const server = createServer(async (request, response) => {
  try {
    assert.equal(request.url, "/v1/chat/completions");
    assert.equal(request.headers.authorization, "Bearer " + key);
    const body = await new Response(request).json();
    assert.equal(body.model, model);
    assert(!JSON.stringify(body).includes(key));
    assert(!JSON.stringify(body).includes("unrelated composer draft"));
    const user = body.messages.findLast(({ role }) => role === "user");
    const prompt = typeof user.content === "string" ? user.content : user.content[0].text;
    const count = (requests.get(prompt) ?? 0) + 1;
    requests.set(prompt, count);
    const tools = body.tools?.map(({ function: tool }) => tool.name) ?? [];
    assert(tools.includes("ask_user_questions"));
    appendFileSync(join(root, "requests"), JSON.stringify({ prompt, count }) + "\n");
    let calls;
    let content;
    switch (prompt) {
      case "Answer questions": {
        assert(tools.includes("write"));
        if (count === 1) {
          const deadline = Date.now() + 20_000;
          while (existsSync(join(root, "hold-first-question")) && !response.destroyed) {
            assert(Date.now() < deadline, "The fixture did not release its first question.");
            await delay(40);
          }
          calls = [ask];
        }
        else if (count === 2) {
          const result = body.messages.at(-1);
          assert.equal(result.role, "tool");
          assert.deepEqual(JSON.parse(result.content), { status: "answered", answers: [
            { questionID: "1", selected: ["North", "West"] },
            { questionID: "2", text: "Night shift" },
          ] });
          calls = [write("approved.txt")];
        } else {
          assert.equal(count, 3);
          content = "Questions answered and the approved write finished.";
        }
        break;
      }
      case "Dismiss questions":
        if (count === 1) calls = [ask];
        else {
          assert.equal(count, 2);
          assert.deepEqual(JSON.parse(body.messages.at(-1).content), { status: "declined" });
          content = "Questions dismissed.";
        }
        break;
      case "Stop questions":
      case "Restart with question":
        assert.equal(count, 1);
        calls = [ask, write(prompt === "Stop questions" ? "stopped.txt" : "restarted.txt")];
        break;
      case "Continue the thread": {
        assert.equal(count, 1);
        const userMessages = body.messages.filter(({ role }) => role === "user");
        assert.deepEqual(userMessages.map(({ content }) => typeof content === "string" ? content : content[0].text),
          ["Answer questions", "Dismiss questions", "Stop questions", "Restart with question", prompt]);
        content = "Same Pi thread continued.";
        break;
      }
      default: assert.fail("Unexpected fixture prompt");
    }
    const delta = calls ? {
      tool_calls: calls.map(({ name, args }, index) => ({
        index, id: "call_question_" + ++nextCallID, type: "function",
        function: { name, arguments: JSON.stringify(args) },
      })),
    } : { content };
    response.writeHead(200, { "Content-Type": "text/event-stream" }).end(
      chunk({ role: "assistant", ...delta }) + chunk({}, calls ? "tool_calls" : "stop") + "data: [DONE]\n\n",
    );
  } catch (error) {
    writeFileSync(join(root, "provider-error"), error.stack);
    response.writeHead(500).end("Fixture assertion failed");
  }
});

server.listen(0, "127.0.0.1", () => {
  writeFileSync(join(root, "endpoint"), "http://127.0.0.1:" + server.address().port + "/v1");
});
process.stdin.resume();
process.stdin.on("end", () => { server.closeAllConnections(); server.close(); });
