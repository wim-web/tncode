import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

// F2 activates inline rename when the thread row has focus.
const [root, role, name, key] = process.argv.slice(2);
if (!root || !role || !name || !key) throw Error("Usage: press.mjs <fixture> <role> <name> <key>");
if (readFileSync(path.join(root, "audit-owned"), "utf8").trim() !== "t3-0.1.12") {
  throw Error("Unknown fixture");
}
const pid = Number(readFileSync(path.join(root, "fixture.pid"), "utf8"));
if (!Number.isSafeInteger(pid) || pid < 2) throw Error("Invalid fixture PID");
const listener = execFileSync("/usr/sbin/lsof", [
  "-nP", "-a", "-p", String(pid), "-iTCP:47861", "-sTCP:LISTEN",
], { encoding: "utf8" });
if (!listener.includes("127.0.0.1:47861")) throw Error("Fixture is not listening");

const { chromium } = await import(pathToFileURL(path.join(root, "playwright-core/index.mjs")));
const browser = await chromium.connectOverCDP("http://127.0.0.1:47861", { timeout: 8000 });
const page = browser.contexts().flatMap((context) => context.pages())
  .find((candidate) => /^t3[a-z-]*:\/\/app\b/.test(candidate.url()));
if (!page) throw Error("Fixture renderer unavailable");
await page.getByRole(role, { name, exact: true }).press(key, { timeout: 3000 });
process.exit(0);
