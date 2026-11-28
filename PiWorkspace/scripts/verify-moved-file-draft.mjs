import assert from "node:assert/strict";
import { chmodSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export async function verifyMovedFileDraft(driver, { directory, repository, git, conversation }) {
  const { press, visible, value, until, tree, setField, dismiss, checkCopy } = driver;
  const name = "recovery-note.txt";
  const first = join(directory, "Original draft checkout");
  const moved = join(directory, "Moved draft checkout");
  const final = join(directory, "Moved checkout with replacement");
  const textIs = text => value("files-editor").includes("value=" + JSON.stringify(text));
  const has = id => { try { return Boolean(visible(id)); } catch { return false; } };
  const where = () => conversation().location?.worktree?.path;
  async function select(checkout) {
    press("choose-workspace");
    const option = await until(() => {
      if (!checkout) return visible("use-project-workspace") && "use-project-workspace";
      return Array.from(tree().matchAll(/id="(existing-worktree-([^"]+))"/g)).find(match =>
        realpathSync(match[2]) === realpathSync(checkout))?.[1];
    }, "checkout in the draft workspace menu");
    press(option);
    await until(() => !tree().includes('id="use-project-workspace"') &&
                      (checkout ? where() && realpathSync(where()) === realpathSync(checkout) : !where()), "draft switched checkout");
  }
  async function showFiles() {
    if (!has("files-folder-actions")) {
      if (!has("hide-right-panel")) dismiss("toggle-right-panel");
      await until(() => visible("add-panel-surface"), "Add Panel Surface in the right panel");
      dismiss("add-panel-surface");
      await until(() => visible("add-panel-files").includes("enabled=true"), "Files in Add Panel Surface");
      dismiss("add-panel-files");
    }
    await until(() => visible("files-folder-actions"), "Files for the current checkout");
  }
  async function openNote() {
    await showFiles();
    await until(() => visible("files-row-" + name), "note in the current checkout");
    press("files-row-" + name);
    await until(() => visible("files-editor"), "opened note editor");
  }
  async function blockEdit(path, text) {
    chmodSync(path, 0o444);
    await setField("files-editor", text);
    await until(() => visible("files-read-only") && visible("files-unsaved") && textIs(text), "blocked write preserves draft");
  }
  git(repository, "worktree", "add", "-b", "recover-draft", first);
  writeFileSync(join(repository, name), "Project copy\n");
  writeFileSync(join(first, name), "Original file\n");
  await select(first);
  await openNote();
  const edit = "Draft from the moved checkout\n";
  await blockEdit(join(first, name), edit);
  const oldPath = join(where(), name);
  git(repository, "worktree", "move", "--", first, moved);
  await select(null);
  await showFiles();
  press("files-folder-actions");
  await until(() => visible("files-unsaved-files"), "unresolved drafts menu");
  press("files-unsaved-files");
  const oldRow = "files-unsaved-row-" + oldPath;
  await until(() => visible(oldRow), "old checkout draft listed under its full path");
  press(oldRow);
  await until(() => visible("files-recovery-copy"), "recovery actions on the old draft");
  dismiss("files-recovery-copy");
  await until(() => checkCopy(edit), "copied unresolved draft, including final newline");
  assert.equal(readFileSync(join(repository, name), "utf8"), "Project copy\n");
  await select(moved);
  await openNote();
  await until(() => textIs(edit) && visible("files-unsaved"), "same draft follows the moved checkout");
  chmodSync(join(moved, name), 0o644);
  await until(() => readFileSync(join(moved, name), "utf8") === edit && !has("files-unsaved"), "autosave follows the verified file");

  const conflict = "Keep me while checking the replacement\n";
  await blockEdit(join(moved, name), conflict);
  git(repository, "worktree", "move", "--", moved, final);
  const replacement = join(final, "new-file.tmp");
  writeFileSync(replacement, edit);
  renameSync(replacement, join(final, name));
  await select(final);
  await openNote();
  await until(() => textIs(conflict) && visible("files-save-error"), "same-byte replacement stays protected");
  dismiss("terminate:");
  await until(() => visible("keep-editing-draft"), "Quit blocked by protected draft");
  dismiss("keep-editing-draft");
  await until(() => !has("keep-editing-draft"), "return to recovery");
  press("files-file-actions");
  await until(() => visible("files-discard"), "discard pending file edit");
  press("files-discard");
  await until(() => visible("files-confirm-discard"), "confirm explicit discard");
  dismiss("files-confirm-discard");
  await until(() => textIs(edit) && !has("files-unsaved"), "discard reloads the replacement");
  assert.equal(readFileSync(join(final, name), "utf8"), edit);
  assert.equal(readFileSync(join(repository, name), "utf8"), "Project copy\n");
  dismiss("close-right-panel-files");
  await until(() => !has("files-folder-actions") && visible("composer"), "close Files after recovering the two drafts");
}
