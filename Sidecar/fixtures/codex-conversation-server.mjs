#!/usr/bin/env node
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

const threadId = "abcdef00-1111-2222-3333-444444444444";
const cwd = process.cwd();
const home = process.env.CODEX_HOME;
const transcript = join(home, "fixture-history.json");
const log = join(home, "fixture-requests.json");
const requests = [];
const turns = existsSync(transcript) ? JSON.parse(readFileSync(transcript, "utf8")) : [];
const send = line => process.stdout.write(JSON.stringify(line) + "\n");
const notification = (method, params) => send({ method, params: { threadId, ...params } });
const persist = () => writeFileSync(transcript, JSON.stringify(turns));
const thread = () => ({
  id: threadId, sessionId: threadId, ephemeral: false, cwd,
  status: { type: "idle" }, path: transcript, historyMode: "paginated",
});
const response = ({ model, sandbox, approvalPolicy, approvalsReviewer, config }) => {
  assert.equal(approvalsReviewer, "user");
  assert.equal(config.web_search, "live");
  return { model: model ?? "configured-model", thread: thread(), approvalsReviewer, approvalPolicy,
    sandbox: { type: sandbox === "read-only" ? "readOnly" : "workspaceWrite", networkAccess: false } };
};
let turn;
let pending;
const approval = (id, method, params) => {
  send({ id, method, params: { threadId, turnId: turn.id, ...params } });
};
const itemNotification = (method, item, turnId = turn.id) => notification(method, { turnId, item });
const chatItem = { type: "agentMessage", id: "reply", text: "Partial answer" };
const controls = {
  name: "cua_repl", tools: { js: { name: "js" }, js_reset: { name: "js_reset" } },
  runtimeStatus: "connected", authStatus: "unsupported",
};

createInterface({ input: process.stdin }).on("line", line => {
  const message = JSON.parse(line);
  const { id, method, params, result } = message;
  if (!method) {
    if (id === "command" && pending === "command") {
      assert.deepEqual(result, { decision: "accept" });
      pending = "patch";
      itemNotification("item/started", {
        type: "fileChange", id: "patch", changes: [{ path: "hello.txt", kind: { type: "add" }, diff: "+hello" }],
      });
      approval("patch", "item/fileChange/requestApproval", { itemId: "patch" });
    } else if (id === "patch" && pending === "patch") {
      assert.deepEqual(result, { decision: "decline" });
      pending = "permissions";
      approval("permissions", "item/permissions/requestApproval", {
        itemId: "permissions", cwd, permissions: { fileSystem: { write: [join(cwd, "hello.txt")] } },
      });
    } else if (id === "permissions" && pending === "permissions") {
      assert.deepEqual(result, { permissions: { fileSystem: { write: [join(cwd, "hello.txt")] } }, scope: "turn" });
      pending = "form";
      itemNotification("item/started", {
        type: "mcpToolCall", id: "cua", status: "inProgress", server: "cua_repl", tool: "js",
        arguments: { description: "Check the example window" },
      });
      approval("form", "mcpServer/elicitation/request", {
        mode: "form", serverName: "cua_repl", message: "Approve this action?",
        requestedSchema: { type: "object", properties: {}, required: [] },
      });
    } else if (id === "form" && pending === "form") {
      assert.deepEqual(result, { action: "accept", content: {} });
      pending = "appAccess";
      approval("appAccess", "mcpServer/elicitation/request", {
        mode: "form", serverName: "cua_repl", message: "Allow ChatGPT to use Safari?",
        _meta: { app_name: "Safari", persist: ["session", "always"] },
        requestedSchema: { type: "object", properties: { approval: {
          type: "string", oneOf: [{ const: "once" }, { const: "session" }, { const: "always" }],
        } }, required: ["approval"] },
      });
    } else if (id === "appAccess" && pending === "appAccess") {
      assert.deepEqual(result, { action: "accept", content: { approval: "once" } });
      pending = "secret";
      approval("secret", "mcpServer/elicitation/request", {
        mode: "form", serverName: "cua_repl", message: "Enter a secret",
        requestedSchema: { type: "object", properties: { secret: { type: "string" } }, required: ["secret"] },
      });
    } else if (id === "secret" && pending === "secret") {
      assert.deepEqual(result, { action: "decline" });
      pending = "stale";
      approval("stale", "item/commandExecution/requestApproval", {
        cwd, itemId: "outdated", command: "echo outdated", turnId: "older-turn",
      });
    } else if (id === "stale" && pending === "stale") {
      assert.deepEqual(result, { decision: "decline" });
      pending = undefined;
      itemNotification("item/completed", {
        type: "webSearch", id: "web", query: "fixture search", action: { type: "search", query: "fixture search" },
      });
      notification("item/agentMessage/delta", { turnId: "older-turn", itemId: chatItem.id, delta: "stale" });
      notification("item/agentMessage/delta", { turnId: turn.id, itemId: chatItem.id, delta: chatItem.text });
    }
    return;
  }
  requests.push({ method, params });
  writeFileSync(log, JSON.stringify(requests));
  const reply = result => send({ id, result });
  switch (method) {
    case "initialize": reply({ codexHome: home }); break;
    case "initialized": break;
    case "config/read": reply({ config: { web_search: null } }); break;
    case "configRequirements/read": reply({ requirements: null }); break;
    case "account/read":
      assert.equal(params.refreshToken, false);
      reply({ account: { type: "chatgpt", email: "test-identity@example.invalid" }, userId: process.env.FIXTURE_USER ?? "user-1" });
      break;
    case "mcpServerStatus/list":
      assert.equal(params.detail, "toolsAndAuthOnly");
      if (params.cursor) reply({ data: [controls], nextCursor: null });
      else reply({ data: [{ name: "computer_use", tools: { js_reset: { name: "js_reset" } } }], nextCursor: "second" });
      break;
    case "thread/start": reply(response(params)); break;
    case "thread/read": reply({ thread: thread() }); break;
    case "thread/resume": reply(response(params)); break;
    case "thread/turns/list": reply({ data: turns, nextCursor: null }); break;
    case "turn/start": {
      assert.equal(params.threadId, threadId);
      const item = { type: "userMessage", id: "user-" + (turns.length + 1), clientId: params.clientUserMessageId, content: params.input };
      turn = { id: "remote-turn-" + (turns.length + 1), items: [item], status: "inProgress" };
      turns.push(turn);
      persist();
      notification("turn/started", { turn: { ...turn, items: [] } });
      itemNotification("item/completed", item);
      if (params.input[0].text === "lose connection") process.exit(2);
      reply({ turn });
      if (params.input[0].text === "finish") {
        const item = { ...chatItem, text: "Full answer" };
        turn.items.push(item);
        itemNotification("item/completed", item);
        turn.status = "completed";
        persist();
        notification("turn/completed", { turn });
      } else {
        pending = "command";
        approval("command", "item/commandExecution/requestApproval", {
          cwd, itemId: "shell", command: "echo hello", availableDecisions: ["accept", "acceptForSession", "decline"],
        });
      }
      break;
    }
    case "turn/interrupt":
      assert.deepEqual(params, { threadId, turnId: turn.id });
      reply({});
      turn.status = "interrupted";
      persist();
      notification("turn/completed", { turn });
      break;
    default: send({ id, error: { code: -32601, message: "Unknown RPC" } });
  }
});
