import assert from "node:assert/strict";
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyFiles(driver, checkout, project, git) {
  const { press, visible, value, until, setField, checkCopy } = driver;
  const relative = "notes/weekly/fixture.txt";
  const file = join(checkout, relative);
  const parentFile = join(project, relative);
  for (const directory of [checkout, project]) mkdirSync(join(directory, "notes/weekly"), { recursive: true });
  writeFileSync(parentFile, "Parent checkout\n");
  writeFileSync(file, "Staged original\n");
  git(checkout, "add", "--", relative);
  writeFileSync(file, "Current worktree\n");
  writeFileSync(join(checkout, "sample.bin"), Buffer.from([0, 0x41, 0xFF, 0x10]));
  writeFileSync(join(checkout, "long.txt"), Buffer.alloc(1024 * 1024 + 1, 65));

  const has = id => {
    try { return Boolean(visible(id)); } catch { return false; }
  };
  const row = path => "files-row-" + path;
  const editorIs = text => value("files-editor").includes("value=" + JSON.stringify(text));
  async function actions(menu, action) {
    press(menu);
    await until(() => visible(action), action);
    press(action);
  }
  async function showExplorer(open) {
    try { press("files-toggle-explorer"); }
    catch (error) { if (!/AX error -(25200|25204)/.test(String(error.stderr))) throw error; }
    await until(() => has("files-search") === open, open ? "restored explorer" : "hidden explorer");
  }
  press("toggle-files");
  await until(() => visible(row("notes")) && visible(row("sample.bin")), "files in the selected checkout");
  assert(!has(row(relative)));
  await actions("files-folder-actions", "files-expand-all");
  await until(() => visible(row(relative)), "expanded nested file");
  await actions("files-folder-actions", "files-collapse-all");
  await until(() => !has(row(relative)), "collapsed file tree");
  const fresh = "created-after-opening.txt";
  assert(!has(row(fresh)));
  writeFileSync(join(checkout, fresh), "Fresh\n");
  press("files-refresh");
  await until(() => visible(row(fresh)), "file created outside the app");

  press(row("sample.bin"));
  await until(() => visible("files-binary-preview") && value("files-contents").includes("00 41 FF 10"), "binary prefix in hex");
  press("files-close-preview");
  press(row("long.txt"));
  await until(() => visible("files-large-preview"), "large text preview");
  assert(!has("files-editor"));
  press("files-close-preview");
  await setField("files-search", "weekly/fixture");
  await until(() => visible(row(relative)) && !has(row("long.txt")), "nested file search");
  press(row(relative));
  await until(() => editorIs("Current worktree\n"), "worktree file bytes");
  await showExplorer(false);
  await showExplorer(true);
  press("files-breadcrumb-notes/weekly");
  await until(() => visible(row(relative)), "breadcrumb parent folder");

  const edited = "Edited in the linked worktree\n";
  await setField("files-editor", edited);
  if (visible("files-save").includes("enabled=true")) press("files-save");
  await until(() => readFileSync(file, "utf8") === edited, "edited file saved");
  await actions("files-file-actions", "files-copy-contents");
  await until(() => checkCopy(edited), "copied the displayed file contents");
  await actions("files-file-actions", "files-copy-path");
  await until(() => checkCopy(relative), "copied the checkout-relative path");
  assert.equal(git(checkout, "show", ":" + relative), "Staged original");
  assert.equal(readFileSync(parentFile, "utf8"), "Parent checkout\n");

  chmodSync(file, 0o444);
  try {
    await setField("files-editor", "Keep these unsaved edits");
    await until(() => visible("files-unsaved"), "pending editor text");
    press("files-refresh");
    await until(() => visible("files-save").includes("enabled=false") && editorIs("Keep these unsaved edits"), "read-only file retains the draft");
    press("toggle-files");
    await until(() => visible("browser-address"), "browser returned under Files");
    press("toggle-files");
    await until(() => editorIs("Keep these unsaved edits") && visible("files-unsaved"), "unsaved file after panel switch");
  } finally {
    chmodSync(file, 0o644);
  }
  writeFileSync(file, "External edit\n");
  press("files-refresh");
  await until(() => visible("files-save-error") && visible("files-save").includes("enabled=false"), "external change protects disk");
  assert(editorIs("Keep these unsaved edits"));
  assert.equal(readFileSync(file, "utf8"), "External edit\n");
  await actions("files-file-actions", "files-discard");
  await until(() => visible("files-confirm-discard"), "explicit discard confirmation");
  press("files-confirm-discard");
  await until(() => editorIs("External edit\n") && !has("files-unsaved"), "discard reloads the external text");
  assert.equal(git(checkout, "show", ":" + relative), "Staged original");
  assert.equal(readFileSync(parentFile, "utf8"), "Parent checkout\n");
  press("toggle-files");
}
