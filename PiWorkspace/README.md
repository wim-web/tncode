# Pi Workspace

Pi Workspace is a native macOS client for the local project and conversation workflow in [T3 Code](https://github.com/pingdotgg/t3code/blob/v0.1.12/docs/user/thread-sidebar.md). It uses the Pi SDK to run the agent and store conversation history.

## Build and open

Install Xcode with Swift 6.2 or later and Node.js 22.19 or newer with npm. From this directory, run:

```sh
./scripts/build-app.sh
open "dist/Pi Workspace.app"
```

The app bundles Node.js and Pi. The build uses the current Mac's architecture and ad-hoc signing.

To keep a build for comparison, pass its destination directory to `./scripts/build-app.sh`. Set `PI_WORKSPACE_VERIFY_APP` to the resulting `.app` path when running the UI verifier.

**Pi Workspace → About Pi Workspace** shows the bundled version, build, and runtime versions. Select **Open source licenses…** to search the notices included in that build.

## Start a conversation

1. From Welcome, open **Model Settings** to choose your provider, model ID and API key. For a local OpenAI-compatible model, enter its loopback base URL and context window. Select **Save**, then **Start**. You can also choose **Start without an agent** and configure a model later.
2. Select **Add Project → Local folder**. Enter a path or select **Browse**, then select **Add Project**. In the path field, use the arrow keys to highlight a folder and Tab to enter it. With several matches, Tab completes their shared prefix. The draft opens with its message field focused. **New project** creates a Git repository in the parent folder you choose.
3. Enter a message and select **Send**. Select **Stop** to cancel an active turn. On relaunch, the app reopens the selected conversation if it has unfinished text. Select a conversation in the sidebar to continue it.
4. Use **Search Threads** to find a thread by title, project name, or message text. Opening a message result takes you to that message. In **Thread filters**, check the projects to include or choose **All Projects**.
5. Use the thread context menu to rename, pin, settle, or archive a thread. Use **Show Archive** in the filter menu to reopen or restore an archived thread. Use the project menu above the thread to manage its folder.

To start from an existing Git repository, choose **Add Project → Git URL** and enter its URL. Choose an empty folder or a new path. **Clone** creates any missing parent folders and opens the checkout. Cloning into an empty folder already registered as a project keeps its conversations.

During a turn, choose **Queue** or press ⌘Return to send a follow-up after Pi finishes. **Steer** sends an instruction into the current run. A queued row’s menu lets you edit, reorder, or remove it. **Stop** and relaunch leave outstanding messages paused until you start a row or select **Resume Queue**.

Use **Attach Files** to add PNG, JPEG, or UTF-8 text files to a draft. You can also paste an image or drop files onto the composer or a thread in the sidebar. Select an image thumbnail to preview it. For a local model that accepts images, enable image input in **Model Settings**.

Pasting at least 32 KiB of UTF-8 text creates a text attachment when it fits. Press ⌘⇧V or choose **Edit → Paste and Match Style** to paste text inline. If a normal paste exceeds the 64 KiB text attachment limit, it stays inline when the resulting draft fits within 120,000 UTF-16 units.

With the composer focused, press ⌘S to stash its text and attachments. Select the stash count to restore an entry into the current draft or delete it. If the composer is empty and the stash has one entry, ⌘S restores it.

For a submitted conversation, right-click its sidebar row and choose **Copy → Thread**. **Edit → Open Thread Link from Clipboard** and macOS can open this link in the same local workspace. If you move the workspace itself, copy a new link.

Choose **Fork from this response** on a completed reply to start a separate conversation with the messages through that reply. **Open source conversation** and **Open fork** take you between the two histories.

Press ⌘K outside the terminal to open the command palette. Type to filter, use the arrow keys and Return to choose an action, or press Escape to return to the workspace. **New thread in…** lets you select a project.

Choose a hit under **In messages** to open the conversation at that message. Press ⌘F to search the current thread. Return and ⇧Return move between matching messages on its active Pi branch. Escape returns to the composer. Press ⌘⇧F to search the sidebar.

If a project folder moves, use **Relink Folder** in its context menu to point the project at the new path and retain its conversations.

Choose **Start without a project** on the empty home screen to work in a private folder. The thread menu's **Turn into project** action registers that folder and keeps the conversation history.

Unsent composer text stays with its thread when you switch threads or quit. If saving fails, the app keeps the draft open. Restore write access, then select **Retry Saving** or **Retry and Quit**. Right-click a draft in the sidebar to copy its working path or selected branch, open its project settings, or discard it.

Pi can read files with models that support tools. Choose **Supervised** to approve or decline individual shell and edit requests. **Shell and edits** enables those tools for the project. They use the permissions of your macOS user.

A local model with tools enabled can ask a question during its turn. Select the options or type an answer, use **Next** and **Previous** to review the pages, then select **Submit**. **Dismiss** sends the model a declined response. **Stop** ends the turn. A supervised write requested after an answer still needs its own approval.

The macOS app keeps API keys in Keychain. The workspace index and Pi conversation files live in `~/Library/Application Support/Pi Workspace`. **Model Settings** removes or replaces a saved key.

In a registered project, **Model Settings → Scope** lets you change that project's model or the workspace default. **Reset to Workspace default** restores inheritance and keeps the provider credential.

Open **Settings** from the sidebar or press ⌘, to search the available controls. For example, search for **Model ID** and press Return to edit the selected project's model, or search for **Open source licenses** to read the packaged notices.

**Settings → General → Add project starts in** sets the initial folder for adding or cloning a project. **Help → Show Welcome** or **Settings → About → Welcome page** reopens onboarding. Closing it returns to the selected draft.

**Settings → Usage** shows token counts and USD costs recorded in local Pi conversation histories. Select a period, filter by project or provider, and select a model to inspect input, output and cache tokens. **Refresh usage** includes newly recorded replies. A total marked **+ unreported** includes only messages with a recorded value.

Press ⌘U to open Usage from the workspace. With focus on the report, C selects Cost, T selects Tokens, and L selects Limits. Press ⌘U again to close it.

If the app cannot read its workspace index, the startup screen shows the affected folder and offers **Retry**. If a valid previous index exists, **Restore Previous Workspace** restores that project and thread list and keeps the damaged index and conversation files.

**Pi Workspace → Appearance Settings…** changes the color scheme and conversation width across projects. **Restore Defaults** returns to the system appearance and Comfortable width.

## Work in a Git checkout

1. In a draft, use the workspace control below the composer or press ⌘⇧X. Choose the project folder, an existing worktree, or a new worktree and its base branch. **Settings → Worktrees → Worktree location** sets the storage folder for new checkouts. An existing checkout or a checkout awaiting Retry keeps its saved path.
2. Send the first message to create a new worktree. If preparation fails, correct the problem and select **Retry** in that thread. The app keeps the prompt and failed stage across relaunch. Before Pi starts the turn, **Cancel** returns the text to the draft. **Work locally** sends it from the project folder.
3. Open **Changes** in the thread header. Select a file to read its unstaged or staged patch. Use the file's stage or unstage button to change the index.
4. Check the files to include, enter a commit message, and select **Commit**. Git commits their current contents. An excluded file keeps its working copy, and any staged changes in it become unstaged after the commit succeeds.
5. Open **Terminal** in the header to start an interactive shell in the thread's directory. Use **New Terminal** for another tab or split a tab horizontally or vertically. Press ⌘⇧[ or ⌘⇧] to move between panes. Drag the top edge to adjust the drawer height for that thread. Hiding the drawer keeps its height and shells. Confirm **Close Terminal** to end the selected shell.

Use the branch button or ⌘⇧G to search local and cached remote refs. **New Branch** creates a branch at the base you choose. Selecting a branch that already has a linked checkout moves the thread to that checkout.

For a new worktree, **Start from remote** defaults to on. On the first send, Pi Workspace fetches the selected branch's upstream, or the same branch on `origin`. If the remote has no such branch, the app uses the local ref. Turn the option off to start at the selected local or cached ref. **Settings → Worktrees** changes the default for future drafts.

Open **Files** to search or browse the selected checkout. Small text files save after a short pause in typing. **Save** writes immediately. A read-only file keeps pending edits until write access returns. If another program replaces or edits the file, copy your pending text or choose **Discard Edits** to reload the disk version.

In Markdown files, select **Show rendered markdown** to read headings and links, then **Show markdown source** to edit. CSV and TSV files open as tables. **Show source** opens the original text, including quoting and line breaks.

If a worktree moves while an edit is pending, select its new path in the draft's workspace menu. The editor reconnects the draft to the same checkout. **Folder Actions → Unsaved Files** also lets you copy or discard pending text from an old location.

Select an image to see its dimensions, change its zoom, or open the expanded preview. Select a PDF to page through it, fit its width, or search its text. **Retry** reloads a file after you replace a damaged copy.

For text files over 1 MiB, enter a line number in **Go to Line** or use **Next Page** and **Previous Page**. Each page holds up to 32 lines. Lines longer than 16 KiB show their first 16 KiB, up to a complete UTF-8 character.

Open **Browser** in the thread header. Enter a URL, a host such as `localhost:5173`, or search terms, then press Return. **Pi Workspace → Browser Settings…** selects the search engine. A custom HTTP or HTTPS search URL uses `%s` for the query. Use **New Browser Tab** to choose the Default or Alternate profile. Tabs keep their own history and zoom. Tabs in the same thread and profile share temporary website data until you quit the app.

Choose **Open Mini Player** to keep the page over the conversation. Drag the arrow handle to move it or drag an edge to resize it. **Open in Browser Panel** returns the page to its tab. **Open in Floating Window** moves it to a separate macOS window.

Open **Pull Requests** in the header and choose **Pull Requests** or **Issues** for the selected checkout. Search by text or a filter such as `label:bug`, choose a state, and use **Load more** for the next page. Choose a PR to read its description, branches, and checks, or an Issue to read its author, labels, and body.

In the PR list, **Author** and **Labels** let you search the repository's available choices. Choose **Anyone** or **Clear labels** to remove that filter while keeping the others.

In **Linked items**, choose **Link pull request** and enter a PR number or URL for the checkout's GitHub repository. The link stays with the selected thread across relaunch. Its menu can copy the URL or number, open GitHub, or unlink the PR from that thread.

For a failed GitHub Actions check, choose **View log** to read up to the last 200 lines and 96 KiB of the selected job. **Retry** fetches it again after access is restored.

Pull Requests uses the GitHub CLI (`gh`) on the app's PATH or in a standard Homebrew or MacPorts location. Sign in to GitHub CLI from Terminal before opening the list. The app uses the checkout's GitHub.com `origin` fetch remote or its sole GitHub.com fetch repository.

To open a specific folder when launching a new instance, run:

```sh
open -na "dist/Pi Workspace.app" --args --project "/path/to/project"
```

## Verify the app locally

Build the app first. Run the Swift tests, then use the packaged app with a loopback model fixture. The UI checks require macOS Accessibility and keyboard input permissions.

```sh
swift test -c release
swiftc -module-cache-path .build/ax-cache scripts/ax.swift -o .build/ax
node scripts/verify-app.mjs "$PWD/.build/ax" --fixture-model
node scripts/verify-app.mjs "$PWD/.build/ax" --fixture-model --worktree
node scripts/verify-app.mjs "$PWD/.build/ax" --usage-only
node scripts/verify-app.mjs "$PWD/.build/ax" --workspace-controls-only
node scripts/verify-app.mjs "$PWD/.build/ax" --conversation-controls-only
node scripts/verify-app.mjs "$PWD/.build/ax" --project-flows-only
node scripts/verify-native-paste.mjs "$PWD/.build/ax" "dist/Pi Workspace.app"
node scripts/verify-app.mjs "$PWD/.build/ax" --thread-actions-only
node scripts/verify-app.mjs "$PWD/.build/ax" --sidebar-and-checks-only
node scripts/verify-app.mjs "$PWD/.build/ax" --image-preview-only
node scripts/verify-app.mjs "$PWD/.build/ax" --new-thread-routes-only
node scripts/verify-app.mjs "$PWD/.build/ax" --startup-draft-only
node scripts/verify-app.mjs "$PWD/.build/ax" --recovery-actions-only
node scripts/verify-app.mjs "$PWD/.build/ax" --pr-files-only
node scripts/verify-app.mjs "$PWD/.build/ax" --right-terminal-only
node scripts/verify-app.mjs "$PWD/.build/ax" --model-account-only
node scripts/verify-app.mjs "$PWD/.build/ax" --side-chat-only
node scripts/verify-app.mjs "$PWD/.build/ax" --local-changes-only
node scripts/verify-stop-retry.mjs "dist/Pi Workspace.app" "$PWD/.build/ax"
node scripts/verify-app.mjs "$PWD/.build/ax" --snooze-only
node scripts/verify-app.mjs "$PWD/.build/ax" --project-settings-only
node scripts/verify-file-drops.mjs "$PWD/.build/ax" "dist/Pi Workspace.app"
node scripts/verify-attachments.mjs --release-suite "dist/Pi Workspace.app"
```

The app verifier writes its report under `dist/verification-*/logs`. The neighboring `fixture` link points to the test data in a temporary folder outside the source checkout. Model turns use a disposable Keychain item. The worktree run checks failure and retry, terminal lifetime, selected commits, and PR details from the mock GitHub CLI. The file-drop verifier moves the pointer across a disposable source window and the app. The release suite supplies loopback providers for both the attachment and question tests. To test real local model replies, run Ollama on port 18541 with `smollm2:135m` installed and omit `--fixture-model`.

On a shared Mac, set `PI_WORKSPACE_VERIFY_IDLE_SECONDS=180` to wait for three minutes of keyboard and pointer inactivity before each test launch. The verifier runs a private copy of the named build throughout that scenario.

The startup-draft, recovery-actions, PR-files, right-terminal, model-account, side-chat and local-changes scenarios use background Accessibility actions. They can run while another application has keyboard focus. The model-account check routes an existing conversation and a fresh draft after a project settings reset. The side-chat check holds the first parent turn, verifies the child's reply, and follows its attachment back into the parent after relaunch. The separate Stop-retry verifier holds the private app's own Pi worker long enough to observe the ten-second retry. Its watchdog releases that worker on controller exit or after 18 seconds.

`logs/artifact.json` records the verified bundle's code directory hash, the SHA-256 digests of its executable and Pi worker, the bundled Pi version and the verifier digest.

To test which network connections the packaged Pi helper attempts during startup, idle time, an explicit local turn, and shutdown, run `node scripts/verify-default-telemetry.mjs`. It checks the Node network and child-process APIs against a loopback receiver and applies a macOS process sandbox. Native app and WebKit traffic require separate observation.

### Verify GitHub reads

From this directory, run the Swift verifier with the mock GitHub CLI. It creates a disposable repository and linked worktree. It checks PR and Issue reads, search, pagination, retry, and responses that arrive after a newer request.

```sh
mkdir -p .build
swiftc -module-cache-path .build/pr-test-cache \
    Sources/PiWorkspace/GitWorkspace.swift Sources/PiWorkspace/GitHubPullRequests.swift \
    Sources/PiWorkspace/GitHubPullRequestFiles.swift \
    Sources/PiWorkspace/GitHubBrowse.swift \
    scripts/verify-github-pull-requests.swift -o .build/verify-github-pull-requests
.build/verify-github-pull-requests "$PWD/scripts/fixtures/github-read"
```

With a signed-in GitHub CLI, `.build/verify-github-pull-requests --public-cli` checks real list, label-search, pagination, and detail responses for the public `cli/cli` repository. It uses a temporary local checkout.

For a packaged-app check, initialize a disposable checkout with fetch remote `git@github.com:fixture/workspace.git`. Launch the app binary with `scripts/fixtures/github-read` on the front of PATH. Pass the checkout with `--project` and a disposable app store with `--workspace`. Set `PI_GH_FIXTURE_STATE` to a file containing `initial`.

- Open `pull-requests` and switch tabs with `github-tab-pull-requests` or `github-tab-issues`. Each list uses the `pr-` or `issue-` prefix for `checkout`, `repository`, `search`, `search-submit`, `filter`, `refresh`, and `load-more`.
- Search for `label:bug`. The PR list shows `pr-row-42`, then adds `pr-row-44`. The Issue list shows `issue-row-71`, then adds `issue-row-73`. In the Issue list, select **Closed** to see `issue-row-70`. Search for `empty` with **Open** selected to exercise `list-empty` and `search-clear`.
- Select `pr-row-42` to inspect `pr-detail-title`, `pr-check-status-0`, `pr-open`, and `pr-check-open-0`. Select `issue-row-71` to inspect `issue-detail-title`, `issue-detail-state`, `issue-detail-author`, `issue-detail-labels`, `issue-detail-body`, and `issue-open`. The Swift verifier checks link destinations.
- Change the fixture state to `updated` and refresh to see a changed PR head and Issue description. Use `no-auth` or `network` with list refresh to exercise `list-error` and `list-retry`. Use `page-error` with **Load more** to exercise `page-error` and `page-retry`. Use `missing` with `issue-detail-refresh` to exercise `issue-detail-error` and `issue-detail-retry`. Restore `initial` before retrying. Close the browser with `pr-close`.
