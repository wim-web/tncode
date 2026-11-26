# Pi Workspace

Pi Workspace is a native macOS client for the local project and conversation workflow in [T3 Code](https://github.com/pingdotgg/t3code/blob/v0.1.12/docs/user/thread-sidebar.md). It uses the Pi SDK to run the agent and store conversation history.

## Build and open

Install Xcode with Swift 6.2 or later and Node.js 22.19 or newer with npm. From this directory, run:

```sh
./scripts/build-app.sh
open "dist/Pi Workspace.app"
```

The app bundles Node.js and Pi. The build uses the current Mac's architecture and ad-hoc signing.

## Start a conversation

1. From Welcome, open **Model Settings** to choose your provider, model ID and API key. For a local OpenAI-compatible model, enter its loopback base URL and context window. Select **Save**, then **Start**. You can also choose **Start without an agent** and configure a model later.
2. Select **Add Project → Local folder**. Enter a path or select **Browse**, then select **Add Project**. In the path field, use the arrow keys to highlight a folder and Tab to enter it. With several matches, Tab completes their shared prefix. The draft opens with its message field focused. **New project** creates a Git repository in the parent folder you choose.
3. Enter a message and select **Send**. Select **Stop** to cancel an active turn. On relaunch, the app reopens the selected conversation if it has unfinished text. Select a conversation in the sidebar to continue it.
4. Use **Search Threads** to find a thread by title, project name, or message text. Opening a message result takes you to that message. In **Thread filters**, check the projects to include or choose **All Projects**.
5. Use the thread context menu to rename, pin, settle, or archive a thread. Use **Show Archive** in the filter menu to reopen or restore an archived thread. Use the project menu above the thread to manage its folder.

If a project folder moves, use **Relink Folder** in its context menu to point the project at the new path and retain its conversations.

Choose **Start without a project** on the empty home screen to work in a private folder. The thread menu's **Turn into project** action registers that folder and keeps the conversation history.

Unsent composer text stays with its thread when you switch threads or quit. Right-click a draft in the sidebar to copy its working path or selected branch, open its project settings, or discard it. A worktree preparation failure saves the submitted prompt so you can retry after relaunch.

Pi can read files with models that support tools. Choose **Supervised** to approve or decline individual shell and edit requests. **Shell and edits** enables those tools for the project. They use the permissions of your macOS user.

The macOS app keeps API keys in Keychain. The workspace index and Pi conversation files live in `~/Library/Application Support/Pi Workspace`. **Model Settings** removes or replaces a saved key.

In a registered project, **Model Settings → Scope** lets you change that project's model or the workspace default. **Reset to Workspace default** restores inheritance and keeps the provider credential.

If the app cannot read its workspace index, the startup screen shows the affected folder and offers **Retry**. If a valid previous index exists, **Restore Previous Workspace** restores that project and thread list and keeps the damaged index and conversation files.

## Work in a Git checkout

1. In a draft, use the workspace control below the composer. Choose the project folder, an existing worktree, or a new worktree and its base branch.
2. Send the first message to create a new worktree. If preparation fails, correct the problem and select **Retry** in that thread. The app keeps the prompt and failed stage across relaunch.
3. Open **Changes** in the thread header. Select a file to read its unstaged or staged patch. Use the file's stage or unstage button to change the index.
4. Check the files to include, enter a commit message, and select **Commit**. Git commits their current contents. An excluded file keeps its working copy, and any staged changes in it become unstaged after the commit succeeds. The branch menu switches between existing local branches.
5. Open **Terminal** in the header to start an interactive shell in the thread's directory. Hide the drawer to keep the shell running. Use **Close** to end the session.

Open **Browser** in the thread header. Enter a URL, a host such as `localhost:5173`, or search terms, then press Return. **Pi Workspace → Browser Settings…** selects the search engine. A custom HTTP or HTTPS search URL uses `%s` for the query. Use **New Browser Tab** to choose the Default or Alternate profile. Tabs keep their own history and zoom. Tabs in the same thread and profile share temporary website data until you quit the app.

Choose **Open Mini Player** to keep the page over the conversation. Drag the arrow handle to move it or drag an edge to resize it. **Open in Browser Panel** returns the page to its tab. **Open in Floating Window** moves it to a separate macOS window.

Open **Pull Requests** in the header to inspect up to 50 pull requests for the selected checkout. Select a state and a PR to see its description, branches, and checks. Use **Refresh pull requests** to reload the list and selected PR. Open the PR or a check with its link.

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
```

The verifier writes its report under `dist/verification-*/logs`. It uses an isolated workspace and a disposable Keychain item. The worktree run also checks failure and retry, terminal lifetime, selected commits, and PR details from the mock GitHub CLI. To test real local model replies, run Ollama on port 18541 with `smollm2:135m` installed and omit `--fixture-model`.

### Verify pull request reads

From this directory, run the Swift verifier with the mock GitHub CLI. It creates a disposable repository and linked worktree.

```sh
mkdir -p .build
swiftc -module-cache-path .build/pr-test-cache \
    Sources/PiWorkspace/GitWorkspace.swift Sources/PiWorkspace/GitHubPullRequests.swift \
    scripts/verify-github-pull-requests.swift -o .build/verify-github-pull-requests
.build/verify-github-pull-requests "$PWD/scripts/fixtures/github-read"
```

For a packaged-app check, initialize a disposable checkout with fetch remote `git@github.com:fixture/workspace.git`. Launch the app binary with `scripts/fixtures/github-read` on the front of PATH. Pass the checkout with `--project` and a disposable app store with `--workspace`. Set `PI_GH_FIXTURE_STATE` to a file containing `initial`, then replace its contents with `updated` and press Refresh to exercise a changed head and check result.

The accessibility IDs for this flow are `pull-requests`, `pr-checkout`, `pr-repository`, `pr-filter`, `pr-refresh`, `pr-row-42`, `pr-detail-title`, `pr-check-status-0`, `pr-open`, `pr-check-open-0`, and `pr-close`. The Swift verifier checks the fixture link destinations without opening a browser.
