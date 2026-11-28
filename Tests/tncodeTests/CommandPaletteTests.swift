import AppKit
import Carbon
import XCTest
@testable import tncode

@MainActor
final class CommandPaletteTests: XCTestCase {
    func testQuotedQueryRequiresTheWordsTogether() {
        let rows = [
            CommandPaletteRow(action: .settings, title: "Review build results", icon: "gearshape"),
            CommandPaletteRow(action: .home, title: "Review this build results", icon: "house")
        ]
        XCTAssertEqual(CommandPaletteRow.matching("\"review build\"", in: rows).map(\.action), [.settings])
    }

    func testProjectSettingsUsesTheActiveFolderEvenWhenTheSidebarFiltersItOut() {
        let other = Project(id: UUID(), path: "/first/Project", title: "Project")
        let active = Project(id: UUID(), path: "/second/Project", title: "Project")
        let contents = CommandPaletteContents(projects: [other], availableProjects: [other], preferredProject: active.id,
                                              threads: [], activeThread: nil, canStartScratchThread: true,
                                              settingsProject: active)
        XCTAssertEqual(contents.results(for: ">Project settings", choosingProject: false).map(\.action),
                       [.projectSettings(active.id)])
    }

    func testMessageSearchRejectsSupersededQueryScopeAndSubmenuResults() throws {
        let fixture = try Fixture()
        let alpha = try fixture.openProject("Alpha")
        defer { fixture.model.terminate() }
        let threadID = try XCTUnwrap(fixture.model.conversation?.id)
        fixture.model.draft = "A pending draft"
        let contents = contents(in: fixture.model, projectID: alpha)
        var session = CommandPaletteSession()
        session.query = "orbital lantern"
        let obsolete = try XCTUnwrap(session.messageSearch(in: contents, latestMessageID: nil))
        let occurrence = TranscriptOccurrence(messageID: "old", range: NSRange(location: 0, length: 14))
        let matches = [threadID: SidebarMessageSearch.Match(occurrence: occurrence, excerpt: "orbital lantern")]
        session.receive(matches, for: obsolete)
        XCTAssertEqual(session.messageMatches(for: obsolete)?.count, 1)
        let changedTranscript = session.messageSearch(in: contents, latestMessageID: "new")
        XCTAssertNil(session.messageMatches(for: changedTranscript))
        let beta = try fixture.openProject("Beta")
        fixture.model.draft = "Another pending draft"
        let changedScope = try XCTUnwrap(session.messageSearch(in: self.contents(in: fixture.model, projectID: beta),
                                                              latestMessageID: nil))
        XCTAssertNil(session.messageMatches(for: changedScope))

        session.query = "other term"
        session.query = "orbital lantern"
        let current = try XCTUnwrap(session.messageSearch(in: contents, latestMessageID: nil))
        session.receive(matches, for: obsolete)
        XCTAssertNil(session.messageMatches(for: current))
        session.receive(matches, for: current)
        XCTAssertEqual(session.messageMatches(for: current)?.count, 1)

        XCTAssertEqual(session.select(.chooseProject), .handled)
        session.query = "orbital lantern"
        XCTAssertNil(session.messageSearch(in: contents, latestMessageID: nil))
        session.back()
        XCTAssertEqual(session.query, "orbital lantern")
        XCTAssertNil(session.messageMatches(for: session.messageSearch(in: contents, latestMessageID: nil)))

        session.query = ">orbital lantern"
        XCTAssertNil(session.messageSearch(in: contents, latestMessageID: nil))
        XCTAssertNil(contents.messageSearch(for: "la", choosingProject: false))
        XCTAssertNotNil(contents.messageSearch(for: "履歴", choosingProject: false))
    }

    func testPaletteSearchAndSelectionWithRealPiHistory() async throws {
        let environment = ProcessInfo.processInfo.environment
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidecar = environment["PI_PALETTE_SIDECAR"] ?? package.appendingPathComponent("Sidecar").path
        guard FileManager.default.fileExists(atPath: sidecar + "/node_modules/@earendil-works/pi-coding-agent") else {
            throw XCTSkip("Set PI_PALETTE_SIDECAR to a Sidecar directory with the bundled Pi SDK.")
        }
        let node = environment["PI_PALETTE_NODE"] ?? "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: node) else {
            throw XCTSkip("Set PI_PALETTE_NODE to the absolute path of Node.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let draft = Conversation(id: UUID(), title: "My draft", isDraft: true, composerText: "Before edit")
        let older = Conversation(id: UUID(), title: "Shared thread", lastActiveAt: Date(timeIntervalSince1970: 2))
        let titled = Conversation(id: UUID(), title: "Orbital lantern by title", lastActiveAt: Date(timeIntervalSince1970: 1))
        let settled = Conversation(id: UUID(), title: "Settled", lastActiveAt: Date(), shelf: .settled)
        let archived = Conversation(id: UUID(), title: "Archived", archived: true, lastActiveAt: Date())
        let outOfScope = Conversation(id: UUID(), title: "Shared thread", lastActiveAt: Date())
        let alpha = Project(id: UUID(), path: root.appendingPathComponent("Alpha").path, title: "Alpha",
                            conversations: [draft, older, titled, settled, archived], selectedConversation: draft.id)
        let beta = Project(id: UUID(), path: root.appendingPathComponent("Beta").path, title: "Beta",
                           conversations: [outOfScope])
        let empty = Project(id: UUID(), path: root.appendingPathComponent("Empty").path, title: "Empty")
        for project in [alpha, beta, empty] {
            try FileManager.default.createDirectory(atPath: project.path, withIntermediateDirectories: true)
        }
        try WorkspaceStore(root: workspace).save(Workspace(projects: [alpha, beta, empty], selectedProject: alpha.id,
                                                           model: ModelSettings(provider: .local, model: "palette-fixture"),
                                                           welcomeCompleted: true))

        struct Seed: Decodable { let messageID: String; let abandonedID: String }
        func seed(_ project: Project, _ thread: Conversation) throws -> Seed {
            let writer = Process()
            let output = Pipe()
            writer.executableURL = URL(fileURLWithPath: node)
            writer.arguments = [package.appendingPathComponent("scripts/fixtures/palette-message-history.mjs").path,
                                sidecar, workspace.path, project.id.uuidString, thread.id.uuidString,
                                project.path, "orbital lantern"]
            writer.standardOutput = output
            writer.environment = ["PI_OFFLINE": "1", "PI_TELEMETRY": "0", "PI_CODING_AGENT_DIR": root.path]
            try writer.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            writer.waitUntilExit()
            XCTAssertEqual(writer.terminationStatus, 0)
            return try JSONDecoder().decode(Seed.self, from: data)
        }

        let history = try seed(alpha, older)
        _ = try seed(alpha, titled)
        let archiveHistory = try seed(alpha, archived)
        _ = try seed(beta, outOfScope)
        func openModel() -> WorkspaceModel {
            WorkspaceModel(root: workspace, keychainService: "palette-pi-test", readCredential: { _ in nil }) { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: node),
                              arguments: [sidecar + "/worker.mjs"])
            }
        }

        do {
            let model = openModel()
            defer { model.terminate() }
            model.draft = "Typed while editing the draft"
            var session = CommandPaletteSession()
            session.query = "\"orbital lantern\""
            let alphaContents = contents(in: model, projectID: alpha.id)
            let search = try XCTUnwrap(session.messageSearch(in: alphaContents, latestMessageID: nil))
            let matches = try await model.searchMessages(search.request)
            XCTAssertEqual(Set(matches.keys), [older.id])
            XCTAssertEqual(matches[older.id]?.messageID, history.messageID)
            XCTAssertTrue(matches[older.id]?.excerpt.contains("orbital lantern") == true)
            let groups = alphaContents.groups(for: session.query, choosingProject: false,
                                             search: search.request, matches: matches)
            XCTAssertEqual(groups.map(\.id), [.threads, .messages])
            let rows = groups.flatMap(\.rows)
            XCTAssertEqual(rows.first?.action, .openThread(titled.id, project: alpha.id))
            _ = session.handle(.down, rows: rows, repeated: false, composing: false)
            guard case .run(.openMessage(let thread, let project, let occurrence, let term)) =
                    session.handle(.select, rows: rows, repeated: false, composing: false) else {
                return XCTFail("Return should select the highlighted message result")
            }
            XCTAssertEqual(occurrence.messageID, history.messageID)
            XCTAssertEqual(occurrence.range, NSRange(location: 26, length: 15))
            XCTAssertEqual(term.text, "orbital lantern")

            let ready = expectation(description: "Real Pi reopened the selected history")
            let observation = model.$phase.first { $0 == .ready }.sink { _ in ready.fulfill() }
            model.selectConversation(thread, in: project)
            await fulfillment(of: [ready], timeout: 10)
            observation.cancel()
            XCTAssertEqual(model.messages.first?.id, occurrence.messageID)
            XCTAssertNotEqual(model.messages.last?.id, occurrence.messageID)
            XCTAssertFalse(model.messages.contains { $0.id == history.abandonedID })
            let abandoned = try XCTUnwrap(alphaContents.messageSearch(for: "palette-abandoned-branch-marker", choosingProject: false))
            let abandonedMatches = try await model.searchMessages(abandoned)
            XCTAssertTrue(abandonedMatches.isEmpty)

            let archive = contents(in: model, projectID: alpha.id, archived: true)
            let archiveSearch = try XCTUnwrap(archive.messageSearch(for: "lantern orbital", choosingProject: false))
            let archiveMatches = try await model.searchMessages(archiveSearch)
            XCTAssertEqual(Set(archiveMatches.keys), [archived.id])
            XCTAssertEqual(archiveMatches[archived.id]?.messageID, archiveHistory.messageID)

            model.selectProjectFromPalette(empty.id)
            XCTAssertEqual(model.project?.id, empty.id)
            XCTAssertEqual(model.conversation?.isDraft, true)
            model.selectProjectFromPalette(alpha.id)
            XCTAssertEqual(model.conversation?.id, older.id)
        }

        let relaunched = openModel()
        defer { relaunched.terminate() }
        relaunched.start()
        let search = try XCTUnwrap(contents(in: relaunched, projectID: alpha.id)
            .messageSearch(for: "orbital lantern", choosingProject: false))
        let matches = try await relaunched.searchMessages(search)
        XCTAssertEqual(matches[older.id]?.messageID, history.messageID)
        relaunched.selectConversation(draft.id, in: alpha.id)
        XCTAssertEqual(relaunched.draft, "Typed while editing the draft")
    }

    private func contents(in model: WorkspaceModel, projectID: UUID, archived: Bool = false) -> CommandPaletteContents {
        let projects = model.projects.filter { $0.id == projectID }
        let threads = SidebarThread.matching(in: projects, search: "", archived: archived)
            .filter { model.showsInSidebar($0.thread) }
        return CommandPaletteContents(projects: projects, availableProjects: projects, preferredProject: projectID,
                                      threads: threads, activeThread: model.conversation?.id, canStartScratchThread: true)
    }

    func testProjectPickerSelectsADraftInTheChosenProject() throws {
        let fixture = try Fixture()
        let model = fixture.model
        defer { model.terminate() }
        let alpha = try fixture.openProject("Alpha")
        let original = try XCTUnwrap(model.conversation?.id)
        model.draft = "Keep the Alpha draft"
        let beta = try fixture.openProject("Beta")
        let originalBetaDraft = try XCTUnwrap(model.conversation?.id)
        model.draft = "Keep the Beta draft"
        model.selectConversation(original, in: alpha)

        var commands: [WorkspaceModel.SidebarCommand] = []
        let observation = model.sidebarCommand.sink { commands.append($0) }
        defer { observation.cancel() }
        model.requestCommandPalette()
        XCTAssertEqual(commands, [.commandPalette])

        let contents = fixture.contents
        var session = CommandPaletteSession()
        let roots = contents.results(for: "", choosingProject: false)
        XCTAssertEqual(session.selected(in: roots)?.action, .newThread(alpha))
        let down = try key(kVK_DownArrow)
        let enter = try key(kVK_Return)
        XCTAssertEqual(session.handle(down, rows: roots, repeated: false, composing: false), .handled)
        XCTAssertEqual(session.selected(in: roots)?.action, .chooseProject)
        XCTAssertEqual(session.handle(enter, rows: roots, repeated: false, composing: false), .handled)

        let projects = contents.results(for: session.query, choosingProject: session.choosingProject)
        XCTAssertEqual(session.selected(in: projects)?.action, .newThread(alpha))
        let up = try key(kVK_UpArrow)
        XCTAssertEqual(session.handle(up, rows: projects, repeated: false, composing: false), .handled)
        XCTAssertEqual(session.selected(in: projects)?.action, .newThread(beta))
        XCTAssertEqual(session.handle(enter, rows: projects, repeated: true, composing: false), .handled)
        XCTAssertEqual(session.handle(enter, rows: projects, repeated: false, composing: true), .ignored)
        guard case .run(.newThread(let target)) = session.handle(enter, rows: projects, repeated: false, composing: false) else {
            return XCTFail("Return should select the highlighted project.")
        }
        model.addConversation(in: target)

        XCTAssertEqual(model.project?.id, beta)
        let newDraft = try XCTUnwrap(model.conversation?.id)
        XCTAssertNotEqual(newDraft, originalBetaDraft)
        XCTAssertEqual(model.conversation?.isDraft, true)
        XCTAssertEqual(model.draft, "")
        let saved = try fixture.saved()
        XCTAssertEqual(saved.activeProject?.id, beta)
        XCTAssertEqual(saved.activeProject?.conversations.map(\.id), [newDraft, originalBetaDraft])
        XCTAssertEqual(saved.activeProject?.conversations.last?.composerText, "Keep the Beta draft")
        XCTAssertEqual(saved.projects.first { $0.id == alpha }?.conversations.first { $0.id == original }?.composerText,
                       "Keep the Alpha draft")
    }

    func testBackRestoresQueryAndEscapeLeavesWorkspaceUnchanged() throws {
        let fixture = try Fixture()
        let project = try fixture.openProject("Alpha")
        let model = fixture.model
        defer { model.terminate() }
        let thread = model.conversation?.id
        model.draft = "  Unsent text  "
        XCTAssertTrue(model.savePendingComposer())
        let before = try Data(contentsOf: fixture.index)

        var session = CommandPaletteSession()
        session.query = "choose project"
        let roots = fixture.contents.results(for: session.query, choosingProject: false)
        XCTAssertEqual(session.handle(try key(kVK_Return), rows: roots, repeated: false, composing: false), .handled)
        XCTAssertTrue(session.choosingProject)
        XCTAssertEqual(session.query, "")
        let backspace = try key(kVK_Delete)
        XCTAssertEqual(session.handle(backspace, rows: [], repeated: true, composing: false), .ignored)
        XCTAssertEqual(session.handle(backspace, rows: [], repeated: false, composing: false), .handled)
        XCTAssertFalse(session.choosingProject)
        XCTAssertEqual(session.query, "choose project")
        let escape = try key(kVK_Escape)
        XCTAssertEqual(session.handle(escape, rows: roots, repeated: false, composing: false), .close)
        XCTAssertEqual(model.project?.id, project)
        XCTAssertEqual(model.conversation?.id, thread)
        XCTAssertEqual(model.draft, "  Unsent text  ")
        XCTAssertEqual(try Data(contentsOf: fixture.index), before)
    }

    func testProjectAndThreadSearchUseTheScopedWorkspaceRecords() throws {
        let fixture = try Fixture()
        let alpha = try fixture.openProject("Alpha")
        let model = fixture.model
        defer { model.terminate() }
        let thread = try XCTUnwrap(model.conversation?.id)
        model.renameConversation(thread, in: alpha, title: "Investigate cache")
        model.draft = "Keep Alpha visible"
        _ = try fixture.openProject("Beta")
        var filter = SidebarProjectFilter()
        filter.selectOnly(alpha)
        let projects = filter.projects(in: model.projects)
        let contents = CommandPaletteContents(
            projects: projects, availableProjects: projects, preferredProject: model.project?.id,
            threads: SidebarThread.matching(in: projects, search: "", archived: false),
            activeThread: model.conversation?.id, canStartScratchThread: true
        )
        XCTAssertEqual(contents.results(for: "cAchE", choosingProject: false).map(\.action),
                       [.openThread(thread, project: alpha)])
        XCTAssertEqual(contents.results(for: "Alpha", choosingProject: false).first?.action, .openProject(alpha))
        XCTAssertFalse(contents.results(for: ">Alpha", choosingProject: false).contains { $0.action == .openProject(alpha) })
        XCTAssertTrue(contents.results(for: "Beta", choosingProject: true).isEmpty)
        XCTAssertEqual(contents.results(for: "find messages", choosingProject: false).first?.action, .searchThreads)
    }

    private func key(_ code: Int) throws -> CommandPaletteSession.Key {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)
        ))
        return try XCTUnwrap(CommandPaletteSession.Key(event))
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let model: WorkspaceModel
        var index: URL { model.root.appendingPathComponent("workspace.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            model = WorkspaceModel(root: root.appendingPathComponent("workspace"), keychainService: "palette-tests",
                                   readCredential: { _ in "palette-fixture-key" }) { config, cwd in
                try PiProcess(config: config, cwd: cwd, executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", Self.helper])
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func openProject(_ name: String) throws -> UUID {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try model.openProject(url)
            return try XCTUnwrap(model.project?.id)
        }

        func saved() throws -> Workspace {
            try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
        }

        var contents: CommandPaletteContents {
            CommandPaletteContents(
                projects: model.projects, availableProjects: model.projects, preferredProject: model.project?.id,
                threads: [], activeThread: model.conversation?.id, canStartScratchThread: model.canStartScratchThread
            )
        }

        private static let helper = #"""
            while IFS= read -r command; do
                case "$command" in
                    *'"type":"open"'*) printf '{"type":"ready","messages":[]}\n' ;;
                esac
            done
            """#
    }
}
