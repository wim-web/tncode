import { randomUUID } from "node:crypto";

export const readTools = ["read", "find", "grep", "ls"];
export const editingTools = ["read", "bash", "edit", "write"];

export function installToolApproval(agent, { threadID, currentTurn, requestApproval }) {
  let pending;
  const previousHook = agent.beforeToolCall;

  // Call and execute each tool in order so a second approval cannot hold up an approved tool.
  agent.toolExecution = "sequential";
  agent.beforeToolCall = async (context, signal) => {
    const prior = await previousHook?.(context, signal);
    if (prior?.block || readTools.includes(context.toolCall.name)) return prior;

    const turnID = currentTurn();
    const cancelled = { block: true, reason: "Tool approval was cancelled." };
    if (!turnID || signal?.aborted || pending) return cancelled;
    const request = {
      threadID,
      turnID,
      requestID: randomUUID(),
      tool: context.toolCall.name,
    };
    const abort = () => settle();
    const decision = await new Promise((resolve) => {
      pending = { request, resolve };
      signal?.addEventListener("abort", abort, { once: true });
      requestApproval(request, context.args);
    }).finally(() => {
      signal?.removeEventListener("abort", abort);
    });

    if (currentTurn() !== turnID || signal?.aborted) return cancelled;
    if (decision === "approve") return prior;
    return { block: true, reason: "The user declined this tool call." };
  };

  function settle(decision) {
    const approval = pending;
    pending = undefined;
    approval?.resolve(decision);
  }

  return {
    respond({ threadID, turnID, requestID, decision }) {
      const request = pending?.request;
      if (request && request.threadID === threadID && request.turnID === turnID &&
          request.requestID === requestID && currentTurn() === turnID &&
          (decision === "approve" || decision === "decline")) {
        settle(decision);
      }
    },
    cancel() { settle(); },
  };
}
