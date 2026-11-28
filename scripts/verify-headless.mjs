import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { constants, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { withModelRoutingFixture } from "./fixtures/model-routing.mjs";

const usage = `Usage: node scripts/verify-headless.mjs
Runs Pi worker and session fixtures on loopback HTTP, checkout Git, and every
Swift test that does not create AppKit windows. Requires macOS, Swift 6.2+,
Node.js 22.19+, and the pinned Sidecar dependencies. From tncode, install them with
npm --prefix Sidecar ci --ignore-scripts.

Swift tests that create AppKit windows skip unless TNCODE_TEST_DESKTOP=dedicated.
Run them, verify-app.mjs, verify-file-drops.mjs, and verify-native-paste.mjs in a
separate macOS session.`;

if (process.argv.length > 2) {
  if (process.argv.length === 3 && process.argv[2] === "--help") console.log(usage);
  else {
    console.error(usage);
    process.exitCode = 2;
  }
} else {
  try {
    await verify();
  } catch (error) {
    console.error(`Headless verification failed. ${error.message}`);
    process.exitCode ||= 1;
  }
}

async function verify() {
  assert.equal(process.platform, "darwin", "The Swift tests require macOS.");
  const workspace = resolve(import.meta.dirname, "..");
  const sidecar = join(workspace, "Sidecar");
  const sdk = "node_modules/@earendil-works/pi-coding-agent";
  const manifest = join(sidecar, sdk, "package.json");
  const locked = JSON.parse(readFileSync(join(sidecar, "package-lock.json"), "utf8")).packages[sdk].version;
  assert(existsSync(manifest) && JSON.parse(readFileSync(manifest, "utf8")).version === locked,
    "Install the pinned Pi SDK with npm --prefix Sidecar ci --ignore-scripts from tncode.");
  const developer = spawnSync("/usr/bin/xcode-select", ["--print-path"], { encoding: "utf8" });
  assert(developer.status === 0 && existsSync(developer.stdout.trim()),
    "Select an installed Xcode toolchain before running the Swift checks.");

  const root = realpathSync(mkdtempSync(join(tmpdir(), "pi-headless-")));
  const environment = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    HOME: root,
    PI_CODING_AGENT_DIR: join(root, "pi-agent"),
    CODEX_HOME: join(root, "codex-home"),
    TMPDIR: root,
    SHELL: "/bin/sh",
    LC_ALL: "C",
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_TERMINAL_PROMPT: "0",
    ...(process.env.DEVELOPER_DIR && { DEVELOPER_DIR: process.env.DEVELOPER_DIR }),
  };

  async function run(label, executable, args, env = environment) {
    console.log(`\n${label}`);
    const child = spawn(executable, args, { cwd: workspace, env, stdio: ["ignore", "pipe", "pipe"] });
    const outputs = [[child.stdout, process.stdout], [child.stderr, process.stderr]];
    const logs = outputs.map(([source, destination]) => {
      let log = "";
      source.setEncoding("utf8").on("data", chunk => {
        log += chunk;
        destination.write(chunk);
      });
      return () => log;
    });
    const [status, signal] = await once(child, "close");
    if (status !== 0) {
      process.exitCode = status ?? 128 + constants.signals[signal];
      throw new Error(`${label} exited with ${signal ?? status}.`);
    }
    return logs.map(read => read()).join("\n");
  }

  // Every XCTest runs. Tests that create AppKit windows skip themselves outside a dedicated desktop.
  const desktopSkip = readFileSync(join(workspace, "Tests/tncodeTests/TestDesktop.swift"), "utf8")
    .match(/^let testDesktopSkipMessage = "(.+)"$/m)?.[1];
  assert(desktopSkip, "Tests/tncodeTests/TestDesktop.swift must define testDesktopSkipMessage.");
  // These tests run only from their own setup.
  const optIn = new Set([
    "CodexAgentTests/testCodexSessionSearchToolsAndHistoryFromSwift", // verify-codex-agent.mjs with PI_CODEX_XCTEST
    "DesignSnapshotTests/testRenderDesignSnapshots", // TNCODE_DESIGN_SNAPSHOTS
  ]);

  try {
    for (const fixture of ["sidecar", "queued-sidecar", "conversation-fork"]) {
      await run(`Pi ${fixture} fixture`, process.execPath, [`scripts/verify-${fixture}.mjs`]);
    }
    const tap = await run("Codex sessions and sign-in, Pi logins, tool approvals and questions", process.execPath,
      ["--test", "--test-reporter=tap", "Sidecar/codex-rpc.test.mjs", "Sidecar/codex-agent.test.mjs",
        "Sidecar/login.test.mjs", "Sidecar/saved-login.test.mjs", "Sidecar/tool-approval.test.mjs", "Sidecar/agent-questions.test.mjs"]);
    assert.match(tap, /^# pass [1-9]\d*$/m, "The Node test runner reported no passes.");
    assert.match(tap, /^# skipped 0$/m, "The Node test runner must report zero skips.");
    assert.match(tap, /^# todo 0$/m, "The Node test runner must report zero pending tests.");

    const selectedCommit = join(root, "verify-selected-commit");
    await run("Build the selected commit verifier", "/usr/bin/swiftc",
      ["-module-cache-path", join(root, "module-cache"),
        "Sources/tncode/GitWorkspace.swift", "scripts/verify-selected-commit.swift", "-o", selectedCommit]);
    await run("Selected commits in disposable checkouts", selectedCommit, []);

    await withModelRoutingFixture(process.execPath, join(sidecar, "worker.mjs"), async fixture => {
      const log = await run("Swift tests without AppKit windows", "/usr/bin/swift",
        ["test", "--disable-sandbox", "--disable-swift-testing", "--only-use-versions-from-resolved-file"],
        { ...environment, ...fixture, PATH: `${dirname(process.execPath)}:${environment.PATH}`,
          PI_PALETTE_NODE: process.execPath, PI_PALETTE_SIDECAR: sidecar });
      assert(log.includes("Test Suite 'All tests' passed"), "XCTest did not report a pass for all tests.");
      const reasons = new Map(Array.from(log.matchAll(/-\[tncodeTests\.(\w+) (\w+)\] : Test skipped - (.*)$/gm),
        ([, suite, test, reason]) => [`${suite}/${test}`, reason]));
      const skipped = Array.from(log.matchAll(/^Test Case '-\[tncodeTests\.(\w+) (\w+)\]' skipped\b/gm),
        ([, suite, test]) => `${suite}/${test}`);
      const unexpected = skipped.filter(test => reasons.get(test) !== desktopSkip && !optIn.has(test))
        .map(test => `${test}: ${reasons.get(test) ?? "no reason"}`);
      assert.deepEqual(unexpected, [], "Only tests that create AppKit windows may skip.");
      const passed = log.match(/^Test Case '.*' passed\b/gm)?.length ?? 0;
      const windowed = skipped.filter(test => reasons.get(test) === desktopSkip).length;
      console.log(`\n${passed} XCTest cases passed. ${windowed} window tests need a dedicated desktop.`);
    });
    console.log("\nHeadless verification passed. GUI checks require a separate run.");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}
