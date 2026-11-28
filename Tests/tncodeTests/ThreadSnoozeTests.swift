import AppKit
import SwiftUI
import XCTest
@testable import tncode

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

    func testConfiguredOptionsSortByWakeMinuteAndKeepTheFirstTie() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = instant("2027-03-14T22:00:24Z")
        let fixed = ThreadSnoozeSchedule.Option.at(day: .today, time: "15:30")
        let elapsed = ThreadSnoozeSchedule.Option.after(minutes: 30)
        let options: [ThreadSnoozeSchedule.Option] = [
            .at(day: .sunday, time: "18:00"), .at(day: .today, time: "14:59"),
            fixed, elapsed, .after(minutes: 1440), .at(day: .tomorrow, time: "09:00"), elapsed
        ]
        let menu = ThreadSnoozeSchedule.presets(at: now, options: options, calendar: calendar)
        XCTAssertEqual(menu.map(\.label), ["This afternoon", "Tomorrow", "In 1 day", "Next Sunday"])
        XCTAssertEqual(menu.map(\.shownDeadline), [instant("2027-03-14T22:30:00Z"), instant("2027-03-15T16:00:00Z"),
                                                   instant("2027-03-15T22:00:24Z"), instant("2027-03-22T01:00:00Z")])
        XCTAssertEqual(menu.first?.deadline(at: now.addingTimeInterval(21)), instant("2027-03-14T22:30:00Z"))
        XCTAssertTrue(ThreadSnoozeSchedule.presets(at: now, options: [], calendar: calendar).isEmpty)
        let defaults = ThreadSnoozeSchedule.defaultOptions
        XCTAssertEqual(ThreadSnoozeSchedule.nextOption(in: []), defaults[0])
        XCTAssertEqual(ThreadSnoozeSchedule.nextOption(in: defaults), elapsed)
        XCTAssertEqual(ThreadSnoozeSchedule.nextOption(in: defaults + [elapsed]), .at(day: .saturday, time: "09:00"))
        XCTAssertFalse(ThreadSnoozeSchedule.Option.at(day: .friday, time: "24:00").isValid)
        XCTAssertFalse(ThreadSnoozeSchedule.Option.after(minutes: 43201).isValid)
    }

    func testNativeShelfWakeUndoAndQueueEditOwnership() async throws {
        try requireTestDesktop()
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        let host = try OffscreenSnoozeView(workspace: model)
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
        try requireTestDesktop()
        let fixture = try Fixture()
        let model = fixture.open(now: Date.init)
        defer { model.terminate() }
        let host = try OffscreenSnoozeView(workspace: model)
        defer { host.close() }
        _ = try await host.waitFor("conversation-title")

        try model.snooze(fixture.selected, amount: "0.02", unit: .minutes)
        _ = try await host.waitFor("wake-open-thread")
        _ = try await host.waitFor("dismiss-open-thread-woke")
        XCTAssertNil(model.nextSnoozeUpdate)
        XCTAssertEqual(model.conversation?.id, fixture.selected.threadID)
    }

    func testDeadlineAndRelaunchKeepWokeScopedToEachThreadAndWorkspace() async throws {
        try requireTestDesktop()
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
            try model.archiveConversation(fixture.archived.threadID, in: fixture.archived.projectID, archived: true)
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
        let host = try OffscreenSnoozeView(workspace: reopened)
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
        try requireTestDesktop()
        let fixture = try Fixture()
        let model = fixture.open()
        defer { model.terminate() }
        let initial = fixture.now
        var submitted = false
        let host = try OffscreenSnoozeView(CustomSnoozeView(model: model, target: fixture.selected, editOptions: {}) {
            submitted = $0
        })
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

    func testNativeSnoozeOptionsPreserveDraftQueueAndDeadlinesAcrossReopen() async throws {
        try requireTestDesktop()
        if let path = ProcessInfo.processInfo.environment[Self.snoozeEditorFixture] {
            let fixture = try Fixture(opening: URL(fileURLWithPath: path))
            try await runSnoozeOptionsEditor(fixture)
            return
        }

        let fixture = try Fixture()
        let oldDeadline = fixture.now.addingTimeInterval(172800)
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        runner.arguments = ["xctest", "-XCTest", "\(String(reflecting: Self.self))/\(#function.dropLast(2))",
                            Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.snoozeEditorFixture] = fixture.root.path
        runner.environment = environment
        try runner.run()
        runner.waitUntilExit()
        guard runner.terminationStatus == 0 else {
            throw WorkspaceError("The first AppKit process failed the snooze options workflow.")
        }

        let reopened = fixture.open()
        defer { reopened.terminate() }
        XCTAssertNil(reopened.startupFailure)
        XCTAssertEqual(reopened.draft, "Open draft")
        XCTAssertEqual(reopened.queuedMessages, [fixture.queue])
        let host = try OffscreenSnoozeView(workspace: reopened)
        defer { host.close() }
        try await host.withSnoozeMenu(for: fixture.archived.threadID) { menu in
            XCTAssertTrue(try XCTUnwrap(menu.items.first).title.hasPrefix("In 31 minutes"))
            fixture.now.addTimeInterval(21)
            try host.choose("In 31 minutes", from: menu)
        }
        _ = try await host.waitFor("snoozed-shelf")
        let deadline = fixture.now.addingTimeInterval(31 * 60)
        let storedDeadline = try XCTUnwrap(fixture.saved()[fixture.archived.threadID]?.snoozedUntil)
        XCTAssertEqual(storedDeadline, deadline)
        print("Relaunch process \(ProcessInfo.processInfo.processIdentifier) stored a snooze \(storedDeadline.timeIntervalSince(fixture.now)) seconds from selection")

        reopened.openSettings(.threads, anchor: .snoozeOptions)
        try await host.press("reset-snooze-options")
        XCTAssertNil(host.element("reset-snooze-options"))
        XCTAssertNil(try fixture.savedWorkspace().snoozeOptions)
        XCTAssertEqual(reopened.workspace.effectiveSnoozeOptions, ThreadSnoozeSchedule.defaultOptions)
        XCTAssertEqual(try fixture.saved()[fixture.archived.threadID]?.snoozedUntil, deadline)
        XCTAssertEqual(try fixture.saved()[fixture.pinned.threadID]?.snoozedUntil, oldDeadline)
    }

    private static let snoozeEditorFixture = "TNCODE_SNOOZE_EDITOR_FIXTURE"

    private func runSnoozeOptionsEditor(_ fixture: Fixture) async throws {
        let oldDeadline = fixture.now.addingTimeInterval(172800)
        let edited = ThreadSnoozeSchedule.Option.after(minutes: 31)
        let model = fixture.open()
        defer { model.terminate() }
        try model.snooze(fixture.pinned, amount: "2", unit: .days)
        model.draft = "Open draft"
        model.editQueuedMessage(fixture.queue.id)
        model.draft = "In-progress queue edit"

        let host = try OffscreenSnoozeView(workspace: model)
        defer { host.close() }
        try await host.withSnoozeMenu(for: fixture.selected.threadID) { menu in
            try host.choose("Custom…", from: menu)
        }
        try await host.press("edit-snooze-options")
        _ = try await host.waitFor("settings-heading-threads")
        _ = try await host.waitFor("snooze-options")
        XCTAssertNil(host.element("confirm-custom-snooze"))
        XCTAssertNil(try fixture.saved()[fixture.selected.threadID]?.snoozedUntil)

        try await host.press("add-snooze-option")
        _ = try await host.waitFor("remove-snooze-option-6")
        XCTAssertEqual(try fixture.savedWorkspace().effectiveSnoozeOptions.last, .after(minutes: 30))
        try await host.editAmount(from: "30", to: "31")
        XCTAssertTrue(try fixture.savedWorkspace().effectiveSnoozeOptions.contains(edited))
        let editedRow = try host.durationRow(amount: "31")
        try await host.press("remove-snooze-option-\(editedRow == 1 ? 2 : 1)")
        let options = try fixture.savedWorkspace().effectiveSnoozeOptions
        XCTAssertEqual(options.count, 5)
        XCTAssertTrue(options.contains(edited))

        let backup = fixture.root.appendingPathComponent(WorkspaceStore.previousIndexName)
        let savedBackup = fixture.root.appendingPathComponent("held-backup.json")
        try FileManager.default.moveItem(at: backup, to: savedBackup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        try await host.press("add-snooze-option")
        _ = try await host.waitFor("snooze-options-save-error")
        XCTAssertEqual(model.workspace.effectiveSnoozeOptions, options)
        XCTAssertEqual(try fixture.savedWorkspace().effectiveSnoozeOptions, options)
        XCTAssertNil(host.element("remove-snooze-option-6"))
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.moveItem(at: savedBackup, to: backup)
        try await host.press("add-snooze-option")
        _ = try await host.waitFor("remove-snooze-option-6")
        XCTAssertNil(host.element("snooze-options-save-error"))
        XCTAssertEqual(Set(try fixture.savedWorkspace().effectiveSnoozeOptions),
                       Set(ThreadSnoozeSchedule.defaultOptions + [edited]))

        try await host.press("settings-close")
        try await host.waitForSheetDismissal()
        XCTAssertEqual(model.conversation?.id, fixture.selected.threadID)
        XCTAssertEqual(model.editingQueuedMessageID, fixture.queue.id)
        XCTAssertEqual(model.draft, "In-progress queue edit")
        XCTAssertEqual(try fixture.saved()[fixture.selected.threadID]?.composerText, "Open draft")
        XCTAssertEqual(try fixture.saved()[fixture.selected.threadID]?.queuedMessages, [fixture.queue])
        XCTAssertEqual(try fixture.saved()[fixture.pinned.threadID]?.snoozedUntil, oldDeadline)
        print("Snooze options persisted by AppKit process \(ProcessInfo.processInfo.processIdentifier)")
    }

    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private final class Fixture {
        let root: URL
        private let ownsRoot: Bool
        var now = Date(timeIntervalSince1970: 1_804_964_424)
        let queue: QueuedMessage
        let initial: Workspace
        let selected: ThreadSnoozeTarget
        let pinned: ThreadSnoozeTarget
        let settled: ThreadSnoozeTarget
        let archived: ThreadSnoozeTarget

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Snooze \(UUID())")
            ownsRoot = true
            queue = QueuedMessage(text: "Original queued message")
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

        init(opening root: URL) throws {
            self.root = root
            ownsRoot = false
            let index = root.appendingPathComponent(WorkspaceStore.indexName)
            initial = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
            let project = try XCTUnwrap(initial.activeProject)
            let thread = try XCTUnwrap(project.conversations.first { $0.id == project.selectedConversation })
            let other = try XCTUnwrap(initial.projects.first { $0.id != project.id })
            selected = .init(projectID: project.id, threadID: thread.id)
            pinned = .init(projectID: other.id, threadID: try XCTUnwrap(other.conversations.first?.id))
            settled = .init(projectID: project.id, threadID: try XCTUnwrap(project.conversations.first { $0.title == "Settled" }?.id))
            archived = .init(projectID: project.id, threadID: try XCTUnwrap(project.conversations.first { $0.title == "Archive target" }?.id))
            queue = try XCTUnwrap(thread.queuedMessages?.first)
        }

        deinit {
            if ownsRoot { try? FileManager.default.removeItem(at: root) }
        }

        func saved(at location: URL? = nil) throws -> [UUID: Conversation] {
            let state = try savedWorkspace(at: location)
            return Dictionary(uniqueKeysWithValues: state.projects.flatMap(\.conversations).map { ($0.id, $0) })
        }

        func savedWorkspace(at location: URL? = nil) throws -> Workspace {
            let index = (location ?? root).appendingPathComponent("workspace.json")
            return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: index))
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

    convenience init(workspace model: WorkspaceModel) throws {
        let board = NSPasteboard.withUniqueName()
        let defaultsName = "dev.tncode.snooze-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        try self.init(WorkspaceWithSnoozeSettings(model: model, defaults: defaults, pasteboard: board)
            .defaultAppStorage(defaults))
        pasteboard = board
        self.defaults = defaults
        self.defaultsName = defaultsName
    }

    init(_ view: some View) throws {
        try requireTestDesktop()
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
        return find(host) ?? find(window) ?? window.sheets.lazy.compactMap(find).first
    }

    func waitFor(_ id: String) async throws -> AnyObject {
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            for sheet in window.sheets {
                sheet.contentView?.layoutSubtreeIfNeeded()
            }
            if let found = element(id) {
                XCTAssertTrue(window.sheets.allSatisfy { sheet in
                    sheet.alphaValue == 0 || NSScreen.screens.allSatisfy { !$0.frame.intersects(sheet.frame) }
                })
                return found
            }
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

    func waitForSheetDismissal() async throws {
        for _ in 0..<100 {
            if window.sheets.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WorkspaceError("The AppKit sheet did not dismiss.")
    }

    func withSnoozeMenu(for threadID: UUID, choose: (NSMenu) throws -> Void) async throws {
        let row = try await waitFor("thread-row-\(threadID)")
        let frame = try XCTUnwrap(row.accessibilityFrame?())
        let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        try autoreleasepool {
            let menu = try XCTUnwrap(host.menu(for: event), "The sidebar row provides an AppKit context menu")
            menu.update()
            let snooze = try XCTUnwrap(menu.item(withTitle: "Snooze")?.submenu)
            snooze.update()
            try choose(snooze)
        }
    }

    func choose(_ prefix: String, from menu: NSMenu) throws {
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title.hasPrefix(prefix) }, prefix)
        menu.performActionForItem(at: index)
    }

    func durationRow(amount: String) throws -> Int {
        let id = try XCTUnwrap(durationField(amount: amount).identifier?.rawValue)
        return try XCTUnwrap(Int(id.split(separator: "-").last ?? ""))
    }

    private func durationField(amount: String) throws -> NSTextField {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue.hasPrefix("snooze-option-amount-") == true,
               field.stringValue == amount { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(window.attachedSheet?.contentView.flatMap(find), "Native amount field \(amount)")
    }

    func editAmount(from amount: String, to text: String) async throws {
        let field = try durationField(amount: amount)
        let sheet = try XCTUnwrap(field.window)
        XCTAssertTrue(sheet.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(sheet.makeFirstResponder(nil))
        await Task.yield()
    }
}

private struct WorkspaceWithSnoozeSettings: View {
    @ObservedObject var model: WorkspaceModel
    let defaults: UserDefaults
    let pasteboard: NSPasteboard

    var body: some View {
        WorkspaceView(model: model, chatWidthMode: .comfortable,
                      browserDefaults: defaults, workspacePasteboard: pasteboard)
            .sheet(item: $model.settingsRequest) { request in
                SettingsView(model: model, appearance: AppearanceSettings(defaults: defaults),
                             browserDefaults: defaults, request: request, pasteboard: pasteboard, openWelcome: {})
            }
    }
}

private final class SnoozeTestPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        sheetWindow.alphaValue = 0
        super.beginSheet(sheetWindow, completionHandler: handler)
        sheetWindow.setFrameOrigin(frame.origin)
    }
}
