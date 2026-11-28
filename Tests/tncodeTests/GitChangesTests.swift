import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import tncode

final class GitChangesTests: XCTestCase {
    func testGeneratedCommitRechecksTreeAndBranchAtTheRefUpdate() async throws {
        let fixture = try ChangesFixture()
        defer { fixture.remove() }
        let root = fixture.alpha
        let workspace = GitWorkspace(path: root.path)
        let paths: Set<String> = ["disk.txt"]
        let checkout = try await workspace.changesCheckout()
        let hooks = fixture.root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appendingPathComponent("pre-commit")
        _ = try fixture.git(root, "config", "core.hooksPath", hooks.path)
        _ = try fixture.git(root, "config", "user.name", "Fixture")
        _ = try fixture.git(root, "config", "user.email", "fixture@example.invalid")
        _ = try fixture.git(root, "config", "commit.gpgsign", "false")
        _ = try fixture.git(root, "branch", "other")
        let before = try fixture.index(root)
        for script in ["printf 'late edit\\n' > disk.txt\ngit add disk.txt", "git symbolic-ref HEAD refs/heads/other"] {
            try fixture.write("#!/bin/sh\n" + script + "\n", at: "pre-commit", in: hooks)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
            let context = try await workspace.commitContext(paths: paths, checkout: checkout.revision)
            do {
                try await workspace.commit(message: "Generated subject", paths: paths, generatedFrom: context)
                XCTFail("Git published a commit after the hook changed the selected tree or branch")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("selected changes"), error.localizedDescription)
            }
            XCTAssertEqual(try fixture.git(root, "rev-parse", "topic-alpha", "other"), String(repeating: fixture.alphaHead + "\n", count: 2))
            XCTAssertEqual(try fixture.index(root), before)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("disk.txt"), encoding: .utf8), "late edit\n")
        }
    }

    func testComparisonScopesReadOnlyInTwoLinkedCheckouts() async throws {
        let fixture = try ChangesFixture()
        defer { fixture.remove() }
        let alphaGit = GitWorkspace(path: fixture.alpha.path)
        let betaGit = GitWorkspace(path: fixture.beta.path)
        let alpha = try await alphaGit.changesCheckout()
        let beta = try await betaGit.changesCheckout()
        XCTAssertEqual(alpha.head, fixture.alphaHead)
        XCTAssertEqual(beta.head, fixture.betaHead)
        XCTAssertEqual(alpha.automaticRef, "refs/remotes/origin/main")
        XCTAssertEqual(beta.automaticRef, "refs/heads/beta-base")
        let indexSnapshots = try [fixture.alpha, fixture.beta].map(fixture.index)
        let statuses = try [fixture.alpha, fixture.beta].map { try fixture.git($0, "status", "--porcelain=v1") }

        let automatic = try await alphaGit.changesTarget(.changes, checkout: alpha, selectedBase: nil)
        let local = try await alphaGit.changesTarget(.changes, checkout: alpha, selectedBase: "refs/heads/integration")
        let remote = try await alphaGit.changesTarget(.changes, checkout: alpha, selectedBase: "refs/remotes/origin/integration")
        let uncommitted = try await alphaGit.changesTarget(.uncommitted, checkout: alpha, selectedBase: nil)

        let (automaticFiles, automaticPatch) = try await comparison(alphaGit, automatic)
        let (localFiles, localPatch) = try await comparison(alphaGit, local)
        let (_, remotePatch) = try await comparison(alphaGit, remote)
        let (dirtyFiles, dirtyPatch) = try await comparison(alphaGit, uncommitted)
        XCTAssertTrue(automaticFiles.contains { $0.path == "alpha-base.txt" })
        XCTAssertFalse(localFiles.contains { $0.path == "alpha-base.txt" })
        XCTAssertTrue(automaticPatch.contains("+alpha-base-marker"))
        XCTAssertTrue(automaticPatch.contains("+alpha-head-marker"))
        XCTAssertFalse(automaticPatch.contains("main-only.txt"))
        XCTAssertFalse(automaticPatch.contains("beta-"))
        XCTAssertFalse(localPatch.contains("alpha-base-marker"))
        XCTAssertTrue(remotePatch.contains("+alpha-base-marker"))
        XCTAssertFalse(dirtyPatch.contains("alpha-head-marker"))
        XCTAssertTrue(dirtyPatch.contains("-index-base\n+index-edited"))
        XCTAssertTrue(dirtyPatch.contains("-disk-base\n+disk-edited"))
        XCTAssertTrue(dirtyPatch.contains("+untracked-alpha-marker"))
        XCTAssertTrue(dirtyPatch.contains("Binary files a/image.bin and b/image.bin differ"))
        XCTAssertTrue(dirtyPatch.contains("new file mode 100644"))
        let rename = try XCTUnwrap(dirtyFiles.first { $0.path == "new name.txt" })
        XCTAssertEqual(rename.status, "R")
        XCTAssertEqual(rename.previousPath, "old name.txt")
        let renamedPatch = try await alphaGit.changesPatch(in: uncommitted, file: rename, files: dirtyFiles)
        XCTAssertTrue(renamedPatch.contains("rename from old name.txt\nrename to new name.txt"))
        XCTAssertFalse(renamedPatch.contains("disk-edited"))
        let empty = try XCTUnwrap(dirtyFiles.first { $0.path == "empty[1].txt" })
        XCTAssertEqual(empty.status, "?")
        let emptyPatch = try await alphaGit.changesPatch(in: uncommitted, file: empty, files: dirtyFiles)
        XCTAssertTrue(emptyPatch.contains("new file mode 100644"))
        XCTAssertFalse(emptyPatch.contains("@@"))

        let status = try await alphaGit.state()
        XCTAssertEqual(status.files.first { $0.path == "index.txt" }?.indexStatus, "M")
        XCTAssertEqual(status.files.first { $0.path == "disk.txt" }?.worktreeStatus, "M")
        let staged = try await alphaGit.patch(for: nil, staged: true)
        let unstaged = try await alphaGit.patch(for: nil, staged: false)
        XCTAssertTrue(staged.contains("+index-edited"))
        XCTAssertFalse(staged.contains("+disk-edited"))
        XCTAssertTrue(unstaged.contains("+disk-edited"))
        XCTAssertFalse(unstaged.contains("+index-edited"))

        let history = try await alphaGit.changesCommits(alpha, selectedBase: nil)
        XCTAssertEqual(history.map(\.id), [fixture.alphaHead, fixture.alphaBase])
        let narrowerHistory = try await alphaGit.changesCommits(alpha, selectedBase: "refs/heads/integration")
        XCTAssertEqual(narrowerHistory.map(\.id), [fixture.alphaHead])
        let expected = [("alpha-head-marker", "alpha-base-marker"), ("alpha-base-marker", "alpha-head-marker")]
        for (commit, (marker, excluded)) in zip(history, expected) {
            let target = try await alphaGit.changesTarget(.commit(commit), checkout: alpha, selectedBase: nil)
            let (_, patch) = try await comparison(alphaGit, target)
            XCTAssertEqual(target.after, commit.id)
            XCTAssertTrue(patch.contains("+\(marker)"))
            XCTAssertFalse(patch.contains(excluded))
            XCTAssertFalse(patch.contains("disk-edited"))
        }

        let betaTarget = try await betaGit.changesTarget(.changes, checkout: beta, selectedBase: nil)
        let (betaFiles, betaPatch) = try await comparison(betaGit, betaTarget)
        XCTAssertEqual(Set(betaFiles.map(\.path)), ["beta-head.txt", "beta-dirty.txt"])
        XCTAssertTrue(betaPatch.contains("+beta-head-marker"))
        XCTAssertTrue(betaPatch.contains("+beta-dirty-marker"))
        XCTAssertFalse(betaPatch.contains("alpha-"))
        let betaHistory = try await betaGit.changesCommits(beta, selectedBase: nil)
        XCTAssertEqual(betaHistory.map(\.id), [fixture.betaHead])
        XCTAssertEqual(try [fixture.alpha, fixture.beta].map(fixture.index), indexSnapshots)
        XCTAssertEqual(try [fixture.alpha, fixture.beta].map { try fixture.git($0, "status", "--porcelain=v1") }, statuses)
        print("Real patches: +alpha-base-marker, +alpha-head-marker, +index-edited, +disk-edited, +untracked-alpha-marker, +beta-head-marker, +beta-dirty-marker")
        print("Binary marker, rename header, empty-file creation, and unchanged linked indexes verified")
    }

    func testUnavailableHistoryEmptyTreeAndMovedRefs() async throws {
        let fixture = try ChangesFixture()
        defer { fixture.remove() }
        let git = GitWorkspace(path: fixture.alpha.path)
        let checkout = try await git.changesCheckout()
        let target = try await git.changesTarget(.changes, checkout: checkout, selectedBase: "refs/heads/integration")
        _ = try fixture.git(fixture.repo, "update-ref", "refs/heads/integration", fixture.rootCommit)
        do {
            _ = try await git.changedFiles(in: target)
            XCTFail("A ref that moved during a review must invalidate the review")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("comparison branch changed"))
        }
        _ = try fixture.git(fixture.repo, "update-ref", "-d", "refs/heads/integration")
        do {
            _ = try await git.changesTarget(.changes, checkout: checkout, selectedBase: "refs/heads/integration")
            XCTFail("A missing explicit branch must be reported")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unavailable locally"))
        }
        let uncommitted = try await git.changesTarget(.uncommitted, checkout: checkout, selectedBase: nil)
        _ = try fixture.git(fixture.alpha, "update-ref", "HEAD", fixture.alphaBase)
        do {
            _ = try await git.changesPatch(in: uncommitted, file: nil, files: [])
            XCTFail("A review of a previous head must not publish a patch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checkout or comparison branch changed"))
        }

        let shallow = fixture.root.appendingPathComponent("shallow")
        _ = try fixture.git(fixture.root, "clone", "-q", "--depth=1", "--branch=topic-beta",
                            fixture.repo.absoluteString, shallow.path)
        _ = try fixture.git(shallow, "fetch", "-q", "--depth=1", fixture.repo.absoluteString,
                            "refs/heads/main:refs/remotes/origin/main")
        let shallowGit = GitWorkspace(path: shallow.path)
        let shallowCheckout = try await shallowGit.changesCheckout()
        do {
            _ = try await shallowGit.changesTarget(.changes, checkout: shallowCheckout, selectedBase: "refs/remotes/origin/main")
            XCTFail("Shallow history has no comparison merge base")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("shallow history"))
        }
        let shallowHistory = try await shallowGit.changesCommits(shallowCheckout, selectedBase: nil)
        let shallowCommit = try XCTUnwrap(shallowHistory.first)
        do {
            _ = try await shallowGit.changesTarget(.commit(shallowCommit), checkout: shallowCheckout, selectedBase: nil)
            XCTFail("A shallow boundary is not a root commit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("first parent is unavailable"))
        }

        let unborn = fixture.root.appendingPathComponent("unborn")
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: false)
        _ = try fixture.git(unborn, "init", "-q", "-b", "main")
        let unbornGit = GitWorkspace(path: unborn.path)
        let emptyCheckout = try await unbornGit.changesCheckout()
        XCTAssertNil(emptyCheckout.repository)
        let emptyTarget = try await unbornGit.changesTarget(.changes, checkout: emptyCheckout, selectedBase: nil)
        let (emptyFiles, emptyPatch) = try await comparison(unbornGit, emptyTarget)
        XCTAssertTrue(emptyFiles.isEmpty)
        XCTAssertTrue(emptyPatch.isEmpty)
        try fixture.write("first-marker\n", at: "first.txt", in: unborn)
        _ = try fixture.git(unborn, "add", "first.txt")
        let (_, initialPatch) = try await comparison(unbornGit, emptyTarget)
        XCTAssertTrue(initialPatch.contains("+first-marker"))
        _ = try fixture.git(unborn, "commit", "-qm", "First")
        let firstCheckout = try await unbornGit.changesCheckout()
        let firstHistory = try await unbornGit.changesCommits(firstCheckout, selectedBase: nil)
        let initialCommit = try XCTUnwrap(firstHistory.first)
        let initialTarget = try await unbornGit.changesTarget(.commit(initialCommit), checkout: firstCheckout, selectedBase: nil)
        let (_, rootPatch) = try await comparison(unbornGit, initialTarget)
        XCTAssertTrue(rootPatch.contains("+first-marker"))
    }

    func testWhitespaceFilteringUsesGitHunksInBothLinkedWorktrees() async throws {
        let fixture = try ChangesFixture()
        defer { fixture.remove() }
        let clean = "indentation\nlet spacing = \"a b\"\nlet content = \"old text\"\n"
        for (root, marker) in [(fixture.alpha, "alpha"), (fixture.beta, "beta")] {
            try fixture.write(clean, at: "formatting.txt", in: root)
            _ = try fixture.git(root, "add", "formatting.txt")
            _ = try fixture.git(root, "commit", "-qm", "Formatting baseline", "--", "formatting.txt")
            _ = try fixture.git(root, "branch", "formatting-base-" + marker)
            try fixture.write("  indentation\nlet spacing = \"ab\"\nlet content = \"\(marker) commit  text\"\n",
                              at: "formatting.txt", in: root)
            _ = try fixture.git(root, "commit", "-qm", "Mixed edit", "--", "formatting.txt")
            try fixture.write("\tindentation\nlet spacing = \"a  b\"\nlet content = \"\(marker) index  text\"\n",
                              at: "formatting.txt", in: root)
            _ = try fixture.git(root, "add", "formatting.txt")
            try fixture.write("indentation\nlet spacing = \"ab \"\nlet content = \"\(marker) disk  text\"\n",
                              at: "formatting.txt", in: root)
            try fixture.write(" \t\n", at: "new-blank.txt", in: root)
        }
        let indexes = try [fixture.alpha, fixture.beta].map(fixture.index)
        for (root, marker) in [(fixture.alpha, "alpha"), (fixture.beta, "beta")] {
            let git = GitWorkspace(path: root.path)
            let checkout = try await git.changesCheckout()
            let commit = GitChangesCommit(id: try XCTUnwrap(checkout.head), subject: "Mixed edit")
            let file = try await git.state().files.first { $0.path == "formatting.txt" }
            for (scope, base, expected) in [
                (GitChangesScope.changes, "refs/heads/formatting-base-" + marker, "disk"),
                (.uncommitted, nil, "disk"),
                (.commit(commit), nil, "commit")
            ] {
                let target = try await git.changesTarget(scope, checkout: checkout, selectedBase: base)
                let files = try await git.changedFiles(in: target)
                let selected = try XCTUnwrap(files.first { $0.path == "formatting.txt" })
                let visible = try await git.changesPatch(in: target, file: selected, files: files)
                let hidden = try await git.changesPatch(in: target, file: selected, files: files, ignoringWhitespace: true)
                XCTAssertTrue(visible.contains("-let spacing = "))
                XCTAssertFalse(hidden.contains("-let spacing = "), hidden)
                XCTAssertFalse(hidden.contains("+let spacing = "), hidden)
                XCTAssertTrue(hidden.contains("+++ b/formatting.txt\n@@ -1,3 +1,3 @@\n"), hidden)
                XCTAssertTrue(hidden.contains("+let content = \"\(marker) \(expected)  text\""), hidden)
                if scope == .uncommitted {
                    let untracked = try XCTUnwrap(files.first { $0.path == "new-blank.txt" })
                    let patch = try await git.changesPatch(in: target, file: untracked, files: files, ignoringWhitespace: true)
                    XCTAssertTrue(patch.contains("+++ b/./new-blank.txt\n@@ -0,0 +1 @@\n+ \t\n"), patch)
                }
            }
            for (staged, expected) in [(true, "index"), (false, "disk")] {
                let patch = try await git.patch(for: try XCTUnwrap(file), staged: staged, ignoringWhitespace: true)
                XCTAssertTrue(patch.contains("+let content = \"\(marker) \(expected)  text\""), patch)
                XCTAssertFalse(patch.contains("+let spacing = "), patch)
                XCTAssertFalse(patch.contains("-let spacing = "), patch)
            }
        }
        XCTAssertEqual(try [fixture.alpha, fixture.beta].map(fixture.index), indexes)
    }

    @MainActor
    func testOffscreenChangesDisplayPreferencesAndOwnership() async throws {
        try requireTestDesktop()
        let fixture = try ChangesFixture()
        defer { fixture.remove() }
        let longLine = "+long-line-" + String(repeating: "unbroken", count: 20) + "-end"
        try fixture.write(String(longLine.dropFirst()) + "\n", at: "untracked.txt", in: fixture.alpha)
        try fixture.write("disk-base  \n", at: "disk.txt", in: fixture.alpha)
        try fixture.write("disk-base\t\n", at: "disk.txt", in: fixture.beta)
        let indexes = try [fixture.alpha, fixture.beta].map(fixture.index)
        let alpha = Conversation(id: UUID(), title: "Alpha", location: .worktree(path: fixture.alpha.path, base: nil), isDraft: false)
        let beta = Conversation(id: UUID(), title: "Beta", location: .worktree(path: fixture.beta.path, base: nil), isDraft: false)
        let project = Project(id: UUID(), path: fixture.repo.path, title: "Display Fixture",
                              conversations: [alpha, beta], selectedConversation: alpha.id)
        let state = fixture.root.appendingPathComponent("workspace")
        try WorkspaceStore(root: state).save(Workspace(projects: [project], selectedProject: project.id,
                                                      model: ModelSettings(), welcomeCompleted: true))
        let model = WorkspaceModel(root: state, keychainService: UUID().uuidString, credentialExists: { _ in false },
                                   readCredential: { _ in nil },
                                   makeProcess: { _, _ in throw WorkspaceError("Display fixture has no agent.") })
        defer { model.shutdown() }
        let ui = try ChangesReplay(model)
        defer { ui.close() }

        try await ui.openChanges()
        try await ui.waitForText("git-review-word-wrap", containing: "Disable diff line wrapping")
        try await ui.waitForText("git-review-whitespace", containing: "Show whitespace changes")
        try await ui.press("git-review-file-untracked-untracked.txt")
        try await ui.waitForPatch(longLine)
        let wrapped = try XCTUnwrap(ui.patchLineFrame(longLine))
        let appearanceLink = try XCTUnwrap(SettingsDeepLink(url: URL(string: "tncode://settings/appearance#word-wrap")!))
        let settingsRequest = SettingsRequest(page: appearanceLink.page, anchor: appearanceLink.anchor, projectID: nil)
        let settings = try ChangesReplay(model, settingsRequest: settingsRequest, sharedDefaults: ui.defaults)
        defer { settings.close() }
        try await settings.pressSwitch("word-wrap")
        try await ui.waitForText("git-review-word-wrap", containing: "Enable diff line wrapping")
        try await ui.wait("unwrapped by the Appearance setting") {
            (ui.patchLineFrame(longLine)?.height ?? .infinity) < wrapped.height
        }
        try await settings.press("reset-word-wrap")
        try await ui.wait("wrapped by the restored Appearance setting") { ui.patchLineFrame(longLine)?.height == wrapped.height }
        try await ui.press("git-review-word-wrap")
        try await ui.wait("single rendered row") { (ui.patchLineFrame(longLine)?.height ?? .infinity) < wrapped.height }
        let unwrapped = try XCTUnwrap(ui.patchLineFrame(longLine))
        XCTAssertGreaterThan(wrapped.height, unwrapped.height * 2)
        try await ui.press("git-review-word-wrap")
        try await ui.wait("wrapped rendered row") { ui.patchLineFrame(longLine)?.height == wrapped.height }

        try await ui.press("git-review-scope")
        try await ui.press("git-review-scope-uncommitted")
        try await ui.press("git-file-disk.txt")
        try await ui.waitForText("git-review-empty", containing: "No changes to display")
        let diffLink = try XCTUnwrap(SettingsDeepLink(url: URL(string: "tncode://settings/diffs#hide-whitespace-changes")!))
        settingsRequest.navigate(to: diffLink.page, anchor: diffLink.anchor, projectID: nil)
        try await settings.pressSwitch("hide-whitespace-changes")
        try await ui.waitForPatch("+disk-base  ")
        try await settings.press("reset-hide-whitespace-changes")
        try await ui.waitForText("git-review-empty", containing: "No changes to display")
        try await ui.press("git-include-disk.txt")
        try await ui.waitForText("git-selection-count", containing: "5 of 6 selected")
        let location = try XCTUnwrap(WorkspaceFilesLocation(thread: alpha, project: project))
        let draft = model.fileSaves.acquire(WorkspaceFileTarget(location: location, path: "index.txt"))
        defer { draft.discard(); model.fileSaves.release(draft) }
        await draft.refresh()
        draft.edit("keep this unsaved edit\n", from: try XCTUnwrap(draft.editorSource))
        try fixture.write("index-edited\nexternal edit\n", at: "index.txt", in: fixture.alpha)
        try await ui.press("git-review-whitespace")
        try await ui.waitForPatch("+disk-base  ")
        XCTAssertTrue(ui.defaults.bool(forKey: DiffPreferences.ignoreWhitespace))
        try await ui.waitForText("git-selection-count", containing: "5 of 6 selected")
        try await ui.press("git-review-whitespace")
        try await ui.waitForText("git-review-empty", containing: "No changes to display")

        try await ui.press("git-review-word-wrap")
        try await ui.press("git-review-whitespace")
        try await ui.press("git-refresh")
        try await ui.press("thread-row-" + beta.id.uuidString)
        try await ui.openChanges()
        try await ui.waitForText("git-review-head", containing: "topic-beta")
        try await ui.waitForText("git-review-word-wrap", containing: "Disable diff line wrapping")
        try await ui.waitForText("git-review-whitespace", containing: "Hide whitespace changes")
        try await ui.press("git-review-file-disk.txt")
        try await ui.waitForPatch("+disk-base\t")
        XCTAssertFalse(ui.text().contains(longLine))
        try await ui.press("git-review-whitespace")
        try await ui.waitForText("git-review-empty", containing: "No changes to display")
        XCTAssertNil(ui.element("git-review-file-disk.txt"))
        XCTAssertEqual(draft.draft?.text, "keep this unsaved edit\n")
        XCTAssertEqual(try String(contentsOf: fixture.alpha.appendingPathComponent("index.txt"), encoding: .utf8),
                       "index-edited\nexternal edit\n")
        XCTAssertEqual(try [fixture.alpha, fixture.beta].map(fixture.index), indexes)
        print("Offscreen Changes row height was \(unwrapped.height) pt unwrapped and \(wrapped.height) pt wrapped.")
    }

    @MainActor
    func testNativeChangesComparisonReplay() async throws {
        try requireTestDesktop()
        let fixture = try ChangesFixture()
        defer { fixture.remove() }
        _ = try fixture.git(fixture.repo, "config", "extensions.worktreeConfig", "true")
        _ = try fixture.git(fixture.alpha, "config", "--worktree",
                            "url.git@github.com:Alpha/Changes.git.insteadOf", fixture.repo.path)
        let beforeRefs = try fixture.git(fixture.repo, "show-ref")
        let beforeIndexes = try [fixture.alpha, fixture.beta].map(fixture.index)
        let alpha = Conversation(id: UUID(), title: "Alpha", location: .worktree(path: fixture.alpha.path, base: nil), isDraft: false)
        let beta = Conversation(id: UUID(), title: "Beta", location: .worktree(path: fixture.beta.path, base: nil), isDraft: false)
        let project = Project(id: UUID(), path: fixture.repo.path, title: "Comparison Fixture",
                              conversations: [alpha, beta], selectedConversation: alpha.id)
        let appState = fixture.root.appendingPathComponent("workspace")
        try WorkspaceStore(root: appState).save(Workspace(projects: [project], selectedProject: project.id,
                                                          model: ModelSettings(), welcomeCompleted: true))
        let model = WorkspaceModel(root: appState, keychainService: UUID().uuidString, credentialExists: { _ in false },
                                   readCredential: { _ in nil },
                                   makeProcess: { _, _ in throw WorkspaceError("Comparison fixture has no agent.") })
        defer { model.shutdown() }
        var opened: [String] = []
        let ui = try ChangesReplay(model, openURL: OpenURLAction { url in
            opened.append(url.absoluteString)
            return .handled
        })
        defer { ui.close() }

        try await ui.wait("workspace header") { ui.element("toggle-right-panel") != nil }
        try ui.pressChangesShortcut()
        try await ui.waitForText("git-review-base", containing: "Automatic (origin/main)")
        try ui.pressChangesShortcut(modifiers: [.command, .shift])
        try ui.pressChangesShortcut(isRepeat: true)
        try ui.assertTerminalOwnsChangesShortcut()
        XCTAssertNotNil(ui.element("git-review-scope"))
        try ui.pressChangesShortcut()
        try await ui.wait("Changes closes with ⌘D") { ui.element("git-review-scope") == nil }
        try ui.assertComposerCompositionOwnsChangesShortcut()
        try await ui.openChanges()
        try await ui.waitForText("git-review-base", containing: "Automatic (origin/main)")
        try await ui.press("git-review-file-alpha-base.txt")
        try await ui.waitForPatch("+alpha-base-marker")
        try await ui.press("git-review-base")
        try await ui.press("git-review-base-refs/heads/integration")
        try await ui.waitForPatch("+alpha-head-marker")
        XCTAssertNil(ui.element("git-review-file-alpha-base.txt"))
        XCTAssertEqual(ui.element("git-commit-message")?.accessibilityRole?(), .textField)

        let remoteSwitch = "git-review-base-remote-refs/heads/integration"
        try await ui.press("git-review-base")
        try await ui.press(remoteSwitch)
        try await ui.waitForText("git-review-base", containing: "origin/integration (Remote)")
        try await ui.press("git-review-file-alpha-base.txt")
        try await ui.waitForPatch("+alpha-base-marker")
        try await ui.press(remoteSwitch)
        try await ui.waitForText("git-review-base", containing: "Currently integration")
        try await ui.waitForPatch("+alpha-head-marker")
        XCTAssertFalse(ui.text().contains("+alpha-base-marker"))
        // Change the selected ref twice without waiting for either diff to arrive.
        try await ui.press(remoteSwitch)
        try await ui.waitForText("git-review-base", containing: "origin/integration (Remote)")
        try await ui.press(remoteSwitch)
        try await ui.waitForPatch("+alpha-head-marker")
        XCTAssertNil(ui.element("git-review-file-alpha-base.txt"))
        XCTAssertFalse(ui.text().contains("+alpha-base-marker"))
        try await ui.press("git-review-base-automatic")
        try await ui.press("git-review-file-alpha-base.txt")
        try await ui.waitForPatch("+alpha-base-marker")

        try await ui.press("git-review-scope")
        try await ui.press("git-review-scope-uncommitted")
        try await ui.waitForPatch("+disk-edited")
        XCTAssertFalse(ui.text().contains("+alpha-head-marker"))
        let location = try XCTUnwrap(WorkspaceFilesLocation(thread: alpha, project: project))
        let draft = model.fileSaves.acquire(WorkspaceFileTarget(location: location, path: "disk.txt"))
        defer { draft.discard(); model.fileSaves.release(draft) }
        await draft.refresh()
        draft.edit("unsaved editor marker\n", from: try XCTUnwrap(draft.editorSource))
        try fixture.write("disk-edited\nexternal edit\n", at: "disk.txt", in: fixture.alpha)

        try await ui.press("git-file-index.txt")
        try await ui.waitForPatch("+index-edited")
        XCTAssertFalse(ui.text().contains("+disk-edited"))
        try await ui.press("git-file-untracked.txt")
        try await ui.waitForPatch("+untracked-alpha-marker")
        try fixture.write("refreshed-alpha-marker\n", at: "untracked.txt", in: fixture.alpha)
        try await ui.press("git-refresh")
        try await ui.waitForPatch("+refreshed-alpha-marker")

        try await ui.press("git-review-scope")
        let alphaBaseURL = "https://github.com/alpha/changes/commit/" + fixture.alphaBase
        try await ui.press("git-review-open-commit-" + fixture.alphaBase)
        try await ui.wait("commit picker opens the full base SHA") { opened == [alphaBaseURL] }
        try await ui.waitForText("git-review-scope", containing: "Uncommitted")
        try await ui.press("git-review-commit-" + fixture.alphaBase)
        try await ui.waitForText("git-review-scope", containing: String(fixture.alphaBase.prefix(7)))
        try await ui.waitForPatch("+alpha-base-marker")
        XCTAssertFalse(ui.text().contains("+disk-edited"))
        try await ui.press("git-review-scope")
        try await ui.press("git-review-commit-" + fixture.alphaHead)
        try await ui.waitForText("git-review-scope", containing: String(fixture.alphaHead.prefix(7)))
        try await ui.waitForPatch("+alpha-head-marker")
        XCTAssertFalse(ui.text().contains("+alpha-base-marker"))
        let alphaHeadURL = "https://github.com/alpha/changes/commit/" + fixture.alphaHead
        try await ui.press("git-review-open-selected-commit")
        try await ui.wait("selected commit opens the full head SHA") { opened == [alphaBaseURL, alphaHeadURL] }
        try await ui.press("git-review-scope")
        try await ui.press("git-review-scope-changes")
        try await ui.press("git-refresh")
        try await ui.press("thread-row-" + beta.id.uuidString)
        try await ui.openChanges()
        try await ui.waitForText("git-review-head", containing: "topic-beta")
        try await ui.waitForText("git-review-base", containing: "Automatic (beta-base)")
        try await ui.press("git-review-file-beta-head.txt")
        try await ui.waitForPatch("+beta-head-marker")
        XCTAssertFalse(ui.text().contains("+alpha-head-marker"))
        XCTAssertNil(ui.element("git-review-file-alpha-base.txt"))

        try await ui.press("git-review-scope")
        try await ui.waitForText("git-review-commit-" + fixture.betaHead, containing: "Beta topic")
        XCTAssertNil(ui.element("git-review-open-commit-" + fixture.betaHead))
        try await ui.press("git-review-commit-" + fixture.betaHead)
        try await ui.waitForPatch("+beta-head-marker")
        XCTAssertNil(ui.element("git-review-open-selected-commit"))
        XCTAssertEqual(opened, [alphaBaseURL, alphaHeadURL])
        XCTAssertEqual(try fixture.git(fixture.repo, "show-ref"), beforeRefs)
        XCTAssertEqual(try [fixture.alpha, fixture.beta].map(fixture.index), beforeIndexes)
        XCTAssertEqual(draft.draft?.text, "unsaved editor marker\n")
        XCTAssertEqual(try String(contentsOf: fixture.alpha.appendingPathComponent("disk.txt"), encoding: .utf8),
                       "disk-edited\nexternal edit\n")
        print("AX replay verified ⌘D with terminal and IME focus, local/cached origin integration, two full-SHA GitHub URLs, and linked topic-beta with a local-path remote.")
    }

    private func comparison(_ git: GitWorkspace, _ target: GitChangesTarget) async throws -> ([GitChangesFile], String) {
        let files = try await git.changedFiles(in: target)
        return (files, try await git.changesPatch(in: target, file: nil, files: files))
    }
}

private struct ChangesFixture {
    let root: URL
    let repo: URL
    let alpha: URL
    let beta: URL
    let rootCommit: String
    let alphaBase: String
    let alphaHead: String
    let betaHead: String

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("git-changes-\(UUID())")
        repo = root.appendingPathComponent("repository")
        alpha = root.appendingPathComponent("linked alpha")
        beta = root.appendingPathComponent("linked beta")
        do {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try Self.git(repo, "init", "-q", "-b", "main")
            for (path, content) in [("disk.txt", "disk-base\n"), ("index.txt", "index-base\n"),
                                    ("old name.txt", "rename-base\n"), (".gitignore", "ignored.txt\n")] {
                try content.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
            try Data([0, 1, 2]).write(to: repo.appendingPathComponent("image.bin"))
            _ = try Self.git(repo, "add", "--all")
            _ = try Self.git(repo, "commit", "-qm", "Root")
            rootCommit = try Self.git(repo, "rev-parse", "HEAD").trimmingCharacters(in: .newlines)
            _ = try Self.git(repo, "worktree", "add", "-qb", "topic-alpha", alpha.path)
            _ = try Self.git(repo, "worktree", "add", "-qb", "topic-beta", beta.path)
            _ = try Self.git(repo, "branch", "beta-base")
            _ = try Self.git(repo, "config", "branch.topic-beta.t3-merge-base-ref", "refs/heads/beta-base")

            try "alpha-base-marker\n".write(to: alpha.appendingPathComponent("alpha-base.txt"), atomically: true, encoding: .utf8)
            _ = try Self.git(alpha, "add", "alpha-base.txt")
            _ = try Self.git(alpha, "commit", "-qm", "Alpha integration")
            alphaBase = try Self.git(alpha, "rev-parse", "HEAD").trimmingCharacters(in: .newlines)
            _ = try Self.git(alpha, "branch", "integration")
            try "alpha-head-marker\n".write(to: alpha.appendingPathComponent("alpha-head.txt"), atomically: true, encoding: .utf8)
            _ = try Self.git(alpha, "add", "alpha-head.txt")
            _ = try Self.git(alpha, "commit", "-qm", "Alpha topic")
            alphaHead = try Self.git(alpha, "rev-parse", "HEAD").trimmingCharacters(in: .newlines)
            try "beta-head-marker\n".write(to: beta.appendingPathComponent("beta-head.txt"), atomically: true, encoding: .utf8)
            _ = try Self.git(beta, "add", "beta-head.txt")
            _ = try Self.git(beta, "commit", "-qm", "Beta topic")
            betaHead = try Self.git(beta, "rev-parse", "HEAD").trimmingCharacters(in: .newlines)
            try "main-only-marker\n".write(to: repo.appendingPathComponent("main-only.txt"), atomically: true, encoding: .utf8)
            _ = try Self.git(repo, "add", "main-only.txt")
            _ = try Self.git(repo, "commit", "-qm", "Main advances")
            _ = try Self.git(repo, "remote", "add", "origin", repo.path)
            _ = try Self.git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
            _ = try Self.git(repo, "update-ref", "refs/remotes/origin/integration", rootCommit)
            _ = try Self.git(repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")

            try write("index-edited\n", at: "index.txt", in: alpha)
            _ = try git(alpha, "add", "index.txt")
            _ = try git(alpha, "mv", "old name.txt", "new name.txt")
            try Data([0, 1, 3]).write(to: alpha.appendingPathComponent("image.bin"))
            try write("disk-edited\n", at: "disk.txt", in: alpha)
            try write("untracked-alpha-marker\n", at: "untracked.txt", in: alpha)
            try write("", at: "empty[1].txt", in: alpha)
            try write("should stay ignored\n", at: "ignored.txt", in: alpha)
            try write("beta-dirty-marker\n", at: "beta-dirty.txt", in: beta)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func write(_ value: String, at path: String, in directory: URL) throws {
        try value.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func index(_ directory: URL) throws -> Data {
        let path = try git(directory, "rev-parse", "--path-format=absolute", "--git-path", "index")
        return try Data(contentsOf: URL(fileURLWithPath: path.trimmingCharacters(in: .newlines)))
    }

    func git(_ directory: URL, _ args: String...) throws -> String { try Self.runGit(directory, args) }
    private static func git(_ directory: URL, _ args: String...) throws -> String { try runGit(directory, args) }

    private static func runGit(_ directory: URL, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=Changes Fixture", "-c", "user.email=fixture@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_ALLOW_PROTOCOL"] = "file"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorkspaceError("Fixture git \(args) failed.") }
        return String(decoding: output, as: UTF8.self)
    }
}

@MainActor
private final class ChangesReplay {
    private let app = NSApplication.shared
    private let policy: NSApplication.ActivationPolicy
    private let window: NSPanel
    private let host: NSHostingView<AnyView>
    private let pasteboard = NSPasteboard.withUniqueName()
    private let suite = "dev.tncode.changes.\(UUID())"
    let defaults: UserDefaults

    init(_ model: WorkspaceModel, openURL: OpenURLAction? = nil,
         settingsRequest: SettingsRequest? = nil, sharedDefaults: UserDefaults? = nil) throws {
        try requireTestDesktop()
        policy = app.activationPolicy()
        defaults = try XCTUnwrap(sharedDefaults ?? UserDefaults(suiteName: suite))
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2400, y: 0)
        window = ChangesReplayPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 1200, height: 800)),
                                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content: AnyView
        if let settingsRequest {
            content = AnyView(SettingsView(model: model, appearance: AppearanceSettings(defaults: defaults),
                                           browserDefaults: defaults, request: settingsRequest,
                                           pasteboard: pasteboard, openWelcome: {}))
        } else {
            content = AnyView(WorkspaceView(model: model, chatWidthMode: .comfortable,
                                            browserDefaults: defaults, workspacePasteboard: pasteboard))
        }
        host = NSHostingView(rootView: AnyView(content.defaultAppStorage(defaults)
            .environment(\.openURL, openURL ?? OpenURLAction { _ in .discarded })))
        host.sizingOptions = []
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
    }

    func close() {
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        app.setActivationPolicy(policy)
    }

    func element(_ id: String) -> AnyObject? {
        host.layoutSubtreeIfNeeded()
        return descendants(host).first { $0.accessibilityIdentifier?() == id }
    }

    func text(_ element: AnyObject? = nil) -> String {
        host.layoutSubtreeIfNeeded()
        return descendants(element ?? host).flatMap { node in
            let value = (node as? NSAccessibilityProtocol)?.accessibilityValue() as? String
            return [node.accessibilityLabel?(), node.accessibilityTitle?(), value].compactMap { $0 }
        }.joined(separator: "\n")
    }

    func press(_ id: String) async throws {
        try await wait(id) { element(id)?.isAccessibilityEnabled?() == true }
        XCTAssertTrue(element(id)?.accessibilityPerformPress?() == true, id)
        await Task.yield()
    }

    /// Like T3 Code, the header has no Changes button: Changes opens from the right panel's add menu.
    func openChanges() async throws {
        if element("hide-right-panel") == nil { try await press("toggle-right-panel") }
        try await press("add-panel-surface")
        try await press("add-panel-changes")
    }

    /// Settings switches are native switches: AppKit toggles them on press but reports the press as unhandled.
    /// Callers check the effect instead.
    func pressSwitch(_ id: String) async throws {
        try await wait(id) { element(id)?.isAccessibilityEnabled?() == true }
        _ = element(id)?.accessibilityPerformPress?()
        await Task.yield()
    }

    func pressChangesShortcut(modifiers: NSEvent.ModifierFlags = .command, isRepeat: Bool = false) throws {
        host.layoutSubtreeIfNeeded()
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "d",
            charactersIgnoringModifiers: "d", isARepeat: isRepeat, keyCode: UInt16(kVK_ANSI_D)
        ))
        app.sendEvent(event)
    }

    func assertTerminalOwnsChangesShortcut() throws {
        let terminal = TerminalSessionView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var splits = 0
        terminal.onCommand = { command in
            if case .split = command { splits += 1 }
        }
        terminal.setPresentation(true, focusRequest: nil)
        host.addSubview(terminal)
        defer { terminal.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertTrue(window.firstResponder === terminal)
        try pressChangesShortcut()
        XCTAssertEqual(splits, 1)
    }

    func assertComposerCompositionOwnsChangesShortcut() throws {
        func composer(in view: NSView) -> ComposerTextField.Field? {
            (view as? ComposerTextField.Field) ?? view.subviews.lazy.compactMap(composer).first
        }
        let field = try XCTUnwrap(composer(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? ComposerTextField.Editor)
        editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        let composition = editor.markedRange()
        defer { editor.insertText("", replacementRange: composition) }
        try pressChangesShortcut()
        XCTAssertEqual(editor.markedRange(), composition)
        XCTAssertNil(element("git-review-scope"))
    }

    func waitForText(_ id: String, containing marker: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await wait("\(id) containing \(marker)", file: file, line: line) {
            guard let node = element(id) else { return false }
            return text(node).contains(marker)
        }
    }

    func waitForPatch(_ marker: String) async throws {
        try await wait("patch line \(marker)") { text().contains(marker) }
    }

    func patchLineFrame(_ line: String) -> NSRect? {
        host.layoutSubtreeIfNeeded()
        return descendants(host).lazy.compactMap { $0 as? NSAccessibilityProtocol }.first {
            [$0.accessibilityLabel(), $0.accessibilityTitle(), $0.accessibilityValue() as? String].contains(line)
        }?.accessibilityFrame()
    }

    func wait(_ label: String, file: StaticString = #filePath, line: UInt = #line, condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label). AX text:\n\(text())", file: file, line: line)
        throw WorkspaceError("Timed out waiting for \(label).")
    }

    private func descendants(_ node: AnyObject) -> [AnyObject] {
        var visited: [ObjectIdentifier: AnyObject] = [:]
        var pending = [node]
        var result: [AnyObject] = []
        while let next = pending.popLast() {
            guard visited.updateValue(next, forKey: ObjectIdentifier(next)) == nil else { continue }
            result.append(next)
            pending.append(contentsOf: (next.accessibilityChildren?() ?? []).reversed().map { $0 as AnyObject })
        }
        return result
    }
}

private final class ChangesReplayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
