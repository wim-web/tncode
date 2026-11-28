import { createInterface } from "node:readline";
import { CodexRPC } from "./codex-rpc.mjs";

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
const knownAccountTypes = new Set(["chatgpt", "apiKey", "amazonBedrock", "gcp"]);
const accountTimeout = 10_000;
let commandType;
let rpc;
let loginId;
let startingLogin = false;
const earlyCompletions = new Map();
let cancelled = false;
let finished = false;

function loginEvent(step, fields = {}) {
  return { type: "login", step, ...fields };
}

async function finish(event) {
  if (finished) return;
  finished = true;
  input.close();
  await rpc?.close();
  process.stdout.write(JSON.stringify(event) + "\n", () => process.exit(0));
}

function fail(message) {
  void finish(loginEvent("error", { message }));
}

async function cancel() {
  if (finished || cancelled) return;
  cancelled = true;
  if (startingLogin) return;
  await cancelLogin();
}

async function cancelLogin() {
  if (loginId) {
    try { await rpc.call("account/login/cancel", { loginId }, { timeoutMs: 1_000 }); }
    catch { /* closing the server also ends the sign-in */ }
  }
  fail("cancelled");
}

function completed(params) {
  if (cancelled || finished || typeof params?.loginId !== "string") return;
  if (startingLogin) {
    earlyCompletions.set(params.loginId, params.success === true);
    return;
  }
  if (loginId !== params.loginId) return;
  if (params.success === true) void finish(loginEvent("complete"));
  else fail("login_failed");
}

function showAddress(address) {
  const url = new URL(address);
  if (url.protocol !== "https:" || url.username || url.password || url.hash ||
      [...url.searchParams.keys()].some((key) => /^(?:access|refresh|id)_token$|^code_verifier$|^client_secret$/i.test(key))) {
    throw new Error("Invalid sign-in address.");
  }
  return url.href;
}

function status(state, accountType) {
  void finish({ type: "codexStatus", state, ...(accountType && { accountType }) });
}

async function run(command) {
  rpc = new CodexRPC({
    cwd: process.cwd(),
    onNotification(method, params) {
      if (method === "account/login/completed") completed(params);
    },
    onClose(error) {
      if (error && loginId && !cancelled) fail("codex_unavailable");
    },
  });
  try {
    await rpc.start();
    const account = await rpc.call("account/read", { refreshToken: false }, { timeoutMs: accountTimeout });
    const accountType = account?.account?.type;
    const signedIn = knownAccountTypes.has(accountType);
    const ready = signedIn || account?.requiresOpenaiAuth === false;
    if (command.type === "status") {
      if (ready) status("ready", signedIn ? accountType : undefined);
      else if (account?.requiresOpenaiAuth === true) status("loginRequired");
      else status("unavailable");
      return;
    }
    if (cancelled) return;
    if (ready) {
      void finish(loginEvent("complete"));
      return;
    }

    const type = command.method === "code" ? "chatgptDeviceCode" : "chatgpt";
    startingLogin = true;
    const flow = await rpc.call("account/login/start", { type }, { timeoutMs: accountTimeout });
    startingLogin = false;
    loginId = typeof flow?.loginId === "string" && flow.loginId ? flow.loginId : undefined;
    if (cancelled) {
      await cancelLogin();
      return;
    }
    if (!loginId || flow.type !== type) return fail("login_failed");
    if (earlyCompletions.has(loginId)) {
      completed({ loginId, success: earlyCompletions.get(loginId) });
      return;
    }
    earlyCompletions.clear();
    const event = type === "chatgpt"
      ? loginEvent("browser", { url: showAddress(flow.authUrl) })
      : loginEvent("device", { url: showAddress(flow.verificationUrl), code: deviceCode(flow.userCode) });
    process.stdout.write(JSON.stringify(event) + "\n");
  } catch (error) {
    const missing = error?.code === "codex_not_installed";
    if (command.type === "status") {
      status(missing ? "notInstalled" : "unavailable");
    } else if (cancelled) {
      await cancelLogin();
    } else if (missing) {
      fail("codex_not_installed");
    } else if (error?.reason) {
      fail(error.reason);
    } else {
      fail(error?.code && error.code !== "codex_rpc_error" ? "codex_unavailable" : "login_failed");
    }
  }
}

function deviceCode(value) {
  if (typeof value !== "string" || !/^[A-Z0-9-]{3,32}$/i.test(value)) throw new Error("Invalid device code.");
  return value;
}

input.on("line", (line) => {
  if (finished || cancelled) return;
  let command;
  try { command = JSON.parse(line); } catch { /* handled below */ }
  if (command?.type === "cancel") {
    void cancel();
  } else if (!commandType) {
    if (command?.type !== "status" &&
        (command?.type !== "login" || command.provider !== "codex-app-server" ||
         ![undefined, "browser", "code"].includes(command.method))) {
      fail("invalid_request");
      return;
    }
    commandType = command.type;
    void run(command);
  }
});
input.on("close", () => { if (commandType !== "status") void cancel(); });
input.on("error", () => void cancel());
process.stdout.on("error", () => void cancel());
process.on("SIGTERM", () => void cancel());
process.on("SIGINT", () => void cancel());
