import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class WorkspaceRecoveryTests: XCTestCase {
    func testFirstLaunchWithoutAnIndexShowsWelcome() async throws {
        let fixture = try Fixture()
        let model = fixture.open()

        XCTAssertNil(model.startupFailure)
        XCTAssertTrue(model.showingWelcome)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.index.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previous.path))
    }

    func testLegacyIndexLoadsWithoutRewritingIt() async throws {
        let fixture = try Fixture()
        let project = UUID()
        let thread = UUID()
        let legacy = Data("""
            {
              "projects": [{
                "id": "\(project)", "path": "/fixture", "title": "Legacy", "allowEdits": false,
                "conversations": [{"id": "\(thread)", "title": "Previous thread", "archived": false}],
                "selectedConversation": "\(thread)"
              }],
              "selectedProject": "\(project)",
              "model": {"provider":"openai","model":"gpt-5-mini","endpoint":"","contextWindow":8192}
            }
            """.utf8)
        try legacy.write(to: fixture.index)
        let store = try WorkspaceStore(root: fixture.root)
        let workspace = try store.load()

        XCTAssertEqual(workspace.activeProject?.id, project)
        XCTAssertEqual(workspace.activeProject?.selectedConversation, thread)
        XCTAssertEqual(workspace.activeProject?.conversations.first?.workingLocation, .project)
        try store.save(workspace)
        XCTAssertEqual(try Data(contentsOf: fixture.index), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previous.path))
    }

    func testSaveRetainsOnlyThePreviousValidIndexAndSkipsUnchangedSaves() async throws {
        let fixture = try Fixture()
        let store = try WorkspaceStore(root: fixture.root)
        var workspace = Workspace()
        workspace.model.model = "first"
        try store.save(workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.previous.path))
        let first = try Data(contentsOf: fixture.index)

        workspace.model.model = "second"
        try store.save(workspace)
        XCTAssertEqual(try Data(contentsOf: fixture.previous), first)
        let second = try Data(contentsOf: fixture.index)

        workspace.model.model = "third"
        try store.save(workspace)
        try store.save(workspace)
        XCTAssertEqual(try store.load().model.model, "third")
        XCTAssertEqual(try Data(contentsOf: fixture.previous), second)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)),
                       [".lock", "workspace.json", "workspace.previous.json"])
    }

    func testSaveFailureLeavesTheCurrentIndexReadable() async throws {
        let fixture = try Fixture()
        let store = try WorkspaceStore(root: fixture.root)
        try store.save(Workspace())
        let original = try Data(contentsOf: fixture.index)
        try FileManager.default.createDirectory(at: fixture.previous, withIntermediateDirectories: false)
        var updated = Workspace()
        updated.model.model = "updated"

        XCTAssertThrowsError(try store.save(updated))
        XCTAssertEqual(try Data(contentsOf: fixture.index), original)
        XCTAssertEqual(try store.load().model.model, Workspace().model.model)
    }

    func testCorruptIndexWithNoValidBackupRemainsInRecovery() async throws {
        let fixture = try Fixture()
        let corrupt = Data([0xff, 0x00, 0x01])
        try corrupt.write(to: fixture.index)
        do {
            let store = try WorkspaceStore(root: fixture.root)
            XCTAssertThrowsError(try store.save(Workspace()))
        }
        let model = fixture.open()
        assertInvalidIndex(model, canRestore: false)

        try Data("{}".utf8).write(to: fixture.previous)
        model.openWorkspace(restoringPrevious: true)
        assertInvalidIndex(model, canRestore: false)
        XCTAssertEqual(try Data(contentsOf: fixture.index), corrupt)
        XCTAssertTrue(try fixture.archives().isEmpty)
    }

    func testRecoveryValidatesAgainAndPreservesCorruptBytesAndSessions() async throws {
        let fixture = try Fixture()
        let project = Project(id: UUID(), path: "/fixture", title: "Earlier project")
        let session = try fixture.seedBackup(for: project)
        let previous = try Data(contentsOf: fixture.previous)
        let corrupt = Data("{truncated".utf8)
        try corrupt.write(to: fixture.index)

        let model = fixture.open()
        assertInvalidIndex(model, canRestore: true)
        model.openWorkspace()
        assertInvalidIndex(model, canRestore: true)
        XCTAssertEqual(try Data(contentsOf: fixture.index), corrupt)

        try Data("null".utf8).write(to: fixture.previous)
        model.openWorkspace(restoringPrevious: true)
        assertInvalidIndex(model, canRestore: false)
        XCTAssertTrue(try fixture.archives().isEmpty)

        try previous.write(to: fixture.previous)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fixture.index.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fixture.index.path) }
        model.openWorkspace(restoringPrevious: true)
        guard case let .access(file, _)? = model.startupFailure else {
            return XCTFail("Expected the index replacement to fail")
        }
        XCTAssertEqual(file, fixture.index)
        XCTAssertEqual(try Data(contentsOf: fixture.index), corrupt)
        let archives = try fixture.archives()
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archives.first)), corrupt)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fixture.index.path)
        model.openWorkspace()
        assertInvalidIndex(model, canRestore: true)
        model.openWorkspace(restoringPrevious: true)
        XCTAssertNil(model.startupFailure)
        XCTAssertEqual(model.project?.id, project.id)
        XCTAssertEqual(model.project?.title, "Earlier project")
        XCTAssertEqual(try Data(contentsOf: fixture.index), previous)
        XCTAssertEqual(try Data(contentsOf: fixture.previous), previous)
        XCTAssertEqual(try Data(contentsOf: session), Data("fixture session".utf8))
        XCTAssertEqual(try fixture.archives(), archives)
    }

    func testMissingCurrentIndexWithBackupRequiresExplicitRestore() async throws {
        let fixture = try Fixture()
        _ = try fixture.seedBackup(for: Project(id: UUID(), path: "/fixture", title: "Previous"))
        try FileManager.default.removeItem(at: fixture.index)
        let model = fixture.open()
        guard case .invalidIndex(missing: true, canRestore: true, _)? = model.startupFailure else {
            return XCTFail("Expected a missing index with a recoverable backup")
        }

        model.openWorkspace(restoringPrevious: true)
        XCTAssertNil(model.startupFailure)
        XCTAssertEqual(model.project?.title, "Previous")
        XCTAssertTrue(try fixture.archives().isEmpty)
    }

    func testRestorePreservesAnIndexRepairedBeforeTheAction() async throws {
        let fixture = try Fixture()
        _ = try fixture.seedBackup(for: Project(id: UUID(), path: "/fixture", title: "Previous"))
        let repaired = try Data(contentsOf: fixture.index)
        try Data("{truncated".utf8).write(to: fixture.index)
        let model = fixture.open()
        assertInvalidIndex(model, canRestore: true)

        try repaired.write(to: fixture.index, options: .atomic)
        model.openWorkspace(restoringPrevious: true)
        XCTAssertNil(model.startupFailure)
        XCTAssertEqual(model.project?.title, "Current project")
        XCTAssertEqual(try Data(contentsOf: fixture.index), repaired)
        XCTAssertTrue(try fixture.archives().isEmpty)
    }

    func testReadPermissionFailureIsDistinctFromCorruptionAndCanRetry() async throws {
        try XCTSkipIf(geteuid() == 0, "Root can read the fixture without file permissions")
        let fixture = try Fixture()
        _ = try fixture.seedBackup(for: Project(id: UUID(), path: "/fixture", title: "Previous"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.index.path)
        let model = fixture.open()
        guard case .access(let file, _)? = model.startupFailure else {
            return XCTFail("Expected an index access error")
        }
        XCTAssertEqual(file, fixture.index)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.index.path)
        model.openWorkspace()
        XCTAssertNil(model.startupFailure)
        XCTAssertEqual(model.project?.title, "Current project")
    }

    func testSecondInstanceCanRetryAfterTheOwnerReleasesTheLock() async throws {
        let fixture = try Fixture()
        var owner: WorkspaceStore? = try WorkspaceStore(root: fixture.root)
        var workspace = Workspace()
        workspace.model.model = "owned workspace"
        try XCTUnwrap(owner).save(workspace)

        let second = fixture.open()
        guard case .inUse? = second.startupFailure else { return XCTFail("Expected a lock conflict") }
        XCTAssertEqual(try owner?.load().model.model, "owned workspace")
        owner = nil

        second.openWorkspace()
        XCTAssertNil(second.startupFailure)
        XCTAssertEqual(second.workspace.model.model, "owned workspace")
    }

    func testCopyDetailsAndQuitInIsolatedApp() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["PI_WORKSPACE_RECOVERY_FIXTURE"] {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let scenario = try XCTUnwrap(environment["PI_WORKSPACE_RECOVERY_SCENARIO"])
            let board = try XCTUnwrap(environment["PI_WORKSPACE_RECOVERY_PASTEBOARD"])
            try await exerciseRecovery(in: root, scenario: scenario, pasteboard: NSPasteboard(name: .init(board)))
            return
        }

        for scenario in ["corrupt", "missing", "locked", "access", "corrupt-with-unreadable-backup"] {
            let fixture = try Fixture()
            let projectPath = fixture.root.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: false)
            let project = Project(id: UUID(), path: projectPath.path, title: "Earlier project")
            _ = try fixture.seedBackup(for: project)
            let validIndex = try Data(contentsOf: fixture.index)
            let validPrevious = try Data(contentsOf: fixture.previous)
            let target = fixture.root.appendingPathComponent("fixture-private-symlink-target")
            var owner: WorkspaceStore?
            switch scenario {
            case "missing": try FileManager.default.removeItem(at: fixture.index)
            case "locked": owner = try WorkspaceStore(root: fixture.root)
            case "access", "corrupt-with-unreadable-backup":
                let inaccessible = scenario == "access" ? fixture.index : fixture.previous
                try FileManager.default.moveItem(at: inaccessible, to: target)
                try FileManager.default.createSymbolicLink(at: inaccessible, withDestinationURL: target)
            default: break
            }
            if scenario.hasPrefix("corrupt") {
                try Data("{fixture-private-index-bytes".utf8).write(to: fixture.index)
            }

            let before = try storageSnapshot(fixture.root)
            let board = NSPasteboard(name: .init("dev.piworkspace.verification.\(UUID())"))
            defer { board.releaseGlobally() }
            let terminated = fixture.root.appendingPathExtension("terminated")
            defer { try? FileManager.default.removeItem(at: terminated) }
            try runRecoveryHost(root: fixture.root, scenario: scenario, pasteboard: board)
            XCTAssertTrue(FileManager.default.fileExists(atPath: terminated.path), "Quit did not terminate AppKit for \(scenario)")
            let details = try XCTUnwrap(board.string(forType: .string), scenario)
            assertCopiedDetails(details, scenario: scenario, root: fixture.root)
            XCTAssertEqual(try storageSnapshot(fixture.root), before, "Copy or Quit changed storage for \(scenario)")

            withExtendedLifetime(owner) {}
            owner = nil
            if scenario == "access" || scenario == "corrupt-with-unreadable-backup" {
                try FileManager.default.removeItem(at: scenario == "access" ? fixture.index : fixture.previous)
                try FileManager.default.removeItem(at: target)
            }
            try validIndex.write(to: fixture.index)
            try validPrevious.write(to: fixture.previous)
            let repaired = try storageSnapshot(fixture.root)
            try runRecoveryHost(root: fixture.root, scenario: "relaunch", pasteboard: board)
            XCTAssertEqual(try storageSnapshot(fixture.root), repaired, "Opening the repaired workspace changed storage")
        }
    }

    private func runRecoveryHost(root: URL, scenario: String, pasteboard: NSPasteboard) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "PiWorkspaceTests.WorkspaceRecoveryTests/testCopyDetailsAndQuitInIsolatedApp",
                             Bundle(for: Self.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment["XCTestSessionIdentifier"] = nil
        environment["PI_WORKSPACE_RECOVERY_FIXTURE"] = root.path
        environment["PI_WORKSPACE_RECOVERY_SCENARIO"] = scenario
        environment["PI_WORKSPACE_RECOVERY_PASTEBOARD"] = pasteboard.name.rawValue
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit, scenario)
        XCTAssertEqual(process.terminationStatus, 0, scenario)
    }

    private func exerciseRecovery(in root: URL, scenario: String, pasteboard: NSPasteboard) async throws {
        let model = WorkspaceModel(root: root, keychainService: "dev.piworkspace.recovery-fixture", readCredential: { _ in
            throw WorkspaceError("Model credentials are unavailable in the recovery fixture.")
        })
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        guard app.activationPolicy() == .prohibited else { throw WorkspaceError("The native host could not disable activation.") }
        let delegate = WorkspaceApplicationDelegate()
        delegate.model = model
        app.delegate = delegate
        defer { app.delegate = nil }
        app.finishLaunching()
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 1200, y: 0)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 800, height: 540)),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host: NSView
        if scenario == "relaunch" {
            XCTAssertNil(model.startupFailure)
            XCTAssertEqual(model.project?.title, "Current project")
            XCTAssertEqual(model.conversation?.title, "Conversation")
            host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable, workspacePasteboard: pasteboard))
        } else {
            let failure = try XCTUnwrap(model.startupFailure)
            host = NSHostingView(rootView: WorkspaceStartupRecoveryView(model: model, failure: failure, pasteboard: pasteboard))
        }
        panel.contentView = host
        panel.setFrameOrigin(origin)
        guard NSScreen.screens.allSatisfy({ !$0.frame.intersects(panel.frame) }) else {
            throw WorkspaceError("The recovery panel must stay offscreen.")
        }
        panel.orderBack(nil)
        defer { panel.close() }

        if scenario == "relaunch" {
            _ = try await element("sidebar-home", in: host)
            return
        }

        pasteboard.clearContents()
        try await press("workspace-startup-copy-details", in: host)
        let terminated = root.appendingPathExtension("terminated")
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: app, queue: nil) { _ in
            try? Data().write(to: terminated)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await press("workspace-startup-quit", in: host)
        try await Task.sleep(for: .seconds(2))
        XCTFail("Quit did not exit the recovery host")
    }

    private func assertCopiedDetails(_ details: String, scenario: String, root: URL) {
        let info = AboutInfo()
        let product = [info.name, info.version].compactMap { $0 }.joined(separator: " ")
        XCTAssertTrue(details.hasPrefix("\(product) (macOS "))
        #if arch(arm64)
        XCTAssertTrue(details.contains(" arm64)"))
        #elseif arch(x86_64)
        XCTAssertTrue(details.contains(" x86_64)"))
        #endif
        XCTAssertTrue(details.contains("\nWorkspace: \(root.path)\n"))
        XCTAssertFalse(details.contains("fixture-private-"))
        XCTAssertFalse(details.contains("fixture session"))
        XCTAssertFalse(details.contains("Current project"))
        switch scenario {
        case "locked":
            XCTAssertTrue(details.contains("This workspace is open in another Pi Workspace process."))
            XCTAssertTrue(details.contains("Lock: \(root.path)/.lock"))
            XCTAssertTrue(details.contains("NSPOSIXErrorDomain \(EWOULDBLOCK):"))
        case "access":
            XCTAssertTrue(details.contains("Could not access workspace.json."))
            XCTAssertTrue(details.contains("Path: \(root.path)/workspace.json"))
            XCTAssertTrue(details.contains("NSPOSIXErrorDomain \(ELOOP):"))
        default:
            XCTAssertTrue(details.contains(scenario == "missing" ? "The workspace index is missing." : "The workspace index is damaged."))
            XCTAssertTrue(details.contains("\nIndex: \(root.path)/workspace.json\nPrevious index: \(root.path)/workspace.previous.json"))
            if scenario == "corrupt-with-unreadable-backup" {
                XCTAssertTrue(details.contains("A readable, valid previous index is unavailable."))
                XCTAssertTrue(details.contains("NSPOSIXErrorDomain \(ELOOP):"))
            }
        }
    }

    private func press(_ id: String, in host: NSView) async throws {
        let button = try await element(id, in: host)
        guard button.accessibilityPerformPress?() == true else { throw WorkspaceError("Could not AXPress \(id)") }
    }

    private func element(_ id: String, in host: NSView) async throws -> AnyObject {
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            var visited = Set<ObjectIdentifier>()
            func find(_ element: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
                if element.accessibilityIdentifier?() == id { return element }
                for child in element.accessibilityChildren?() ?? [] {
                    if let found = find(child as AnyObject) { return found }
                }
                return nil
            }
            if let element = find(host) { return element }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WorkspaceError("Missing AX element \(id)")
    }

    private func storageSnapshot(_ root: URL) throws -> [String: Data] {
        let fs = FileManager.default
        var snapshot: [String: Data] = [:]
        for path in try fs.subpathsOfDirectory(atPath: root.path) {
            let file = root.appendingPathComponent(path)
            switch try fs.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType {
            case .typeDirectory: snapshot[path + "/"] = Data()
            case .typeSymbolicLink: snapshot[path] = Data(try fs.destinationOfSymbolicLink(atPath: file.path).utf8)
            default: snapshot[path] = try Data(contentsOf: file)
            }
        }
        return snapshot
    }

    private func assertInvalidIndex(_ model: WorkspaceModel, canRestore expected: Bool,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard case let .invalidIndex(missing, canRestore, _)? = model.startupFailure else {
            return XCTFail("Expected a damaged index", file: file, line: line)
        }
        XCTAssertFalse(missing, file: file, line: line)
        XCTAssertEqual(canRestore, expected, file: file, line: line)
    }

    private final class Fixture {
        let root: URL
        var index: URL { root.appendingPathComponent("workspace.json") }
        var previous: URL { root.appendingPathComponent("workspace.previous.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @MainActor
        func open() -> WorkspaceModel {
            WorkspaceModel(root: root, keychainService: "dev.piworkspace.recovery-test")
        }

        func seedBackup(for project: Project) throws -> URL {
            let store = try WorkspaceStore(root: root)
            var project = project
            let thread = Conversation(id: UUID(), title: "Conversation")
            project.conversations = [thread]
            project.selectedConversation = thread.id
            var workspace = Workspace(projects: [project], selectedProject: project.id)
            try store.save(workspace)
            workspace.projects[0].title = "Current project"
            try store.save(workspace)
            let directory = store.history(project: project.id, conversation: thread.id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = directory.appendingPathComponent("fixture.jsonl")
            try Data("fixture session".utf8).write(to: session)
            return session
        }

        func archives() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("workspace.corrupt-") }
        }
    }
}
