import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyBrowserSearchSettings(driver, { root, launch, quit, record }) {
  const { pick, press, dismiss, visible, value, tree, openSettingsLink, setField, until } = driver;
  const searchURL = "browser-custom-search-url", reset = "reset-browser-search-engine";
  const unfinished = "http://127.0.0.1:1/search?q=";
  const path = join(root, "workspace.json");
  mkdirSync(root, { recursive: true });
  writeFileSync(path, JSON.stringify({ welcomeCompleted: true, projects: [],
    model: { provider: "local", model: "settings-fixture", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 } }), { mode: 0o600 });
  const open = async () => {
    await launch("empty-open-project", root);
    openSettingsLink("pi-workspace://settings/browser");
    await until(() => visible("browser-search-engine"), "browser search settings");
  };
  const close = async () => {
    dismiss("browser-settings-save");
    await until(() => !tree().includes('id="browser-settings-save"') && visible("empty-open-project"), "browser settings saved");
    await quit();
  };
  await open();
  const before = readFileSync(path);
  assert(!tree().includes('id="' + reset + '"'));
  pick("browser-search-engine", "Custom");
  await until(() => visible(searchURL) && visible(reset), "custom search template field");
  await setField(searchURL, unfinished);
  await until(() => tree().includes("Searches use DuckDuckGo until then.") && visible("browser-settings-save").includes("enabled=true"),
              "an unfinished template can be saved with the fallback visible");
  await close();
  await open();
  assert(value(searchURL).includes("value=" + JSON.stringify(unfinished)));
  press(reset);
  await until(() => value("browser-search-engine").includes('value="DuckDuckGo"') && !tree().includes('id="' + reset + '"') &&
    !tree().includes('id="' + searchURL + '"'), "reset restored the default engine and cleared its custom URL");
  await close();
  await open();
  assert(!tree().includes('id="' + reset + '"'));
  pick("browser-search-engine", "Custom");
  await until(() => value(searchURL).includes('value=""'), "the previous custom template was cleared across relaunch");
  dismiss("browser-settings-cancel");
  await until(() => visible("empty-open-project") && !tree().includes('id="browser-settings-save"'), "cancel returned to Home");
  await quit();
  assert.deepEqual(readFileSync(path), before);
  record("A custom URL without %s survived relaunch and displayed the DuckDuckGo fallback. Reset restored DuckDuckGo and cleared the URL after another relaunch. The workspace index stayed byte-identical.");
}

export async function verifyChatSettings(driver, { root, otherRoot, launch, quit, record }) {
  const { press, dismiss, visible, value, tree, setField, until } = driver;
  const selected = id => /\bvalue=1\b/.test(value(id));
  const has = id => tree().includes('id="' + id + '"');
  function seed(workspace, draft) {
    const projectID = randomUUID().toUpperCase(), threadID = randomUUID().toUpperCase(), path = join(workspace, "Project");
    mkdirSync(path, { recursive: true });
    writeFileSync(join(workspace, "workspace.json"), JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
      model: { provider: "local", model: "chat-settings", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
      projects: [{ id: projectID, path, title: "Shortcut project", allowEdits: false, selectedConversation: threadID,
        conversations: [{ id: threadID, isDraft: true, archived: false, title: "Waiting", composerText: draft }] }],
    }), { mode: 0o600 });
  }
  async function chat(workspace, draft, search) {
    await launch("composer", workspace);
    await until(() => value("composer").includes("value=" + JSON.stringify(draft)), "original draft");
    press("model-settings");
    await until(() => visible("settings-nav-chat"), "Chat settings navigation");
    if (search) {
      await setField("settings-search", search, () => has("settings-result-" + search.replaceAll(" ", "-")));
      press("settings-result-" + search.replaceAll(" ", "-"));
    } else press("settings-nav-chat");
    await until(() => visible("settings-heading-chat") && visible("follow-up-behavior"), "Chat controls");
  }
  async function close(draft) {
    dismiss("settings-close");
    await until(() => !has("settings-search") && value("composer").includes("value=" + JSON.stringify(draft)), "the original draft after closing Chat");
    await quit();
  }
  const original = "Keep this multiline\nconversation draft.", other = "Independent preference domain";
  seed(root, original);
  seed(otherRoot, other);
  await chat(root, original, "send shortcut");
  assert(selected("send-shortcut-enter") && selected("follow-up-behavior-steer"));
  press("send-shortcut-mod-enter-multiline");
  await until(() => selected("send-shortcut-mod-enter-multiline") && visible("reset-send-shortcut"), "modifier required for multiline prompts");
  press("send-shortcut-mod-enter");
  press("follow-up-behavior-queue");
  await until(() => selected("send-shortcut-mod-enter") && selected("follow-up-behavior-queue"), "Command-Return and Queue selected");
  await close(original);
  await chat(otherRoot, other);
  assert(selected("send-shortcut-enter") && selected("follow-up-behavior-steer"));
  await close(other);
  await chat(root, original, "follow up behavior");
  assert(selected("send-shortcut-mod-enter") && selected("follow-up-behavior-queue"));
  press("reset-send-shortcut");
  press("reset-follow-up-behavior");
  await until(() => selected("send-shortcut-enter") && selected("follow-up-behavior-steer") &&
    !has("reset-send-shortcut") && !has("reset-follow-up-behavior"), "restored Enter and Steer defaults");
  await close(original);
  record("Settings search reached both Chat controls. The selected Command-Return and Queue options survived relaunch. Another workspace kept Enter and Steer. Reset restored both defaults, and both original drafts survived.");
}

export async function verifySettingsLinks(driver, { root, app, launch, quit, record }) {
  const { openModelSettings, openSettingsLink, press, dismiss, value, visible, setField, until } = driver;
  const plist = join(app, "Contents/Info.plist");
  const packaged = execFileSync("/usr/bin/plutil", ["-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist], { encoding: "utf8" }).trim();
  const projectID = randomUUID().toUpperCase(), threadID = randomUUID().toUpperCase(), otherID = randomUUID().toUpperCase();
  const otherDirectory = join(root, "Other project");
  const directory = join(root, "Project"), index = join(root, "workspace.json");
  const draft = "Preserve this draft through Settings links";
  mkdirSync(directory, { recursive: true });
  mkdirSync(otherDirectory);
  writeFileSync(index, JSON.stringify({ selectedProject: projectID, welcomeCompleted: true,
    model: { provider: "local", model: "original-model", endpoint: "http://127.0.0.1:1/v1", contextWindow: 8192 },
    projects: [{ id: projectID, title: "Project", path: directory, allowEdits: false, selectedConversation: threadID,
      conversations: [{ id: threadID, title: "Draft", isDraft: true, archived: false, composerText: draft }] },
      { id: otherID, title: "Other project", path: otherDirectory, allowEdits: false, conversations: [] }] }), { mode: 0o600 });
  await launch("composer", root);
  await until(() => value("composer").includes(draft), "existing draft");
  const before = readFileSync(index);
  await openModelSettings();
  await setField("model-id", "unsaved-model");
  openSettingsLink("pi-workspace://settings/open-source-licenses");
  await until(() => visible("licenses-search"), "license route in the open settings sheet");
  await setField("licenses-search", "SwiftTerm");
  press("license-entry-swiftterm");
  await until(() => value("license-notice-text-LICENSE").includes("Miguel de Icaza"), "packaged SwiftTerm license");
  openSettingsLink("pi-workspace://settings/about#app-version");
  await until(() => value("about-version").includes("value=" + JSON.stringify(packaged)), "packaged version in the routed About pane");
  for (const [route, control] of [
    ["settings", "settings-group-by-project"], ["settings/appearance", "appearance-color-scheme"], ["settings/chat", "send-shortcut"],
    ["usage", "usage-refresh"], ["settings/worktrees", "storage-worktrees-location"],
    ["settings/threads", "snooze-options"], ["settings/browser", "browser-search-engine"],
  ]) {
    openSettingsLink("pi-workspace://" + route);
    await until(() => visible(control), "routed Settings control " + control);
  }
  openSettingsLink("pi-workspace://projects/" + otherID);
  await until(() => value("project-settings-name").includes("Other project"), "right project from the short URL");
  press("project-settings-copy-path");
  await until(() => driver.checkCopy(otherDirectory), "registered folder of the linked project");
  await setField("project-settings-name", "Unsaved other name");
  const unknown = randomUUID().toUpperCase();
  openSettingsLink("pi-workspace://settings/projects?project=" + unknown);
  await until(() => value("thread-link-error").includes("unavailable") && value("project-settings-name").includes("Unsaved other name"),
              "unknown project preserved the current settings form");
  openSettingsLink("pi-workspace://settings/projects?project=" + projectID);
  await until(() => value("project-settings-name").includes('value="Project"'), "original project from the settings URL");
  press("settings-nav-model");
  await until(() => value("model-id").includes("unsaved-model"), "unsaved model field after both links");
  await setField("settings-search", "Version", () => Boolean(visible("settings-result-app-version")));
  press("settings-result-app-version");
  await until(() => value("about-version").includes("value=" + JSON.stringify(packaged)), "Version search result");
  dismiss("settings-close");
  await until(() => value("composer").includes(draft), "return to the same draft");
  assert.deepEqual(readFileSync(index), before);
  await quit();
  record("Launch Services opened General, Appearance, Chat, Usage, Worktrees, Threads, Browser, the SwiftTerm license and the packaged version. The project shortcut copied the second project's directory. An unknown project retained its open form. Returning to the first project restored the unsaved model edit. Closing Settings preserved the draft and byte-identical workspace index.");
}

export async function verifyAbout({ menuItem, press, visible, value, until, closeWindow, setField, closeSettings }, app) {
  const plist = join(app, "Contents/Info.plist");
  const bundleValue = key => execFileSync("/usr/bin/plutil", ["-extract", key, "raw", "-o", "-", plist], { encoding: "utf8" }).trim();
  const notices = JSON.parse(readFileSync(join(app, "Contents/Resources/ThirdPartyNotices.json"), "utf8"));
  const swiftTerm = notices.find(notice => notice.id === "swiftterm");
  const text = swiftTerm.texts.find(notice => notice.file === "LICENSE").text;
  const copyright = text.split("\n").find(line => line.includes("Copyright"));
  assert(copyright);
  const version = bundleValue("CFBundleShortVersionString");
  const build = bundleValue("CFBundleVersion");
  const matchesBundle = () => value("about-version").includes("value=" + JSON.stringify(version)) &&
                               value("about-build").includes("value=" + JSON.stringify(build));
  menuItem("About " + bundleValue("CFBundleName"));
  await until(matchesBundle, "packaged About version and build");
  press("about-licenses");
  await until(() => visible("licenses-search"), "license list");
  await setField("licenses-search", "SwiftTerm");
  press("license-entry-swiftterm");
  await until(() => value("license-notice-text-LICENSE").includes(copyright), "matching bundled SwiftTerm notice");
  press("licenses-back");
  await until(matchesBundle, "return to About");
  closeWindow("about");
  await until(() => { menuItem("Model Settings…"); return true; }, "enabled Model Settings menu");
  await until(() => visible("settings-about"), "About in Model Settings");
  press("settings-about");
  await until(matchesBundle, "About from settings");
  closeWindow("about");
  await closeSettings();
}

async function openAppearance({ menuItem, visible, until }) {
  await until(() => { menuItem("Appearance Settings…"); return true; }, "enabled Appearance Settings menu");
  await until(() => visible("appearance-chat-width"), "Appearance Settings sheet");
}

export async function verifyAppearance(driver) {
  const { pick, press, until, visible, value, frame, sizeWindow } = driver;
  sizeWindow(1680, 810);
  const initialWidth = frame("composer")[2];
  const draft = value("composer").match(/value=(".*")/)?.[1];
  assert(draft);
  async function select(id, label) {
    pick(id, label);
    await until(() => value(id).includes(label), "selected " + label);
  }
  async function done() {
    press("appearance-done");
    await until(() => { try { visible("appearance-done"); } catch { return true; } }, "dismiss appearance settings");
    assert(value("composer").includes(draft));
  }
  await openAppearance(driver);
  assert(value("appearance-color-scheme").includes("System"));
  assert(value("appearance-chat-width").includes("Comfortable"));
  await select("appearance-color-scheme", "Light");
  await select("appearance-chat-width", "Full");
  await done();
  const fullWidth = await until(() => {
    const width = frame("composer")[2];
    return width > initialWidth + 2 && width;
  }, "wider packaged composer");
  await openAppearance(driver);
  await select("appearance-color-scheme", "Dark");
  await select("appearance-chat-width", "Wide");
  await done();
  const wideWidth = frame("composer")[2];
  assert(wideWidth > initialWidth && wideWidth <= fullWidth + 1);
  return { comfortable: initialWidth, wide: wideWidth, full: fullWidth };
}

export async function restoreAppearance(driver) {
  const { press, value, visible, until } = driver;
  await openAppearance(driver);
  await until(() => value("appearance-chat-width").includes("Wide") && value("appearance-color-scheme").includes("Dark"),
              "appearance settings after relaunch");
  press("appearance-restore-defaults");
  await until(() => value("appearance-chat-width").includes("Comfortable") && value("appearance-color-scheme").includes("System") &&
                    visible("appearance-restore-defaults").includes("enabled=false"), "default appearance restored");
  press("appearance-done");
}
export async function verifySettingsSearch({ press, visible, value, tree, setField, until, keyFor }, index) {
  const before = index();
  const savedModel = before.projects.find(p => p.id === before.selectedProject).modelOverride ?? before.model;
  press("model-settings");
  await until(() => visible("settings-heading-general") && visible("settings-search").includes("focused=true"), "Settings opens General with search focus");
  await setField("settings-search", "no such setting in this fixture");
  await until(() => visible("settings-search-empty"), "unmatched settings search");
  keyFor("settings-search", 53);
  await until(() => value("settings-search").includes('value=""') && visible("settings-nav-model"), "Escape clears the current settings query");

  async function result(query, id) {
    await setField("settings-search", query);
    await until(() => visible("settings-result-" + id), "settings result for " + query);
    keyFor("settings-search", 125);
    keyFor("settings-search", 126);
    keyFor("settings-search", 36);
  }
  await result("Model ID", "model-id");
  await until(() => visible("model-id").includes("focused=true") && value("model-id").includes(savedModel.model),
              "Return focuses the project's actual model field");
  await setField("model-id", "unsaved-route-fixture");
  keyFor("model-id", 3, "cmd");
  await until(() => visible("settings-search").includes("focused=true"), "Command-F returns to settings search");
  await result("Open source licenses", "licenses-search");
  await until(() => visible("licenses-search").includes("focused=true"), "licenses search in the About pane");
  await setField("licenses-search", "SwiftTerm");
  press("license-entry-swiftterm");
  await until(() => value("license-notice-text-LICENSE").includes("Miguel de Icaza"), "bundled license text via settings search");
  press("settings-nav-model");
  await until(() => value("model-id").includes("unsaved-route-fixture"), "unsaved model edit stays in its pane");
  press("settings-nav-general");
  await until(() => visible("settings-close"), "General Done button");
  press("settings-close");
  await until(() => !tree().includes('id="settings-search"'), "Settings closed");
  const saved = index();
  assert.deepEqual(saved.projects.find(p => p.id === before.selectedProject).modelOverride,
                   before.projects.find(p => p.id === before.selectedProject).modelOverride);
  assert.deepEqual(saved.model, before.model);
}
