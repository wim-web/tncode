import { createInterface } from "node:readline";
import { appendFileSync } from "node:fs";

const consentID = "fixture-consent";
let pending;

for await (const line of createInterface({ input: process.stdin })) {
  const incoming = JSON.parse(line);
  const { id, method, params } = incoming;
  if (id === undefined) continue;
  if (id === consentID && pending !== undefined) {
    const granted = incoming.result?.action === "accept" && incoming.result.content?.approval === "once";
    appendFileSync(process.argv[2], granted ? "approved once\n" : "declined\n");
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: pending, result: {
      content: [{ type: "text", text: granted ? "fixture action confirmed" : "fixture action declined" }], isError: !granted,
    } }) + "\n");
    pending = undefined;
    continue;
  }
  let result;
  switch (method) {
    case "initialize":
      result = {
        protocolVersion: params.protocolVersion,
        capabilities: { tools: {} },
        serverInfo: { name: "synthetic-cua-repl-fixture", version: "1.0.0" },
      };
      break;
    case "tools/list":
      appendFileSync(process.argv[2], "tools/list\n");
      result = { tools: [{
        name: "js",
        description: "Synthetic computer-use inventory entry for an acceptance test.",
        inputSchema: { type: "object", properties: { code: { type: "string" } }, required: ["code"] },
      }] };
      break;
    case "tools/call":
      appendFileSync(process.argv[2], "tools/call\n");
      if (params?.name === "js" && params.arguments?.code === "fixture-noop" && pending === undefined) {
        pending = id;
        process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: consentID, method: "elicitation/create", params: {
          mode: "form", message: "Allow access to the inert fixture?", _meta: { app_name: "Fixture" },
          requestedSchema: { type: "object", properties: { approval: { type: "string", enum: ["once", "session", "always"] } }, required: ["approval"] },
        } }) + "\n");
        continue;
      }
      break;
  }
  const payload = result === undefined ? { error: { code: -32601, message: "Unsupported fixture method" } } : { result };
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, ...payload }) + "\n");
}
