import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

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
