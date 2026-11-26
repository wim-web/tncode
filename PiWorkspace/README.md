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

1. Open **Model Settings**. Select a provider, enter its model ID and API key, and select **Save**. For a local OpenAI-compatible provider, enter a loopback base URL and the model's context window. Enable coding tools for local models that support them.
2. Select **Open Project**. Enter a folder path or select **Browse**, then select **Add Project**. The new project's draft opens with the message field focused.
3. Enter a message and select **Send**. Select **Stop** to cancel an active turn. On relaunch, the app opens a draft in the most recently active project. Select the previous conversation in the sidebar to continue it.
4. Search or filter threads in the sidebar. Select **Group by Project** in the filter menu to organize them into collapsible folders.
5. Use the thread context menu to rename, pin, settle, or archive a thread. Use **Show Archive** in the filter menu to reopen or restore an archived thread. Use the project menu above the thread to manage its folder.

If a project folder moves, use **Relink Folder** in its context menu to point the project at the new path and retain its conversations.

Pi can read project files with models that support tools. **Shell and edits** enables Pi's shell and write tools for that project. These tools use the permissions of your macOS user.

The macOS app keeps API keys in Keychain. The workspace index and Pi conversation files live in `~/Library/Application Support/Pi Workspace`. **Model Settings** removes or replaces a saved key.

## Work in a Git checkout

1. In a draft, use the workspace control below the composer. Choose the project folder, an existing worktree, or a new worktree and its base branch.
2. Send the first message to create a new worktree. If preparation fails, correct the problem and select **Retry** in that thread. The app keeps the prompt and failed stage across relaunch.
3. Open **Changes** in the thread header. Select a file to read its unstaged or staged patch. Use the file's stage or unstage button to change the index.
4. Check the files to include, enter a commit message, and select **Commit**. Git commits their current contents. An excluded file keeps its working copy, and any staged changes in it become unstaged after the commit succeeds. The branch menu switches between existing local branches.
5. Open **Terminal** in the header to start an interactive shell in the thread's directory. Hide the drawer to keep the shell running. Use **Close** to end the session.

To open a specific folder when launching a new instance, run:

```sh
open -na "dist/Pi Workspace.app" --args --project "/path/to/project"
```

## Verify the app locally

Run Ollama on loopback port 18541 with `smollm2:135m` installed. Build the accessibility driver and run the verifier with macOS Accessibility access.

```sh
swiftc -module-cache-path .build/ax-cache scripts/ax.swift -o .build/ax
node scripts/verify-app.mjs "$PWD/.build/ax"
node scripts/verify-app.mjs "$PWD/.build/ax" --worktree
```

Add `--fixture-model` to either verifier command to use fixed streaming replies on loopback without Ollama. The verifier opens the packaged app, uses a disposable Keychain item and an isolated workspace, and saves its report under `dist/verification-*/logs`. The worktree run also exercises the terminal, diff, staging, and committing in a disposable repository.
