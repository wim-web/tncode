import AppKit
import XCTest
@testable import tncode

@MainActor
final class SidebarThreadDragTests: XCTestCase {
    private static let relaunchFixture = "PI_SIDEBAR_DRAG_RELAUNCH_FIXTURE"

    func testVisibleDropPlacementAndRelaunchPreserveThreadOwnership() async throws {
        try requireTestDesktop()
        if let path = ProcessInfo.processInfo.environment[Self.relaunchFixture] {
            try await performDrops(Fixture(opening: URL(fileURLWithPath: path)))
            return
        }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "\(String(reflecting: Self.self))/\(#function.dropLast(2))",
                             Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.relaunchFixture] = fixture.root.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        if process.terminationStatus == 0 { try await verifyRelaunch(fixture.root) }
    }

    func testEmptyShelvesAndDisabledGroupedRows() async throws {
        try requireTestDesktop()
        let fixture = try Fixture(onlyOneActive: true)
        defer { fixture.remove() }
        do {
            let groupedFixture = try Fixture(onlyOneActive: true)
            defer { groupedFixture.remove() }
            let ui = try SidebarDragTestWindow(model: SidebarDragTestWindow.open(groupedFixture.root), grouped: true)
            defer { ui.close() }
            try await ui.waitForRow(groupedFixture.active)
            XCTAssertFalse(ui.destinations.contains { $0.registeredDraggedTypes.contains(SidebarThreadDrag.type) })
        }
        let ui = try SidebarDragTestWindow(model: SidebarDragTestWindow.open(fixture.root))
        defer { ui.close() }
        try await ui.waitForRow(fixture.active)
        let source = try ui.dragSource(fixture.active)
        XCTAssertNil(ui.element("sidebar-pinned-drop"))
        let item = source.drag.begin(try XCTUnwrap(source.origin()))
        try await ui.waitForElement("sidebar-pinned-drop")
        try ui.deliver(item, from: source.drag, to: ui.destination("sidebar-pinned-drop", requiringSource: false),
                       offering: .move, expects: true)
        try await ui.waitForRow(fixture.active)
        let pinned = try ui.dragSource(fixture.active)
        XCTAssertEqual(pinned.origin()?.section, .pinned)
        let pinnedItem = pinned.drag.begin(try XCTUnwrap(pinned.origin()))
        try await ui.waitForElement("sidebar-active-drop")
        try ui.deliver(pinnedItem, from: pinned.drag, to: ui.destination("sidebar-active-drop", requiringSource: false),
                       offering: .move, expects: true)
        XCTAssertEqual(try fixture.thread(fixture.active).threadShelf, .active)
    }

    func testFileURLUsesTheRowAttachmentAndFolderRoutes() async throws {
        try requireTestDesktop()
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ui = try SidebarDragTestWindow(model: SidebarDragTestWindow.open(fixture.root))
        defer { ui.close() }
        let path = fixture.root.appendingPathComponent("native-file.txt")
        let contents = Data("Native file payload".utf8)
        try contents.write(to: path)
        let item = NSPasteboardItem()
        item.setString(UUID().uuidString, forType: SidebarThreadDrag.type)
        item.setString(path.absoluteString, forType: .fileURL)
        try await ui.waitForRow(fixture.other)
        try ui.deliver(item, from: nil, to: ui.rowDestination(fixture.other),
                       offering: .copy, expects: true, mask: .copy)
        XCTAssertEqual(ui.model.conversation?.id, fixture.other)
        XCTAssertEqual(try fixture.thread(fixture.other).composerAttachments?.first?.name, path.lastPathComponent)
        XCTAssertEqual(try fixture.thread(fixture.active).composerAttachments, [fixture.attachment])
        let folder = fixture.root.appendingPathComponent("New project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let folderItem = NSPasteboardItem()
        folderItem.setString(folder.absoluteString, forType: .fileURL)
        try ui.deliver(folderItem, from: nil, to: ui.rowDestination(fixture.other),
                       offering: .copy, expects: true, mask: .copy)
        XCTAssertEqual(ui.model.project?.path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(try fixture.thread(fixture.other).composerAttachments?.count, 1)
    }

    private func performDrops(_ fixture: Fixture) async throws {
        let ui = try SidebarDragTestWindow(model: SidebarDragTestWindow.open(fixture.root))
        defer { ui.close() }
        let model = ui.model
        try await ui.waitForRow(fixture.active)
        model.updateSidebarScope { $0.selectOnly(fixture.project) }
        model.draft = "Unsent draft typed immediately before dragging"
        model.editQueuedMessage(fixture.queue.id)
        model.draft = "Uncommitted queue edit"
        XCTAssertEqual(model.editingQueuedMessageID, fixture.queue.id)
        try await ui.expectOrder([fixture.firstPin, fixture.secondPin, fixture.active, fixture.other])
        XCTAssertNil(ui.element("thread-row-\(fixture.filteredPin)"))

        try await ui.drop(fixture.firstPin, onto: fixture.secondPin, expects: true, height: 0.9)
        try await ui.expectOrder([fixture.secondPin, fixture.firstPin, fixture.active, fixture.other])
        let sameTitle = try fixture.thread(fixture.active)
        XCTAssertEqual(sameTitle.title, try fixture.thread(fixture.firstPin).title)
        try await ui.drop(fixture.active, onto: fixture.firstPin, expects: true, height: 0.1)
        try await ui.expectOrder([fixture.secondPin, fixture.active, fixture.firstPin, fixture.other])
        XCTAssertEqual(try fixture.thread(fixture.active).threadShelf, .pinned)
        XCTAssertEqual(try fixture.thread(fixture.filteredPin).sidebarPinOrder, "n")
        XCTAssertEqual(try fixture.thread(fixture.firstPin).threadShelf, .pinned)
        XCTAssertEqual(try fixture.thread(fixture.active).composerAttachments, [fixture.attachment])

        try await ui.drop(fixture.active, onto: fixture.other, expects: true)
        try await ui.expectOrder([fixture.secondPin, fixture.firstPin, fixture.other, fixture.active])
        XCTAssertEqual(try fixture.thread(fixture.active).threadShelf, .active)
        try await ui.drop(fixture.active, onto: fixture.other, expects: true)
        try await ui.expectOrder([fixture.secondPin, fixture.firstPin, fixture.active, fixture.other])

        model.setSnoozedShelfExpanded(true)
        try await ui.waitForRow(fixture.snoozed)
        try await ui.drop(fixture.snoozed, onto: fixture.other, expects: true)
        XCTAssertNil(try fixture.thread(fixture.snoozed).snoozedUntil)
        try await ui.expectOrder([fixture.secondPin, fixture.firstPin, fixture.active, fixture.snoozed, fixture.other])

        try await ui.waitForElement("settled-shelf")
        let disclosure = try XCTUnwrap(ui.element("settled-shelf"))
        XCTAssertTrue(disclosure.accessibilityPerformPress?() == true)
        try await ui.waitForRow(fixture.settled)
        try await Task.sleep(for: .milliseconds(300))
        try await ui.drop(fixture.settled, onto: fixture.other, expects: true)
        try await ui.expectOrder([fixture.secondPin, fixture.firstPin, fixture.active, fixture.snoozed, fixture.settled, fixture.other])
        XCTAssertEqual(try fixture.thread(fixture.settled).threadShelf, .active)
        model.moveConversation(fixture.settled, in: fixture.project, to: .settled)
        XCTAssertNil(try fixture.thread(fixture.settled).sidebarActiveOrder)
        model.moveConversation(fixture.settled, in: fixture.project, to: .active)
        try await ui.expectOrder([fixture.secondPin, fixture.firstPin, fixture.active, fixture.snoozed, fixture.settled, fixture.other])

        let before = try Data(contentsOf: fixture.index)
        let source = try ui.dragSource(fixture.active)
        let item = source.drag.begin(try XCTUnwrap(source.origin()))
        let destination = try ui.rowDestination(fixture.firstPin)
        try ui.deliver(item, from: SidebarThreadDrag(), to: destination, offering: [])
        source.drag.cancel()
        try ui.deliver(item, from: source.drag, to: destination, offering: [])
        XCTAssertEqual(try Data(contentsOf: fixture.index), before)

        // The old token stays tied to the scope that supplied it, even before the view re-renders.
        let scopedItem = source.drag.begin(try XCTUnwrap(source.origin()))
        model.updateSidebarScope { $0.clear() }
        try ui.deliver(scopedItem, from: source.drag, to: destination, offering: [])
        source.drag.cancel()
        try await ui.expectOrder([fixture.secondPin, fixture.filteredPin, fixture.firstPin,
                                  fixture.active, fixture.snoozed, fixture.settled, fixture.other])
        model.updateSidebarScope { $0.selectOnly(fixture.project) }
        try await ui.expectOrder([fixture.secondPin, fixture.firstPin, fixture.active, fixture.snoozed, fixture.settled, fixture.other])

        let previous = fixture.root.appendingPathComponent(WorkspaceStore.previousIndexName)
        let held = fixture.root.appendingPathComponent("held-previous.json")
        try FileManager.default.moveItem(at: previous, to: held)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: false)
        let beforeFailure = try Data(contentsOf: fixture.index)
        try await ui.drop(fixture.active, onto: fixture.firstPin, expects: false)
        XCTAssertEqual(try Data(contentsOf: fixture.index), beforeFailure)
        XCTAssertEqual(model.conversation?.id, fixture.active)
        XCTAssertEqual(model.editingQueuedMessageID, fixture.queue.id)
        XCTAssertEqual(model.draft, "Uncommitted queue edit")
        XCTAssertEqual(model.queuedMessages, [fixture.queue])
        XCTAssertNotNil(model.error)
        try FileManager.default.removeItem(at: previous)
        try FileManager.default.moveItem(at: held, to: previous)

        try await ui.drop(fixture.active, onto: fixture.firstPin, expects: true)
        let finalOrder = [fixture.secondPin, fixture.active, fixture.firstPin, fixture.snoozed, fixture.settled, fixture.other]
        try await ui.expectOrder(finalOrder)
        XCTAssertEqual(model.conversation?.id, fixture.active)
        XCTAssertEqual(model.draft, "Uncommitted queue edit")
        XCTAssertEqual(model.editingQueuedMessageID, fixture.queue.id)
        model.updateQueuedMessage()
        XCTAssertEqual(model.draft, "Unsent draft typed immediately before dragging")
        XCTAssertEqual(model.composerAttachments, [fixture.attachment])
        try fixture.writeExpectedOrder(finalOrder)
    }

    private func verifyRelaunch(_ root: URL) async throws {
        let expected = try JSONDecoder().decode([UUID].self,
                                               from: Data(contentsOf: root.appendingPathComponent("expected-order.json")))
        let model = SidebarDragTestWindow.open(root)
        let ui = try SidebarDragTestWindow(model: model)
        defer { ui.close() }
        try await ui.expectOrder(expected)
        XCTAssertEqual(model.conversation?.id, expected[1])
        XCTAssertEqual(model.draft, "Unsent draft typed immediately before dragging")
        XCTAssertEqual(model.composerAttachments.map(\.name), ["draft.txt"])
        XCTAssertEqual(model.queuedMessages.first?.text, "Uncommitted queue edit")
        print("Confirmed the same sidebar row order in process \(getpid()).")
    }

    private struct Fixture {
        let root: URL
        let project: UUID
        let firstPin: UUID
        let secondPin: UUID
        let active: UUID
        let other: UUID
        let snoozed: UUID
        let settled: UUID
        let filteredPin: UUID
        let queue: QueuedMessage
        let attachment: ComposerAttachment
        var index: URL { root.appendingPathComponent(WorkspaceStore.indexName) }

        init(onlyOneActive: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Sidebar drag \(UUID())")
            project = UUID()
            firstPin = UUID()
            secondPin = UUID()
            active = UUID()
            other = UUID()
            snoozed = UUID()
            settled = UUID()
            filteredPin = UUID()
            queue = QueuedMessage(text: "Saved queue")
            attachment = try ComposerAttachment(name: "draft.txt", payload: ComposerAttachment.payload(for: Data("attachment bytes".utf8)))
            let date = Date(timeIntervalSince1970: 100)
            let a = Conversation(id: active, title: "Same title", lastActiveAt: date,
                                 composerAttachments: [attachment], queuedMessages: [queue])
            let p1 = Conversation(id: firstPin, title: "Same title", lastActiveAt: date, shelf: .pinned)
            let p2 = Conversation(id: secondPin, title: "Second pin", lastActiveAt: date.addingTimeInterval(-1), shelf: .pinned)
            let o = Conversation(id: other, title: "Other thread", lastActiveAt: date.addingTimeInterval(-2))
            let z = Conversation(id: snoozed, title: "Snoozed", snoozedUntil: Date().addingTimeInterval(3600))
            let s = Conversation(id: settled, title: "Settled", shelf: .settled)
            let first = Project(id: project, path: root.path, title: "Project",
                                conversations: onlyOneActive ? [a] : [a, p1, p2, o, z, s], selectedConversation: active)
            let filtered = Project(id: UUID(), path: root.path, title: "Filtered",
                                   conversations: [Conversation(id: filteredPin, title: "Hidden pin", shelf: .pinned,
                                                                sidebarPinOrder: "n")])
            try WorkspaceStore(root: root).save(Workspace(projects: onlyOneActive ? [first] : [first, filtered],
                                                          selectedProject: project, welcomeCompleted: true))
        }

        init(opening root: URL) throws {
            self.root = root
            let state = try JSONDecoder().decode(Workspace.self,
                from: Data(contentsOf: root.appendingPathComponent(WorkspaceStore.indexName)))
            let project = try XCTUnwrap(state.activeProject)
            self.project = project.id
            let threads = project.conversations
            let selected = try XCTUnwrap(threads.first { $0.id == project.selectedConversation })
            active = selected.id
            firstPin = try XCTUnwrap(threads.first { $0.title == selected.title && $0.threadShelf == .pinned }).id
            secondPin = try XCTUnwrap(threads.first { $0.title == "Second pin" }).id
            other = try XCTUnwrap(threads.first { $0.title == "Other thread" }).id
            snoozed = try XCTUnwrap(threads.first { $0.title == "Snoozed" }).id
            settled = try XCTUnwrap(threads.first { $0.title == "Settled" }).id
            filteredPin = try XCTUnwrap(state.projects.first { $0.id != project.id }?.conversations.first).id
            queue = try XCTUnwrap(selected.queuedMessages?.first)
            attachment = try XCTUnwrap(selected.composerAttachments?.first)
        }

        func thread(_ id: UUID) throws -> Conversation {
            let state = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
            return try XCTUnwrap(state.projects.flatMap(\.conversations).first(where: { $0.id == id }))
        }

        func writeExpectedOrder(_ ids: [UUID]) throws {
            try JSONEncoder().encode(ids).write(to: root.appendingPathComponent("expected-order.json"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private extension SidebarDragTestWindow {
    func expectOrder(_ expected: [UUID]) async throws {
        for id in expected { try await waitForRow(id) }
        let frames = try expected.map { id in
            (id: id, frame: try XCTUnwrap(element("thread-row-\(id)")?.accessibilityFrame?()))
        }
        let actual = frames.sorted { $0.frame.midY > $1.frame.midY }
        XCTAssertEqual(actual.map(\.id), expected)
        print("Visible top-to-bottom rows: \(actual.map { "\($0.id)@\($0.frame.midY)" }.joined(separator: " "))")
    }

    func rowDestination(_ id: UUID) throws -> AttachmentDropDestination.Destination {
        let row = try destination("thread-row-\(id)", requiringSource: true)
        XCTAssertEqual(row.source?.origin()?.threadID, id)
        return row
    }

    func destination(_ id: String, requiringSource: Bool) throws -> AttachmentDropDestination.Destination {
        host.layoutSubtreeIfNeeded()
        let ax = try XCTUnwrap(element(id)?.accessibilityFrame?())
        let point = window.convertPoint(fromScreen: NSPoint(x: ax.midX, y: ax.midY))
        return try XCTUnwrap(destinations.first { view in
            (requiringSource ? view.source != nil : view.registeredDraggedTypes.contains(SidebarThreadDrag.type)) &&
                view.bounds.intersection(view.visibleRect).contains(view.convert(point, from: nil))
        }, "No registered thread drop destination at \(point) for \(id).")
    }

    func dragSource(_ id: UUID) throws -> SidebarThreadDrag.Source {
        let source = try XCTUnwrap(rowDestination(id).source)
        XCTAssertEqual(source.origin()?.threadID, id)
        return source
    }

    func drop(_ sourceID: UUID, onto target: UUID, expects result: Bool, height: CGFloat = 0.5) async throws {
        try await waitForRow(sourceID)
        try await waitForRow(target)
        let source = try dragSource(sourceID)
        let item = source.drag.begin(try XCTUnwrap(source.origin()))
        try await waitForElement("sidebar-active-drop")
        let view = try rowDestination(target)
        let y = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.height * height), to: nil).y
        print("Drop \(sourceID) onto \(target) at window y=\(y).")
        try deliver(item, from: source.drag, to: view, offering: .move, expects: result, height: height)
    }

    func deliver(_ item: NSPasteboardItem, from source: SidebarThreadDrag?, to destination: AttachmentDropDestination.Destination,
                 offering expected: NSDragOperation, expects result: Bool = false,
                 mask: NSDragOperation = .move, height: CGFloat = 0.5) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        XCTAssertTrue(board.writeObjects([copy]))
        let sender = ThreadDragSender(board: board, source: source, window: window,
                                      location: destination.convert(NSPoint(x: destination.bounds.midX,
                                                                            y: destination.bounds.height * height), to: nil),
                                      mask: mask)
        XCTAssertEqual(destination.draggingEntered(sender), expected)
        XCTAssertEqual(destination.prepareForDragOperation(sender), !expected.isEmpty)
        XCTAssertEqual(destination.performDragOperation(sender), result)
        destination.draggingExited(sender)
    }
}

private final class ThreadDragSender: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingSourceOperationMask: NSDragOperation

    init(board: NSPasteboard, source: SidebarThreadDrag?, window: NSWindow, location: NSPoint,
         mask: NSDragOperation = .move) {
        draggingPasteboard = board
        draggingSource = source
        draggingDestinationWindow = window
        draggingLocation = location
        draggingSourceOperationMask = mask
    }

    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
