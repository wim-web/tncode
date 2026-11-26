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
    func testFileMentionSpellingMatchesPinnedComposer() {
        let cases = [
            ("docs/My File (draft).md", "[My File (draft).md](docs/My%20File%20%28draft%29.md)"),
            ("@scope/package.json", "[package.json](@scope/package.json)"),
            ("icon@2x.png", "[icon@2x.png](./icon@2x.png)"),
            ("C#/Program.cs", "[Program.cs](./C%23/Program.cs)"),
            ("docs/R&copy;.md", #"[R\&copy;.md](./docs/R%26copy;.md)"#),
            ("docs/Bob's notes.md", "[Bob's notes.md](./docs/Bob's%20notes.md)"),
            ("pages/posts/[id].tsx", #"[\[id\].tsx](pages/posts/%5Bid%5D.tsx)"#),
            ("pkg/__init__.py", #"[\_\_init\_\_.py](pkg/__init__.py)"#),
            ("notes/*draft*.md", #"[\*draft\*.md](./notes/*draft*.md)"#),
            ("folder\\name.md", "[name.md](folder%5Cname.md)"),
            ("線性代數/考試.pdf", "[考試.pdf](%E7%B7%9A%E6%80%A7%E4%BB%A3%E6%95%B8/%E8%80%83%E8%A9%A6.pdf)"),
            ("cafe\u{301}.txt", "[cafe\u{301}.txt](cafe%CC%81.txt)"),
            ("a.\u{301}", "[a.\u{301}](a.%CC%81)"),
            ("notes/🌱.txt", "[🌱.txt](./notes/%F0%9F%8C%B1.txt)"),
            (".gitignore", "[.gitignore](./.gitignore)"),
            ("README", "[README](README)"),
            ("README.md", "[README.md](README.md)"),
            ("Study notes", "[Study notes](./Study%20notes)"),
            ("docs/Study notes", "[Study notes](docs/Study%20notes)")
        ]
        for (path, expected) in cases {
            XCTAssertEqual(Array(WorkspaceFileMention.serialize(path).utf8), Array(expected.utf8), path)
        }
    }

    @MainActor
    func testFileMentionsStayWithTheSelectedCheckoutAndQueueEdit() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try folder("Project Checkout", in: root)
        let linked = root.appendingPathComponent("Linked Checkout", isDirectory: true)
        let name = "Review [v2] #%.md"
        let path = "Study notes/" + name
        let notes = try folder("Study notes", in: repo)
        try write("project", name, in: notes)
        _ = try git(repo, ["init", "-q", "-b", "main"])
        _ = try git(repo, ["add", "--", path])
        _ = try git(repo, ["commit", "-qm", "File mention fixture"])
        _ = try git(repo, ["worktree", "add", "--detach", "--", linked.path, "HEAD"])
        try write("linked", name, in: linked.appendingPathComponent("Study notes"))

        let queued = QueuedMessage(text: "Queued draft\n")
        let local = Conversation(id: UUID(), title: "Local", composerText: "Local draft")
        let worktree = Conversation(id: UUID(), title: "Linked", location: .worktree(path: linked.path, base: "main"),
                                    composerText: "Keep this draft 🌱", queuedMessages: [queued])
        let project = Project(id: UUID(), path: repo.path, title: "Fixture",
                              conversations: [local, worktree], selectedConversation: worktree.id)
        let store = try folder("store", in: root)
        try WorkspaceStore(root: store).save(Workspace(projects: [project], selectedProject: project.id, welcomeCompleted: true))
        let model = WorkspaceModel(root: store, keychainService: UUID().uuidString, readCredential: { _ in "fixture-key" }) { _, _ in
            throw WorkspaceError("This test edits drafts without Pi.")
        }
        defer { model.terminate() }
        let worktreeLocation = try XCTUnwrap(WorkspaceFilesLocation(thread: worktree, project: project))
        let target = WorkspaceFileTarget(location: worktreeLocation, path: path)
        let mention = #"[Review \[v2\] #%.md](./Study%20notes/Review%20%5Bv2%5D%20%23%25.md)"#
        XCTAssertEqual(try target.composerMention(), mention)
        let directory = WorkspaceFileTarget(location: worktreeLocation, path: "Study notes")
        XCTAssertEqual(try directory.composerMention(), "[Study notes](./Study%20notes)")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("link"), withDestinationURL: notes)
        XCTAssertThrowsError(try WorkspaceFileTarget(location: worktreeLocation, path: "link").composerMention())
        XCTAssertThrowsError(try WorkspaceFileTarget(location: worktreeLocation, path: "link/" + name).composerMention())

        let localLocation = try XCTUnwrap(WorkspaceFilesLocation(thread: local, project: project))
        XCTAssertThrowsError(try model.addFileMention(.init(location: localLocation, path: path)))
        XCTAssertEqual(model.draft, "Keep this draft 🌱")
        // A stale tree row must not fall back to the same file path in the project checkout.
        try FileManager.default.removeItem(atPath: target.fullPath)
        XCTAssertThrowsError(try model.addFileMention(target))
        try write("linked again", name, in: linked.appendingPathComponent("Study notes"))

        XCTAssertTrue(try model.addFileMention(target))
        let draft = "Keep this draft 🌱 \(mention) "
        XCTAssertEqual(model.draft, draft)
        model.editQueuedMessage(queued.id)
        XCTAssertTrue(try model.addFileMention(target))
        XCTAssertEqual(model.draft, queued.text + mention + " ")
        model.cancelQueuedMessageEdit()
        XCTAssertEqual(model.queuedMessages, [queued])
        XCTAssertEqual(model.draft, draft)

        model.editQueuedMessage(queued.id)
        XCTAssertTrue(try model.addFileMention(target))
        model.updateQueuedMessage()
        XCTAssertEqual(model.queuedMessages.map(\.id), [queued.id])
        XCTAssertEqual(model.queuedMessages.map(\.text), [queued.text + mention])
        XCTAssertEqual(model.draft, draft)
        XCTAssertTrue(model.composerAttachments.isEmpty)

        let rejectedName = "fixture-key.txt"
        try write("key-like filename", rejectedName, in: linked)
        XCTAssertFalse(try model.addFileMention(.init(location: worktreeLocation, path: rejectedName)))
        XCTAssertEqual(model.draft, draft)
        model.selectConversation(local.id, in: project.id)
        XCTAssertThrowsError(try model.addFileMention(target))
        XCTAssertEqual(model.draft, "Local draft")
    }

    @MainActor
    func testFileMentionDragBelongsToTheComposerThatStartedIt() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("fixture", "README.md", in: root)
        let queued = QueuedMessage(text: "Queued text")
        let active = Conversation(id: UUID(), title: "Active", composerText: "Draft", queuedMessages: [queued])
        let other = Conversation(id: UUID(), title: "Other", composerText: "Other draft")
        let project = Project(id: UUID(), path: root.path, title: "Fixture",
                              conversations: [active, other], selectedConversation: active.id)
        let store = try folder("store", in: root)
        try WorkspaceStore(root: store).save(Workspace(projects: [project], selectedProject: project.id, welcomeCompleted: true))
        let model = WorkspaceModel(root: store, keychainService: UUID().uuidString, readCredential: { _ in "fixture-key" }) { _, _ in
            throw WorkspaceError("This test edits drafts without Pi.")
        }
        defer { model.terminate() }
        let location = try XCTUnwrap(WorkspaceFilesLocation(thread: active, project: project))
        let file = WorkspaceFileTarget(location: location, path: "README.md")

        func beginDrag() async throws -> UUID {
            let provider = try XCTUnwrap(model.beginFileMentionDrag(file))
            let type = WorkspaceFileMentionDrag.type.rawValue
            XCTAssertEqual(provider.registeredTypeIdentifiers, [type])
            let data = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            return try XCTUnwrap(data.flatMap { UUID(uuidString: String(decoding: $0, as: UTF8.self)) })
        }

        let draftTarget = model.attachmentTarget(for: active.id)
        let beforeNavigation = try await beginDrag()
        model.selectConversation(other.id, in: project.id)
        XCTAssertFalse(model.dropFileMention(beforeNavigation, in: model.attachmentTarget(for: other.id)))
        XCTAssertEqual(model.draft, "Other draft")
        model.selectConversation(active.id, in: project.id)
        XCTAssertFalse(model.dropFileMention(beforeNavigation, in: draftTarget))

        let beforeQueue = try await beginDrag()
        model.editQueuedMessage(queued.id)
        let queueTarget = model.attachmentTarget(for: active.id)
        XCTAssertFalse(model.dropFileMention(beforeQueue, in: queueTarget))
        let editing = try await beginDrag()
        XCTAssertTrue(model.dropFileMention(editing, in: queueTarget))
        XCTAssertFalse(model.dropFileMention(editing, in: queueTarget))
        XCTAssertEqual(model.draft, "Queued text [README.md](README.md) ")
        let beforeCancel = try await beginDrag()
        model.cancelQueuedMessageEdit()
        XCTAssertFalse(model.dropFileMention(beforeQueue, in: draftTarget))
        XCTAssertFalse(model.dropFileMention(beforeCancel, in: draftTarget))
        XCTAssertEqual(model.queuedMessages, [queued])
        XCTAssertEqual(model.draft, "Draft")

        let current = try await beginDrag()
        model.draft += " with newer text"
        XCTAssertTrue(model.dropFileMention(current, in: draftTarget))
        XCTAssertEqual(model.draft, "Draft with newer text [README.md](README.md) ")
        XCTAssertTrue(model.composerAttachments.isEmpty)
    }

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
    func testMarkdownSourceAndRenderedDraftStayInTheirCheckoutOffscreen() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = try folder("local", in: root)
        let linked = root.appendingPathComponent("linked")
        let path = "Guide.MDX"
        let markup = """
        # Local heading

        **Bold text**, *emphasis*, `inline()` and [Docs](https://example.test/docs).

        > A quoted note
        > - A nested bullet

        3. A numbered item

        | Name | Value |
        | --- | ---: |
        | café | 42 |

        ```swift
        let value = 42
        ```
        """
        let file = try write(markup, path, in: local)
        _ = try git(local, ["init", "-q"])
        _ = try git(local, ["add", "--", path])
        _ = try git(local, ["commit", "-qm", "Markdown fixture"])
        _ = try git(local, ["worktree", "add", "--detach", "--", linked.path, "HEAD"])
        let linkedMarkup = "# Linked heading\n\n[Open sibling](Sibling.md)"
        let linkedFile = try write(linkedMarkup, path, in: linked)
        try write("# Linked sibling", "Sibling.md", in: linked)
        try write("# Parent sibling", "Sibling.md", in: local)
        XCTAssertEqual(chmod(linkedFile.path, 0o444), 0)
        let project = Project(id: UUID(), path: local.path, title: "Fixture")
        var thread = Conversation(id: UUID(), title: "Fixture Thread")
        let localTarget = try target(path, thread: thread, project: project)
        thread.location = .worktree(path: linked.path, base: "HEAD")
        let linkedTarget = try target(path, thread: thread, project: project)
        let saves = WorkspaceFileSaves()
        let panel = FilesPanelFixture(location: localTarget.location, selection: path, saves: saves)
        let suite = "RenderedFilesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (window, host) = hostFiles(panel, defaults: defaults)
        defer { window.contentView = nil }

        func textView(_ id: String) -> NSTextView? {
            firstSubview(in: host) {
                guard let view = $0 as? NSTextView, view.accessibilityIdentifier() == id else { return nil }
                return view
            }
        }
        let sourceID = "files-editor"
        let markdownID = "files-rendered-markdown"
        try await waitFor { textView(sourceID)?.string == markup }

        defaults.set(true, forKey: "files-render-markdown")
        try await waitFor { textView(markdownID)?.string.hasPrefix("Local heading") == true }
        let view = try XCTUnwrap(textView(markdownID))
        XCTAssertFalse(view.isEditable)
        let storage = try XCTUnwrap(view.textStorage)
        let rendered = view.string
        for phrase in ["Bold text", "emphasis", "inline()", "A quoted note", "•\tA nested bullet",
                       "3.\tA numbered item", "let value = 42", "café"] {
            XCTAssertTrue(rendered.contains(phrase), phrase)
        }
        func offset(of value: String) throws -> Int {
            NSRange(try XCTUnwrap(rendered.range(of: value)), in: rendered).location
        }
        let heading = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(heading.pointSize, NSFont.systemFontSize)
        let bold = try XCTUnwrap(storage.attribute(.font, at: offset(of: "Bold text"), effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        let link = try storage.attribute(.link, at: offset(of: "Docs"), effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "https://example.test/docs")
        let style = try storage.attribute(.paragraphStyle, at: offset(of: "42"), effectiveRange: nil)
            as? NSParagraphStyle
        let cell = try XCTUnwrap(style?.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(cell.startingRow, 1)
        XCTAssertEqual(cell.startingColumn, 1)

        defaults.set(false, forKey: "files-render-markdown")
        try await waitFor { textView(sourceID)?.string == markup }
        let editor = try XCTUnwrap(textView(sourceID))
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(chmod(file.path, 0o444), 0)
        let draft = "# Draft heading\n\n**Pending edit**"
        editor.insertText(draft, replacementRange: NSRange(location: 0, length: markup.utf16.count))
        try await waitFor { saves.hasDraft(for: localTarget) }
        defaults.set(true, forKey: "files-render-markdown")
        try await waitFor { textView(markdownID)?.string.contains("Pending edit") == true }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), markup)

        panel.location = linkedTarget.location
        try await waitFor { textView(markdownID)?.string == "Linked heading\nOpen sibling" }
        XCTAssertFalse(saves.hasDraft(for: linkedTarget))
        let linkedView = try XCTUnwrap(textView(markdownID))
        let linkRange = try XCTUnwrap(linkedView.string.range(of: "Open sibling"))
        let linkOffset = NSRange(linkRange, in: linkedView.string).location
        let siblingURL = try XCTUnwrap(linkedView.textStorage?.attribute(.link, at: linkOffset, effectiveRange: nil) as? URL)
        XCTAssertEqual(linkedView.delegate?.textView?(linkedView, clickedOnLink: siblingURL, at: linkOffset), true)
        try await waitFor { textView(markdownID)?.string == "Linked sibling" }
        panel.selection = path
        defaults.set(false, forKey: "files-render-markdown")
        try await waitFor { textView(sourceID)?.string == linkedMarkup }
        XCTAssertFalse(try XCTUnwrap(textView(sourceID)).isEditable)

        panel.location = localTarget.location
        try await waitFor { textView(sourceID)?.string == draft }
        XCTAssertFalse(try XCTUnwrap(textView(sourceID)).isEditable)
    }

    func testQuotedCSVFieldCanResolveAnAmbiguousDelimiter() throws {
        let prices = "\"Artikel\";Preis, EUR;Menge\n\"Apfel\";1,25;2"
        let table = try WorkspaceDelimitedTable(text: prices, delimiter: .comma)
        XCTAssertEqual(table.rows, [["Artikel", "Preis, EUR", "Menge"], ["Apfel", "1,25", "2"]])
        let ordinary = try WorkspaceDelimitedTable(text: "Name,Note\nApple,\"a;b,c\"", delimiter: .comma)
        XCTAssertEqual(ordinary.rows, [["Name", "Note"], ["Apple", "a;b,c"]])
        XCTAssertThrowsError(try WorkspaceDelimitedTable(text: "A,B\n\"price\"invalid,2", delimiter: .comma))
        XCTAssertThrowsError(try WorkspaceDelimitedTable(text: prices, delimiter: .tab))
    }

    @MainActor
    func testDelimitedTableRendersCellsAndRefreshesAfterParseFailureOffscreen() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let csv = "Name,Notes,Empty\r\n\"A, B\",\"say \"\"hi\"\"\r\nagain 東京\",\r\n"
        let file = try write("\u{FEFF}" + csv, "data.CSV", in: root)
        _ = try write("Name\tNotes\rBob\t\"one\ttwo\"\r", "data.tsv", in: root)
        let project = Project(id: UUID(), path: root.path, title: "Fixture")
        let target = try target(file.lastPathComponent, thread: Conversation(id: UUID(), title: "Thread"),
                                project: project)
        let saves = WorkspaceFileSaves()
        let session = saves.acquire(target)
        defer { saves.release(session) }
        let panel = FilesPanelFixture(location: target.location, selection: target.path, saves: saves)
        let suite = "RenderedFilesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (window, host) = hostFiles(panel, defaults: defaults)
        defer { window.contentView = nil }

        func table() -> NSTableView? {
            firstSubview(in: host) { $0 as? NSTableView }
        }
        func cell(_ column: Int) -> String? {
            (table()?.view(atColumn: column, row: 0, makeIfNecessary: false) as? NSTableCellView)?.textField?.stringValue
        }
        try await waitFor { cell(0) == "A, B" }
        let initial = try XCTUnwrap(table())
        XCTAssertEqual(initial.accessibilityIdentifier(), "files-rendered-table")
        XCTAssertNotNil(initial.headerView)
        XCTAssertEqual(initial.tableColumns.map(\.title), ["Name", "Notes", "Empty"])
        XCTAssertEqual(initial.numberOfRows, 1)
        XCTAssertEqual(cell(1), "say \"hi\"\r\nagain 東京")
        XCTAssertEqual(cell(2), "")
        let notes = try XCTUnwrap(initial.view(atColumn: 1, row: 0, makeIfNecessary: false) as? NSTableCellView)
        try await waitFor {
            host.layoutSubtreeIfNeeded()
            return notes.frame.height > initial.rowHeight
        }

        panel.selection = "data.tsv"
        try await waitFor { cell(1) == "one\ttwo" }
        XCTAssertEqual(table()?.tableColumns.map(\.title), ["Name", "Notes"])
        panel.selection = target.path
        try await waitFor { cell(0) == "A, B" }

        let broken = "Name,Notes\nAlice,\"unfinished"
        try Data(broken.utf8).write(to: file, options: .atomic)
        await session.refresh()
        XCTAssertThrowsError(try WorkspaceDelimitedTable(text: broken, delimiter: .comma)) {
            XCTAssertEqual($0.localizedDescription, "Unclosed quoted field in row 2.")
        }
        try await waitFor { table() == nil }
        defaults.set(false, forKey: "files-render-table")
        try await waitFor {
            firstSubview(in: host) { ($0 as? NSTextView)?.string } == broken
        }
        defaults.set(true, forKey: "files-render-table")
        try Data("\"A, B\";Value\r\nZoë;2,5".utf8).write(to: file, options: .atomic)
        await session.refresh()
        try await waitFor { cell(0) == "Zoë" }
        XCTAssertEqual(table()?.tableColumns.map(\.title), ["A, B", "Value"])
        XCTAssertEqual(cell(1), "2,5")
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
            let image = try previewImage(files.preview("sample.svg")).bitmap
            // AppKit rasterizes SVG into the display profile. Compare both fills in that profile.
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                                 bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                 space: try XCTUnwrap(image.colorSpace),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            bitmap.setBlendMode(.copy)
            bitmap.draw(image, in: bounds)
            let pixels = try XCTUnwrap(bitmap.data)
            let byteCount = bitmap.bytesPerRow * bitmap.height
            let rendered = Data(bytes: pixels, count: byteCount)
            bitmap.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            bitmap.fill(bounds)
            XCTAssertEqual(rendered, Data(bytes: pixels, count: byteCount), "Expected solid opaque sRGB red")

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
        XCTAssertEqual(saves.pendingFiles(for: threadID).map(\.target), [projectTarget])
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
        XCTAssertEqual(saves.pendingFiles(for: session.target.location.threadID).map(\.target), [session.target])

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
    private func moveCheckoutWithBlockedDraft(in root: URL) async throws
        -> (WorkspaceModel, WorkspaceFileSaveSession, URL, URL) {
        let projectRoot = try folder("project", in: root)
        let old = root.appendingPathComponent("old", isDirectory: true)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        try write("base", "notes.txt", in: projectRoot)
        _ = try git(projectRoot, ["init", "-q"])
        _ = try git(projectRoot, ["add", "notes.txt"])
        _ = try git(projectRoot, ["commit", "-qm", "Original file"])
        _ = try git(projectRoot, ["worktree", "add", "--detach", "--", old.path, "HEAD"])
        let thread = Conversation(id: UUID(), title: "Draft", location: .worktree(path: old.path, base: nil), isDraft: true)
        let project = Project(id: UUID(), path: projectRoot.path, title: "Project",
                              conversations: [thread], selectedConversation: thread.id)
        let state = root.appendingPathComponent("state", isDirectory: true)
        try WorkspaceStore(root: state).save(Workspace(projects: [project], selectedProject: project.id))
        let model = WorkspaceModel(root: state, keychainService: UUID().uuidString, readCredential: { _ in nil },
                                   makeProcess: { _, _ in throw WorkspaceError("Worker disabled in Files fixture.") })
        let session = model.fileSaves.acquire(try target("notes.txt", thread: thread, project: project))
        await session.refresh()
        session.edit("pending revision", from: try XCTUnwrap(session.editorSource))
        XCTAssertEqual(chmod(old.appendingPathComponent("notes.txt").path, 0o444), 0)
        XCTAssertFalse(model.savePendingEditsForQuit())
        _ = try git(projectRoot, ["worktree", "move", "--", old.path, moved.path])
        return (model, session, projectRoot, moved)
    }

    @MainActor
    func testBlockedDraftFollowsMovedCheckoutAndResumesAutosave() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, previous, project, moved) = try await moveCheckoutWithBlockedDraft(in: root)
        let saves = model.fileSaves
        let oldTarget = previous.target
        saves.release(previous)
        let movedFile = moved.appendingPathComponent("notes.txt")

        // Even a hard link to the original file must not authorize a write in a different checkout.
        let old = URL(fileURLWithPath: oldTarget.location.directory)
        _ = try git(project, ["worktree", "add", "--detach", "--", old.path, "HEAD"])
        let otherFile = old.appendingPathComponent("notes.txt")
        try FileManager.default.removeItem(at: otherFile)
        try FileManager.default.linkItem(at: movedFile, to: otherFile)
        XCTAssertEqual(chmod(movedFile.path, 0o644), 0)
        try await model.changeThreadLocation(.project)
        XCTAssertFalse(model.savePendingEditsForQuit())
        XCTAssertEqual(saves.pendingFiles(for: oldTarget.location.threadID).map(\.target), [oldTarget])
        XCTAssertTrue(saves.pendingFiles(for: UUID()).isEmpty)
        XCTAssertEqual(try String(contentsOf: otherFile, encoding: .utf8), "base")

        XCTAssertEqual(chmod(movedFile.path, 0o444), 0)
        try await model.changeThreadLocation(.existing(path: moved.path))
        let current = try target("notes.txt", thread: XCTUnwrap(model.conversation), project: XCTUnwrap(model.project))
        XCTAssertEqual(saves.pendingFiles(for: current.location.threadID).map(\.target), [current])
        XCTAssertFalse(saves.hasDraft(for: oldTarget))
        let reopened = saves.acquire(current)
        await reopened.refresh()
        XCTAssertEqual(reopened.draft?.text, "pending revision")
        saves.release(reopened)
        XCTAssertFalse(model.savePendingEditsForQuit())
        XCTAssertEqual(chmod(movedFile.path, 0o644), 0)
        try await waitFor { saves.pendingFiles(for: current.location.threadID).isEmpty }
        XCTAssertEqual(try String(contentsOf: movedFile, encoding: .utf8), "pending revision")
        XCTAssertEqual(try String(contentsOf: otherFile, encoding: .utf8), "base")
        XCTAssertTrue(model.savePendingEditsForQuit())
    }

    @MainActor
    func testReplacementInMovedCheckoutRetainsDraftUntilExplicitDiscard() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, previous, _, moved) = try await moveCheckoutWithBlockedDraft(in: root)
        let replacement = moved.appendingPathComponent("notes.txt")
        try Data("base".utf8).write(to: replacement, options: .atomic)
        XCTAssertEqual(chmod(replacement.path, 0o644), 0)
        try await model.changeThreadLocation(.existing(path: moved.path))
        model.fileSaves.release(previous)
        let current = try target("notes.txt", thread: XCTUnwrap(model.conversation), project: XCTUnwrap(model.project))
        let editor = model.fileSaves.acquire(current)
        defer { model.fileSaves.release(editor) }
        await editor.refresh()
        XCTAssertFalse(model.savePendingEditsForQuit())
        XCTAssertTrue(editor.changedOnDisk)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(editor.draft?.text, "pending revision")
        editor.discard()
        await editor.refresh()
        XCTAssertEqual(editor.editorSource?.text, "base")
        XCTAssertTrue(model.savePendingEditsForQuit())
        XCTAssertEqual(try String(contentsOf: replacement, encoding: .utf8), "base")
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
    private func hostFiles(_ panel: FilesPanelFixture, defaults: UserDefaults) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 850, height: 520),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: FilesPanelFixtureView(fixture: panel).defaultAppStorage(defaults))
        host.sizingOptions = []
        window.contentView = host
        return (window, host)
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
                           activeLocation: { fixture.location }, close: {},
                           canAddToComposer: false, addToComposer: { _ in }, beginMentionDrag: { _ in nil },
                           selection: $fixture.selection)
            .id(fixture.location)
    }
}
