import Foundation
import XCTest
@testable import PiWorkspace

final class WorktreeDirectoryTests: XCTestCase {
    func testResolvesHomeAndValidatesPathOnThisHost() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(try WorktreeDirectory.resolve("~", home: home).path, home.path)
        XCTAssertEqual(try WorktreeDirectory.resolve("~\\Worktrees", home: home).path, "/Users/example/Worktrees")
        XCTAssertEqual(try WorktreeDirectory.resolve("~/storage/../Worktrees/", home: home).path,
                       "/Users/example/Worktrees")
        for path in ["relative/worktrees", "D:\\worktrees", "/", "/tmp/..", "/tmp/bad\0path"] {
            XCTAssertThrowsError(try WorktreeDirectory.resolve(path, home: home), path)
        }
    }

    func testPastingFinderPathsReplacesThePreviousFolder() {
        XCTAssertEqual(WorktreeDirectory.replacingPastedPath(previous: "~/", next: "~/'/tmp/Work Trees'"),
                       "/tmp/Work Trees")
        XCTAssertEqual(WorktreeDirectory.replacingPastedPath(previous: "", next: #"/tmp/A\ B"#), "/tmp/A B")
        XCTAssertEqual(WorktreeDirectory.replacingPastedPath(previous: "", next: #"'/tmp/A'\''s Tree'"#),
                       "/tmp/A's Tree")
        XCTAssertEqual(WorktreeDirectory.replacingPastedPath(previous: "/tmp/", next: "/tmp/W"), "/tmp/W")
    }

    func testCustomRootMayBeASymlinkButItsProjectFolderCannotEscapeIt() throws {
        let files = FileManager.default
        let fixture = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: fixture) }
        let actual = fixture.appendingPathComponent("storage")
        try files.createDirectory(at: actual, withIntermediateDirectories: false)
        let outside = fixture.appendingPathComponent("unowned")
        try files.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = fixture.appendingPathComponent("location")
        try files.createSymbolicLink(at: link, withDestinationURL: actual)
        let store = try WorkspaceStore(root: fixture.appendingPathComponent("workspace"))
        let project = UUID()
        let thread = UUID()
        let chosen = link.appendingPathComponent("new storage")
        let expectedParent = actual.appendingPathComponent("new storage").appendingPathComponent(project.uuidString)
        XCTAssertEqual(try store.worktree(project: project, conversation: thread, directory: chosen.path).path,
                       expectedParent.appendingPathComponent(thread.uuidString).path)

        try files.removeItem(at: expectedParent)
        try files.createSymbolicLink(at: expectedParent, withDestinationURL: outside)
        XCTAssertThrowsError(try store.worktree(project: project, conversation: thread, directory: chosen.path))
        XCTAssertEqual(try files.contentsOfDirectory(atPath: outside.path), [])
    }
}
