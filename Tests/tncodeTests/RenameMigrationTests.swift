import Darwin
import Foundation
@testable import tncode
import XCTest

final class RenameMigrationTests: XCTestCase {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameMigrationTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    private func makeLegacyFolder(in base: URL) throws -> URL {
        let legacy = base.appendingPathComponent(RenameMigration.legacySupportFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("workspace.json"))
        FileManager.default.createFile(atPath: legacy.appendingPathComponent(".lock").path, contents: nil)
        return legacy
    }

    func testFormerDataFolderMovesToTheNewName() throws {
        let base = try makeBase()
        let legacy = try makeLegacyFolder(in: base)

        let root = RenameMigration.supportDirectory(in: base)

        XCTAssertEqual(root.lastPathComponent, "tncode")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testExistingDataFolderIsKeptAndTheFormerOneIsLeftAlone() throws {
        let base = try makeBase()
        let legacy = try makeLegacyFolder(in: base)
        let current = base.appendingPathComponent("tncode", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

        XCTAssertEqual(RenameMigration.supportDirectory(in: base), current)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("workspace.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.appendingPathComponent("workspace.json").path))
    }

    func testFormerFolderStaysInUseWhileAFormerBuildHoldsItsLock() throws {
        let base = try makeBase()
        let legacy = try makeLegacyFolder(in: base)
        let lock = open(legacy.appendingPathComponent(".lock").path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)

        XCTAssertEqual(RenameMigration.supportDirectory(in: base), legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("tncode").path))
    }

    func testFormerPreferencesAreCopiedOnceWithoutReplacingNewOnes() throws {
        let domain = "dev.tncode.rename-tests.\(UUID().uuidString)"
        let legacyDomain = "dev.piworkspace.rename-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: domain)
            defaults.removePersistentDomain(forName: legacyDomain)
        }
        defaults.setPersistentDomain([
            "appearance.darkTheme": "ocean", "chat.sendShortcut": "enter", "PiWorkspaceLanguage": "ja"
        ], forName: legacyDomain)
        defaults.setPersistentDomain(["chat.sendShortcut": "modifier"], forName: domain)

        RenameMigration.migrateDefaults(defaults, domain: domain, legacyDomain: legacyDomain)

        var migrated = try XCTUnwrap(defaults.persistentDomain(forName: domain))
        XCTAssertEqual(migrated["appearance.darkTheme"] as? String, "ocean")
        XCTAssertEqual(migrated["chat.sendShortcut"] as? String, "modifier")
        XCTAssertEqual(migrated[AppLanguage.key] as? String, "ja")
        XCTAssertNil(migrated["PiWorkspaceLanguage"])

        migrated["appearance.darkTheme"] = "forest"
        defaults.setPersistentDomain(migrated, forName: domain)
        RenameMigration.migrateDefaults(defaults, domain: domain, legacyDomain: legacyDomain)
        XCTAssertEqual(defaults.persistentDomain(forName: domain)?["appearance.darkTheme"] as? String, "forest")
    }

    func testThreadAndDraftLinksCopiedBeforeTheRenameStillOpen() throws {
        let root = URL(fileURLWithPath: "/tmp/rename-tests", isDirectory: true)
        let workspaceID = UUID()
        let thread = ThreadLink(workspaceID: workspaceID, root: root, projectID: UUID(), threadID: UUID())
        let draft = DraftLink(workspaceID: workspaceID, root: root, draftID: UUID())
        XCTAssertTrue(thread.text.hasPrefix("tncode://thread/"))

        let formerThread = try XCTUnwrap(ThreadLink(text: thread.text.replacingOccurrences(of: "tncode://", with: "pi-workspace://")))
        XCTAssertEqual(formerThread.workspace, thread.workspace)
        XCTAssertEqual(formerThread.projectID, thread.projectID)
        XCTAssertEqual(formerThread.threadID, thread.threadID)

        let formerDraft = try XCTUnwrap(DraftLink(text: draft.text.replacingOccurrences(of: "tncode://", with: "PI-WORKSPACE://")))
        XCTAssertEqual(formerDraft.draftID, draft.draftID)
        XCTAssertNil(ThreadLink(text: thread.text.replacingOccurrences(of: "tncode://", with: "other://")))
    }
}
