import AppKit
import SwiftUI
import XCTest
@testable import PiWorkspace

@MainActor
final class ThreadSnoozeTests: XCTestCase {
    func testPresetsUseLocalCalendarAndResolveElapsedTimeWhenPicked() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let sunday = instant("2027-03-14T22:00:24Z")
        let options = ThreadSnoozeSchedule.presets(at: sunday, calendar: calendar)
        XCTAssertEqual(options.map(\.id), ["one-hour", "three-hours", "tomorrow"])
        XCTAssertEqual(options.map(\.shownDeadline), [
            instant("2027-03-14T23:00:24Z"), instant("2027-03-15T01:00:24Z"), instant("2027-03-15T16:00:00Z")
        ])
        XCTAssertEqual(options[0].deadline(at: sunday.addingTimeInterval(32)), instant("2027-03-14T23:00:56Z"))

        let monday = instant("2027-03-15T02:30:00Z")
        let late = ThreadSnoozeSchedule.presets(at: monday, calendar: calendar)
        XCTAssertFalse(late.contains { $0.id == "this-evening" })
        XCTAssertEqual(late.last?.shownDeadline, instant("2027-03-15T16:00:00Z"))
        let next = ThreadSnoozeSchedule.presets(at: instant("2027-03-15T18:30:00Z"), calendar: calendar)
        XCTAssertEqual(next.last?.shownDeadline, instant("2027-03-22T16:00:00Z"))
    }

    func testCustomDateRejectsRolloverAndDSTGapAndDurationIsElapsed() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = instant("2027-03-13T20:00:00Z")
        for (date, time) in [("2027-02-29", "09:00"), ("2027-03-14", "02:30"),
                             ("2027-03-13", "24:00"), ("2027-03-13", "12:00")] {
            XCTAssertNil(ThreadSnoozeSchedule.deadline(date: date, time: time, after: now, calendar: calendar))
        }
        XCTAssertEqual(ThreadSnoozeSchedule.deadline(date: "2027-03-14", time: "09:00", after: now, calendar: calendar),
                       instant("2027-03-14T16:00:00Z"))
        XCTAssertEqual(ThreadSnoozeSchedule.deadline(date: "2027-11-07", time: "01:30", after: now, calendar: calendar),
                       instant("2027-11-07T08:30:00Z"))
        for amount in ["0", "-1", "NaN", "1e300"] {
            XCTAssertNil(ThreadSnoozeSchedule.deadline(amount: amount, unit: .hours, after: now))
        }
        XCTAssertEqual(ThreadSnoozeSchedule.deadline(amount: "1.5", unit: .hours, after: now),
                       instant("2027-03-13T21:30:00Z"))
        XCTAssertEqual(ThreadSnoozeSchedule.deadline(amount: "1", unit: .days, after: now),
                       instant("2027-03-14T20:00:00Z"))
    }

    func testNativeShelfWakeUndoAndQueueEditOwnership() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        let host = OffscreenSnoozeView(workspace: model)
        defer { host.close() }

        XCTAssertNil(model.nextSnoozeUpdate)
        model.draft = "Unsent draft"
        model.editQueuedMessage(fixture.queue.id)
        model.draft = "Pending queue edit"

        let preset = try XCTUnwrap(model.snoozePresets.first { $0.id == "one-hour" })
        model.snooze(fixture.selected, preset: preset)
        try model.snooze(fixture.pinned, amount: "30", unit: .minutes)
        let stored = try fixture.saved()
        XCTAssertEqual(stored[fixture.selected.threadID]?.snoozedUntil, fixture.now.addingTimeInterval(3600))
        XCTAssertEqual(stored[fixture.selected.threadID]?.composerText, "Unsent draft")
        XCTAssertEqual(stored[fixture.selected.threadID]?.queuedMessages, [fixture.queue])
        XCTAssertEqual(model.editingQueuedMessageID, fixture.queue.id)
        XCTAssertEqual(model.draft, "Pending queue edit")

        let pinnedRow = "wake-snoozed-thread-\(fixture.pinned.threadID)"
        _ = try await host.waitFor("snoozed-shelf")
        XCTAssertNil(host.element(pinnedRow))
        try await host.press("snoozed-shelf")
        XCTAssertEqual(model.workspace.snoozedShelfExpanded, true)
        model.advanceAfterSidebarSnooze(fixture.selected, next: fixture.pinned)
        XCTAssertEqual(model.conversation?.id, fixture.selected.threadID)
        let earlier = try await host.waitFor(pinnedRow)
        let later = try await host.waitFor("wake-snoozed-thread-\(fixture.selected.threadID)")
        XCTAssertGreaterThan(earlier.accessibilityFrame?().minY ?? 0, later.accessibilityFrame?().minY ?? 0)
        _ = try await host.waitFor("snooze-deadline-\(fixture.selected.threadID)")
        try await host.press("snoozed-shelf")
        XCTAssertEqual(model.workspace.snoozedShelfExpanded, false)
        try await host.press("snoozed-shelf")
        try await host.press(pinnedRow)
        XCTAssertNil(try fixture.saved()[fixture.pinned.threadID]?.snoozedUntil)
        XCTAssertEqual(try fixture.saved()[fixture.pinned.threadID]?.threadShelf, .pinned)
        XCTAssertEqual(model.conversation?.id, fixture.selected.threadID)
        XCTAssertEqual(model.draft, "Pending queue edit")

        try await host.press("undo-snooze")
        XCTAssertNil(try fixture.saved()[fixture.selected.threadID]?.snoozedUntil)
        XCTAssertNil(model.nextSnoozeUpdate)
        XCTAssertEqual(model.editingQueuedMessageID, fixture.queue.id)
        model.updateQueuedMessage()
        XCTAssertEqual(model.draft, "Unsent draft")
        XCTAssertEqual(try fixture.saved()[fixture.selected.threadID]?.queuedMessages?.first?.text, "Pending queue edit")

        try model.snooze(fixture.selected, amount: "1", unit: .hours)
        model.advanceAfterSidebarSnooze(fixture.selected, next: fixture.pinned)
        XCTAssertEqual(model.conversation?.id, fixture.pinned.threadID)
        model.selectConversation(fixture.selected.threadID, in: fixture.selected.projectID)
        XCTAssertEqual(model.draft, "Unsent draft")
        XCTAssertEqual(model.queuedMessages.first?.text, "Pending queue edit")
    }

    func testNativeTimerReturnsTheThreadWithoutReopeningIt() async throws {
        let fixture = try Fixture()
        let model = fixture.open(now: Date.init)
        defer { model.terminate() }
        let host = OffscreenSnoozeView(workspace: model)
        defer { host.close() }
        _ = try await host.waitFor("conversation-title")

        try model.snooze(fixture.selected, amount: "0.02", unit: .minutes)
        _ = try await host.waitFor("wake-open-thread")
        _ = try await host.waitFor("dismiss-open-thread-woke")
        XCTAssertNil(model.nextSnoozeUpdate)
        XCTAssertEqual(model.conversation?.id, fixture.selected.threadID)
    }

    func testDeadlineAndRelaunchKeepWokeScopedToEachThreadAndWorkspace() async throws {
        let fixture = try Fixture()
        let otherRoot = fixture.root.appendingPathComponent("other")
        try WorkspaceStore(root: otherRoot).save(fixture.initial)
        let other = fixture.open(at: otherRoot)
        defer { other.terminate() }
        XCTAssertNil(other.startupFailure)

        let deadline = fixture.now.addingTimeInterval(60)
        do {
            let model = fixture.open()
            try model.snooze(fixture.selected, amount: "1", unit: .minutes)
            try model.snooze(fixture.pinned, amount: "1", unit: .minutes)
            try model.snooze(fixture.settled, amount: "1", unit: .minutes)
            try model.snooze(fixture.archived, amount: "1", unit: .minutes)
            model.archiveConversation(fixture.archived.threadID, in: fixture.archived.projectID, archived: true)
            fixture.now = deadline.addingTimeInterval(-0.001)
            model.refreshSnoozes()
            XCTAssertEqual(model.nextSnoozeUpdate, deadline)
            XCTAssertEqual(model.conversation?.snoozeStatus(at: model.snoozeClock), .snoozed(until: deadline))
            fixture.now = deadline
            model.refreshSnoozes()
            XCTAssertEqual(model.conversation?.snoozeStatus(at: model.snoozeClock), .woke(at: deadline))
            XCTAssertNil(model.nextSnoozeUpdate)
            XCTAssertEqual(try fixture.saved()[fixture.selected.threadID]?.snoozedUntil, deadline)
            XCTAssertNil(try fixture.saved(at: otherRoot)[fixture.selected.threadID]?.snoozedUntil)
            XCTAssertNil(other.conversation?.snoozeStatus(at: fixture.now))
            XCTAssertNil(other.nextSnoozeUpdate)
            XCTAssertTrue(model.terminate())
        }

        fixture.now = deadline.addingTimeInterval(2)
        let reopened = fixture.open()
        defer { reopened.terminate() }
        XCTAssertNil(reopened.startupFailure)
        reopened.start()
        XCTAssertNil(reopened.nextSnoozeUpdate)
        XCTAssertEqual(reopened.snoozeUndoCount, 0)
        let host = OffscreenSnoozeView(workspace: reopened)
        defer { host.close() }
        let pinnedWoke = "dismiss-woke-\(fixture.pinned.threadID)"
        _ = try await host.waitFor(pinnedWoke)
        XCTAssertNil(host.element("dismiss-woke-\(fixture.settled.threadID)"))
        XCTAssertNil(host.element("dismiss-woke-\(fixture.archived.threadID)"))
        try await host.press("dismiss-open-thread-woke")
        XCTAssertNil(try fixture.saved()[fixture.selected.threadID]?.snoozedUntil)
        XCTAssertEqual(try fixture.saved()[fixture.pinned.threadID]?.snoozedUntil, deadline)
        try await host.press(pinnedWoke)
        XCTAssertNil(try fixture.saved()[fixture.pinned.threadID]?.snoozedUntil)
        XCTAssertEqual(try fixture.saved()[fixture.settled.threadID]?.threadShelf, .settled)
        XCTAssertEqual(try fixture.saved()[fixture.archived.threadID]?.archived, true)
    }

    func testNativeCustomSnoozeRejectsElapsedSelectionThenSavesFutureTime() async throws {
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        let initial = fixture.now
        var submitted = false
        let host = OffscreenSnoozeView(CustomSnoozeView(model: model, target: fixture.selected) { submitted = $0 })
        defer { host.close() }

        fixture.now.addTimeInterval(7200)
        try await host.press("confirm-custom-snooze")
        _ = try await host.waitFor("snooze-validation-error")
        XCTAssertFalse(submitted)
        XCTAssertNil(try fixture.saved()[fixture.selected.threadID]?.snoozedUntil)
        fixture.now = initial
        try await host.press("confirm-custom-snooze")
        XCTAssertTrue(submitted)
        XCTAssertEqual(try fixture.saved()[fixture.selected.threadID]?.snoozedUntil,
                       Date(timeIntervalSince1970: floor(initial.timeIntervalSince1970 / 60) * 60 + 3600))
    }

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Snooze \(UUID())")
        var now = Date(timeIntervalSince1970: 1_804_964_424)
        let queue = QueuedMessage(text: "Original queued message")
        let initial: Workspace
        let selected: ThreadSnoozeTarget
        let pinned: ThreadSnoozeTarget
        let settled: ThreadSnoozeTarget
        let archived: ThreadSnoozeTarget

        init() throws {
            let projectID = UUID(), otherProjectID = UUID()
            selected = .init(projectID: projectID, threadID: UUID())
            pinned = .init(projectID: otherProjectID, threadID: UUID())
            settled = .init(projectID: projectID, threadID: UUID())
            archived = .init(projectID: projectID, threadID: UUID())
            let threads = [
                Conversation(id: selected.threadID, title: "Selected", isDraft: false, queuedMessages: [queue]),
                Conversation(id: settled.threadID, title: "Settled", shelf: .settled, isDraft: false),
                Conversation(id: archived.threadID, title: "Archive target", isDraft: false)
            ]
            let project = Project(id: projectID, path: root.path, title: "Fixture",
                                  conversations: threads, selectedConversation: selected.threadID)
            let otherProject = Project(id: otherProjectID, path: root.path, title: "Other project", conversations: [
                Conversation(id: pinned.threadID, title: "Pinned", shelf: .pinned, isDraft: false)
            ])
            initial = Workspace(projects: [project, otherProject], selectedProject: projectID, welcomeCompleted: true)
            try WorkspaceStore(root: root).save(initial)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func saved(at location: URL? = nil) throws -> [UUID: Conversation] {
            let index = (location ?? root).appendingPathComponent("workspace.json")
            let state = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
            return Dictionary(uniqueKeysWithValues: state.projects.flatMap(\.conversations).map { ($0.id, $0) })
        }

        @MainActor
        func open(at location: URL? = nil, now clock: (() -> Date)? = nil) -> WorkspaceModel {
            WorkspaceModel(root: location ?? root, keychainService: UUID().uuidString, now: clock ?? { self.now },
                           readCredential: { _ in "fixture-key" }, makeProcess: { _, _ in Connection() })
        }
    }

    private final class Connection: PiConnection {
        var onEvent: ((PiEvent) -> Void)?
        var onClose: (() -> Void)?

        func send(_ command: any Encodable) throws {
            if command is OpenConversation { onEvent?(.ready([])) }
        }

        func close() {}
    }
}

@MainActor
private final class OffscreenSnoozeView {
    let window: NSPanel
    let host: NSHostingView<AnyView>
    let activationPolicy: NSApplication.ActivationPolicy
    private var pasteboard: NSPasteboard?
    private var defaults: UserDefaults?
    private var defaultsName: String?

    convenience init(workspace model: WorkspaceModel) {
        let board = NSPasteboard.withUniqueName()
        let defaultsName = "dev.piworkspace.snooze-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        self.init(WorkspaceView(model: model, chatWidthMode: .comfortable,
                                browserDefaults: defaults, workspacePasteboard: board)
            .defaultAppStorage(defaults))
        pasteboard = board
        self.defaults = defaults
        self.defaultsName = defaultsName
    }

    init(_ view: some View) {
        let app = NSApplication.shared
        activationPolicy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 2200, y: 0)
        window = SnoozeTestPanel(contentRect: NSRect(origin: origin, size: NSSize(width: 1100, height: 720)),
                                 styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(view))
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)
    }

    func close() {
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
        pasteboard?.releaseGlobally()
        if let defaultsName { defaults?.removePersistentDomain(forName: defaultsName) }
        NSApplication.shared.setActivationPolicy(activationPolicy)
    }

    func element(_ id: String) -> AnyObject? {
        var visited: [ObjectIdentifier: AnyObject] = [:]
        func find(_ node: AnyObject) -> AnyObject? {
            guard visited.updateValue(node, forKey: ObjectIdentifier(node)) == nil else { return nil }
            if node.accessibilityIdentifier?() == id { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let found = find(child as AnyObject) { return found }
            }
            return nil
        }
        return find(host) ?? find(window)
    }

    func waitFor(_ id: String) async throws -> AnyObject {
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            if let found = element(id) { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        let message = "Timed out waiting for \(id)."
        XCTFail(message)
        throw WorkspaceError(message)
    }

    func press(_ id: String) async throws {
        let button = try await waitFor(id)
        XCTAssertTrue(button.accessibilityPerformPress?() == true)
        await Task.yield()
    }
}

private final class SnoozeTestPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
