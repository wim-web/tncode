import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ThreadIssueLinkTests: XCTestCase {
    func testIssueOnlyDraftMovesAndSameNumberLinksKeepTheirRepositoriesAfterRelaunch() async throws {
        let fixture = try ThreadGitHubFixture()
        let otherCheckout = try fixture.makeOtherCheckout()
        let original: ThreadGitHubScope
        let moved: ThreadGitHubScope
        let issue: GitHubIssueReference
        let otherRepository: GitHubRepository
        let attachment: ComposerAttachment
        do {
            let model = fixture.open()
            original = try XCTUnwrap(model.gitHubScope)
            let repository = try await model.gitHubRepository(in: original)
            XCTAssertFalse(try String(contentsOf: fixture.index, encoding: .utf8).contains("linkedIssues"))
            try await model.linkIssue(" https://GitHub.com/Fixture/Workspace/issues/42#issuecomment-1 ", in: original,
                                      repository: repository)
            issue = try XCTUnwrap(model.conversation?.issueLinks.first?.reference)
            XCTAssertEqual(issue.url.absoluteString, "https://github.com/fixture/workspace/issues/42")
            XCTAssertNil(model.conversation?.composerText)
            XCTAssertTrue(model.conversation.map(model.showsInSidebar) == true)

            try model.openProject(otherCheckout)
            let otherProject = try XCTUnwrap(model.project?.id)
            model.selectConversation(original.threadID, in: original.projectID)
            model.switchDraftProject(to: otherProject)
            moved = try XCTUnwrap(model.gitHubScope)
            XCTAssertEqual(moved.projectID, otherProject)
            XCTAssertEqual(moved.threadID, original.threadID)
            XCTAssertEqual(model.conversation?.issueLinks.first?.reference, issue)
            XCTAssertFalse(model.workspace.projects.first { $0.id == original.projectID }?
                .conversations.contains { $0.id == original.threadID } ?? true)

            otherRepository = try await model.gitHubRepository(in: moved)
            let readCount = try fixture.commands().count
            await expectFailure("uses fixture/other") {
                try await model.linkIssue(issue.url.absoluteString, in: moved, repository: otherRepository)
            }
            XCTAssertEqual(try fixture.commands().count, readCount)
            let originalDetails = try await model.gitHubReader(in: moved).linkedIssueDetails(for: issue)
            XCTAssertEqual(originalDetails.title, "Issue sharing a pull request number")
            XCTAssertEqual(originalDetails.reference, issue)

            fixture.expectedRepository = "github.com/fixture/other"
            try await model.linkIssue("#42", in: moved, repository: otherRepository)
            try await model.linkPullRequest("#42", in: moved, repository: otherRepository)
            let beforeDuplicate = try Data(contentsOf: fixture.index)
            let readsBeforeDuplicate = try fixture.commands().count
            await expectFailure("already linked") {
                try await model.linkIssue("https://GitHub.com/FIXTURE/OTHER/issues/42/", in: moved, repository: otherRepository)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.index), beforeDuplicate)
            XCTAssertEqual(try fixture.commands().count, readsBeforeDuplicate)
            model.draft = "Pending issue notes"
            XCTAssertTrue(model.attach([.pastedText("Issue notes attachment")], to: model.attachmentTarget(for: moved.threadID)))
            attachment = try XCTUnwrap(model.composerAttachments.first)
            XCTAssertTrue(model.terminate())
        }

        let reopened = fixture.open()
        defer { reopened.terminate() }
        reopened.start()
        XCTAssertNil(reopened.startupFailure)
        XCTAssertEqual(reopened.gitHubScope, moved)
        XCTAssertEqual(reopened.draft, "Pending issue notes")
        XCTAssertEqual(reopened.composerAttachments, [attachment])
        XCTAssertEqual(reopened.conversation?.issueLinks.map(\.reference.url.absoluteString), [
            "https://github.com/fixture/workspace/issues/42", "https://github.com/fixture/other/issues/42",
        ])
        XCTAssertEqual(reopened.conversation?.pullRequestLinks.map(\.reference.url.absoluteString), [
            "https://github.com/fixture/other/pull/42",
        ])

        reopened.selectConversation(fixture.secondThread, in: original.projectID)
        XCTAssertTrue(try XCTUnwrap(reopened.conversation).issueLinks.isEmpty)
        XCTAssertThrowsError(try reopened.unlinkIssue(issue, in: moved))
        reopened.selectConversation(moved.threadID, in: moved.projectID)
        XCTAssertEqual(reopened.draft, "Pending issue notes")
        XCTAssertEqual(reopened.composerAttachments, [attachment])
        let readsBeforeUnlink = try fixture.commands().count
        try reopened.unlinkIssue(issue, in: moved)
        XCTAssertEqual(reopened.conversation?.issueLinks.map(\.reference.repository), [otherRepository])
        XCTAssertEqual(reopened.conversation?.pullRequestLinks.count, 1)
        XCTAssertEqual(try fixture.commands().count, readsBeforeUnlink)
    }

    func testInvalidReferencesAndStaleReadsLeaveDraftIntact() async throws {
        let fixture = try ThreadGitHubFixture()
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let repository = try await model.gitHubRepository(in: scope)
        model.draft = "Keep this draft"
        XCTAssertTrue(model.savePendingComposer())
        let before = try Data(contentsOf: fixture.index)

        for input in ["#0", "-42", "https://github.com/fixture/workspace/pull/42",
                      "https://github.com.example.invalid/fixture/workspace/issues/42",
                      "https://user@github.com/fixture/workspace/issues/42"] {
            await expectFailure("Enter a GitHub issue URL") {
                try await model.linkIssue(input, in: scope, repository: repository)
            }
        }
        XCTAssertTrue(try fixture.commands().isEmpty)

        for mode in ["wrong-repo", "wrong-kind"] {
            try fixture.setMode(mode)
            await expectFailure("unreadable issue response") {
                try await model.linkIssue("42", in: scope, repository: repository)
            }
        }
        try await fixture.holdRead {
            let task = Task { try await model.linkIssue("#42", in: scope, repository: repository) }
            try await fixture.waitForRead()
            model.selectConversation(fixture.secondThread, in: scope.projectID)
            model.selectConversation(scope.threadID, in: scope.projectID)
            try fixture.releaseRead()
            await expectFailure("selected thread or checkout changed") { try await task.value }
        }
        try await fixture.holdRead {
            let task = Task { try await model.linkIssue("#42", in: scope, repository: repository) }
            try await fixture.waitForRead()
            try fixture.setRemote("https://github.com/fixture/other.git")
            try fixture.releaseRead()
            await expectFailure("repository changed") { try await task.value }
        }
        try fixture.setRemote("git@github.com:fixture/workspace.git")
        try await fixture.holdRead {
            let task = Task { try await model.linkIssue("#42", in: scope, repository: repository) }
            try await fixture.waitForRead()
            task.cancel()
            try fixture.releaseRead()
            do {
                try await task.value
                XCTFail("A dismissed request added a link")
            } catch is CancellationError {}
        }
        XCTAssertEqual(try Data(contentsOf: fixture.index), before)
        XCTAssertEqual(model.gitHubScope, scope)
        XCTAssertEqual(model.draft, "Keep this draft")
        XCTAssertTrue(try XCTUnwrap(model.project).conversations.allSatisfy { $0.issueLinks.isEmpty })
    }

    func testFailedSaveLeavesDraftAndLinkedItemsAvailableForRetry() async throws {
        let fixture = try ThreadGitHubFixture()
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let repository = try await model.gitHubRepository(in: scope)
        let draft = "Draft for the existing issue"
        model.draft = draft
        XCTAssertTrue(model.savePendingComposer())
        let base = try Data(contentsOf: fixture.index)
        let damaged = Data("fixture unavailable".utf8)

        try damaged.write(to: fixture.index, options: .atomic)
        defer {
            if (try? Data(contentsOf: fixture.index)) == damaged {
                try? base.write(to: fixture.index, options: .atomic)
            }
        }
        await expectFailure("index is damaged") {
            try await model.linkIssue("#42", in: scope, repository: repository)
        }
        XCTAssertEqual(model.gitHubScope, scope)
        XCTAssertEqual(model.draft, draft)
        XCTAssertTrue(try XCTUnwrap(model.conversation).issueLinks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.index), damaged)

        try base.write(to: fixture.index, options: .atomic)
        try await model.linkIssue("#42", in: scope, repository: repository)
        let linked = try Data(contentsOf: fixture.index)
        let reference = try XCTUnwrap(model.conversation?.issueLinks.first?.reference)
        try damaged.write(to: fixture.index, options: .atomic)
        XCTAssertThrowsError(try model.unlinkIssue(reference, in: scope))
        XCTAssertEqual(model.conversation?.issueLinks.first?.reference, reference)
        XCTAssertEqual(model.draft, draft)

        try linked.write(to: fixture.index, options: .atomic)
        try model.unlinkIssue(reference, in: scope)
        XCTAssertEqual(try Data(contentsOf: fixture.index), base)
    }

    func testNativeIssueDetailsLinkAndLinkedItemsReopenCopyAndUnlink() async throws {
        let fixture = try ThreadGitHubFixture()
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let repository = try await model.gitHubRepository(in: scope)
        try await model.linkPullRequest("#42", in: scope, repository: repository)
        try await model.linkIssue("#42", in: scope, repository: repository)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = OffscreenBrowser(GitHubBrowserView(workspace: model, scope: scope, pasteboard: board))
        defer { panel.close() }
        try await panel.press("github-tab-issues")
        try await panel.press("issue-row-71")
        try await panel.press("issue-link-to-thread")
        let field = try await panel.find("linked-issue-reference")
        XCTAssertEqual(panel.text(field), "https://github.com/fixture/workspace/issues/71")
        try await panel.press("linked-issue-submit")
        _ = try await panel.find("issue-unlink-from-thread")
        try await panel.press("github-tab-linked-items")
        try await panel.press("linked-pr-row-fixture/workspace-42")
        let pullRequestTitle = try await panel.find("pr-detail-title")
        XCTAssertTrue(panel.text(pullRequestTitle)?.contains("Update checkout") == true)
        try await panel.press("linked-issue-row-fixture/workspace-42")
        let title = try await panel.find("issue-detail-title")
        XCTAssertEqual(panel.text(title), "#42 Issue sharing a pull request number")
        try await panel.press("linked-issue-copy-link")
        XCTAssertEqual(board.string(forType: .string), "https://github.com/fixture/workspace/issues/42")
        let reads = try fixture.commands().count
        try await panel.press("linked-issue-unlink")
        XCTAssertNil(panel.element("linked-issue-row-fixture/workspace-42"))
        XCTAssertNotNil(panel.element("linked-pr-row-fixture/workspace-42"))
        XCTAssertNotNil(panel.element("linked-issue-row-fixture/workspace-71"))
        XCTAssertEqual(try fixture.commands().count, reads)
        try await panel.press("linked-issue-add")
        let wrongRepository = "https://github.com/fixture/other/issues/42"
        try await panel.enterIssueReference(wrongRepository)
        try await panel.press("linked-issue-submit")
        let wrongRepositoryError = try await panel.find("linked-issue-link-error")
        XCTAssertTrue(panel.text(wrongRepositoryError)?.contains("uses fixture/workspace") == true)
        let retainedField = try await panel.find("linked-issue-reference")
        XCTAssertEqual(panel.text(retainedField), wrongRepository)
        try await panel.enterIssueReference("#71")
        try await panel.press("linked-issue-submit")
        _ = try await panel.find("linked-issue-link-error") { node in
            panel.text(node)?.contains("already linked") == true
        }
        XCTAssertEqual(model.conversation?.issueLinks.map(\.reference.number), [71])
        XCTAssertEqual(try fixture.commands().count, reads)
        try await panel.enterIssueReference("#42")
        try await panel.press("linked-issue-submit")
        _ = try await panel.find("linked-issue-row-fixture/workspace-42")
        XCTAssertEqual(model.conversation?.issueLinks.map(\.reference.number), [71, 42])
    }

    private func expectFailure(_ message: String, operation: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Expected \(message)", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(message), error.localizedDescription,
                          file: file, line: line)
        }
    }

    func testIssueEditsAndCommentsThroughBothNativeEntryPoints() async throws {
        let fixture = try ThreadGitHubFixture()
        fixture.issueWrites = true
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let repository = try await model.gitHubRepository(in: scope)
        try await model.linkIssue("#71", in: scope, repository: repository)
        model.draft = "Keep this chat draft"
        XCTAssertTrue(model.savePendingComposer())
        let before = try Data(contentsOf: fixture.index)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = OffscreenBrowser(GitHubBrowserView(workspace: model, scope: scope, pasteboard: board))
        defer { panel.close() }
        try await panel.press("github-tab-issues")
        try await panel.press("issue-row-71")
        try await panel.press("issue-edit-title")
        let invalidTitle = String(repeating: "a", count: 1025)
        try await panel.enterDetailText("issue-title-editor", text: invalidTitle)
        try await panel.press("issue-title-save")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("1,024") == true }
        try await panel.expectDetailText("issue-title-editor", invalidTitle)
        XCTAssertTrue(try fixture.issueWritesLog().isEmpty)

        let title = "Edited issue title"
        try await panel.enterDetailText("issue-title-editor", text: " \(title) ")
        try fixture.setMode("no-auth")
        try await panel.press("issue-title-save")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("gh auth login") == true }
        try await panel.expectDetailText("issue-title-editor", " \(title) ")
        XCTAssertTrue(try fixture.issueWritesLog().isEmpty)
        try fixture.setMode("edit-denied")
        try await panel.press("issue-title-save")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("can’t edit") == true }
        try await panel.expectDetailText("issue-title-editor", " \(title) ")
        XCTAssertTrue(try fixture.issueWritesLog().isEmpty)
        try fixture.setMode("write-forbidden")
        try await panel.press("issue-title-save")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("denied access") == true }
        try await panel.expectDetailText("issue-title-editor", " \(title) ")
        try fixture.setMode("commit-unreadable")
        try await panel.press("issue-title-save")
        _ = try await panel.find("issue-detail-title") { panel.text($0) == "#71 " + title }

        try await panel.press("issue-edit-description")
        try await panel.enterDetailText("issue-description-editor", text: "Cancel this edit")
        try await panel.press("issue-description-cancel")
        _ = try await panel.find("issue-detail-body") { panel.text($0) == "Original issue 71 body" }
        try fixture.setMode("initial")
        try await panel.press("issue-edit-description")
        try await panel.enterDetailText("issue-description-editor", text: "")
        try await panel.press("issue-description-save")
        _ = try await panel.find("issue-detail-body-empty")
        XCTAssertNil(panel.element("issue-detail-body"))

        let comment = "A **comment** with \"quotes\"\n@fixture-path \\ and 😀"
        try await panel.enterDetailText("issue-comment-editor", text: comment)
        try fixture.setMode("write-invalid")
        try await panel.press("issue-comment-submit")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("rejected") == true }
        try await panel.expectDetailText("issue-comment-editor", comment)
        try await panel.press("github-tab-linked-items")
        try await panel.press("linked-issue-row-fixture/workspace-71")
        _ = try await panel.find("issue-detail-title") { panel.text($0) == "#71 " + title }
        try await panel.expectDetailText("issue-comment-editor", comment)
        try fixture.setMode("initial")
        try await panel.press("issue-comment-submit")
        _ = try await panel.find("issue-comment-body-posted-2") { panel.text($0) == comment }
        try await panel.expectDetailText("issue-comment-editor", "")

        try await panel.press("issue-edit-description")
        let description = "Updated **description**\nSecond line with $HOME and @file"
        try await panel.enterDetailText("issue-description-editor", text: description)
        try await panel.press("issue-description-save")
        _ = try await panel.find("issue-detail-body") { panel.text($0) == description }
        try await panel.press("github-tab-issues")
        try await panel.press("issue-row-72")
        _ = try await panel.find("issue-detail-body") { panel.text($0) == "Original issue 72 body" }
        try await panel.expectDetailText("issue-comment-editor", "")
        XCTAssertEqual(model.draft, "Keep this chat draft")
        XCTAssertEqual(try Data(contentsOf: fixture.index), before)
        let writes = try fixture.issueWritesLog()
        XCTAssertEqual(writes.map(\.method), ["PATCH", "PATCH", "PATCH", "POST", "POST", "PATCH"])
        XCTAssertEqual(Set(writes.map(\.repo)), ["fixture/workspace"])
        XCTAssertEqual(Set(writes.map(\.number)), [71])
        XCTAssertEqual(Set(writes.map { URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path }),
                       [fixture.checkout.resolvingSymlinksInPath().path])
        XCTAssertEqual(writes.map(\.payload), [
            ["title": title], ["title": title], ["body": ""], ["body": comment], ["body": comment], ["body": description]
        ])
    }

    func testUnconfirmedCommentChecksForNewActivityBeforeAllowingAnotherPost() async throws {
        let fixture = try ThreadGitHubFixture()
        fixture.issueWrites = true
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let repository = try await model.gitHubRepository(in: scope)
        try await model.linkIssue("#71", in: scope, repository: repository)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = OffscreenBrowser(GitHubBrowserView(workspace: model, scope: scope, pasteboard: board))
        defer { panel.close() }
        try await panel.press("github-tab-issues")
        try await panel.press("issue-row-71")
        try await panel.enterDetailText("issue-comment-editor", text: "Repeated text")
        let send = try await panel.find("issue-comment-submit")
        try fixture.setMode("lost-pending")
        XCTAssertTrue(send.accessibilityPerformPress?() == true)
        _ = send.accessibilityPerformPress?()
        _ = try await panel.find("issue-write-check")
        XCTAssertEqual(try fixture.issueWritesLog().count, 1)
        XCTAssertNotNil(panel.element("issue-comment-body-previous-1"))
        XCTAssertNil(panel.element("issue-comment-body-posted-2"))
        XCTAssertEqual(panel.element("issue-comment-submit")?.isAccessibilityEnabled?(), false)
        try await panel.press("github-tab-linked-items")
        try await panel.press("linked-issue-row-fixture/workspace-71")
        try await panel.press("issue-write-check")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("has not confirmed") == true }
        XCTAssertEqual(try fixture.issueWritesLog().count, 1)
        XCTAssertEqual(panel.element("issue-comment-editor").flatMap(panel.text), "Repeated text")
        try fixture.setMode("reveal")
        try await panel.press("issue-write-check")
        _ = try await panel.find("issue-comment-body-posted-2")
        XCTAssertEqual(try fixture.issueWritesLog().count, 1)
        try await panel.expectDetailText("issue-comment-editor", "")
        XCTAssertNil(panel.element("issue-write-check"))
    }

    func testCommentRetryAfterRestart() async throws {
        // Launch the first editor in a separate XCTest process so only on-disk state survives.
        let launchRoot = "PI_TEST_COMMENT_FIRST_LAUNCH"
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        if let path = ProcessInfo.processInfo.environment[launchRoot] {
            let fixture = try ThreadGitHubFixture(reopening: URL(fileURLWithPath: path))
            fixture.issueWrites = true
            let model = fixture.open()
            let scope = try XCTUnwrap(model.gitHubScope)
            model.draft = "Keep the chat draft"
            XCTAssertTrue(model.savePendingComposer())
            let panel = OffscreenBrowser(GitHubBrowserView(workspace: model, scope: scope, pasteboard: board))
            defer { panel.close() }
            try await panel.press("github-tab-issues")
            try await panel.press("issue-row-71")
            _ = try await panel.find("issue-comment-body-previous-1")
            try await panel.press("issue-detail-refresh")
            _ = try await panel.find("issue-detail-refresh") { _ in
                (try? fixture.issueRequestsLog().filter { $0.kind == "snapshot" }.count) == 2
            }
            XCTAssertEqual(try fixture.issueRequestsLog().map(\.kind), ["view", "snapshot", "view", "snapshot"])
            try await panel.enterDetailText("issue-comment-editor", text: "Repeated text")
            try fixture.setMode("hold-ack")
            try await panel.press("issue-comment-submit")
            let committed = fixture.root.appendingPathComponent("comment-committed")
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: committed.path) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: committed.path))
            XCTAssertNotNil(panel.element("issue-write-progress"))
            XCTAssertEqual(try fixture.issueWritesLog().count, 1)
            XCTAssertTrue(model.terminate())
            return
        }

        let fixture = try ThreadGitHubFixture()
        fixture.issueWrites = true
        let first = Process()
        first.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        first.arguments = ["xctest", "-XCTest", "PiWorkspaceTests.ThreadIssueLinkTests/testCommentRetryAfterRestart",
                           Bundle(for: Self.self).bundlePath]
        first.environment = ProcessInfo.processInfo.environment.merging([launchRoot: fixture.root.path]) { _, new in new }
        try first.run()
        first.waitUntilExit()
        guard first.terminationStatus == 0 else {
            return XCTFail("First editor process exited with \(first.terminationStatus)")
        }
        try fixture.releaseIssueWrite()
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let folder = try fixture.makeOtherCheckout()
        try model.openProject(folder)
        let other = try XCTUnwrap(model.gitHubScope)
        model.draft = "Other checkout chat"
        XCTAssertTrue(model.savePendingComposer())
        fixture.expectedRepository = "github.com/fixture/other"
        let otherRepository = try await model.gitHubRepository(in: other)
        try await model.linkIssue("#71", in: other, repository: otherRepository)
        let otherPanel = OffscreenBrowser(GitHubBrowserView(workspace: model, scope: other, pasteboard: board))
        try await otherPanel.press("github-tab-linked-items")
        try await otherPanel.press("linked-issue-row-fixture/other-71")
        try await otherPanel.expectDetailText("issue-comment-editor", "")
        XCTAssertNil(otherPanel.element("issue-write-check"))
        otherPanel.close()
        fixture.expectedRepository = "github.com/fixture/workspace"
        model.selectConversation(scope.threadID, in: scope.projectID)
        let index = try Data(contentsOf: fixture.index)
        let panel = OffscreenBrowser(GitHubBrowserView(workspace: model, scope: scope, pasteboard: board))
        defer { panel.close() }
        try await panel.press("github-tab-issues")
        try await panel.press("issue-row-71")
        _ = try await panel.find("issue-comment-body-previous-1")
        XCTAssertEqual(try fixture.issueWritesLog().count, 1)
        try await panel.expectDetailText("issue-comment-editor", "Repeated text")
        XCTAssertEqual(panel.element("issue-comment-submit")?.isAccessibilityEnabled?(), false)
        try await panel.press("issue-write-check")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("has not confirmed") == true }
        try fixture.setMode("reveal")
        try await panel.press("issue-detail-refresh")
        _ = try await panel.find("issue-comment-body-posted-2")
        for mode in ["different-viewer", "different-author", "replacement-issue", "window-moved"] {
            try fixture.setMode(mode)
            try await panel.press("issue-write-check")
            _ = try await panel.find("issue-write-check") { _ in
                (try? fixture.issueRequestsLog().contains { $0.kind == "snapshot" && $0.mode == mode }) == true
            }
            try await panel.expectDetailText("issue-comment-editor", "Repeated text")
        }
        try fixture.setMode("initial")
        try fixture.setRemote("https://github.com/fixture/other.git")
        try await panel.press("issue-write-check")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("changed") == true }
        try fixture.setRemote("https://github.com/fixture/workspace.git")
        try await panel.press("issue-write-check")
        try await panel.expectDetailText("issue-comment-editor", "")
        let reference = try XCTUnwrap(GitHubIssueReference(url: "https://github.com/fixture/workspace/issues/71"))
        let snapshot = try await model.gitHubReader(in: scope).issueSnapshot(for: reference)
        XCTAssertEqual(snapshot.viewerID, "fixture-user")
        XCTAssertEqual(snapshot.activity.comments.nodes.map(\.id), ["previous-1", "posted-2"])
        XCTAssertEqual(try fixture.issueWritesLog().count, 1)
        XCTAssertEqual(model.draft, "Keep the chat draft")

        try await panel.enterDetailText("issue-comment-editor", text: "Repeated text")
        try await panel.press("issue-comment-submit")
        _ = try await panel.find("issue-comment-body-posted-3")
        let confirmed = try await model.gitHubReader(in: scope).issueSnapshot(for: reference)
        XCTAssertEqual(confirmed.activity.comments.nodes.map(\.id), ["previous-1", "posted-2", "posted-3"])
        XCTAssertTrue(confirmed.activity.comments.nodes.allSatisfy { $0.viewerDidAuthor && $0.body == "Repeated text" })
        XCTAssertEqual(try Data(contentsOf: fixture.index), index)
        model.selectConversation(other.threadID, in: other.projectID)
        XCTAssertEqual(model.draft, "Other checkout chat")
        let writes = try fixture.issueWritesLog()
        XCTAssertEqual(writes.map(\.method), ["POST", "POST"])
        XCTAssertTrue(writes.allSatisfy {
            $0.repo == "fixture/workspace" && $0.number == 71 && $0.payload == ["body": "Repeated text"] &&
                URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path == fixture.checkout.resolvingSymlinksInPath().path
        })
    }

    func testCommentReceiptStorageFailureKeepsDraftAndBlocksDuplicateDispatch() async throws {
        let fixture = try ThreadGitHubFixture()
        fixture.issueWrites = true
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = OffscreenBrowser(GitHubBrowserView(workspace: model, scope: scope, pasteboard: board))
        defer { panel.close() }
        try await panel.press("github-tab-issues")
        try await panel.press("issue-row-71")
        try await panel.enterDetailText("issue-comment-editor", text: "Save receipt first")
        let file = fixture.workspace.appendingPathComponent("pending-issue-comments.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.workspace.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.workspace.path) }
        try await panel.press("issue-comment-submit")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("save the comment receipt") == true }
        try await panel.expectDetailText("issue-comment-editor", "Save receipt first")
        XCTAssertTrue(try fixture.issueWritesLog().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.workspace.path)

        try fixture.setMode("lost-pending")
        try await panel.press("issue-comment-submit")
        _ = try await panel.find("issue-write-check")
        let pending = try Data(contentsOf: file)
        try Data("unreadable journal".utf8).write(to: file, options: .atomic)
        try fixture.setMode("reveal")
        try await panel.press("issue-write-check")
        _ = try await panel.find("issue-write-error") { panel.text($0)?.contains("clear the saved comment receipt") == true }
        XCTAssertEqual(panel.element("issue-comment-submit")?.isAccessibilityEnabled?(), false)
        try pending.write(to: file, options: .atomic)
        try await panel.press("issue-write-check")
        try await panel.expectDetailText("issue-comment-editor", "")
        _ = try await panel.find("issue-comment-body-posted-2")
        XCTAssertEqual(try fixture.issueWritesLog().count, 1)
    }

    func testIssueWritePreflightRejectsChangedCheckoutThreadAndIssue() async throws {
        let fixture = try ThreadGitHubFixture()
        fixture.issueWrites = true
        let model = fixture.open()
        defer { model.terminate() }
        let scope = try XCTUnwrap(model.gitHubScope)
        let repository = try await model.gitHubRepository(in: scope)
        try await model.linkIssue("#71", in: scope, repository: repository)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = OffscreenBrowser(GitHubBrowserView(workspace: model, scope: scope, pasteboard: board))
        defer { panel.close() }
        try await panel.press("github-tab-issues")
        try await panel.press("issue-row-71")
        let draft = "Keep this issue draft"
        try await panel.enterDetailText("issue-comment-editor", text: draft)
        for change in ["issue", "thread", "checkout"] {
            try fixture.setMode("hold-preflight")
            try await panel.press("issue-comment-submit")
            try await fixture.waitForIssuePreflight()
            switch change {
            case "issue":
                try await panel.press("issue-row-72")
                try await panel.press("issue-row-71")
            case "thread":
                model.selectConversation(fixture.secondThread, in: scope.projectID)
                model.selectConversation(scope.threadID, in: scope.projectID)
            default:
                try fixture.setRemote("https://github.com/fixture/other.git")
            }
            try fixture.releaseIssueWrite()
            _ = try await panel.find("issue-write-error") {
                panel.text($0)?.contains("changed") == true
            }
            XCTAssertEqual(panel.element("issue-comment-editor").flatMap(panel.text), draft)
            XCTAssertTrue(try fixture.issueWritesLog().isEmpty)
            try fixture.setMode("initial")
            try fixture.resetIssuePreflight()
        }
        try await panel.press("github-tab-linked-items")
        try await panel.press("linked-issue-row-fixture/workspace-71")
        _ = try await panel.find("issue-write-blocked") { panel.text($0)?.contains("selected checkout") == true }
        XCTAssertEqual(panel.element("issue-comment-submit")?.isAccessibilityEnabled?(), false)
        XCTAssertTrue(try fixture.issueWritesLog().isEmpty)
    }
}

@MainActor
private final class OffscreenBrowser {
    private let app = NSApplication.shared
    private let policy: NSApplication.ActivationPolicy
    private let window: Panel

    init(_ view: GitHubBrowserView) {
        policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let origin = CGPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2200, y: 0)
        window = Panel(contentRect: NSRect(origin: origin, size: CGSize(width: 760, height: 550)),
                       styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
    }

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.contentView = nil
        window.close()
        app.setActivationPolicy(policy)
    }

    func element(_ id: String) -> AnyObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ node: AnyObject) -> AnyObject? {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.accessibilityIdentifier?() == id { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let found = find(child as AnyObject) { return found }
            }
            return nil
        }
        if let sheet = window.attachedSheet {
            XCTAssertEqual(sheet.alphaValue, 0)
            sheet.contentView?.layoutSubtreeIfNeeded()
            if let content = sheet.contentView, let found = find(content) { return found }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return window.contentView.flatMap(find)
    }

    func find(_ id: String, matching predicate: (AnyObject) -> Bool = { _ in true }) async throws -> AnyObject {
        for _ in 0..<150 {
            if let node = element(id), (node is NSTextView || node.isAccessibilityEnabled?() != false), predicate(node) {
                return node
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Missing or unexpected AX element \(id). Value: \(element(id).flatMap(text) ?? "(none)")")
        throw WorkspaceError("Missing AX element \(id)")
    }

    func press(_ id: String) async throws {
        let node = try await find(id)
        XCTAssertTrue(node.accessibilityPerformPress?() == true, id)
    }

    func text(_ node: AnyObject) -> String? {
        if let editor = node as? NSTextView { return editor.string }
        let value = (node as? NSObject)?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
        return (value as? String) ?? node.accessibilityLabel?()
    }

    func enterIssueReference(_ value: String) async throws {
        _ = try await find("linked-issue-reference")
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Issue URL or #42" { return field }
            return view.subviews.lazy.compactMap(field).first
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let input = try XCTUnwrap(sheet.contentView.flatMap(field))
        XCTAssertTrue(sheet.makeFirstResponder(input))
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertEqual(editor.string, value)
    }

    func expectDetailText(_ id: String, _ expected: String) async throws {
        _ = try await find(id) { self.text($0) == expected }
    }

    func enterDetailText(_ id: String, text: String) async throws {
        let node = try await find(id)
        if let editor = node as? NSTextView {
            XCTAssertTrue(editor.window?.makeFirstResponder(editor) == true, id)
            XCTAssertTrue(editor.isEditable, id)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            XCTAssertEqual(editor.string, text, id)
        } else {
            func field(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.placeholderString == "Issue title" { return field }
                return view.subviews.lazy.compactMap(field).first
            }
            let input = try XCTUnwrap(window.contentView.flatMap(field), id)
            XCTAssertTrue(window.makeFirstResponder(input))
            let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }
        _ = try await find(id) { self.text($0) == text }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

        override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
            sheetWindow.alphaValue = 0
            super.beginSheet(sheetWindow, completionHandler: handler)
            sheetWindow.setFrameOrigin(frame.origin)
        }
    }
}
