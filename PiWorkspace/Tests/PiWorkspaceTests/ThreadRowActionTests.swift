import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ThreadRowActionTests: XCTestCase {
    func testCommandSSavesOnlyTheFocusedFile() async throws {
        let queue = QueuedMessage(text: "Keep queued")
        let fixture = try Fixture(queuedMessages: [queue])
        let file = fixture.repo.appendingPathComponent("shortcut.txt")
        try Data("old-file".utf8).write(to: file)
        let model = fixture.open()
        defer { model.terminate() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let host = OffscreenWorkspace(model: model, pasteboard: board)
        defer { host.close() }
        try await host.press("toggle-files")
        try await host.press("files-row-shortcut.txt")
        let editor: NSTextView = try await host.waitFor("Files editor") { host.element("files-editor") as? NSTextView }
        XCTAssertTrue(host.window.makeFirstResponder(editor))
        editor.insertText("new-file", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        let selection = NSRange(location: 1, length: 3)
        editor.setSelectedRange(selection)
        XCTAssertEqual(try String(contentsOf: file), "old-file")
        XCTAssertTrue(host.window.firstResponder === editor)
        try host.pressCommandS()
        XCTAssertEqual(try String(contentsOf: file), "new-file")
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(host.window.firstResponder === editor)
        XCTAssertEqual(model.draft, "Other draft")
        XCTAssertTrue(model.stashedPrompts.isEmpty)
        XCTAssertEqual(model.queuedMessages.map(\.id), [queue.id])
        XCTAssertEqual(model.conversation?.id, fixture.local.id)
        let branch = try await GitWorkspace(path: fixture.repo.path).currentBranch()
        XCTAssertEqual(branch, "main")
    }

    func testCommandSInAnotherTextFieldLeavesTheComposerAlone() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let host = OffscreenWorkspace(model: model, pasteboard: board)
        defer { host.close() }
        _ = try await host.waitFor("composer") { host.composer }
        let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        host.host.addSubview(search)
        search.stringValue = "Query"
        XCTAssertTrue(host.window.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor())
        XCTAssertTrue(host.window.firstResponder === editor)
        try host.pressCommandS()
        XCTAssertEqual(model.draft, "Other draft")
        XCTAssertTrue(model.stashedPrompts.isEmpty)
        XCTAssertEqual(editor.string, "Query")
    }

    func testCopyTargetsUseTheirOwnCheckoutAndPasteTheThreadLinkAsText() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        model.connect()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let local = ThreadCopyTarget(project: fixture.project, thread: fixture.local)
        let linked = ThreadCopyTarget(project: fixture.project, thread: fixture.linked)
        let scratch = ThreadCopyTarget(project: fixture.scratch, thread: fixture.scratchThread)

        for (target, path) in [(local, fixture.repo.path), (linked, fixture.checkout.path), (scratch, fixture.scratch.path)] {
            try await target.copy(.path, to: board)
            XCTAssertEqual(board.string(forType: .string), path)
        }
        for (target, branch) in [(local, "main"), (linked, "topic/作業")] {
            try await target.copy(.branch, to: board)
            XCTAssertEqual(board.string(forType: .string), branch)
        }
        XCTAssertNil(scratch.branchReadPath)
        try Fixture.git(["checkout", "--quiet", "--detach", "HEAD"], in: fixture.checkout)
        do {
            try await linked.copy(.branch, to: board)
            XCTFail("A detached checkout has no branch to copy.")
        } catch {
            XCTAssertEqual(board.string(forType: .string), "topic/作業")
        }
        try await linked.copy(.id, to: board)
        XCTAssertEqual(board.string(forType: .string), fixture.linked.id.uuidString)
        try model.copyThreadReference(fixture.linked.id, in: fixture.project.id, to: board)
        let record = try JSONDecoder().decode(ThreadReference.self,
            from: XCTUnwrap(board.data(forType: ThreadReference.pasteboardType)))
        XCTAssertEqual(record.link.projectID, fixture.project.id)
        XCTAssertEqual(record.link.threadID, fixture.linked.id)
        XCTAssertEqual(record.title, fixture.linked.title)
        let text = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(text, record.link.text)
        XCTAssertEqual(URL(string: text)?.scheme, "pi-workspace")
        XCTAssertFalse(text.contains(fixture.workspace.path))
        XCTAssertNil(board.string(forType: .fileURL))
        XCTAssertEqual(model.conversation?.id, fixture.local.id)

        let host = OffscreenWorkspace(model: model, pasteboard: board)
        defer { host.close() }
        let field = try await host.waitFor("active composer") { host.composer }
        XCTAssertTrue(host.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.paste(nil)
        XCTAssertEqual(model.draft, text)
        XCTAssertTrue(model.composerAttachments.isEmpty)
    }

    func testOpeningCopiedLinksAfterRelinkingAndRelaunchReadsRealPiHistory() async throws {
        guard let nodePath = ProcessInfo.processInfo.environment["PI_PALETTE_NODE"] else {
            throw XCTSkip("Set PI_PALETTE_NODE to the absolute path of Node.")
        }
        let fixture = try Fixture()
        let node = URL(fileURLWithPath: nodePath)
        let sidecar = try fixture.seedPiHistory(node: node)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let linkedText: String
        let retargeted = fixture.root.appendingPathComponent("Retargeted Project", isDirectory: true)
        try FileManager.default.createDirectory(at: retargeted, withIntermediateDirectories: false)
        let projectID = fixture.project.id
        let localID = fixture.local.id
        let linkedID = fixture.linked.id
        do {
            let model = fixture.open()
            model.selectConversation(fixture.scratchThread.id, in: fixture.scratch.id)
            model.draft = "Keep the original draft 🧪"
            try model.copyThreadReference(linkedID, in: projectID, to: board)
            linkedText = try XCTUnwrap(board.string(forType: .string))
            try model.copyThreadReference(localID, in: projectID, to: board)
            let localText = try XCTUnwrap(board.string(forType: .string))
            // Exercise an outside app carrying only the URL text.
            board.clearContents()
            board.setString(" \(localText)\n", forType: .string)
            try model.openProject(retargeted, request: .init(relinking: projectID, startThread: false,
                                                           initialPath: retargeted.path, basePath: nil))
            model.renameProject(projectID, title: "Renamed project")
            model.renameConversation(localID, in: projectID, title: "Renamed local thread")
            model.selectConversation(fixture.scratchThread.id, in: fixture.scratch.id)
            model.terminate()
        }

        let model = WorkspaceModel(root: fixture.workspace, keychainService: fixture.root.lastPathComponent,
                                   readCredential: { _ in nil }) { config, cwd in
            try PiProcess(config: config, cwd: cwd, executable: node,
                          arguments: [sidecar.appendingPathComponent("worker.mjs").path])
        }
        defer { model.terminate() }
        let host = OffscreenWorkspace(model: model, pasteboard: board)
        defer { host.close() }
        XCTAssertEqual(model.conversation?.id, fixture.scratchThread.id)
        await model.openThreadLink(from: board)
        XCTAssertNil(model.threadLinkError)
        XCTAssertEqual(model.project?.title, "Renamed project")
        XCTAssertEqual(model.conversation?.id, localID)
        XCTAssertEqual(model.workingDirectory, retargeted.resolvingSymlinksInPath().path)
        _ = try await host.waitFor("renamed title and Pi history") {
            model.messages.last?.text == "Latest active fixture reply mentions local-history."
                && host.element("conversation-title")?.accessibilityLabel?() == "Renamed local thread" ? true : nil
        }
        let opened = await model.openThreadLink(linkedText)
        XCTAssertTrue(opened)
        XCTAssertEqual(model.workingDirectory, fixture.checkout.path)
        _ = try await host.waitFor("linked checkout’s Pi history") {
            model.messages.last?.text == "Latest active fixture reply mentions worktree-history." ? true : nil
        }
        model.selectConversation(fixture.scratchThread.id, in: fixture.scratch.id)
        XCTAssertEqual(model.draft, "Keep the original draft 🧪")
    }

    func testDamagedForkLinkKeepsSourceSelectionAfterRestart() async throws {
        guard let nodePath = ProcessInfo.processInfo.environment["PI_PALETTE_NODE"] else {
            throw XCTSkip("Set PI_PALETTE_NODE to the absolute path of Node.")
        }
        let fixture = try Fixture()
        let node = URL(fileURLWithPath: nodePath)
        let sidecar = try fixture.seedPiHistory(node: node)
        let linkID = UUID()
        let queued = QueuedMessage(text: "Keep this queued follow-up")
        do {
            let store = try WorkspaceStore(root: fixture.workspace)
            var index = try store.load()
            index.threadLinkID = linkID
            index.model = ModelSettings(provider: .local, model: "palette-fixture")
            index.projects[0].conversations[0].queuedMessages = [queued]
            try store.save(index)
        }
        func savedIndex() throws -> Workspace {
            try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: fixture.workspace.appendingPathComponent("workspace.json")))
        }
        func openModel() -> WorkspaceModel {
            WorkspaceModel(root: fixture.workspace, keychainService: fixture.root.lastPathComponent,
                           readCredential: { _ in nil }) { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: node,
                              arguments: [sidecar.appendingPathComponent("worker.mjs").path])
            }
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while !condition() {
                guard ContinuousClock.now < deadline else { throw WorkspaceError("Timed out waiting for Pi.") }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let sourceID = fixture.local.id
        let projectID = fixture.project.id
        let forkID: UUID
        let cutoff: String
        do {
            let model = openModel()
            defer { model.terminate() }
            model.connect()
            try await waitUntil { model.phase == .ready }
            cutoff = try XCTUnwrap(model.messages.last(where: { $0.canFork == true })?.id)
            model.forkResponse(cutoff)
            try await waitUntil { model.phase == .ready && model.conversation?.forkOrigin?.messageID == cutoff }
            forkID = try XCTUnwrap(model.conversation?.id)
            model.selectConversation(sourceID, in: projectID)
            model.draft = "Source draft before restart"
        }

        let model = openModel()
        defer { model.terminate() }
        model.start()
        try await waitUntil { model.phase == .ready }
        let link = ThreadLink(workspaceID: linkID, root: fixture.workspace, projectID: projectID, threadID: forkID)
        let forkHistory = fixture.workspace.appendingPathComponent("sessions/\(projectID)/\(forkID)").appendingPathComponent("\(forkID).jsonl")
        let original = try Data(contentsOf: forkHistory)
        let endOfHeader = try XCTUnwrap(original.firstIndex(of: 10))
        try original[...endOfHeader].write(to: forkHistory, options: .atomic)
        model.draft = "Dirty while opening the damaged fork"
        let sourceMessages = model.messages.map(\.id)
        var publishedSelections: [UUID?] = []
        let subscription = model.$workspace.sink { publishedSelections.append($0.activeProject?.selectedConversation) }
        defer { subscription.cancel() }
        let accepted = await model.openThreadLink(link.text)
        XCTAssertFalse(accepted)
        try await waitUntil { model.phase != .connecting }
        XCTAssertTrue(model.threadLinkError?.contains("fork history is incomplete") == true)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.messages.map(\.id), sourceMessages)
        XCTAssertEqual(model.queuedMessages, [queued])
        XCTAssertEqual(model.draft, "Dirty while opening the damaged fork")
        XCTAssertEqual(try savedIndex().activeProject?.selectedConversation, sourceID)
        XCTAssertEqual(Set(publishedSelections), [sourceID])

        try original.write(to: forkHistory, options: .atomic)
        let sourceDir = fixture.workspace.appendingPathComponent("sessions/\(projectID)/\(sourceID)")
        try FileManager.default.moveItem(at: sourceDir, to: fixture.root.appendingPathComponent("Moved source history"))
        let restored = await model.openThreadLink(link.text)
        XCTAssertTrue(restored)
        try await waitUntil { model.phase == .ready && model.conversation?.id == forkID }
        XCTAssertEqual(model.messages.last?.id, cutoff)
        let savedSource = try savedIndex().activeProject?.conversations.first { $0.id == sourceID }
        XCTAssertEqual(savedSource?.composerText, "Dirty while opening the damaged fork")
        XCTAssertEqual(savedSource?.queuedMessages, [queued])
    }

    func testPendingLinkRechecksTargetAndKeepsNewSourceTurn() async throws {
        let fixture = try Fixture()
        let linkID = UUID()
        let target = fixture.linked.id
        let projectID = fixture.project.id
        do {
            let store = try WorkspaceStore(root: fixture.workspace)
            var workspace = try store.load()
            workspace.threadLinkID = linkID
            workspace.projects[0].modelOverride = ModelSettings(provider: .local, model: "target-model")
            workspace.selectedProject = fixture.scratch.id
            try store.save(workspace)
        }
        try Data("{\"type\":\"session\",\"version\":3,\"id\":\"\(target)\"}\n".utf8).write(to: fixture.historyFile)
        let link = ThreadLink(workspaceID: linkID, root: fixture.workspace, projectID: projectID, threadID: target)
        let source = ControlledConnection()
        var sourceOpens = 0
        var opening: XCTestExpectation?
        var candidate: ControlledConnection?
        let model = WorkspaceModel(root: fixture.workspace, keychainService: fixture.root.lastPathComponent,
                                   readCredential: { _ in "fixture-key" }) { _, cwd in
            guard cwd == fixture.checkout.path else {
                sourceOpens += 1
                return source
            }
            let worker = ControlledConnection()
            candidate = worker
            opening?.fulfill()
            return worker
        }
        defer { model.terminate() }
        model.connect()
        let sourceLink = ThreadLink(workspaceID: linkID, root: fixture.workspace,
                                    projectID: fixture.scratch.id, threadID: fixture.scratchThread.id)
        Task { source.onEvent?(.ready([])) }
        let openedCurrent = await model.openThreadLink(sourceLink.text)
        XCTAssertTrue(openedCurrent)
        XCTAssertEqual(sourceOpens, 1)
        model.draft = "Send from the source"
        func beginLink() async throws -> (Task<Bool, Never>, ControlledConnection) {
            let started = expectation(description: "Started opening the linked thread")
            opening = started
            let task = Task { await model.openThreadLink(link.text) }
            await fulfillment(of: [started], timeout: 2)
            return (task, try XCTUnwrap(candidate))
        }
        var selections: [UUID?] = []
        let subscription = model.$workspace.sink { selections.append($0.selectedProject) }
        defer { subscription.cancel() }

        let (oldModel, first) = try await beginLink()
        XCTAssertEqual(first.command?.config.model, "target-model")
        try model.resetProjectModel(projectID)
        first.onEvent?(.ready([]))
        let acceptedOldModel = await oldModel.value
        XCTAssertFalse(acceptedOldModel)
        XCTAssertTrue(first.closed)

        let (nowArchived, second) = try await beginLink()
        model.archiveConversation(target, in: projectID, archived: true)
        second.onEvent?(.ready([]))
        let openedArchived = await nowArchived.value
        XCTAssertFalse(openedArchived)
        XCTAssertTrue(second.closed)
        XCTAssertTrue(model.threadLinkError?.contains("archived") == true)
        model.archiveConversation(target, in: projectID, archived: false)

        let (superseded, staleWorker) = try await beginLink()
        let stayedOnSource = await model.openThreadLink(sourceLink.text)
        XCTAssertTrue(stayedOnSource)
        let openedStale = await superseded.value
        XCTAssertFalse(openedStale)
        XCTAssertTrue(staleWorker.closed)
        staleWorker.onEvent?(.ready([]))

        let (duringTurn, third) = try await beginLink()
        model.send()
        let turn = try XCTUnwrap(source.turnID)
        third.onEvent?(.ready([]))
        let interruptedTurn = await duringTurn.value
        XCTAssertFalse(interruptedTurn)
        XCTAssertTrue(third.closed)
        XCTAssertFalse(source.closed)
        XCTAssertEqual(model.phase, .running)
        source.onEvent?(.finished(turnID: turn, [], error: nil))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(Set(selections), [fixture.scratch.id])
    }

    func testRejectedLinksKeepTheDraftAndActiveTurn() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let id = fixture.linked.id
        let projectID = fixture.project.id
        model.connect()
        model.draft = "Keep me in this thread"
        try model.copyThreadReference(id, in: projectID, to: board)
        let text = try XCTUnwrap(board.string(forType: .string))
        let workspaceID = try XCTUnwrap(model.workspace.threadLinkID)
        let otherRoot = fixture.root.appendingPathComponent("Foreign workspace", isDirectory: true)
        let clone = try WorkspaceStore(root: otherRoot)
        try clone.save(model.workspace)
        let foreign = ThreadLink(workspaceID: workspaceID, root: clone.root, projectID: projectID, threadID: id)
        let wrongProject = ThreadLink(workspaceID: workspaceID, root: fixture.workspace,
                                      projectID: fixture.scratch.id, threadID: id)
        let missingThread = ThreadLink(workspaceID: workspaceID, root: fixture.workspace, projectID: projectID, threadID: UUID())

        for (input, errorText) in [(fixture.checkout.absoluteString, "Pi Workspace thread link"),
                                   (text + "?path=/tmp", "Pi Workspace thread link"),
                                   (text + "/", "Pi Workspace thread link"),
                                   (foreign.text, "different Pi Workspace"),
                                   (wrongProject.text, "unavailable"),
                                   (missingThread.text, "unavailable"),
                                   (text, "history is missing or invalid")] {
            let opened = await model.openThreadLink(input)
            XCTAssertFalse(opened)
            XCTAssertTrue(model.threadLinkError?.contains(errorText) == true, model.threadLinkError ?? "No error")
            XCTAssertEqual(model.conversation?.id, fixture.local.id)
            XCTAssertEqual(model.draft, "Keep me in this thread")
        }

        try FileManager.default.removeItem(at: fixture.historyFile)
        let missingHistory = await model.openThreadLink(text)
        XCTAssertFalse(missingHistory)
        XCTAssertTrue(model.threadLinkError?.contains("history is missing or invalid") == true)
        XCTAssertEqual(model.draft, "Keep me in this thread")

        func writeHeader(id: UUID) throws {
            try Data("{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\"}\n".utf8).write(to: fixture.historyFile)
        }
        try writeHeader(id: fixture.local.id)
        let wrongID = await model.openThreadLink(text)
        XCTAssertFalse(wrongID)
        XCTAssertTrue(model.threadLinkError?.contains("history is missing or invalid") == true)
        try writeHeader(id: id)
        let movedCheckout = fixture.root.appendingPathComponent("Moved checkout")
        try FileManager.default.moveItem(at: fixture.checkout, to: movedCheckout)
        let missingCheckout = await model.openThreadLink(text)
        XCTAssertFalse(missingCheckout)
        XCTAssertTrue(model.threadLinkError?.contains("checkout is unavailable") == true)
        try FileManager.default.moveItem(at: movedCheckout, to: fixture.checkout)

        model.archiveConversation(id, in: projectID, archived: true)
        try model.copyThreadReference(id, in: projectID, to: board)
        XCTAssertEqual(board.string(forType: .string), text)
        let archived = await model.openThreadLink(text)
        XCTAssertFalse(archived)
        XCTAssertTrue(model.threadLinkError?.contains("Restore it from the archive") == true)
        XCTAssertEqual(model.draft, "Keep me in this thread")
        model.archiveConversation(id, in: projectID, archived: false)

        model.send()
        XCTAssertEqual(model.phase, .running)
        let runningDraft = model.draft
        let running = await model.openThreadLink(text)
        XCTAssertFalse(running)
        XCTAssertTrue(model.threadLinkError?.contains("Finish the current operation") == true)
        XCTAssertEqual(model.conversation?.id, fixture.local.id)
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.draft, runningDraft)
    }

    func testRenameArchiveAndRestoreKeepHistoryCheckoutAndDirtyDrafts() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        model.connect()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let host = OffscreenWorkspace(model: model, pasteboard: board)
        defer { host.close() }
        let id = fixture.linked.id
        let projectID = fixture.project.id
        let row = "thread-row-\(id)"
        try await host.press(row)
        XCTAssertEqual(model.conversation?.id, id)
        XCTAssertEqual(model.workingDirectory, fixture.checkout.path)
        XCTAssertEqual(model.messages.first?.text, "Keep the linked checkout history.")

        model.renameConversation(id, in: projectID, title: " \n \t")
        XCTAssertEqual(model.conversation?.title, fixture.linked.title)
        model.draft = "Dirty linked follow-up 🚲"
        model.renameConversation(id, in: projectID, title: "  Renamed linked thread \n")
        XCTAssertEqual(model.conversation?.title, "Renamed linked thread")
        XCTAssertEqual(SidebarThread.matching(in: model.threadProjects, search: "Renamed linked thread",
                                              archived: false).map(\.id), [id])
        _ = try await host.waitFor("renamed conversation title") {
            host.element("conversation-title")?.accessibilityLabel?() == "Renamed linked thread" ? true : nil
        }
        model.draft += "\nBefore archive"
        model.archiveConversation(id, in: projectID, archived: true)
        XCTAssertFalse(model.showArchive)
        XCTAssertEqual(model.conversation?.isDraft, true)
        XCTAssertEqual(model.workingDirectory, fixture.repo.path)
        XCTAssertEqual(model.draft, "")
        _ = try await host.waitFor("archived row removed") { host.element(row) == nil ? true : nil }

        model.showArchive = true
        XCTAssertEqual(SidebarThread.matching(in: model.threadProjects, search: "", archived: true).map(\.id), [id])
        try await host.press(row)
        XCTAssertEqual(model.conversation?.archived, true)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.messages.first?.text, "Keep the linked checkout history.")
        try await host.press("restore-open-thread")
        XCTAssertFalse(model.showArchive)
        XCTAssertEqual(model.conversation?.id, id)
        XCTAssertEqual(model.conversation?.archived, false)
        XCTAssertEqual(model.conversation?.title, "Renamed linked thread")
        XCTAssertEqual(model.draft, "Dirty linked follow-up 🚲\nBefore archive")
        XCTAssertEqual(model.workingDirectory, fixture.checkout.path)
        XCTAssertEqual(try Data(contentsOf: fixture.historyFile), fixture.historyBytes)
        XCTAssertEqual(try String(contentsOf: fixture.checkout.appendingPathComponent("local note"), encoding: .utf8),
                       "Keep this untracked file.")
        try await host.press("thread-row-\(fixture.local.id)")
        XCTAssertEqual(model.draft, "Other draft")
    }

    func testArchiveTargetsOnlyTheIdleRowAndStartsAnIndependentScratchDraft() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        model.connect()
        model.send()
        XCTAssertEqual(model.phase, .running)
        let id = fixture.local.id
        let other = fixture.linked.id
        let projectID = fixture.project.id
        model.archiveConversation(id, in: projectID, archived: true)
        XCTAssertEqual(model.conversation?.archived, false)
        model.archiveConversation(other, in: projectID, archived: true)
        XCTAssertEqual(model.project?.conversations.first { $0.id == other }?.archived, true)
        XCTAssertEqual(model.conversation?.id, id)
        XCTAssertEqual(model.phase, .running)
        model.archiveConversation(other, in: projectID, archived: false)
        XCTAssertEqual(model.project?.conversations.first { $0.id == other }?.archived, false)
        XCTAssertEqual(model.phase, .running)
        model.shutdown()

        model.selectConversation(fixture.scratchThread.id, in: fixture.scratch.id)
        model.draft = "Scratch follow-up"
        model.archiveConversation(fixture.scratchThread.id, in: fixture.scratch.id, archived: true)
        XCTAssertEqual(model.project?.isScratch, true)
        XCTAssertNotEqual(model.project?.id, fixture.scratch.id)
        XCTAssertNotEqual(model.workingDirectory, fixture.scratch.path)
        XCTAssertEqual(model.conversation?.isDraft, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.scratch.path))
        model.selectConversation(fixture.scratchThread.id, in: fixture.scratch.id)
        XCTAssertEqual(model.conversation?.archived, true)
        model.archiveConversation(fixture.scratchThread.id, in: fixture.scratch.id, archived: false)
        XCTAssertEqual(model.draft, "Scratch follow-up")
        XCTAssertEqual(model.workingDirectory, fixture.scratch.path)
    }

    func testArchiveWaitsForQueuedEditAndPreservesBothComposersAfterRelaunch() async throws {
        let item = QueuedMessage(text: "Original queued text")
        let fixture = try Fixture(queuedMessages: [item])
        let id = fixture.local.id
        let projectID = fixture.project.id
        let draftFile: ComposerAttachment
        let editedFile: ComposerAttachment
        do {
            let model = fixture.open()
            model.connect()

            XCTAssertTrue(model.attach([.pastedText("Draft file")], to: model.attachmentTarget(for: id)))
            draftFile = try XCTUnwrap(model.composerAttachments.first)
            model.editQueuedMessage(item.id)
            model.draft = "Edited queued text"
            XCTAssertTrue(model.attach([.pastedText("Queue file")], to: model.attachmentTarget(for: id)))
            editedFile = try XCTUnwrap(model.composerAttachments.first)

            let other = fixture.linked.id
            XCTAssertTrue(model.canChangeArchive(for: other))
            model.archiveConversation(other, in: projectID, archived: true)
            XCTAssertEqual(model.project?.conversations.first { $0.id == other }?.archived, true)
            model.archiveConversation(other, in: projectID, archived: false)

            XCTAssertFalse(model.canChangeArchive(for: id))
            model.archiveConversation(id, in: projectID, archived: true)
            XCTAssertEqual(model.conversation?.id, id)
            XCTAssertEqual(model.draft, "Edited queued text")
            XCTAssertEqual(model.composerAttachments, [editedFile])
            let editingID = try XCTUnwrap(model.editingQueuedMessageID)
            XCTAssertEqual(editingID, item.id)

            let backup = fixture.workspace.appendingPathComponent("workspace.previous.json")
            try FileManager.default.removeItem(at: backup)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
            try Data().write(to: backup.appendingPathComponent("obstruction"))
            model.updateQueuedMessage()
            XCTAssertNotNil(model.error)
            XCTAssertFalse(model.canChangeArchive(for: id))
            XCTAssertEqual(model.queuedMessages, [item])
            XCTAssertEqual(model.draft, "Edited queued text")
            XCTAssertEqual(model.composerAttachments, [editedFile])

            try FileManager.default.removeItem(at: backup)
            model.updateQueuedMessage()
            XCTAssertNil(model.editingQueuedMessageID)
            XCTAssertTrue(model.canChangeArchive(for: id))
            XCTAssertEqual(model.draft, "Other draft")
            XCTAssertEqual(model.composerAttachments, [draftFile])
            model.archiveConversation(id, in: projectID, archived: true)
            XCTAssertNotEqual(model.conversation?.id, id)
            XCTAssertTrue(model.terminate())
        }

        let reopened = fixture.open()
        defer { reopened.terminate() }
        XCTAssertNil(reopened.startupFailure)
        reopened.selectConversation(id, in: projectID)
        XCTAssertEqual(reopened.conversation?.archived, true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let host = OffscreenWorkspace(model: reopened, pasteboard: board)
        defer { host.close() }
        try await host.press("restore-open-thread")
        XCTAssertEqual(reopened.draft, "Other draft")
        XCTAssertEqual(reopened.composerAttachments, [draftFile])
        reopened.editQueuedMessage(item.id)
        XCTAssertEqual(reopened.draft, "Edited queued text")
        XCTAssertEqual(reopened.composerAttachments, [editedFile])
        reopened.draft = "Discard this edit"
        try await host.press("queue-cancel-edit")
        XCTAssertTrue(reopened.canChangeArchive(for: id))
        XCTAssertEqual(reopened.queuedMessages.first?.text, "Edited queued text")
    }

    func testChangingSelectionWaitsForCancelAndKeepsTheStoredMessage() throws {
        let item = QueuedMessage(text: "Before edit")
        let fixture = try Fixture(queuedMessages: [item])
        let model = fixture.open()
        defer { model.terminate() }
        let projectID = fixture.project.id
        let other = fixture.linked.id
        model.editQueuedMessage(item.id)
        model.draft = "Pending edit"

        model.selectConversation(other, in: projectID)
        model.addConversation(in: projectID)
        model.startScratchThread()
        model.showHome()
        model.removeProject(projectID)
        XCTAssertEqual(model.project?.id, projectID)
        XCTAssertEqual(model.conversation?.id, fixture.local.id)
        XCTAssertEqual(model.draft, "Pending edit")
        XCTAssertEqual(model.editingQueuedMessageID, item.id)
        model.cancelQueuedMessageEdit()
        XCTAssertEqual(model.draft, "Other draft")
        XCTAssertEqual(model.queuedMessages, [item])
        model.selectConversation(other, in: projectID)
        XCTAssertEqual(model.conversation?.id, other)
    }

    private final class Fixture {
        let root: URL
        let workspace: URL
        let repo: URL
        let checkout: URL
        let local: Conversation
        let scratchThread = Conversation(id: UUID(), title: "Scratch thread", isDraft: false)
        let linked: Conversation
        let project: Project
        let scratch: Project
        let historyFile: URL
        let historyBytes = Data("""
            {"type":"message","id":"linked-reply","role":"assistant","text":"Keep the linked checkout history."}
            """.utf8)

        init(queuedMessages: [QueuedMessage]? = nil) throws {
            local = Conversation(id: UUID(), title: "Local thread", isDraft: false, composerText: "Other draft",
                                 queuedMessages: queuedMessages)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Thread Actions \(UUID())", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            repo = root.appendingPathComponent("Project Files", isDirectory: true)
            checkout = root.appendingPathComponent("Linked Checkout", isDirectory: true)
            let files = FileManager.default
            try files.createDirectory(at: repo, withIntermediateDirectories: true)
            try Self.git(["init", "-q", "-b", "main", "--template="], in: repo)
            try Self.git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                          "commit", "--allow-empty", "-q", "-m", "Fixture"], in: repo)
            try Self.git(["worktree", "add", "-q", "-b", "topic/作業", checkout.path], in: repo)
            try Data("Keep this untracked file.".utf8).write(to: checkout.appendingPathComponent("local note"))
            let store = try WorkspaceStore(root: workspace)
            linked = Conversation(id: UUID(), title: "Linked thread", location: .worktree(path: checkout.path, base: "main"),
                                  isDraft: false)
            project = Project(id: UUID(), path: repo.path, title: "Fixture",
                              conversations: [local, linked], selectedConversation: local.id)
            scratch = try store.makeScratchProject(for: scratchThread)
            try store.save(Workspace(projects: [project, scratch], selectedProject: project.id, welcomeCompleted: true))
            let history = store.history(project: project.id, conversation: linked.id)
            try files.createDirectory(at: history, withIntermediateDirectories: true)
            historyFile = history.appendingPathComponent("seed.jsonl")
            try historyBytes.write(to: historyFile)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func open() -> WorkspaceModel {
            WorkspaceModel(root: workspace, keychainService: root.lastPathComponent, readCredential: { _ in "fixture-key" }) { _, _ in
                Connection()
            }
        }

        func seedPiHistory(node: URL) throws -> URL {
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let sidecar = package.appendingPathComponent("Sidecar")
            try XCTSkipUnless(FileManager.default.fileExists(atPath:
                sidecar.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/package.json").path),
                "Install the Sidecar dependencies to run the Pi history fixture.")
            let script = package.appendingPathComponent("scripts/fixtures/palette-message-history.mjs")
            try FileManager.default.removeItem(at: historyFile)
            for (thread, path, keyword) in [(local, repo.path, "local-history"), (linked, checkout.path, "worktree-history")] {
                let process = Process()
                process.executableURL = node
                process.arguments = [script.path, sidecar.path, workspace.path, project.id.uuidString,
                                     thread.id.uuidString, path, keyword, keyword]
                process.environment = ["PI_CODING_AGENT_DIR": root.appendingPathComponent("pi-fixture").path,
                                       "PI_OFFLINE": "1", "PI_TELEMETRY": "0"]
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw WorkspaceError("Could not seed Pi history.") }
            }
            return sidecar
        }

        static func git(_ arguments: [String], in folder: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = folder
            process.environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw WorkspaceError("Fixture Git command failed.") }
        }
    }

    private final class ControlledConnection: PiConnection {
        var onEvent: ((PiEvent) -> Void)?
        var onClose: (() -> Void)?
        var command: OpenConversation?
        var turnID: UUID?
        var closed = false

        func send(_ command: any Encodable) throws {
            if let open = command as? OpenConversation { self.command = open }
            if let prompt = command as? SendPrompt { turnID = prompt.turnID }
        }

        func close() { closed = true }
    }

    private final class Connection: PiConnection {
        var onEvent: ((PiEvent) -> Void)?
        var onClose: (() -> Void)?

        func send(_ command: any Encodable) throws {
            guard let open = command as? OpenConversation else { return }
            let file = URL(fileURLWithPath: open.sessionDir).appendingPathComponent("seed.jsonl")
            let messages = if FileManager.default.fileExists(atPath: file.path) {
                [try JSONDecoder().decode(ChatMessage.self, from: Data(contentsOf: file))]
            } else {
                [ChatMessage]()
            }
            onEvent?(.ready(messages))
        }

        func close() {}
    }

    @MainActor
    private final class OffscreenWorkspace {
        let window: NSWindow
        let host: NSView
        let activationPolicy: NSApplication.ActivationPolicy

        init(model: WorkspaceModel, pasteboard: NSPasteboard) {
            let app = NSApplication.shared
            activationPolicy = app.activationPolicy()
            app.setActivationPolicy(.prohibited)
            app.finishLaunching()
            let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2200, y: 0)
            window = ThreadActionsOffscreenPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1100, height: 720)),
                                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                         workspacePasteboard: pasteboard))
            window.contentView = host
            window.setFrameOrigin(origin)
            XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
            window.orderBack(nil)
        }

        func close() {
            window.contentView = nil
            window.close()
            NSApplication.shared.setActivationPolicy(activationPolicy)
        }

        var composer: ComposerTextField.Field? {
            func find(_ view: NSView) -> ComposerTextField.Field? {
                (view as? ComposerTextField.Field) ?? view.subviews.lazy.compactMap(find).first
            }
            return find(host)
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
            return find(host) ?? find(window)
        }

        func waitFor<T>(_ description: String, _ read: () -> T?) async throws -> T {
            for _ in 0..<80 {
                host.layoutSubtreeIfNeeded()
                if let value = read() { return value }
                try await Task.sleep(for: .milliseconds(20))
            }
            let message = "Timed out waiting for \(description)."
            XCTFail(message)
            throw WorkspaceError(message)
        }

        func pressCommandS() throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       characters: "s", charactersIgnoringModifiers: "s",
                                                       isARepeat: false, keyCode: 1))
            NSApp.sendEvent(event)
        }

        func press(_ id: String) async throws {
            let button = try await waitFor(id) { element(id) }
            XCTAssertTrue(button.accessibilityPerformPress?() == true)
            await Task.yield()
        }
    }
}

private final class ThreadActionsOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
