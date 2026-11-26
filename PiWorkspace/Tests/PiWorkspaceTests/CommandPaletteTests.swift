import AppKit
import Carbon
import XCTest
@testable import PiWorkspace

@MainActor
final class CommandPaletteTests: XCTestCase {
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

    func testFolderPickerAndActiveTurnBlockInvocation() async throws {
        let fixture = try Fixture()
        _ = try fixture.openProject("Alpha")
        let model = fixture.model
        defer { model.terminate() }
        var requests = 0
        let observation = model.sidebarCommand.sink { _ in requests += 1 }
        defer { observation.cancel() }
        model.openFolder()
        XCTAssertNotNil(model.projectPicker)
        model.requestCommandPalette()
        XCTAssertEqual(requests, 0)
        model.projectPicker = nil

        let ready = expectation(description: "Disposable helper is ready")
        let readyObservation = model.$phase.first { $0 == .ready }.sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 4)
        readyObservation.cancel()
        model.requestCommandPalette()
        XCTAssertEqual(requests, 1)

        model.draft = "Start a local fixture turn"
        model.send()
        XCTAssertEqual(model.phase, .running)
        model.requestCommandPalette()
        XCTAssertEqual(requests, 1)
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
