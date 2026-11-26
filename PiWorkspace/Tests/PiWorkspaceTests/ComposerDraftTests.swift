import Foundation
import XCTest
@testable import PiWorkspace

@MainActor
final class ComposerDraftTests: XCTestCase {
    func testQuitRefusesToDiscardAnUnwritableDraft() async throws {
        let fixture = try Fixture()
        let latest = "Edit made just before quitting"
        do {
            let model = fixture.open()
            try model.openProject(fixture.project)
            await wait(for: .ready, in: model)
            model.draft = "Saved text"
            XCTAssertTrue(model.savePendingComposer())
            try fixture.blockBackup()
            model.draft = latest
            XCTAssertFalse(model.terminate())
            XCTAssertEqual(model.phase, .ready)
            XCTAssertNotNil(model.composerSaveError)
            XCTAssertEqual(model.draft, latest)
            try fixture.repairBackup()
            XCTAssertTrue(model.terminate())
        }
        let reopened = fixture.open()
        reopened.start()
        XCTAssertEqual(reopened.draft, latest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commands.path))
        reopened.terminate()
    }

    func testFinishedSubmissionUnlocksTheDraftWhenTheBackupCannotBeSaved() async throws {
        for accepted in [false, true] {
            let fixture = try Fixture()
            let model = fixture.open()
            try model.openProject(fixture.project)
            await wait(for: .ready, in: model)
            if !accepted { try Data().write(to: fixture.reject) }
            let gate = fixture.project.appendingPathComponent("hold-response")
            try Data().write(to: gate)
            model.draft = "Send this message"
            model.send()
            XCTAssertEqual(model.phase, .running)
            try fixture.blockBackup()
            try FileManager.default.removeItem(at: gate)
            await wait(for: .ready, in: model)
            XCTAssertNotNil(model.composerSaveError)
            XCTAssertNil(model.conversation?.composerSubmission)
            XCTAssertEqual(model.draft, accepted ? "" : "Send this message")
            model.draft = "Editable follow-up"
            XCTAssertEqual(model.draft, "Editable follow-up")
            XCTAssertFalse(model.savePendingComposer())
            try fixture.repairBackup()
            XCTAssertTrue(model.savePendingComposer())
            XCTAssertNil(model.composerSaveError)
            XCTAssertEqual(try fixture.saved().activeProject?.conversations.first?.composerText, "Editable follow-up")
            XCTAssertEqual(try String(contentsOf: fixture.commands, encoding: .utf8).split(separator: "\n").count, 1)
            model.terminate()
        }
    }

    func testSwitchingAndQuittingRetainsTwoPopulatedDrafts() async throws {
        let fixture = try Fixture()
        let firstText = "  First line\nSecond line 🌱"
        let secondText = "Second conversation\n"
        let projectID: UUID
        let firstID: UUID
        let secondID: UUID

        do {
            let model = fixture.open()
            try model.openProject(fixture.project)
            projectID = try XCTUnwrap(model.project?.id)
            firstID = try XCTUnwrap(model.conversation?.id)
            model.draft = firstText
            model.addConversation()
            secondID = try XCTUnwrap(model.conversation?.id)
            XCTAssertNotEqual(firstID, secondID)
            model.draft = secondText
            model.selectConversation(firstID, in: projectID)
            model.editDraft("Late change from the other field", in: secondID)
            XCTAssertEqual(model.draft, firstText)
            model.selectConversation(secondID, in: projectID)
            XCTAssertEqual(model.draft, secondText)
            model.draft += "Edited immediately before quit"
            model.terminate()
        }

        let reopened = fixture.open()
        defer { reopened.terminate() }
        reopened.start()
        XCTAssertEqual(reopened.conversation?.id, secondID)
        XCTAssertEqual(reopened.draft, secondText + "Edited immediately before quit")
        reopened.selectConversation(firstID, in: projectID)
        XCTAssertEqual(reopened.draft, firstText)
        XCTAssertTrue(try XCTUnwrap(reopened.project).conversations.allSatisfy(reopened.showsInSidebar))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commands.path))
    }

    func testRetargetAndDiscardPreserveTheOtherDraftAndScratchFiles() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        try model.openProject(fixture.project)
        let projectID = try XCTUnwrap(model.project?.id)
        let keptID = try XCTUnwrap(model.conversation?.id)
        model.draft = "Keep this draft"

        model.startScratchThread()
        model.draft = "Move this draft"
        let scratch = try XCTUnwrap(model.project)
        let movedID = try XCTUnwrap(model.conversation?.id)
        model.switchDraftProject(to: projectID)
        XCTAssertEqual(model.conversation?.id, movedID)
        XCTAssertEqual(model.draft, "Move this draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))

        model.selectConversation(keptID, in: projectID)
        model.discardDraft(movedID, in: projectID)
        XCTAssertEqual(model.conversation?.id, keptID)
        XCTAssertEqual(model.draft, "Keep this draft")
        XCTAssertFalse(try fixture.saved().activeProject?.conversations.contains { $0.id == movedID } ?? true)

        model.switchDraftProject(to: nil)
        let retainedScratch = try XCTUnwrap(model.project)
        let note = URL(fileURLWithPath: retainedScratch.path).appendingPathComponent("notes.txt")
        let fileContents = Data("Keep this file".utf8)
        try fileContents.write(to: note)
        model.discardDraft(keptID, in: retainedScratch.id)
        XCTAssertFalse(try fixture.saved().projects.contains { $0.id == retainedScratch.id })
        XCTAssertEqual(try Data(contentsOf: note), fileContents)

        model.startScratchThread()
        model.draft = "Convert this draft"
        let converted = try XCTUnwrap(model.project)
        let convertedID = try XCTUnwrap(model.conversation?.id)
        XCTAssertTrue(model.convertScratchThread(convertedID, in: converted.id))
        XCTAssertEqual(model.project?.isScratch, false)
        XCTAssertEqual(try fixture.saved().activeProject?.path, converted.path)
        XCTAssertEqual(model.conversation?.id, convertedID)
        XCTAssertEqual(model.draft, "Convert this draft")
    }

    func testSendRetainsUnrecordedTextAndClearsRecordedText() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        try model.openProject(fixture.project)
        await wait(for: .ready, in: model)
        let threadID = try XCTUnwrap(model.conversation?.id)
        let projectID = try XCTUnwrap(model.project?.id)
        let text = "  Send this message  "

        model.draft = "Pasted \(Fixture.key)"
        XCTAssertTrue(model.draft.isEmpty)
        model.draft = text
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commands.path))
        try Data().write(to: fixture.reject)
        model.send()
        await wait(for: .ready, in: model)
        XCTAssertEqual(model.draft, text)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.error, "The fixture declined the prompt.")

        try FileManager.default.removeItem(at: fixture.reject)
        model.send()
        model.discardDraft(threadID, in: projectID)
        await wait(for: .ready, in: model)
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertEqual(model.messages.map(\.text), ["Send this message"])
        XCTAssertEqual(model.conversation?.isDraft, false)
        model.discardDraft(threadID, in: projectID)
        XCTAssertEqual(model.conversation?.id, threadID)
        XCTAssertEqual(try fixture.saved().activeProject?.conversations.first?.composerText, nil)

        try Data().write(to: fixture.reject)
        model.draft = text
        model.send()
        await wait(for: .ready, in: model)
        XCTAssertEqual(model.draft, text)
        XCTAssertEqual(model.messages.map(\.text), ["Send this message"])

        let commands = try String(contentsOf: fixture.commands, encoding: .utf8).split(separator: "\n")
        let texts = try commands.map { line in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
            return json["text"]
        }
        XCTAssertEqual(texts, Array(repeating: "Send this message", count: 3))
        for name in ["workspace.json", "workspace.previous.json"] {
            let data = try Data(contentsOf: fixture.workspace.appendingPathComponent(name))
            XCTAssertNil(data.range(of: Data(Fixture.key.utf8)))
        }
    }

    func testMissingKeyKeepsTheDraftWithoutDispatchingIt() async throws {
        let fixture = try Fixture()
        let model = fixture.open(key: nil)
        defer { model.terminate() }
        try model.openProject(fixture.project)
        await wait(for: .ready, in: model)
        model.draft = "Keep this until a key is available"
        model.send()
        XCTAssertTrue(model.showingSettings)
        XCTAssertEqual(model.draft, "Keep this until a key is available")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commands.path))
    }

    func testInterruptedSendChecksHistoryWithoutResubmitting() async throws {
        for recorded in [false, true] {
            let fixture = try Fixture()
            let threadID: UUID
            do {
                let model = fixture.open()
                try model.openProject(fixture.project)
                await wait(for: .ready, in: model)
                threadID = try XCTUnwrap(model.conversation?.id)
                let marker = recorded ? fixture.interruptAfterRecording : fixture.interruptBeforeRecording
                try Data().write(to: marker)
                model.draft = "Send this message"
                model.send()
                await wait(for: .closed, in: model)
                model.terminate()
            }

            let reopened = fixture.open()
            defer { reopened.terminate() }
            reopened.start()
            await wait(for: .ready, in: reopened)
            XCTAssertEqual(reopened.conversation?.id, threadID)
            XCTAssertEqual(reopened.draft, recorded ? "" : "Send this message")
            XCTAssertEqual(reopened.messages.map(\.text), recorded ? ["Send this message"] : [])
            let commands = try String(contentsOf: fixture.commands, encoding: .utf8)
            XCTAssertEqual(commands.split(separator: "\n").count, 1)
        }
    }

    func testWorktreePreparationFailureKeepsThePromptForRetry() async throws {
        let fixture = try Fixture()
        let repo = try await GitWorkspace.createRepository(named: "repository", in: fixture.root)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repo.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                         "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                         "commit", "--allow-empty", "-m", "Base"]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)

        let threadID: UUID
        let projectID: UUID
        let worktrees = fixture.workspace.appendingPathComponent("worktrees")
        try Data("obstruction".utf8).write(to: worktrees)
        do {
            let model = fixture.open()
            try model.openProject(repo)
            threadID = try XCTUnwrap(model.conversation?.id)
            projectID = try XCTUnwrap(model.project?.id)
            try await model.changeThreadLocation(.create(branch: "draft-test", base: "HEAD"))
            await wait(for: .ready, in: model)
            model.draft = "Send this message"
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commands.path))
            let failed = expectation(description: "Worktree preparation failed")
            let observation = model.$preparingWorktree.dropFirst().filter { !$0 }.first().sink { _ in failed.fulfill() }
            model.send()
            await fulfillment(of: [failed], timeout: 5)
            observation.cancel()
            XCTAssertEqual(model.conversation?.worktreeLaunch?.stage, .createCheckout)
            XCTAssertEqual(model.conversation?.worktreeLaunch?.prompt, "Send this message")
            XCTAssertTrue(model.draft.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commands.path))
            model.discardDraft(threadID, in: projectID)
            XCTAssertEqual(model.conversation?.id, threadID)
            model.terminate()
        }

        try FileManager.default.removeItem(at: worktrees)
        let reopened = fixture.open()
        defer { reopened.terminate() }
        reopened.selectConversation(threadID, in: projectID)
        XCTAssertTrue(reopened.canRetryWorktree)
        let received = expectation(description: "Pi recorded the worktree prompt")
        let observation = reopened.$messages.filter { $0.contains { $0.role == .user } }.first().sink { _ in
            received.fulfill()
        }
        reopened.retryWorktree()
        await fulfillment(of: [received], timeout: 5)
        observation.cancel()
        await wait(for: .ready, in: reopened)
        let path = try XCTUnwrap(reopened.workingDirectory)
        let branch = try await GitWorkspace(path: path).currentBranch()
        XCTAssertEqual(branch, "draft-test")
        XCTAssertNil(reopened.conversation?.worktreeLaunch)
        XCTAssertTrue(reopened.draft.isEmpty)
        let commands = try String(contentsOf: fixture.commands, encoding: .utf8)
        XCTAssertEqual(commands.split(separator: "\n").count, 1)
    }

    func testLegacyIndexAndArchivedComposerRemainUsable() async throws {
        let fixture = try Fixture()
        let projectID = UUID()
        let threadID = UUID()
        let projectPath = String(decoding: try JSONEncoder().encode(fixture.project.path), as: UTF8.self)
        let legacy = Data("""
            {
              "projects": [{
                "id": "\(projectID)", "path": \(projectPath), "title": "Legacy", "allowEdits": false,
                "conversations": [{"id": "\(threadID)", "title": "Old thread", "archived": false}],
                "selectedConversation": "\(threadID)"
              }],
              "selectedProject": "\(projectID)",
              "model": {"provider":"openai","model":"gpt-5-mini","endpoint":"","contextWindow":8192}
            }
            """.utf8)
        try legacy.write(to: fixture.workspace.appendingPathComponent("workspace.json"))
        do {
            let model = fixture.open()
            XCTAssertEqual(model.conversation?.id, threadID)
            XCTAssertTrue(model.draft.isEmpty)
            model.draft = "Unsent follow-up"
            model.archiveConversation(threadID, in: projectID, archived: true)
            model.terminate()
        }
        let reopened = fixture.open()
        defer { reopened.terminate() }
        reopened.start()
        XCTAssertEqual(reopened.conversation?.archived, true)
        XCTAssertTrue(reopened.showArchive)
        XCTAssertFalse(reopened.canSend)
        reopened.discardDraft(threadID, in: projectID)
        reopened.archiveConversation(threadID, in: projectID, archived: false)
        XCTAssertEqual(reopened.conversation?.id, threadID)
        XCTAssertEqual(reopened.draft, "Unsent follow-up")
    }

    private func wait(for phase: WorkspaceModel.Phase, in model: WorkspaceModel) async {
        let reachedPhase = expectation(description: "Pi phase is \(phase)")
        let observation = model.$phase.filter { $0 == phase }.first().sink { _ in reachedPhase.fulfill() }
        await fulfillment(of: [reachedPhase], timeout: 5)
        observation.cancel()
    }

    private final class Fixture {
        static let key = "fixture-composer-key"
        let root: URL
        var workspace: URL { root.appendingPathComponent("workspace") }
        var project: URL { root.appendingPathComponent("project") }
        var commands: URL { project.appendingPathComponent("fixture-commands") }
        var reject: URL { project.appendingPathComponent("fixture-reject") }
        var interruptBeforeRecording: URL { project.appendingPathComponent("fixture-interrupt-before") }
        var interruptAfterRecording: URL { project.appendingPathComponent("fixture-interrupt-after") }

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func open(key: String? = Fixture.key) -> WorkspaceModel {
            WorkspaceModel(root: workspace, keychainService: "dev.piworkspace.composer-tests",
                           readCredential: { _ in key }) { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", Self.helper, "composer-tests", self.commands.path])
            }
        }

        func saved() throws -> Workspace {
            try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: workspace.appendingPathComponent("workspace.json")))
        }

        private var backup: URL { workspace.appendingPathComponent("workspace.previous.json") }
        private var heldBackup: URL { root.appendingPathComponent("held-index") }

        func blockBackup() throws {
            let files = FileManager.default
            if files.fileExists(atPath: backup.path) { try files.moveItem(at: backup, to: heldBackup) }
            try files.createDirectory(at: backup, withIntermediateDirectories: false)
            try Data().write(to: backup.appendingPathComponent("obstruction"))
        }

        func repairBackup() throws {
            try FileManager.default.removeItem(at: backup)
            if FileManager.default.fileExists(atPath: heldBackup.path) { try FileManager.default.moveItem(at: heldBackup, to: backup) }
        }

        private static let helper = #"""
            while IFS= read -r command; do
                case "$command" in
                    *'"type":"open"'*)
                        history=$(cat fixture-history 2>/dev/null || printf '[]')
                        printf '{"type":"ready","messages":%s}\n' "$history"
                        ;;
                    *'"type":"prompt"'*)
                        printf '%s\n' "$command" >> "$1"
                        while [ -e hold-response ]; do sleep 0.02; done
                        if [ -f fixture-interrupt-before ]; then exit 0; fi
                        if [ -f fixture-reject ]; then
                            printf '{"type":"finished","messages":%s,"error":"The fixture declined the prompt."}\n' "$history"
                        else
                            history='[{"id":"fixture-message","role":"user","text":"Send this message"}]'
                            printf '%s' "$history" > fixture-history
                            if [ -f fixture-interrupt-after ]; then exit 0; fi
                            printf '{"type":"history","messages":%s}\n' "$history"
                            printf '{"type":"finished","messages":%s}\n' "$history"
                        fi
                        ;;
                esac
            done
            """#
    }
}
