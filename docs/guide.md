# tncode

tncode is a native macOS client for local projects and conversations. A new workspace runs Codex through the installed `codex app-server`. You can also choose the bundled Pi agent. Each agent keeps its own conversation history. [T3 Code sidebar](https://github.com/pingdotgg/t3code/blob/v0.1.12/docs/user/thread-sidebar.md)

## Build and open

Install Xcode with Swift 6.2 or later and Node.js 22.19 or newer with npm. From the repository root, run:

```sh
./scripts/build-app.sh
open "dist/tncode.app"
```

The app bundles Node.js and Pi. The build uses the current Mac's architecture and ad-hoc signing.

To keep a build for comparison, pass its destination directory to `./scripts/build-app.sh`. Set `TNCODE_VERIFY_APP` to the resulting `.app` path when running the UI verifier.

**tncode → About tncode** shows the bundled version, build, and runtime versions. Select **Open source licenses…** to search the notices included in that build.

Open `tncode://settings/open-source-licenses` to go directly to the notices. `tncode://settings/about#app-version` and the **Version** Settings search result show the packaged version.

## Start a conversation

1. If Codex is already signed in on this Mac, select **Start** in Welcome. Otherwise, select **Sign in…**, choose **Codex**, and finish signing in with your ChatGPT account. In an existing workspace, select **Model Settings → Agent → Codex → Use Codex** and open a new conversation. Submitted Pi conversations keep using Pi.
2. Select **Add Project → Local folder**. Enter a path or select **Browse**, then select **Add Project**. In the path field, use the arrow keys to highlight a folder and Tab to enter it. With several matches, Tab completes their shared prefix. The draft opens with its message field focused. **New project** creates a Git repository in the parent folder you choose.
3. Enter a message and select **Send**. Select **Stop** to cancel an active turn. On relaunch, the app reopens the selected conversation if it has unfinished text. Select a conversation in the sidebar to continue it.
4. Use **Search Threads** to find a thread by title, project name, or message text. Opening a message result takes you to that message. In **Thread filters**, check the projects to include or choose **All Projects**.
5. Use the thread context menu to rename, pin, settle, or archive a thread. Use **Show Archive** in the filter menu to reopen or restore an archived thread. Use the project menu above the thread to manage its folder.

**Settings → Archive** lists archived threads by project and checkout. Choose **Unarchive** to return a thread to the sidebar and keep editing the current conversation. Turn on **Archive confirmation** in **Settings → General** to see the thread name before archiving it.

In **Project Overview**, choose a symbol, emoji, monogram, or image for the sidebar. tncode saves the imported image with the project. **Reset project icon to default** restores that project's original icon.

**Welcome → Find Pi Projects** lists projects with local Pi history. Select a session to import its saved messages as a read-only conversation. Pi records its provider and model, but an external session does not identify the account that originally received those messages.

To start from an existing Git repository, choose **Add Project → Git URL** and enter its URL. Choose an empty folder or a new path. **Clone** creates any missing parent folders and opens the checkout. Cloning into an empty folder already registered as a project keeps its conversations.

Choose **Add project** from a draft's project picker to register another folder. Cancel returns to the draft. A new folder opens its own empty draft. A previously registered folder opens its latest unarchived conversation, or an empty draft if that conversation is settled or there is no saved conversation. Your earlier draft and attachments stay in the sidebar.

By default, Return sends a message. When Pi accepts steering during a turn, Return steers Pi and ⌘Return queues a follow-up. **Settings → Chat** lets you change the send shortcut and choose **Queue** or **Steer** as the usual follow-up action. Shift-Return inserts a new line.

Use a queued row's menu to edit, reorder, or remove it. You can update a paused queue before signing in to the provider. **Stop** and relaunch leave outstanding messages paused until you start a row or select **Resume Queue**.

Codex conversations accept UTF-8 text attachments and queue follow-ups between turns. In a Pi conversation, **Attach Files** also accepts PNG and JPEG images. You can paste an image or drop files onto the composer or a thread in the sidebar. Select an image thumbnail to preview it. For a local Pi model that accepts images, enable image input in **Model Settings**.

Select a text attachment to read its contents. **Remove from Draft** removes the selected attachment from the draft or queued edit. For sent files, **Save File** opens the macOS save dialog. Older Pi histories that recorded only the name show **Attachment unavailable**.

Pasting at least 32 KiB of UTF-8 text creates a text attachment when it fits. Press ⌘⇧V or choose **Edit → Paste and Match Style** to paste text inline. If a normal paste exceeds the 64 KiB text attachment limit, it stays inline when the resulting draft fits within 120,000 UTF-16 units.

With the composer focused, press ⌘S to stash its text and attachments. Select the stash count to restore an entry into the current draft or delete it. If the composer is empty and the stash has one entry, ⌘S restores it.

For a submitted conversation, right-click its sidebar row and choose **Copy → Thread**. **Edit → Open Thread Link from Clipboard** and macOS can open this link in the same local workspace. If you move the workspace itself, copy a new link.

A shared prompt link such as `tncode://new/v1?prompt=Review+the+tests&repo=owner%2Frepo` opens a review sheet. Confirm the project or choose **Use without project** to open an unsent draft. Select **Send** when the draft is ready.

For a PR link such as `tncode://new/v1?pr=owner%2Frepo%2F42&prompt=Review+this+change`, review the folder and commit before selecting **Check out**. If you clone the repository first, open the link again. When a linked conversation already exists, **Open Thread** keeps its draft. **Replace Draft and Open** applies the linked prompt to it.

In a Pi conversation, choose **Fork from this response** on a completed reply to start a separate conversation with the messages through that reply. **Open source conversation** and **Open fork** take you between the two histories.

In a Pi conversation, use **Add Panel Surface → Side chat**, or send `/btw` followed by a question, to ask beside the current thread. The side chat has its own Pi history. **Add to chat** attaches a copy of its messages to the parent’s draft.

Press ⌘K outside the terminal to open the command palette. Type to filter, use the arrow keys and Return to choose an action, or press Escape to return to the workspace. **New thread in…** lets you select a project.

Type a setting name such as **Chat width** or **Model ID** in the palette to jump to its control. ⌘⇧[ and ⌘⇧] move between visible sidebar threads. ⌘1 through ⌘9 open the corresponding visible row.

Choose a hit under **In messages** to open the conversation at that message. Press ⌘F to search the current thread. Return and ⇧Return move between matching messages on its active Pi branch. Escape returns to the composer. **Edit → Search Threads** focuses the sidebar.

Press ⌘P to find a file by name, or ⌘⇧F to search text in the current checkout. Choosing a text match opens Files at the matching line. Both searches are also available in the command palette.

If a project folder moves, use **Relink Folder** in its context menu to point the project at the new path and retain its conversations.

Choose **Start without a project** on the empty home screen to work in a private folder. The thread menu's **Turn into project** action registers that folder and keeps the conversation history.

Unsent composer text stays with its thread when you switch threads or quit. If saving fails, the app keeps the draft open. Restore write access, then select **Retry Saving** or **Retry and Quit**. Right-click a draft in the sidebar to copy its working path or selected branch, open its project settings, or discard it.

Pi can read files with models that support tools. Choose **Supervised** to approve or decline individual shell and edit requests. **Shell and edits** enables those tools for the project. They use the permissions of your macOS user.

A local model with tools enabled can ask a question during its turn. Select the options or type an answer, use **Next** and **Previous** to review the pages, then select **Submit**. **Dismiss** sends the model a declined response. **Stop** ends the turn. A supervised write requested after an answer still needs its own approval.

Codex uses its own login, model configuration, and MCP servers. Open a Codex conversation's details to see the Web search mode and whether this session advertises Computer Use. To approve an app access request, choose **Supervised** in the composer. The Codex conversation history lives in the Codex home.

Pi uses the bundled Pi SDK and its own saved accounts. You can sign in from **Model Settings → Account**. If you choose an API-key provider, the app stores your key in Keychain. The workspace index and Pi conversation files live in `~/Library/Application Support/tncode`.

In a registered project, **Model Settings → Scope** lets you change that project's model or the workspace default. **Reset to Workspace default** restores inheritance and keeps the provider credential.

Open **Settings** from the sidebar or press ⌘, to search the available controls. For example, search for **Model ID** and press Return to edit the selected project's model, or search for **Open source licenses** to read the packaged notices.

**Settings → Threads → Snooze options** sets the choices in the Snooze menu. Add a duration or a local day and time. You can keep up to eight choices. **Reset to defaults** restores the preset list. Existing reminders keep their scheduled times.

**Settings → General → Add project starts in** sets the initial folder for adding or cloning a project. **Help → Show Welcome** or **Settings → About → Welcome page** reopens onboarding. Closing it returns to the selected draft.

**Settings → Usage** shows token counts and USD costs recorded in local Pi conversation histories. Select a period, filter by project or provider, and select a model to inspect input, output and cache tokens. **Refresh usage** includes newly recorded replies. A total marked **+ unreported** includes only messages with a recorded value.

Press ⌘U to open Usage from the workspace. With focus on the report, C selects Cost, T selects Tokens, and L selects Limits. Press ⌘U again to close it.

If the app cannot read its workspace index, the startup screen shows the affected folder and offers **Retry**. If a valid previous index exists, **Restore Previous Workspace** restores that project and thread list and keeps the damaged index and conversation files.

**tncode → Appearance Settings…** changes the color scheme and conversation width across projects. **Restore Defaults** returns to the system appearance and Comfortable width.

**Settings → General → Restore device defaults** lists the local preferences it will change. Review the list, then choose **Confirm** to restore them.

## Work in a Git checkout

1. In a draft, use the workspace control below the composer or press ⌘⇧X. Choose the project folder, an existing worktree, or a new worktree and its base branch. **Settings → Worktrees → Worktree location** sets the storage folder for new checkouts. An existing checkout or a checkout awaiting Retry keeps its saved path.
2. Send the first message to create a new worktree. If preparation fails, correct the problem and select **Retry** in that thread. The app keeps the prompt and failed stage across relaunch. Before Pi starts the turn, **Cancel** returns the text to the draft. **Work locally** sends it from the project folder.
3. Open **Changes** in the thread header. Select a file to read its unstaged or staged patch. Use the file's stage or unstage button to change the index.
4. Check the files to include and select **Commit**. Enter a subject to commit directly. Leave it empty to generate a subject and optional body with Pi. In **Settings → Source Control**, choose repository conventions, Conventional Commits, or custom instructions and an optional writer model. A generated commit preserves excluded staging. With a typed subject, excluded files keep their working copies and their staged changes become unstaged when the commit succeeds.
5. Open **Terminal** in the header to start an interactive shell in the thread's directory. Use **New Terminal** for another tab or split a tab horizontally or vertically. Press ⌘⇧[ or ⌘⇧] to move between panes. Drag the top edge to adjust the drawer height for that thread. Hiding the drawer keeps its height and shells. Confirm **Close Terminal** to end the selected shell.

Use the branch button or ⌘⇧G to search local and cached remote refs. **New Branch** creates a branch at the base you choose. Selecting a branch that already has a linked checkout moves the thread to that checkout.

For a new worktree, **Start from remote** defaults to on. On the first send, tncode fetches the selected branch's upstream, or the same branch on `origin`. If the remote has no such branch, the app uses the local ref. Turn the option off to start at the selected local or cached ref. **Settings → Worktrees** changes the default for future drafts.

Open **Files** to search or browse the selected checkout. Small text files save after a short pause in typing. **Save** writes immediately. A read-only file keeps pending edits until write access returns. If another program replaces or edits the file, copy your pending text or choose **Discard Edits** to reload the disk version.

In Markdown files, select **Show rendered markdown** to read headings and links, then **Show markdown source** to edit. CSV and TSV files open as tables. **Show source** opens the original text, including quoting and line breaks.

If a worktree moves while an edit is pending, select its new path in the draft's workspace menu. The editor reconnects the draft to the same checkout. **Folder Actions → Unsaved Files** also lets you copy or discard pending text from an old location.

Select an image to see its dimensions, change its zoom, or open the expanded preview. Select a PDF to page through it, fit its width, or search its text. **Retry** reloads a file after you replace a damaged copy.

For a standalone SQLite database, select a table and use **Previous Rows** and **Next Rows** to read it in pages of 50. Files reads a snapshot of the selected checkout's database. If it is in WAL mode or has a rollback journal, open a standalone copy.

Open a ZIP, JAR, TAR, TAR.GZ, TGZ, or GZIP file to browse its entries. Select a text file or image to preview it. Files reads the members in memory and leaves the archive and checkout untouched.

For text files over 1 MiB, enter a line number in **Go to Line** or use **Next Page** and **Previous Page**. Each page holds up to 32 lines. Lines longer than 16 KiB show their first 16 KiB, up to a complete UTF-8 character.

Open **Browser** in the thread header. Enter a URL, a host such as `localhost:5173`, or search terms, then press Return. **tncode → Browser Settings…** selects the search engine. A custom HTTP or HTTPS search URL uses `%s` for the query. Use **New Browser Tab** to choose the Default or Alternate profile. Tabs keep their own history and zoom. Tabs in the same thread and profile share temporary website data until you quit the app.

Choose **Open Mini Player** to keep the page over the conversation. Drag the arrow handle to move it or drag an edge to resize it. **Open in Browser Panel** returns the page to its tab. **Open in Floating Window** moves it to a separate macOS window.

With the page focused, press ⌘F or choose **Find on page**. Return and ⇧Return step through matches in that tab. Escape returns focus to the page.

An unfinished custom search URL stays editable after you save it. Until the URL contains a usable `%s` placeholder, address-bar searches use DuckDuckGo. **Reset** beside **Search engine** restores DuckDuckGo and clears the custom URL.

Open **Pull Requests** in the header and choose **Pull Requests** or **Issues** for the selected checkout. Search by text or a filter such as `label:bug`, choose a state, and use **Load more** for the next page. Choose a PR to read its description, branches, and checks, or an Issue to read its author, labels, and body.

In the PR list, **Author** and **Labels** let you search the repository's available choices. Choose **Anyone** or **Clear labels** to remove that filter while keeping the others.

In **Linked items**, choose **Link pull request** or **Link issue**, then enter the number or URL for the checkout's GitHub repository. **Link to thread** in Issue details fills in the issue URL. The links stay with the selected thread across relaunch. Select a linked issue to read it, copy its URL or unlink it.

From either Issue detail view, edit the title or description and select **Save**, or enter a comment and select **Comment**. If GitHub’s acknowledgement is lost, **Check result** reads the issue for the submitted text. The app keeps the pending comment through relaunch and enables submission again when it can confirm the new comment.

For a failed GitHub Actions check, choose **View log** to read up to the last 200 lines and 96 KiB of the selected job. **Retry** fetches it again after access is restored.

Pull Requests uses the GitHub CLI (`gh`) on the app's PATH or in a standard Homebrew or MacPorts location. Sign in to GitHub CLI from Terminal before opening the list. The app uses the checkout's GitHub.com `origin` fetch remote or its sole GitHub.com fetch repository.

To open a specific folder when launching a new instance, run:

```sh
open -na "dist/tncode.app" --args --project "/path/to/project"
```

## Verify the app locally

Run the headless suite while using your Mac. It exercises the Pi worker, saved conversations, checkout Git operations, and file formats with private fixtures. A skipped selected test makes the run fail.

```sh
node scripts/verify-headless.mjs
```

To test the Codex agent, set `CODEX_BINARY` to the absolute path of the installed Codex executable and run `node scripts/verify-codex-agent.mjs`. It uses a disposable Codex home, a loopback model fixture, and a test MCP server. Set `PI_CODEX_XCTEST` to the built `tncodePackageTests.xctest` bundle to include Swift conversation routing.

For the full native UI suite, use a separate macOS login session or virtual machine with Accessibility and keyboard input access for the test driver. Build the app and run the following commands inside that session.

```sh
export TNCODE_TEST_DESKTOP=dedicated
swift test -c release
swiftc -module-cache-path .build/ax-cache scripts/ax.swift -o .build/ax
node scripts/verify-app.mjs "$PWD/.build/ax" --fixture-model
node scripts/verify-app.mjs "$PWD/.build/ax" --fixture-model --worktree
node scripts/verify-app.mjs "$PWD/.build/ax" --usage-only
node scripts/verify-app.mjs "$PWD/.build/ax" --workspace-controls-only
node scripts/verify-app.mjs "$PWD/.build/ax" --conversation-controls-only
node scripts/verify-app.mjs "$PWD/.build/ax" --project-flows-only
node scripts/verify-native-paste.mjs "$PWD/.build/ax" "dist/tncode.app"
node scripts/verify-app.mjs "$PWD/.build/ax" --thread-actions-only
node scripts/verify-app.mjs "$PWD/.build/ax" --queue-edit-only
node scripts/verify-app.mjs "$PWD/.build/ax" --sidebar-and-checks-only
node scripts/verify-app.mjs "$PWD/.build/ax" --image-preview-only
node scripts/verify-text-attachment-save.mjs --foreground "$PWD/.build/ax" "dist/tncode.app"
node scripts/verify-app.mjs "$PWD/.build/ax" --new-thread-routes-only
node scripts/verify-app.mjs "$PWD/.build/ax" --draft-projects-only
node scripts/verify-app.mjs "$PWD/.build/ax" --palette-files-only
node scripts/verify-app.mjs "$PWD/.build/ax" --startup-draft-only
node scripts/verify-app.mjs "$PWD/.build/ax" --recovery-actions-only
node scripts/verify-app.mjs "$PWD/.build/ax" --pr-files-only
node scripts/verify-app.mjs "$PWD/.build/ax" --right-terminal-only
node scripts/verify-app.mjs "$PWD/.build/ax" --model-account-only
node scripts/verify-app.mjs "$PWD/.build/ax" --side-chat-only
node scripts/verify-app.mjs "$PWD/.build/ax" --settings-links-only
node scripts/verify-app.mjs "$PWD/.build/ax" --chat-settings-only
node scripts/verify-app.mjs "$PWD/.build/ax" --prompt-links-only
node scripts/verify-app.mjs "$PWD/.build/ax" --pr-prompt-links-only
node scripts/verify-app.mjs "$PWD/.build/ax" --issue-edits-only
node scripts/verify-draft-links.mjs "$PWD/.build/ax" "dist/tncode.app"
node scripts/verify-app.mjs "$PWD/.build/ax" --local-changes-only
node scripts/verify-app.mjs "$PWD/.build/ax" --sqlite-files-only
node scripts/verify-app.mjs "$PWD/.build/ax" --archive-files-only
node scripts/verify-app.mjs "$PWD/.build/ax" --browser-find-only
node scripts/verify-app.mjs "$PWD/.build/ax" --browser-find-keys-only
node scripts/verify-app.mjs "$PWD/.build/ax" --browser-search-settings-only
node scripts/verify-commit-generation.mjs "$PWD/.build/ax" "dist/tncode.app"
node scripts/verify-stop-retry.mjs "dist/tncode.app" "$PWD/.build/ax"
node scripts/verify-app.mjs "$PWD/.build/ax" --snooze-only
node scripts/verify-app.mjs "$PWD/.build/ax" --snooze-options-only
node scripts/verify-app.mjs "$PWD/.build/ax" --project-settings-only
node scripts/verify-app.mjs "$PWD/.build/ax" --project-icons-only
node scripts/verify-app.mjs "$PWD/.build/ax" --archived-threads-only
node scripts/verify-file-drops.mjs "$PWD/.build/ax" "dist/tncode.app"
node scripts/verify-attachments.mjs --release-suite "dist/tncode.app"
```

The app verifier writes its report under `dist/verification-*/logs`. The neighboring `fixture` link points to the test data in a temporary folder outside the source checkout. Model turns use a disposable Keychain item. The worktree run checks failure and retry, terminal lifetime, selected commits, and PR details from the mock GitHub CLI. The file-drop verifier moves the pointer across a disposable source window and the app. The release suite supplies loopback providers for both the attachment and question tests. To test real local model replies, run Ollama on port 18541 with `smollm2:135m` installed and omit `--fixture-model`.

The desktop verifier runs a private copy of the named build. Input, drag, and system-picker scenarios check for `TNCODE_TEST_DESKTOP=dedicated` before starting. The idle timer can delay those scenarios within the dedicated session.

The startup-draft, recovery-actions, PR-files, right-terminal, model-account, side-chat, settings-links, chat-settings, prompt-links, PR-prompt-links, issue-edits, queue-edit, snooze-options, and local-changes scenarios use background Accessibility actions. They can run while another application has keyboard focus. The settings-links check opens the packaged version and license list while retaining an unsaved project model edit. The PR-link check clones from a local Git mirror and changes the simulated PR head before confirmation. The issue-edits check uses a private mock GitHub CLI and counts its requests across two app restarts.

The model-account check routes an existing conversation and a fresh draft after a project settings reset. The side-chat check holds the first parent turn, verifies the child's reply, and follows its attachment back into the parent after relaunch. The separate Stop-retry verifier holds the private app's Pi worker for the ten-second retry. Its watchdog releases that worker on controller exit or after 18 seconds.

`logs/artifact.json` records the bundle's code directory hash and bundled Pi version. Its SHA-256 digests cover the app executable, Pi worker, Accessibility driver, verification scripts, fixture modules, and the private copy of the mock GitHub CLI.

To test which network connections the packaged Pi helper attempts during startup, idle time, an explicit local turn, and shutdown, run `node scripts/verify-default-telemetry.mjs`. It checks the Node network and child-process APIs against a loopback receiver and applies a macOS process sandbox. Native app and WebKit traffic require separate observation.

### Check the sidebar project scope

After `node scripts/verify-app.mjs "$PWD/.build/ax" --sidebar-and-checks-only` in the dedicated session, the report is in `dist/verification-*/logs/report.txt`. The fixture starts with Alpha and Beta threads, Gamma's active unsent draft, and an empty project.

1. Open **Thread filters** (`thread-filters`). Enable **Group by Project**. Click Alpha to select its scope, then reopen the picker. Search for an unmatched title in **Search projects** (`project-filter-search`). Confirm **No matching projects** (`project-filter-no-results`) appears and Return keeps the picker open.
2. Replace the query with `a`. Press Down to highlight Beta. Press Shift-Return to add Beta to Alpha. Press it again to remove Beta. Check the native checkboxes and confirm the query stays in the field.
3. Add Beta again with its checkbox. Collapse Alpha, quit, and reopen the fixture. Confirm the saved scope contains exactly Alpha and Beta, Alpha stays collapsed, and Gamma's unsent draft is still active.
4. Choose **All Projects** (`project-filter-all`). Reopen the picker, search for `EMPTY`, and press Return. Confirm the picker closes and the sidebar offers **Show All Projects** (`sidebar-clear-project-scope`). Press it to restore the full scope.
5. Open the context menu on Beta's inactive thread. Choose **Filter by Beta**, then reopen the menu and choose **Show All Projects** (`thread-project-scope`). Confirm both actions keep Gamma's draft active.

Run `swift test --filter SidebarPersistenceTests` for the offscreen AppKit check that sends Shift-Return while the search field contains marked text.

### Verify GitHub reads

From the repository root, run the Swift verifier with the mock GitHub CLI. It creates a disposable repository and linked worktree. It checks PR and Issue reads, search, pagination, retry, and responses that arrive after a newer request.

```sh
mkdir -p .build
swiftc -module-cache-path .build/pr-test-cache \
    Sources/tncode/GitWorkspace.swift Sources/tncode/GitHubPullRequests.swift \
    Sources/tncode/GitHubPullRequestFiles.swift \
    Sources/tncode/GitHubBrowse.swift \
    scripts/verify-github-pull-requests.swift -o .build/verify-github-pull-requests
.build/verify-github-pull-requests "$PWD/scripts/fixtures/github-read"
```

With a signed-in GitHub CLI, `.build/verify-github-pull-requests --public-cli` checks real list, label-search, pagination, and detail responses for the public `cli/cli` repository. It uses a temporary local checkout.

For a packaged-app check, initialize a disposable checkout with fetch remote `git@github.com:fixture/workspace.git`. Launch the app binary with `scripts/fixtures/github-read` on the front of PATH. Pass the checkout with `--project` and a disposable app store with `--workspace`. Set `PI_GH_FIXTURE_STATE` to a file containing `initial`.

- Open `pull-requests` and switch tabs with `github-tab-pull-requests` or `github-tab-issues`. Each list uses the `pr-` or `issue-` prefix for `checkout`, `repository`, `search`, `search-submit`, `filter`, `refresh`, and `load-more`.
- Search for `label:bug`. The PR list shows `pr-row-42`, then adds `pr-row-44`. The Issue list shows `issue-row-71`, then adds `issue-row-73`. In the Issue list, select **Closed** to see `issue-row-70`. Search for `empty` with **Open** selected to exercise `list-empty` and `search-clear`.
- Select `pr-row-42` to inspect `pr-detail-title`, `pr-check-status-0`, `pr-open`, and `pr-check-open-0`. Select `issue-row-71` to inspect `issue-detail-title`, `issue-detail-state`, `issue-detail-author`, `issue-detail-labels`, `issue-detail-body`, and `issue-open`. The Swift verifier checks link destinations.
- Change the fixture state to `updated` and refresh to see a changed PR head and Issue description. Use `no-auth` or `network` with list refresh to exercise `list-error` and `list-retry`. Use `page-error` with **Load more** to exercise `page-error` and `page-retry`. Use `missing` with `issue-detail-refresh` to exercise `issue-detail-error` and `issue-detail-retry`. Restore `initial` before retrying. Close the browser with `pr-close`.
