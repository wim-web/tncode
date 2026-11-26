import assert from "node:assert/strict";
import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { verifyMediaFiles } from "./verify-media-files.mjs";

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
  const marker = "Unique worktree line 6000 — 目印";
  const line = "日".repeat(64) + "\n";
  const prefix = line.repeat(5999);
  assert(Buffer.byteLength(prefix) > 1024 * 1024);
  writeFileSync(join(checkout, "long.txt"), prefix + marker + "\n" + line.repeat(120));

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
  async function transition(id, ready, label) {
    try { press(id); }
    catch (error) { if (!/AX error -(25200|25204)/.test(String(error.stderr))) throw error; }
    await until(ready, label);
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
  await transition("files-refresh", () => visible(row(fresh)), "file created outside the app");
  await verifyMediaFiles(driver, checkout);
  await verifyRenderedFiles(driver, checkout);

  press(row("sample.bin"));
  await until(() => visible("files-binary-preview") && value("files-contents").includes("00 41 FF 10"), "binary prefix in hex");
  press("files-close-preview");
  press(row("long.txt"));
  await until(() => visible("files-large-preview"), "large text preview");
  assert(!has("files-editor"));
  await setField("files-large-line", "6000");
  driver.keyFor("files-large-line", 36);
  await until(() => driver.selectedText("files-contents") === marker, "selected full line 6000 beyond the first MiB");
  const range = value("files-large-range");
  press("files-large-next");
  await until(() => value("files-large-range") !== range && visible("files-large-previous").includes("enabled=true"), "next page of large text");
  press("files-large-previous");
  await until(() => value("files-large-range") === range, "previous page restores its line range");
  press("files-close-preview");
  press(row("long.txt"));
  await setField("files-large-line", "6000");
  press("files-large-go");
  await until(() => driver.selectedText("files-contents") === marker, "button selects line 6000 after reopening");
  press("files-close-preview");
  await setField("files-search", "weekly/fixture");
  await until(() => visible(row(relative)) && !has(row("long.txt")), "nested file search");
  press(row(relative));
  await until(() => editorIs("Current worktree\n"), "worktree file bytes");
  await transition("files-toggle-explorer", () => !has("files-search"), "hidden explorer");
  await transition("files-toggle-explorer", () => has("files-search"), "restored explorer");
  await transition("files-breadcrumb-notes/weekly", () =>
    visible("files-parent-folder").includes("notes/weekly") && value("files-search").includes('value=""') &&
    visible(row(relative)), "breadcrumb opens the parent directory and clears its search");

  const edited = "Edited in the linked worktree\n";
  await setField("files-editor", edited);
  await until(() => readFileSync(file, "utf8") === edited && !has("files-unsaved"), "idle editor saved the exact bytes");
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
    await transition("files-refresh", () => visible("files-read-only") && visible("files-save").includes("enabled=false") &&
                     editorIs("Keep these unsaved edits"), "read-only file retains the draft");
    await transition("terminate:", () => visible("keep-editing-draft") && driver.tree().includes("Couldn’t save " + relative),
                     "quit blocked by the unsaved file");
    await transition("keep-editing-draft", () => !has("keep-editing-draft") && editorIs("Keep these unsaved edits"), "keep editing the blocked file");
    await transition("toggle-files", () => visible("browser-address"), "browser returned under Files");
    await transition("toggle-files", () => editorIs("Keep these unsaved edits") && visible("files-unsaved"), "unsaved file after panel switch");
  } finally {
    chmodSync(file, 0o644);
  }
  await until(() => readFileSync(file, "utf8") === "Keep these unsaved edits" && !has("files-unsaved"), "restored permission resumes autosave");
  chmodSync(file, 0o444);
  try {
    await setField("files-editor", "Draft awaiting conflict resolution");
    await until(() => visible("files-read-only") && has("files-unsaved"), "new draft blocked before replacement");
    const replacement = join(checkout, "replacement.fixture");
    writeFileSync(replacement, "External edit\n");
    renameSync(replacement, file);
  } finally {
    chmodSync(file, 0o644);
  }
  await transition("files-refresh", () => visible("files-save-error") && visible("files-save").includes("enabled=false"), "external change protects disk");
  assert(editorIs("Draft awaiting conflict resolution"));
  assert.equal(readFileSync(file, "utf8"), "External edit\n");
  await actions("files-file-actions", "files-discard");
  await until(() => visible("files-confirm-discard"), "explicit discard confirmation");
  await transition("files-confirm-discard", () => editorIs("External edit\n") && !has("files-unsaved"), "discard reloads the external text");
  assert.equal(git(checkout, "show", ":" + relative), "Staged original");
  assert.equal(readFileSync(parentFile, "utf8"), "Parent checkout\n");
  press("toggle-files");
}

async function verifyRenderedFiles({ press, visible, value, until, setField }, checkout) {
  const markdown = "# Checkout notes\n\nSee [the heading](#checkout-notes).\n";
  const csv = 'Name,Note\r\nTokyo,"quoted, 日本語"\r\nOsaka,"two\nlines"\r\n';
  const names = ["outline.md", "cities.csv", "cities.tsv", "prices.csv"];
  const sources = [markdown, csv, 'Name\tNote\nTokyo\t"quoted\tvalue"\n', '"Artikel";Preis, EUR;Menge\n"Apfel";1,25;2'];
  for (const [i, name] of names.entries()) writeFileSync(join(checkout, name), sources[i]);
  press("files-refresh");
  const row = name => "files-row-" + name;
  const displays = (id, text) => value(id).includes("value=" + JSON.stringify(text));
  await until(() => names.every(name => visible(row(name))), "Markdown, CSV and TSV fixture files");
  press(row(names[0]));
  await until(() => displays("files-editor", markdown), "Markdown source");
  const edited = markdown + "\nCurrent worktree text";
  await setField("files-editor", edited);
  press("files-toggle-rendered");
  const rendered = () => {
    const content = value("files-rendered-markdown");
    return content.includes("Checkout notes") && content.includes("the heading") &&
           content.includes("Current worktree text") && !content.includes("# Checkout notes") && !content.includes("](#");
  };
  await until(rendered, "rendered heading and link label from the edited Markdown");
  press("files-close-preview");
  press(row(names[0]));
  await until(rendered, "remembered Markdown preview");
  press("files-toggle-rendered");
  await until(() => displays("files-editor", edited) && readFileSync(join(checkout, names[0]), "utf8") === edited,
              "Markdown returned to its exact saved source");
  press("files-close-preview");
  press(row(names[1]));
  await until(() => displays("files-table-cell-1-2", "quoted, 日本語") && displays("files-table-cell-2-2", "two\nlines"),
              "quoted CSV values in separate rows");
  press("files-toggle-rendered");
  await until(() => displays("files-editor", csv), "original CSV source with CRLF");
  press("files-close-preview");
  press(row(names[2]));
  await until(() => displays("files-editor", sources[2]), "remembered source mode on TSV");
  press("files-toggle-rendered");
  await until(() => displays("files-table-cell-1-2", "quoted\tvalue"), "TSV delimiter in a quoted cell");
  press("files-close-preview");
  press(row(names[3]));
  await until(() => displays("files-table-cell-1-2", "1,25") && displays("files-table-cell-1-3", "2"),
              "decimal comma in a semicolon-delimited CSV");
  press("files-close-preview");
  assert.equal(readFileSync(join(checkout, names[1]), "utf8"), csv);
  assert.equal(readFileSync(join(checkout, names[2]), "utf8"), sources[2]);
}
