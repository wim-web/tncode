import AppKit
import CoreText
import Darwin
import Foundation
import Observation
import PDFKit
import SwiftUI
import XCTest
@testable import PiWorkspace

final class WorkspaceFilesTests: XCTestCase {
    func testTreeSearchAndRefreshStayInsideTheSelectedDirectory() throws {
        try withFixture { root in
            let checkout = try folder("checkout", in: root)
            let sources = try folder("Sources", in: checkout)
            let outside = try folder("sibling", in: root)
            try write("outside", "Outside.swift", in: outside)
            try write("source", "Content.swift", in: sources)
            try write("notes", "notes.md", in: checkout)
            try write("git metadata", ".git", in: checkout)
            try FileManager.default.createSymbolicLink(at: checkout.appendingPathComponent("Escape"),
                                                       withDestinationURL: outside)
            let files = WorkspaceFiles(directory: checkout.path)

            let tree = try files.tree()
            XCTAssertEqual(tree.entries.map(\.path), ["Sources", "Sources/Content.swift", "Escape", "notes.md"])
            XCTAssertEqual(tree.matching("sources/con").map(\.path), ["Sources/Content.swift"])
            XCTAssertTrue(tree.matching("outside").isEmpty)
            XCTAssertThrowsError(try files.preview("Escape/Outside.swift"))
            XCTAssertThrowsError(try files.preview("../sibling/Outside.swift"))
            XCTAssertThrowsError(try files.preview(".git"))

            try FileManager.default.removeItem(at: checkout.appendingPathComponent("notes.md"))
            try write("new", "added.md", in: checkout)
            XCTAssertEqual(try files.tree().matching(".md").map(\.path), ["added.md"])
            XCTAssertThrowsError(try files.preview("notes.md")) {
                XCTAssertEqual($0 as? WorkspaceFileError, .missing)
            }
        }
    }

    func testRegularReadOnlyLargeAndBinaryPreviews() throws {
        try withFixture { root in
            let files = WorkspaceFiles(directory: root.path)
            let readOnly = try write("read only\n", "readonly.txt", in: root)
            XCTAssertEqual(chmod(readOnly.path, 0o444), 0)
            let ordinary = try text("readonly.txt", in: files)
            XCTAssertEqual(ordinary.text, "read only\n")
            XCTAssertFalse(ordinary.writable)

            // The preview limit lands inside a multi-byte character.
            let largePrefix = String(repeating: "a", count: WorkspaceFiles.textLimit - 1)
            try write(largePrefix + "é\nlast line", "large.txt", in: root)
            guard case let .largeText(large) = try files.preview("large.txt") else {
                return XCTFail("Expected a bounded text preview.")
            }
            let page = try large.page(containing: 2)
            XCTAssertEqual(page.lines, [String(largePrefix.prefix(WorkspaceLargeTextPage.lineByteLimit)), "last line"])
            XCTAssertTrue(page.hasClippedLines)
            XCTAssertEqual(large.size, Int64(WorkspaceFiles.textLimit + 11))

            let bytes = Data([0x50, 0x00, 0x80, 0xFF])
            try bytes.write(to: root.appendingPathComponent("binary.dat"))
            guard case let .binary(prefix, size) = try files.preview("binary.dat") else {
                return XCTFail("Expected a binary preview.")
            }
            XCTAssertEqual(prefix, bytes)
            XCTAssertEqual(size, 4)
        }
    }

    func testLargeTextPagesKeepUTF8AndCRLFBoundaries() throws {
        try withFixture { root in
            let files = WorkspaceFiles(directory: root.path)
            let limit = WorkspaceLargeTextPage.lineByteLimit
            let prefix = String(repeating: "a", count: limit - 1)
            // The UTF-8 scalar crosses the display limit and CRLF crosses the 64 KiB read boundary.
            let longLine = prefix + "🙂" + String(repeating: "a", count: 65_535 - prefix.utf8.count - 4)
            let laterLine = String(repeating: "界", count: WorkspaceFiles.textLimit / 3)
            try write(longLine + "\r\n\rline 3\n" + String(repeating: "row\n", count: 28)
                      + "line 32\r\n" + laterLine + "\r\u{FEFF}last 🙂", "large.txt", in: root)
            guard case let .largeText(large) = try files.preview("large.txt") else {
                return XCTFail("Expected a large text preview.")
            }

            let first = try large.page(containing: 1)
            XCTAssertEqual(first.lines.prefix(3), [prefix, "", "line 3"])
            XCTAssertEqual(first.lastLine, 32)
            XCTAssertEqual(first.lines.last, "line 32")
            XCTAssertTrue(first.hasNext)
            XCTAssertTrue(first.hasClippedLines)
            let next = try large.page(containing: 34, after: first)
            XCTAssertEqual(next.firstLine, 33)
            XCTAssertEqual(next.lines, [String(laterLine.prefix(limit / 3)), "\u{FEFF}last 🙂"])
            XCTAssertEqual(try large.page(containing: 34).lines, next.lines)
            XCTAssertTrue(next.hasClippedLines)
            XCTAssertFalse(next.hasNext)
            for line in [0, 35, Int64.max] {
                XCTAssertThrowsError(try large.page(containing: line)) {
                    XCTAssertEqual($0 as? WorkspaceLargeTextError, .lineNotFound)
                }
            }
        }
    }

    @MainActor
    func testLargeTextGoToLineUsesTheOpenCheckoutAndReloadsOffscreen() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try folder("local", in: root)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        let path = "trace.txt"
        let line = 6_000
        let padding = String(repeating: String(repeating: "α", count: 96) + "\r\n", count: line - 1)
        let tail = String(repeating: "\nnext", count: 64)
        let localMarker = "DEV-153 local marker 🙂"
        let refreshedMarker = "DEV-153 refreshed marker 🙂"
        let linkedMarker = "DEV-153 linked marker 🙂"
        XCTAssertEqual(padding.utf8.count, 1_163_806)
        let file = try write(padding + localMarker + tail, path, in: local)
        _ = try git(local, ["init", "-q"])
        _ = try git(local, ["add", "--", path])
        _ = try git(local, ["commit", "-qm", "Large preview fixture"])
        _ = try git(local, ["worktree", "add", "--detach", "--", linked.path, "HEAD"])
        let linkedFile = try write(padding + linkedMarker + tail, path, in: linked)
        let project = Project(id: UUID(), path: local.path, title: "Fixture")
        var thread = Conversation(id: UUID(), title: "Fixture Thread")
        let localLocation = try XCTUnwrap(WorkspaceFilesLocation(thread: thread, project: project))
        thread.location = .worktree(path: linked.path, base: "HEAD")
        let linkedLocation = try XCTUnwrap(WorkspaceFilesLocation(thread: thread, project: project))

        let saves = WorkspaceFileSaves()
        let panel = FilesPanelFixture(location: localLocation, selection: path, saves: saves)
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: FilesPanelFixtureView(fixture: panel))
        host.sizingOptions = []
        window.contentView = host
        defer { window.contentView = nil }

        func contents() -> NSTextView? {
            firstSubview(in: host) {
                guard let view = $0 as? NSTextView, view.accessibilityIdentifier() == "files-contents" else { return nil }
                return view
            }
        }
        func jump() throws {
            let field: NSTextField = try XCTUnwrap(firstSubview(in: host) {
                guard let field = $0 as? NSTextField, field.placeholderString == "Go to Line" else { return nil }
                return field
            })
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.insertText(String(line), replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertNewline(nil)
        }
        func selectedText() -> String? {
            contents().map { ($0.string as NSString).substring(with: $0.selectedRange()) }
        }

        try await waitFor { contents() != nil }
        XCTAssertFalse(try XCTUnwrap(contents()).string.contains(localMarker))
        try jump()
        try await waitFor { selectedText() == localMarker }
        let viewer = try XCTUnwrap(contents())
        XCTAssertFalse(viewer.isEditable)
        let layout = try XCTUnwrap(viewer.layoutManager)
        let container = try XCTUnwrap(viewer.textContainer)
        let start = NSRange(location: viewer.selectedRange().location, length: 1)
        let glyphs = layout.glyphRange(forCharacterRange: start, actualCharacterRange: nil)
        let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
        XCTAssertTrue(viewer.visibleRect.intersects(bounds.offsetBy(dx: viewer.textContainerOrigin.x,
                                                                    dy: viewer.textContainerOrigin.y)))

        // A stale page request detects an atomic replacement. Refresh keeps the requested line.
        let session = saves.acquire(WorkspaceFileTarget(location: localLocation, path: path))
        defer { saves.release(session) }
        try Data((padding + refreshedMarker + tail).utf8).write(to: file, options: .atomic)
        try jump()
        try await waitFor { contents() == nil }
        await session.refresh()
        try await waitFor { selectedText() == refreshedMarker }

        panel.selection = nil
        try await waitFor { contents() == nil }
        panel.selection = path
        try await waitFor { contents() != nil }
        XCTAssertFalse(try XCTUnwrap(contents()).string.contains(refreshedMarker))
        try jump()
        try await waitFor { selectedText() == refreshedMarker }

        panel.location = linkedLocation
        try await waitFor { contents()?.string.hasPrefix("α") == true && selectedText()?.isEmpty == true }
        try jump()
        try await waitFor { selectedText() == linkedMarker }
        XCTAssertFalse(try XCTUnwrap(contents()).string.contains(refreshedMarker))

        // Never reopen a previously approved path through a replacement symlink.
        try FileManager.default.removeItem(at: linkedFile)
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: file)
        try jump()
        try await waitFor { contents() == nil }
    }

    @MainActor
    func testMediaUsesLinkedCheckoutBytesAndRecoversAfterReplacement() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try folder("local", in: root)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        let image = local.appendingPathComponent("sample.PNG")
        let pdf = local.appendingPathComponent("sample.PDF")
        try png(.red).write(to: image)
        try pdfData(["Local first", "Local second"]).write(to: pdf)
        _ = try git(local, ["init", "-q"])
        _ = try git(local, ["add", "--", "sample.PNG", "sample.PDF"])
        _ = try git(local, ["commit", "-qm", "Preview fixtures"])
        _ = try git(local, ["worktree", "add", "--detach", "--", linked.path, "HEAD"])
        let linkedImage = linked.appendingPathComponent(image.lastPathComponent)
        let linkedPDF = linked.appendingPathComponent(pdf.lastPathComponent)
        try png(.blue).write(to: linkedImage)
        try pdfData(["Linked first", "Linked second"]).write(to: linkedPDF)

        let project = Project(id: UUID(), path: local.path, title: "Fixture")
        var thread = Conversation(id: UUID(), title: "Fixture Thread")
        let localLocation = try XCTUnwrap(WorkspaceFilesLocation(thread: thread, project: project))
        thread.location = .worktree(path: linked.path, base: "HEAD")
        let linkedLocation = try XCTUnwrap(WorkspaceFilesLocation(thread: thread, project: project))
        let saves = WorkspaceFileSaves()
        let imageTarget = WorkspaceFileTarget(location: linkedLocation, path: image.lastPathComponent)
        let imageSession = saves.acquire(imageTarget)
        await imageSession.refresh()
        let blue = try previewImage(try XCTUnwrap(imageSession.preview).get())
        let red = try previewImage(WorkspaceFiles(directory: local.path).preview(image.lastPathComponent))
        XCTAssertEqual(blue.size, CGSize(width: 48, height: 32))
        XCTAssertEqual(try pixel(blue.bitmap), [0, 0, 255, 255])
        XCTAssertEqual(try pixel(red.bitmap), [255, 0, 0, 255])
        XCTAssertNil(imageSession.editorSource)
        XCTAssertFalse(imageSession.isEditable)

        try Data("broken image".utf8).write(to: linkedImage, options: .atomic)
        await imageSession.refresh()
        XCTAssertThrowsError(try XCTUnwrap(imageSession.preview).get()) {
            XCTAssertEqual($0 as? WorkspaceMediaError, .image)
        }
        try png(.green).write(to: linkedImage, options: .atomic)
        await imageSession.refresh()
        let green = try previewImage(try XCTUnwrap(imageSession.preview).get())
        XCTAssertEqual(try pixel(green.bitmap), [0, 255, 0, 255])
        saves.release(imageSession)

        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let panel = FilesPanelFixture(location: localLocation, selection: pdf.lastPathComponent, saves: saves)
        let host = NSHostingView(rootView: FilesPanelFixtureView(fixture: panel))
        host.sizingOptions = []
        window.contentView = host
        defer { window.contentView = nil }
        try await waitFor { self.findPDFCanvas(in: host)?.document?.page(at: 1)?.string == "Local second" }
        let localCanvas = try XCTUnwrap(findPDFCanvas(in: host))
        XCTAssertEqual(localCanvas.document?.page(at: 0)?.string, "Local first")

        panel.location = linkedLocation
        try await waitFor { self.findPDFCanvas(in: host)?.document?.page(at: 1)?.string == "Linked second" }
        let linkedCanvas = try XCTUnwrap(findPDFCanvas(in: host))
        XCTAssertFalse(localCanvas === linkedCanvas)
        XCTAssertEqual(linkedCanvas.document?.page(at: 0)?.string, "Linked first")

        let pdfSession = saves.acquire(WorkspaceFileTarget(location: linkedLocation, path: pdf.lastPathComponent))
        defer { saves.release(pdfSession) }
        try Data("broken PDF".utf8).write(to: linkedPDF, options: .atomic)
        await pdfSession.refresh()
        XCTAssertThrowsError(try XCTUnwrap(pdfSession.preview).get()) {
            XCTAssertEqual($0 as? WorkspaceMediaError, .pdf)
        }
        try await waitFor { self.findPDFCanvas(in: host) == nil }
        try pdfData(["Refreshed first", "Refreshed second"]).write(to: linkedPDF, options: .atomic)
        await pdfSession.refresh()
        try await waitFor { self.findPDFCanvas(in: host)?.document?.page(at: 1)?.string == "Refreshed second" }
        XCTAssertEqual(try git(linked, ["diff", "--cached", "--name-only"]), "")

        try FileManager.default.removeItem(at: linkedImage)
        try FileManager.default.createSymbolicLink(at: linkedImage, withDestinationURL: image)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("Escape"), withDestinationURL: local)
        let files = WorkspaceFiles(directory: linked.path)
        for path in [image.lastPathComponent, "Escape/\(pdf.lastPathComponent)", "../local/\(pdf.lastPathComponent)"] {
            XCTAssertThrowsError(try files.preview(path)) { XCTAssertEqual($0 as? WorkspaceFileError, .unsupportedPath) }
        }
    }

    @MainActor
    func testPDFKitPagingZoomSearchAndRestoringViewOffscreen() async throws {
        let reader = WorkspacePDFReader()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = reader.canvas
        defer { window.contentView = nil }
        let file = WorkspacePDFFile(data: try pdfData(["Token on page one", "Token on page two"]))
        XCTAssertTrue(reader.open(file, at: nil))
        reader.canvas.layoutSubtreeIfNeeded()
        XCTAssertEqual(reader.pageCount, 2)
        XCTAssertEqual(reader.canvas.scaleFactor, (500 - 32) / 612, accuracy: 0.001)
        reader.go(to: 1)
        XCTAssertEqual(reader.page, 1)
        XCTAssertEqual(reader.canvas.currentPage?.string, "Token on page two")

        reader.stepZoom(0.25)
        XCTAssertEqual(try XCTUnwrap(reader.zoom), (500 - 32) / 612 + 0.25, accuracy: 0.001)
        XCTAssertEqual(reader.page, 1)
        let savedPosition = try XCTUnwrap(reader.position)
        XCTAssertTrue(reader.open(file, at: savedPosition))
        XCTAssertEqual(reader.page, 1)
        XCTAssertEqual(reader.zoom, savedPosition.zoom)
        reader.setZoom(nil)
        XCTAssertNil(reader.zoom)
        XCTAssertEqual(reader.canvas.scaleFactor, (500 - 32) / 612, accuracy: 0.001)

        reader.find("tOkEn")
        try await waitFor { !reader.searching }
        XCTAssertEqual(reader.matchCount, 2)
        XCTAssertEqual(reader.page, 0)
        XCTAssertEqual(reader.canvas.highlightedSelections?.count, 2)
        reader.nextMatch()
        XCTAssertEqual(reader.page, 1)
        reader.nextMatch()
        XCTAssertEqual(reader.page, 0)
        reader.clearSearch()
        XCTAssertNil(reader.canvas.highlightedSelections)
        reader.find("no match")
        try await waitFor { !reader.searching }
        XCTAssertEqual(reader.matchCount, 0)
    }

    func testSVGPreviewRendersLocalPixelsAndRejectsMalformedInput() throws {
        try withFixture { root in
            let files = WorkspaceFiles(directory: root.path)
            let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="48" height="32">
              <rect width="48" height="32" fill="#ff0000"/>
            </svg>
            """
            try write(svg, "sample.svg", in: root)
            XCTAssertEqual(try pixel(previewImage(files.preview("sample.svg")).bitmap), [255, 0, 0, 255])
            try write("<svg>", "broken.svg", in: root)
            XCTAssertThrowsError(try files.preview("broken.svg"))
            let sibling = try folder("sibling", in: root)
            let outside = root.appendingPathComponent("outside.png")
            try png(.red).write(to: outside)
            let escape = sibling.appendingPathComponent("escape.png")
            try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
            try write("""
                <svg xmlns="http://www.w3.org/2000/svg" width="48" height="32">
                  <image width="48" height="32" href="\(escape.absoluteString)"/>
                </svg>
                """, "external.svg", in: sibling)
            XCTAssertThrowsError(try WorkspaceFiles(directory: sibling.path).preview("external.svg")) {
                XCTAssertEqual($0 as? WorkspaceMediaError, .externalSVGResources)
            }
            let oversized = try write("", "large.png", in: root)
            let descriptor = Darwin.open(oversized.path, O_WRONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { Darwin.close(descriptor) }
            XCTAssertEqual(ftruncate(descriptor, off_t(WorkspaceMediaFormat.byteLimit + 1)), 0)
            XCTAssertThrowsError(try files.preview("large.png")) {
                XCTAssertEqual($0 as? WorkspaceMediaError, .tooLarge)
            }
        }
    }

    @MainActor
    func testNavigationFlushesOriginalCheckoutWithoutChangingGitIndex() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = try folder("project", in: root)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        let threadID = UUID()
        let project = Project(id: UUID(), path: projectRoot.path, title: "Fixture")
        var thread = Conversation(id: threadID, title: "Fixture Thread")
        let projectTarget = try target("notes.txt", thread: thread, project: project)
        let file = try write("base\n", "notes.txt", in: projectRoot)
        _ = try git(projectRoot, ["init", "-q"])
        _ = try git(projectRoot, ["add", "notes.txt"])
        _ = try git(projectRoot, ["commit", "-qm", "Base"])
        _ = try git(projectRoot, ["worktree", "add", "--detach", "--", worktree.path, "HEAD"])
        try Data("staged\n".utf8).write(to: file)
        _ = try git(projectRoot, ["add", "notes.txt"])
        try Data("unstaged\n".utf8).write(to: file)

        let saves = WorkspaceFileSaves()
        let projectSession = saves.acquire(projectTarget)
        await projectSession.refresh()
        let original = try XCTUnwrap(projectSession.editorSource)
        projectSession.edit(original.text + "editor\n", from: original)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unstaged\n")
        thread.location = .newWorktree(branch: "pending", base: "HEAD")
        XCTAssertNil(WorkspaceFilesLocation(thread: thread, project: project))
        thread.location = .worktree(path: worktree.path, base: "HEAD")
        let worktreeTarget = try target("notes.txt", thread: thread, project: project)
        let worktreeFiles = WorkspaceFiles(directory: worktreeTarget.location.directory)
        let otherThread = Conversation(id: UUID(), title: "Same Checkout")
        let otherTarget = try target("notes.txt", thread: otherThread, project: project)
        XCTAssertEqual(saves.paths(in: projectTarget.location), ["notes.txt"])
        XCTAssertFalse(saves.hasDraft(for: worktreeTarget))
        XCTAssertFalse(saves.hasDraft(for: otherTarget))

        saves.release(projectSession)
        projectSession.edit("retired editor", from: original)
        XCTAssertFalse(saves.hasDraft(for: projectTarget))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unstaged\neditor\n")
        XCTAssertEqual(try git(projectRoot, ["show", ":notes.txt"]), "staged\n")
        XCTAssertEqual(try text("notes.txt", in: worktreeFiles).text, "base\n")
    }

    func testDiffNavigationMapsRepositoryPathsToTheSelectedSubfolder() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let subfolder = try folder("app", in: root)
        let duplicate = try folder("app", in: subfolder)
        try write("right file", "note", in: subfolder)
        try write("wrong file", "note", in: duplicate)
        try write("outside selected subfolder", "outside", in: root)
        _ = try git(root, ["init", "-q"])

        let status = try await GitWorkspace(path: subfolder.path).state()
        let inside = try XCTUnwrap(status.files.first { $0.path == "app/note" })
        let outside = try XCTUnwrap(status.files.first { $0.path == "outside" })
        let workspacePath = try XCTUnwrap(status.workspacePath(for: inside))
        XCTAssertEqual(try text(workspacePath, in: WorkspaceFiles(directory: subfolder.path)).text, "right file")
        XCTAssertNil(status.workspacePath(for: outside))
    }

    func testSaveRejectsExternalChangesReplacementAndDeletion() throws {
        try withFixture { root in
            let project = Project(id: UUID(), path: root.path, title: "Fixture")
            let selection = try target("note", thread: Conversation(id: UUID(), title: "Thread"), project: project)
            let files = WorkspaceFiles(directory: root.path)
            let file = try write("before", "note", in: root)
            let original = try text("note", in: files)
            let draft = WorkspaceFileDraft(target: selection, original: original, text: "my edit")

            try Data("outside".utf8).write(to: file)
            XCTAssertThrowsError(try draft.save()) {
                XCTAssertEqual($0 as? WorkspaceFileError, .changed)
            }
            XCTAssertEqual(try text("note", in: files).text, "outside")
            XCTAssertEqual(draft.text, "my edit")

            try Data("before".utf8).write(to: file, options: .atomic)
            XCTAssertThrowsError(try draft.save()) {
                XCTAssertEqual($0 as? WorkspaceFileError, .changed)
            }
            try FileManager.default.removeItem(at: file)
            XCTAssertThrowsError(try draft.save()) {
                XCTAssertEqual($0 as? WorkspaceFileError, .missing)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            let other = try write("keep", "other", in: root)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            XCTAssertThrowsError(try draft.save())
            XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "keep")
        }
    }

    func testSaveRetainsDraftWhenPermissionIsLostAndPreservesFileMetadata() throws {
        try withFixture { root in
            let project = Project(id: UUID(), path: root.path, title: "Fixture")
            let selection = try target("note", thread: Conversation(id: UUID(), title: "Thread"), project: project)
            let file = root.appendingPathComponent("note")
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            try Data(bom + Array("before\r\n".utf8)).write(to: file)
            XCTAssertEqual(chmod(file.path, 0o751), 0)
            let files = WorkspaceFiles(directory: root.path)
            let original = try text("note", in: files)
            let edit = "before\r\n追加\r\n"
            let draft = WorkspaceFileDraft(target: selection, original: original, text: edit)

            XCTAssertEqual(chmod(file.path, 0o451), 0)
            XCTAssertThrowsError(try draft.save()) {
                XCTAssertEqual($0 as? WorkspaceFileError, .readOnly)
            }
            XCTAssertEqual(try text("note", in: files).text, "before\r\n")
            XCTAssertEqual(chmod(file.path, 0o751), 0)
            let saved = try draft.save()
            XCTAssertTrue(try text("note", in: files).matches(saved))
            XCTAssertEqual(try Data(contentsOf: file), Data(bom + Array(edit.utf8)))
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o751)
        }
    }

    @MainActor
    func testAutosaveWaitsForQuietAndAdvancesTheEditorBaseline() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("base", "note", in: root)
        let saves = WorkspaceFileSaves()
        let session = try await openSession(saves, file: file, in: root)
        let source = try XCTUnwrap(session.editorSource)

        session.edit("first", from: source)
        try await Task.sleep(for: .milliseconds(300))
        session.edit("latest\n追加", from: source)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try Data(contentsOf: file), Data("base".utf8))
        XCTAssertEqual(session.draft?.text, "latest\n追加")

        try await waitFor { session.draft == nil }
        XCTAssertEqual(try Data(contentsOf: file), Data("latest\n追加".utf8))
        session.edit("latest\n追加!", from: source)
        XCTAssertNil(session.flush())
        XCTAssertEqual(try Data(contentsOf: file), Data("latest\n追加!".utf8))
        XCTAssertFalse(saves.hasDraft(for: session.target))
    }

    @MainActor
    func testPermissionRecoveryRetainsUnsavedTextAcrossClosingAndReopening() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("base", "note", in: root)
        let saves = WorkspaceFileSaves()
        let session = try await openSession(saves, file: file, in: root)
        session.edit("unsaved", from: try XCTUnwrap(session.editorSource))
        XCTAssertEqual(chmod(file.path, 0o444), 0)

        try await waitFor { session.isReadOnly }
        XCTAssertFalse(session.isEditable)
        XCTAssertEqual(session.draft?.text, "unsaved")
        XCTAssertEqual(try Data(contentsOf: file), Data("base".utf8))
        saves.release(session)
        XCTAssertEqual(saves.paths(in: session.target.location), ["note"])

        let reopened = saves.acquire(session.target)
        await reopened.refresh()
        XCTAssertEqual(reopened.draft?.text, "unsaved")
        XCTAssertTrue(reopened.isReadOnly)
        saves.release(reopened)
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        try await waitFor { !saves.hasDraft(for: session.target) }
        XCTAssertEqual(try Data(contentsOf: file), Data("unsaved".utf8))

        let clean = saves.acquire(session.target)
        XCTAssertEqual(chmod(file.path, 0o444), 0)
        await clean.refresh()
        XCTAssertNil(clean.draft)
        XCTAssertEqual(clean.editorSource?.text, "unsaved")
        XCTAssertTrue(clean.isReadOnly)
        XCTAssertFalse(clean.isEditable)
    }

    @MainActor
    func testRefreshDoesNotRebaseKeystrokesFromAnOlderEditorDisplay() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("base", "note", in: root)
        let saves = WorkspaceFileSaves()
        let session = try await openSession(saves, file: file, in: root)
        let oldDisplay = try XCTUnwrap(session.editorSource)
        try Data("base".utf8).write(to: file, options: .atomic)
        await session.refresh()
        session.edit("base edit", from: oldDisplay)
        saves.release(session)

        XCTAssertEqual(try Data(contentsOf: file), Data("base".utf8))
        let reopened = saves.acquire(session.target)
        XCTAssertEqual(reopened.draft?.text, "base edit")
        XCTAssertTrue(reopened.changedOnDisk)
    }

    @MainActor
    func testQuitFlushesPendingFilesAndKeepsBlockedFilesForRetry() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(root: root.appendingPathComponent("state", isDirectory: true),
                                   keychainService: UUID().uuidString, readCredential: { _ in nil })
        let checkout = try folder("checkout", in: root)
        let good = try write("base", "good.txt", in: checkout)
        let blocked = try write("base", "blocked.txt", in: checkout)
        let original = try write("keep", "outside.txt", in: root)
        let goodSession = try await openSession(model.fileSaves, file: good, in: checkout)
        let blockedSession = try await openSession(model.fileSaves, file: blocked, in: checkout)

        goodSession.edit("save immediately", from: try XCTUnwrap(goodSession.editorSource))
        blockedSession.edit("keep this draft", from: try XCTUnwrap(blockedSession.editorSource))
        let backup = checkout.appendingPathComponent("original.txt")
        try FileManager.default.moveItem(at: blocked, to: backup)
        try FileManager.default.createSymbolicLink(at: blocked, withDestinationURL: original)
        model.fileSaves.release(blockedSession)
        XCTAssertTrue(model.fileSaves.hasDraft(for: blockedSession.target))
        XCTAssertFalse(model.savePendingEditsForQuit())
        XCTAssertTrue(try XCTUnwrap(model.quitFileSaveError).contains("blocked.txt"))
        XCTAssertEqual(try Data(contentsOf: good), Data("save immediately".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
        XCTAssertEqual(blockedSession.draft?.text, "keep this draft")

        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.moveItem(at: backup, to: blocked)
        XCTAssertTrue(model.terminate())
        XCTAssertNil(model.quitFileSaveError)
        XCTAssertEqual(try Data(contentsOf: blocked), Data("keep this draft".utf8))
    }

    @MainActor
    func testOversizedDraftRemainsAvailableAndCanBeTrimmedAndSaved() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("base", "note", in: root)
        let saves = WorkspaceFileSaves()
        let session = try await openSession(saves, file: file, in: root)
        let source = try XCTUnwrap(session.editorSource)
        let oversized = String(repeating: "a", count: WorkspaceFiles.textLimit + 1)
        session.edit(oversized, from: source)
        XCTAssertEqual(session.flush() as? WorkspaceFileError, .tooLarge)
        XCTAssertEqual(session.draft?.text, oversized)
        XCTAssertTrue(session.isEditable)
        XCTAssertEqual(try Data(contentsOf: file), Data("base".utf8))

        session.edit("trimmed", from: source)
        XCTAssertNil(session.flush())
        XCTAssertEqual(try Data(contentsOf: file), Data("trimmed".utf8))
    }

    @MainActor
    private func openSession(_ saves: WorkspaceFileSaves, file: URL, in checkout: URL) async throws -> WorkspaceFileSaveSession {
        let project = Project(id: UUID(), path: checkout.path, title: "Fixture")
        let thread = Conversation(id: UUID(), title: "Fixture Thread")
        let session = saves.acquire(try target(file.lastPathComponent, thread: thread, project: project))
        await session.refresh()
        return session
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PiWorkspaceFilesTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func folder(_ name: String, in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    @discardableResult
    private func write(_ contents: String, _ name: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func target(_ path: String, thread: Conversation, project: Project) throws -> WorkspaceFileTarget {
        WorkspaceFileTarget(location: try XCTUnwrap(WorkspaceFilesLocation(thread: thread, project: project)), path: path)
    }

    private func text(_ path: String, in files: WorkspaceFiles) throws -> WorkspaceFileText {
        guard case let .text(text) = try files.preview(path) else {
            throw WorkspaceError("Expected a text preview for \(path).")
        }
        return text
    }

    private func previewImage(_ preview: WorkspaceFilePreview) throws -> WorkspaceImageFile {
        guard case let .image(image) = preview else { throw WorkspaceError("Expected an image preview.") }
        return image
    }

    private func png(_ color: NSColor) throws -> Data {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(color.cgColor)
        bitmap.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        let image = try XCTUnwrap(bitmap.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func pixel(_ image: CGImage) throws -> [UInt8] {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeRawBufferPointer(start: try XCTUnwrap(bitmap.data), count: 4))
    }

    private func pdfData(_ pages: [String]) throws -> Data {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for text in pages {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 52, y: 720)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]))
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @MainActor
    private func findPDFCanvas(in view: NSView) -> WorkspacePDFCanvas? {
        firstSubview(in: view) { $0 as? WorkspacePDFCanvas }
    }

    @MainActor
    private func firstSubview<T>(in view: NSView, matching find: (NSView) -> T?) -> T? {
        if let match = find(view) { return match }
        for child in view.subviews {
            if let match = firstSubview(in: child, matching: find) { return match }
        }
        return nil
    }

    private func git(_ directory: URL, _ arguments: [String]) throws -> String {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        command.currentDirectoryURL = directory
        command.environment = [
            "PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "TMPDIR": directory.path
        ]
        command.arguments = ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        let output = Pipe()
        command.standardOutput = output
        try command.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw WorkspaceError("Fixture git command failed.") }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@MainActor @Observable
private final class FilesPanelFixture {
    var location: WorkspaceFilesLocation
    var selection: String?
    let saves: WorkspaceFileSaves

    init(location: WorkspaceFilesLocation, selection: String?, saves: WorkspaceFileSaves) {
        self.location = location
        self.selection = selection
        self.saves = saves
    }
}

private struct FilesPanelFixtureView: View {
    @Bindable var fixture: FilesPanelFixture

    var body: some View {
        WorkspaceFilesView(location: fixture.location, saves: fixture.saves, pasteboard: .general,
                           activeLocation: { fixture.location }, close: {}, selection: $fixture.selection)
            .id(fixture.location)
    }
}
