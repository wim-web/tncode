import Foundation
import XCTest
@testable import PiWorkspace

final class ProjectPathSuggestionsTests: XCTestCase {
    func testTabCompletesCommonPrefixesAndEntersTheHighlightedDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDirectory("Palette Alpha/Leaf One", in: root)
        try makeDirectory("Palette Alpine", in: root)
        try makeDirectory("Palette Beta", in: root)
        let listing = try await ProjectPathSuggestions.Listing.load(root)

        let partial = try XCTUnwrap(ProjectPathSuggestions(path: root.path + "/pal", basePath: nil))
        let rows = partial.rows(in: listing)
        XCTAssertEqual(rows, [.parent, .folder("Palette Alpha"), .folder("Palette Alpine"), .folder("Palette Beta")])
        XCTAssertEqual(partial.tabCompletion(in: rows, highlighted: nil), root.path + "/Palette ")
        XCTAssertEqual(partial.tabCompletion(in: rows, highlighted: .folder("Palette Beta")),
                       root.path + "/Palette Beta/")

        let shared = try relativeSuggestions("palette al", in: root)
        XCTAssertEqual(shared.tabCompletion(in: shared.rows(in: listing), highlighted: nil), "Palette Alp")
        let unchanged = try relativeSuggestions("Palette Alp", in: root)
        XCTAssertNil(unchanged.tabCompletion(in: unchanged.rows(in: listing), highlighted: nil))
        let unique = try relativeSuggestions("./palette alph", in: root)
        XCTAssertEqual(unique.tabCompletion(in: unique.rows(in: listing), highlighted: nil), "./Palette Alpha/")

        let inside = try relativeSuggestions("./Palette Alpha/", in: root)
        let children = try await ProjectPathSuggestions.Listing.load(inside.directory)
        let childRows = inside.rows(in: children)
        XCTAssertEqual(childRows, [.parent, .folder("Leaf One")])
        XCTAssertEqual(inside.tabCompletion(in: childRows, highlighted: nil), "./Palette Alpha/Leaf One/")
        XCTAssertEqual(inside.tabCompletion(in: childRows, highlighted: .parent), "./")
    }

    func testHiddenDirectoriesRequireADotAndOnlyLiveDirectoryLinksAreListed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDirectory(".hidden folder", in: root)
        try makeDirectory("Café", in: root)
        let file = root.appendingPathComponent("notes.txt")
        try Data().write(to: file)
        let manager = FileManager.default
        try manager.createSymbolicLink(at: root.appendingPathComponent("Folder Link"),
                                       withDestinationURL: root.appendingPathComponent("Café"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("File Link"), withDestinationURL: file)
        try manager.createSymbolicLink(at: root.appendingPathComponent("Broken Link"),
                                       withDestinationURL: root.appendingPathComponent("missing"))
        let listing = try await ProjectPathSuggestions.Listing.load(root)

        let all = try relativeSuggestions("", in: root)
        XCTAssertEqual(all.rows(in: listing), [.folder("Café"), .folder("Folder Link")])
        let hidden = try relativeSuggestions(".hid", in: root)
        XCTAssertEqual(hidden.tabCompletion(in: hidden.rows(in: listing), highlighted: nil), ".hidden folder/")
        let unicode = try relativeSuggestions("CAFE\u{0301}", in: root)
        XCTAssertEqual(unicode.tabCompletion(in: unicode.rows(in: listing), highlighted: nil), "Café/")
        let link = try relativeSuggestions("folder l", in: root)
        let linkPath = try XCTUnwrap(link.tabCompletion(in: link.rows(in: listing), highlighted: nil))
        let target = try ProjectFolder.existing(at: ProjectFolder.resolve(linkPath, relativeTo: root.path))
        XCTAssertEqual(target.lastPathComponent, "Café")
    }

    func testNoMatchOrDisappearingDirectoryLeavesThePathEditable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDirectory("Gone/Deeper", in: root)
        let listing = try await ProjectPathSuggestions.Listing.load(root)
        let partial = try relativeSuggestions("zz", in: root)
        XCTAssertNil(partial.tabCompletion(in: partial.rows(in: listing), highlighted: nil))
        XCTAssertNil(ProjectPathSuggestions(path: "zz", basePath: nil))

        let inside = try relativeSuggestions("Gone/", in: root)
        try FileManager.default.removeItem(at: inside.directory)
        let staleRows = inside.rows(in: listing)
        XCTAssertEqual(staleRows, [.parent])
        XCTAssertNil(inside.tabCompletion(in: staleRows, highlighted: nil))
        XCTAssertEqual(inside.tabCompletion(in: staleRows, highlighted: .parent), "./")
        do {
            _ = try await ProjectPathSuggestions.Listing.load(inside.directory)
            XCTFail("Listed a directory that was removed")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadNoSuchFile)
        }
    }

    func testCancellationDiscardsTheListingAndLeavesTheDirectoryIntact() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDirectory("Keep Me", in: root)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProjectPathSuggestions.Listing.load(root)
        }

        do {
            _ = try await cancelled.value
            XCTFail("Returned a directory listing after cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["Keep Me"])
    }

    private func relativeSuggestions(_ path: String, in root: URL) throws -> ProjectPathSuggestions {
        try XCTUnwrap(ProjectPathSuggestions(path: path, basePath: root.path))
    }

    private func makeDirectory(_ name: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name, isDirectory: true),
                                                withIntermediateDirectories: true)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
