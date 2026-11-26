import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import PiWorkspace

final class ThreadTerminalTests: XCTestCase {
    func testGroupLimitAndSelectionAfterClosing() {
        var drawer = ThreadTerminalDrawerState(id: .init(thread: UUID(), path: "/fixture"))
        drawer.split(.horizontal)
        drawer.select(1)
        drawer.split(.vertical)
        drawer.split(.vertical)
        drawer.split(.horizontal)
        XCTAssertEqual(drawer.activeGroup?.panes, [1, 3, 4, 2])
        XCTAssertEqual(drawer.activeGroup?.direction, .vertical)
        XCTAssertFalse(drawer.canSplit)

        drawer.newTab()
        XCTAssertEqual(drawer.activePane, 5)
        XCTAssertTrue(drawer.cycle(by: 1))
        XCTAssertEqual(drawer.activePane, 1)
        drawer.close(3)
        XCTAssertEqual(drawer.activePane, 1)
        drawer.close(1)
        XCTAssertEqual(drawer.activePane, 4)
        drawer.close(4)
        XCTAssertEqual(drawer.activePane, 2)
        drawer.close(2)
        XCTAssertEqual(drawer.activePane, 5)
        drawer.close(5)
        XCTAssertFalse(drawer.isOpen)
        XCTAssertTrue(drawer.groups.isEmpty)
    }

    @MainActor
    func testRightPanelTerminalControlsKeepIndependentPTYs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("right-terminal-\(UUID())")
        let local = root.appendingPathComponent("local", isDirectory: true)
        let checkout = root.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Local file fixture\n".write(to: local.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        try git(in: local, ["init", "-q"])
        try git(in: local, ["add", "fixture.txt"])
        try git(in: local, ["-c", "user.name=Terminal Fixture", "-c", "user.email=terminal@example.invalid",
                            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "Fixture"])
        try git(in: local, ["worktree", "add", "--detach", "--", checkout.path, "HEAD"])

        let shell = root.appendingPathComponent("shell")
        try """
        #!/bin/sh
        [ -t 0 ] || exit 1
        printf 'READY-%s\\n' "$$"
        exec /bin/sh -i
        """.write(to: shell, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(shell.path, 0o700), 0)
        let previousShell = ProcessInfo.processInfo.environment["SHELL"]
        XCTAssertEqual(setenv("SHELL", shell.path, 1), 0)
        defer {
            if let previousShell { setenv("SHELL", previousShell, 1) }
            else { unsetenv("SHELL") }
        }

        let first = Conversation(id: UUID(), title: "Local Checkout", isDraft: false)
        let sameCheckout = Conversation(id: UUID(), title: "Another Thread", isDraft: false)
        let second = Conversation(id: UUID(), title: "Linked Checkout",
                                  location: .worktree(path: checkout.path, base: nil), isDraft: false)
        let pending = Conversation(id: UUID(), title: "Pending Checkout",
                                   location: .newWorktree(branch: "pending", base: "HEAD"), isDraft: false)
        let unavailable = Conversation(id: UUID(), title: "Missing Checkout",
                                       location: .worktree(path: root.appendingPathComponent("missing").path, base: nil),
                                       isDraft: false)
        let project = Project(id: UUID(), path: local.path, title: "Terminal Fixture",
                              conversations: [first, sameCheckout, second, pending, unavailable], selectedConversation: first.id)
        let state = root.appendingPathComponent("workspace", isDirectory: true)
        do {
            let store = try WorkspaceStore(root: state)
            try store.save(Workspace(projects: [project], selectedProject: project.id,
                                     model: ModelSettings(), welcomeCompleted: true))
        }
        let model = WorkspaceModel(root: state, keychainService: UUID().uuidString, readCredential: { _ in nil },
                                   makeProcess: { _, _ in throw WorkspaceError("The terminal fixture runs without an agent.") })
        XCTAssertNil(model.startupFailure)
        XCTAssertEqual(model.conversation?.id, first.id)
        defer { model.shutdown() }
        let suite = "dev.piworkspace.right-terminal.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        defer { app.setActivationPolicy(policy) }
        let origin = NSPoint(x: (NSScreen.screens.map(\.frame.minX).min() ?? 0) - 3200, y: 0)
        let window = TerminalOffscreenPanel(contentRect: NSRect(origin: origin, size: CGSize(width: 1500, height: 820)),
                                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let host = NSHostingView(rootView: WorkspaceView(model: model, chatWidthMode: .comfortable,
                                                        browserDefaults: defaults, workspacePasteboard: pasteboard)
            .defaultAppStorage(defaults))
        host.sizingOptions = []
        window.contentView = host
        window.setFrameOrigin(origin)
        XCTAssertTrue(NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) })
        window.orderBack(nil)

        func element(_ id: String) -> AnyObject? {
            host.layoutSubtreeIfNeeded()
            var visited = Set<ObjectIdentifier>()
            func find(_ node: AnyObject) -> AnyObject? {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return nil }
                if node.accessibilityIdentifier?() == id { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let result = find(child as AnyObject) { return result }
                }
                return nil
            }
            let windows = [window as NSWindow] + (window.childWindows ?? []) + [window.attachedSheet].compactMap { $0 }
            if let result = find(host) { return result }
            for window in windows {
                if let result = find(window) ?? window.contentView.flatMap({ find($0) }) { return result }
            }
            return nil
        }
        func press(_ id: String) async throws {
            try await waitFor("AX control \(id)") { element(id) != nil }
            XCTAssertTrue(element(id)?.accessibilityPerformPress?() == true, id)
        }
        func focused(_ id: String) async throws -> TerminalSessionView {
            try await waitFor("focused \(id) in \(model.conversation?.title ?? "?")") {
                host.layoutSubtreeIfNeeded()
                guard let view = window.firstResponder as? TerminalSessionView else { return false }
                return view.accessibilityIdentifier() == id && !view.isHidden && view.bounds.width > 100
            }
            return try XCTUnwrap(window.firstResponder as? TerminalSessionView)
        }
        func add(_ pane: Int, usingKey: Bool = false) async throws -> TerminalSessionView {
            try await press("add-panel-surface")
            if usingKey {
                try await waitFor("open Add Panel Surface menu") { element("add-panel-terminal") != nil }
                try key(kVK_ANSI_T, "t", modifiers: [])
            } else {
                try await press("add-panel-terminal")
            }
            return try await focused("right-terminal-pane-\(pane)")
        }
        func select(_ thread: Conversation) async throws {
            try await press("thread-row-\(thread.id)")
            try await waitFor(thread.title) { model.conversation?.id == thread.id }
        }
        func key(_ code: Int, _ characters: String, modifiers: NSEvent.ModifierFlags) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       characters: characters, charactersIgnoringModifiers: characters,
                                                       isARepeat: false, keyCode: UInt16(code)))
            app.sendEvent(event)
        }
        func tabFrame(_ id: String) throws -> CGRect {
            try XCTUnwrap(element(id)?.accessibilityFrame?())
        }
        func dragTab(_ id: String, onto target: String) throws {
            let from = try tabFrame(id)
            let to = try tabFrame(target)
            let start = window.convertPoint(fromScreen: CGPoint(x: from.midX, y: from.midY))
            let end = window.convertPoint(fromScreen: CGPoint(x: to.midX, y: to.midY))
            window.sendEvent(try mouse(.leftMouseDown, in: window, at: start))
            window.sendEvent(try mouse(.leftMouseDragged, in: window, at: end))
            window.sendEvent(try mouse(.leftMouseUp, in: window, at: end))
        }

        try await press("toggle-terminal")
        let drawer = try await focused("thread-terminal")
        let drawerPID = try await readyPID(of: drawer)
        let drawerTTY = try await verifyDirectoryAndTTY(in: local, terminal: drawer, name: "drawer")
        let right = try await add(2)
        let rightPID = try await readyPID(of: right)
        let rightTTY = try await verifyDirectoryAndTTY(in: local, terminal: right, name: "right")
        XCTAssertNotEqual(rightTTY, drawerTTY)
        XCTAssertNotEqual(rightPID, drawerPID)
        XCTAssertFalse(drawer.isHidden)
        XCTAssertGreaterThan(right.convert(right.bounds, to: nil).minY, drawer.convert(drawer.bounds, to: nil).minY)
        let initialWidth = right.bounds.width
        window.setContentSize(CGSize(width: 1100, height: 820))
        try await waitFor("right terminal follows workspace resize") { right.bounds.width < initialWidth }
        window.setContentSize(CGSize(width: 1500, height: 820))
        try await waitFor("right terminal fits restored panel") { right.bounds.width == initialWidth }
        XCTAssertEqual(right.process.shellPid, rightPID)
        send("printf 'RIGHT-MARKER-%s\\n' \"$$\"\n", to: right)
        try await waitFor("right marker") { self.output(of: right).contains("RIGHT-MARKER-\(rightPID)") }
        XCTAssertFalse(output(of: drawer).contains("RIGHT-MARKER"))

        send("/bin/sleep 60 & echo $! > right-background\n", to: right)
        let background = try await readPID(at: local.appendingPathComponent("right-background"))
        send("/bin/sh -c 'echo $$ > right-foreground; exec /bin/sleep 60'\n", to: right)
        let foreground = try await readPID(at: local.appendingPathComponent("right-foreground"))

        try await press("toggle-files")
        try await waitFor("loaded Files surface") { element("files-row-fixture.txt") != nil && right.isHidden }
        try await press("files-row-fixture.txt")
        try await waitFor("opened file") { element("files-preview") != nil }
        try key(kVK_ANSI_T, "t", modifiers: .command)
        try await waitFor("Cmd+T opens Add Panel Surface") { element("add-panel-terminal") != nil }
        try key(kVK_Escape, "\u{1B}", modifiers: [])
        try await waitFor("Escape dismisses Add Panel Surface") { element("add-panel-terminal") == nil }
        try await press("toggle-browser")
        try await waitFor("Browser beside the terminal") { element("browser-address") != nil }
        try await press("right-panel-tab-files")
        try await waitFor("Files restores alongside Browser") { element("files-row-fixture.txt") != nil }
        try await press("right-panel-tab-terminal-2")
        let afterFiles = try await focused("right-terminal-pane-2")
        XCTAssertTrue(afterFiles === right)
        try dragTab("right-panel-tab-browser", onto: "right-panel-tab-terminal-2")
        try await waitFor("tab drag reorders Browser before Terminal") {
            guard let browser = try? tabFrame("right-panel-tab-browser"),
                  let terminal = try? tabFrame("right-panel-tab-terminal-2") else { return false }
            return browser.minX < terminal.minX
        }
        XCTAssertFalse(right.isHidden)

        try await press("hide-right-panel")
        try await waitFor("hidden right panel keeps the drawer") {
            right.isHidden && !drawer.isHidden && element("right-panel-tab-terminal-2") == nil
        }
        try await press("toggle-right-panel")
        let restored = try await focused("right-terminal-pane-2")
        XCTAssertTrue(restored === right)
        XCTAssertTrue(output(of: restored).contains("RIGHT-MARKER-\(rightPID)"))

        try await select(sameCheckout)
        try await waitFor("thread scope even in the same checkout") {
            right.isHidden && drawer.isHidden && element("right-panel-tab-terminal-2") == nil
        }
        try await select(second)
        let linked = try await add(1, usingKey: true)
        let linkedPID = try await readyPID(of: linked)
        let linkedTTY = try await verifyDirectoryAndTTY(in: checkout, terminal: linked, name: "linked")
        XCTAssertEqual(Set([drawerTTY, rightTTY, linkedTTY]).count, 3)
        XCTAssertEqual(Set([drawerPID, rightPID, linkedPID]).count, 3)
        XCTAssertFalse(output(of: linked).contains("RIGHT-MARKER"))
        try await select(first)
        try await waitFor("restored local terminals") { !right.isHidden && !drawer.isHidden && linked.isHidden }
        XCTAssertEqual(right.process.shellPid, rightPID)
        for pid in [drawerPID, rightPID, linkedPID, background, foreground] { XCTAssertEqual(kill(pid, 0), 0) }

        try await press("split-right-terminal-horizontal")
        let split = try await focused("right-terminal-pane-3")
        let splitPID = try await readyPID(of: split)
        XCTAssertLessThanOrEqual(right.convert(right.bounds, to: nil).maxX, split.convert(split.bounds, to: nil).minX)
        try key(kVK_ANSI_LeftBracket, "[", modifiers: [.command, .shift])
        let previous = try await focused("right-terminal-pane-2")
        XCTAssertTrue(previous === right)
        try key(kVK_ANSI_RightBracket, "]", modifiers: [.command, .shift])
        let next = try await focused("right-terminal-pane-3")
        XCTAssertTrue(next === split)
        try await press("split-right-terminal-vertical")
        let vertical = try await focused("right-terminal-pane-4")
        let verticalPID = try await readyPID(of: vertical)
        XCTAssertGreaterThanOrEqual(split.convert(split.bounds, to: nil).minY, vertical.convert(vertical.bounds, to: nil).maxY)
        try await press("close-right-terminal-pane")
        try await press("confirm-close-right-terminal")
        try await waitFor("only the vertical pane closed") { kill(verticalPID, 0) == -1 }
        for pid in [drawerPID, rightPID, linkedPID, splitPID, background, foreground] { XCTAssertEqual(kill(pid, 0), 0) }

        try await press("close-right-panel-terminal-2")
        try await press("cancel-close-right-terminal")
        try await waitFor("cancelled close") { window.attachedSheet == nil }
        for pid in [drawerPID, rightPID, linkedPID, splitPID, background, foreground] { XCTAssertEqual(kill(pid, 0), 0) }

        try await press("close-right-panel-terminal-2")
        try await press("confirm-close-right-terminal")
        try await waitFor("panel tab, both shells and their jobs closed") {
            [rightPID, splitPID, foreground, background].allSatisfy { kill($0, 0) == -1 }
        }
        XCTAssertEqual(kill(drawerPID, 0), 0)
        XCTAssertEqual(kill(linkedPID, 0), 0)
        try await waitFor("neighboring Files tab selected") { element("files-row-fixture.txt") != nil }
        try await select(second)
        let linkedRestored = try await focused("right-terminal-pane-1")
        XCTAssertTrue(linkedRestored === linked)
        try await press("close-right-panel-terminal-1")
        try await press("confirm-close-right-terminal")
        try await waitFor("last right panel terminal closes the panel") {
            kill(linkedPID, 0) == -1 && element("hide-right-panel") == nil
        }
        try await select(pending)
        try await press("add-panel-surface")
        try await waitFor("pending checkout cannot launch a terminal") {
            element("add-panel-terminal")?.isAccessibilityEnabled?() == false
        }
        try await select(unavailable)
        let failedTerminal = try await add(1)
        try await waitFor("missing checkout error in terminal") {
            self.output(of: failedTerminal).contains("The workspace folder is unavailable.")
        }
        XCTAssertLessThanOrEqual(failedTerminal.process.shellPid, 0)
        print("Right panel PTYs: drawer \(drawerPID) \(drawerTTY), right \(rightPID) \(rightTTY), linked \(linkedPID) \(linkedTTY), split \(splitPID) and \(verticalPID). Closed jobs \(foreground) and \(background).")
    }

    @MainActor
    func testDrawerKeepsPTYSessionsThroughLayoutAndThreadChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-fixture-\(UUID().uuidString)", isDirectory: true)
        let local = root.appendingPathComponent("local", isDirectory: true)
        let checkout = root.appendingPathComponent("worktree", isDirectory: true)
        let nested = local.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try git(in: local, ["init", "-q"])
        try git(in: local, ["-c", "user.name=Terminal Fixture", "-c", "user.email=terminal@example.invalid",
                            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                            "commit", "-qm", "Fixture", "--allow-empty"])
        try git(in: local, ["worktree", "add", "--detach", "--", checkout.path, "HEAD"])

        let shell = root.appendingPathComponent("fixture-shell")
        try """
        #!/bin/sh
        [ -t 0 ] || exit 1
        printf 'READY-%s\\n' "$$"
        exec /bin/sh -i
        """.write(to: shell, atomically: true, encoding: .utf8)
        guard chmod(shell.path, 0o700) == 0, FileManager.default.isExecutableFile(atPath: shell.path) else {
            return XCTFail("Could not make the fixture shell executable.")
        }
        let previousShell = ProcessInfo.processInfo.environment["SHELL"]
        XCTAssertEqual(setenv("SHELL", shell.path, 1), 0)
        defer {
            if let previousShell { setenv("SHELL", previousShell, 1) }
            else { unsetenv("SHELL") }
        }
        guard ProcessInfo.processInfo.environment["SHELL"] == shell.path else {
            return XCTFail("Could not install the fixture shell.")
        }

        let localThread = ThreadTerminalLocation(thread: UUID(), path: local.path)
        let checkoutThread = ThreadTerminalLocation(thread: UUID(), path: checkout.path)
        let fixture = DrawerFixture(selected: localThread)
        let suite = "dev.piworkspace.terminal-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DrawerFixtureView(fixture: fixture).defaultAppStorage(defaults))
        host.sizingOptions = []
        window.contentView = host
        defer { window.contentView = nil }

        let original = try await focusedTerminal(in: window, labeled: "Terminal 1")
        let originalPID = try await readyPID(of: original)
        let localTTY = try await verifyDirectoryAndTTY(in: local, terminal: original, name: "original")
        send("printf 'FIRST-%s\\n' \"$$\"\n", to: original)
        try await waitFor("original PTY output") { self.output(of: original).contains("FIRST-\(originalPID)") }
        send("cd nested\n", to: original)
        try await verifyDrawerResize(in: window, terminal: original, defaults: defaults, thread: localThread, cwd: nested)
        XCTAssertEqual(original.process.shellPid, originalPID)
        let resizedTTY = try await verifyDirectoryAndTTY(in: nested, terminal: original, name: "resized")
        XCTAssertEqual(resizedTTY, localTTY)
        XCTAssertTrue(output(of: original).contains("FIRST-\(originalPID)"))

        fixture.drawers[0].newTab()
        let tab = try await focusedTerminal(in: window, labeled: "Terminal 2")
        let tabPID = try await readyPID(of: tab)
        XCTAssertNotEqual(originalPID, tabPID)
        XCTAssertTrue(original.isHidden)
        fixture.drawers[0].select(1)
        let selectedOriginal = try await focusedTerminal(in: window, labeled: "Terminal 1")
        XCTAssertTrue(selectedOriginal === original)

        fixture.drawers[0].split(.horizontal)
        let right = try await focusedTerminal(in: window, labeled: "Terminal 3")
        let rightPID = try await readyPID(of: right)
        let rightTTY = try await verifyDirectoryAndTTY(in: local, terminal: right, name: "right")
        XCTAssertNotEqual(rightTTY, localTTY)
        try await waitFor("side-by-side panes") {
            let leftFrame = original.convert(original.bounds, to: nil)
            let rightFrame = right.convert(right.bounds, to: nil)
            return leftFrame.maxX <= rightFrame.minX + 1 && abs(leftFrame.minY - rightFrame.minY) < 1
        }

        fixture.drawers[0].split(.vertical)
        let bottom = try await focusedTerminal(in: window, labeled: "Terminal 4")
        let bottomPID = try await readyPID(of: bottom)
        XCTAssertEqual(Set([originalPID, tabPID, rightPID, bottomPID]).count, 4)
        try await waitFor("stacked panes") {
            let above = right.convert(right.bounds, to: nil)
            let below = bottom.convert(bottom.bounds, to: nil)
            return abs(above.minX - below.minX) < 1 && above.minY >= below.maxY - 1
        }

        original.setAccessibilityFocused(true)
        try await waitFor("original pane selected") { fixture.drawers[0].activePane == 1 }
        XCTAssertTrue(ThreadTerminal.hasFocus(in: window))
        let next = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "}", charactersIgnoringModifiers: "}", isARepeat: false, keyCode: 30))
        XCTAssertTrue(original.cycleFocus(for: next))
        let cycled = try await focusedTerminal(in: window, labeled: "Terminal 3")
        XCTAssertTrue(cycled === right)
        send("printf 'FOCUSED-%s\\n' \"$$\"\n", to: cycled)
        try await waitFor("input sent to the focused pane") { self.output(of: right).contains("FOCUSED-\(rightPID)") }
        XCTAssertFalse(output(of: original).contains("FOCUSED-"))

        fixture.drawers[0].isOpen = false
        try await waitFor("hidden terminal releases focus") { original.isHidden && !ThreadTerminal.hasFocus(in: window) }
        XCTAssertNil(resizeDivider(in: host))
        XCTAssertEqual(kill(originalPID, 0), 0)
        XCTAssertEqual(kill(rightPID, 0), 0)
        fixture.drawers[0].isOpen = true
        let restored = try await focusedTerminal(in: window, labeled: "Terminal 3")
        XCTAssertTrue(restored === right)
        try await waitFor("reopened drawer height") { self.drawerHeight(in: host) == 400 }

        fixture.drawers.append(.init(id: checkoutThread))
        fixture.selected = checkoutThread
        try await waitFor("original thread hidden") { original.isHidden && right.isHidden }
        let worktree = try await focusedTerminal(in: window, labeled: "Terminal 1")
        try await waitFor("other thread uses its own height") { self.drawerHeight(in: host) == 280 }
        let worktreePID = try await readyPID(of: worktree)
        let checkoutTTY = try await verifyDirectoryAndTTY(in: checkout, terminal: worktree, name: "checkout")
        XCTAssertNotEqual(checkoutTTY, localTTY)

        fixture.selected = localThread
        let resumed = try await focusedTerminal(in: window, labeled: "Terminal 3")
        XCTAssertTrue(resumed === right)
        try await waitFor("original thread restores its own height") { self.drawerHeight(in: host) == 400 }
        XCTAssertTrue(output(of: original).contains("FIRST-\(originalPID)"))
        XCTAssertTrue(output(of: right).contains("FOCUSED-\(rightPID)"))
        XCTAssertEqual(original.process.shellPid, originalPID)
        XCTAssertEqual(restored.process.shellPid, rightPID)
        let resumedTTY = try await verifyDirectoryAndTTY(in: nested, terminal: original, name: "resumed")
        XCTAssertEqual(resumedTTY, localTTY)

        send("/bin/sh -c 'echo $$ > interrupted; exec /bin/sleep 30'\n", to: right)
        let interrupted = try await readPID(at: local.appendingPathComponent("interrupted"))
        send("\u{03}", to: right)
        try await waitFor("Ctrl+C stopped only the foreground job") { kill(interrupted, 0) == -1 }
        XCTAssertEqual(kill(rightPID, 0), 0)
        send("/bin/sleep 30 & echo $! > background\n", to: right)
        let background = try await readPID(at: local.appendingPathComponent("background"))
        send("/bin/sh -c 'echo $$ > foreground; exec /bin/sleep 30'\n", to: right)
        let foreground = try await readPID(at: local.appendingPathComponent("foreground"))
        fixture.drawers[0].close(3)
        try await waitFor("closed pane shell \(rightPID) has exited") { kill(rightPID, 0) == -1 }
        try await waitFor("foreground job \(foreground) has exited") { kill(foreground, 0) == -1 }
        try await waitFor("background job \(background) has exited") { kill(background, 0) == -1 }
        let sibling = try await focusedTerminal(in: window, labeled: "Terminal 4")
        XCTAssertTrue(sibling === bottom)
        for pid in [originalPID, tabPID, bottomPID, worktreePID] { XCTAssertEqual(kill(pid, 0), 0) }

        fixture.drawers.removeAll { $0.id.thread == localThread.thread }
        try await waitFor("checkout switch closes every pane of the selected thread") {
            [originalPID, tabPID, bottomPID].allSatisfy { kill($0, 0) == -1 }
        }
        XCTAssertEqual(kill(worktreePID, 0), 0)
        fixture.selected = checkoutThread
        let untouched = try await focusedTerminal(in: window, labeled: "Terminal 1")
        XCTAssertTrue(untouched === worktree)

        fixture.drawers.append(.init(id: localThread))
        fixture.selected = localThread
        _ = try await focusedTerminal(in: window, labeled: "Terminal 1")
        try await waitFor("recreated drawer loads the saved height") { self.drawerHeight(in: host) == 400 }
        fixture.drawers[1].close(1)
        try await waitFor("last pane closes and resets its height") {
            fixture.drawers.count == 1 && defaults.object(forKey: "terminal-drawer-height.\(localThread.thread.uuidString)") == nil
        }
        fixture.drawers.append(.init(id: localThread))
        _ = try await focusedTerminal(in: window, labeled: "Terminal 1")
        try await waitFor("reset drawer uses default height") { self.drawerHeight(in: host) == 280 }
        fixture.drawers[1].close(1)
        try await waitFor("reset drawer closes") { fixture.drawers.count == 1 }

        fixture.drawers[0].close(1)
        try await waitFor("worktree shell exits") { kill(worktreePID, 0) == -1 }
        try await waitFor("all drawers closed") { fixture.drawers.isEmpty }

        print("PTY fixture local \(originalPID) \(localTTY), worktree \(worktreePID) \(checkoutTTY). Closed shell \(rightPID), foreground \(foreground), background \(background).")
    }

    @MainActor
    private func verifyDrawerResize(in window: NSWindow, terminal: TerminalSessionView, defaults: UserDefaults,
                                    thread: ThreadTerminalLocation, cwd: URL) async throws {
        let host = try XCTUnwrap(window.contentView)
        let key = "terminal-drawer-height.\(thread.thread.uuidString)"
        try await waitFor("default 280-point drawer") { self.drawerHeight(in: host) == 280 && terminal.bounds.height == 249 }
        let divider = try XCTUnwrap(resizeDivider(in: host))
        XCTAssertEqual(divider.accessibilityIdentifier(), "terminal-drawer-resize-handle")
        XCTAssertEqual(divider.accessibilityLabel(), "Resize Terminal Drawer")
        XCTAssertEqual(divider.accessibilityRole(), .splitter)
        XCTAssertEqual(divider.bounds.size, CGSize(width: 800, height: 6))
        XCTAssertEqual(divider.convert(divider.bounds, to: nil).maxY, 280)
        let originalGrid = try await shellGrid(in: cwd, terminal: terminal, name: "default")

        let start = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        XCTAssertTrue(host.hitTest(start) === divider)
        divider.mouseDown(with: try mouse(.leftMouseDown, in: window, at: start))
        divider.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: start.offsetBy(dy: -300)))
        try await waitFor("180-point minimum") { self.drawerHeight(in: host) == 180 && terminal.bounds.height == 149 }
        divider.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: start.offsetBy(dy: 1_000)))
        try await waitFor("75-percent viewport cap") { self.drawerHeight(in: host) == 540 && terminal.bounds.height == 509 }
        divider.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: start.offsetBy(dy: 80)))
        try await waitFor("live 360-point drawer") { self.drawerHeight(in: host) == 360 && terminal.bounds.height == 329 }
        XCTAssertNil(defaults.object(forKey: key))
        divider.mouseUp(with: try mouse(.leftMouseUp, in: window, at: start.offsetBy(dy: 120)))
        try await waitFor("drawer height saved on release") { defaults.double(forKey: key) == 400 }
        XCTAssertTrue(window.firstResponder === terminal)

        let resizedGrid = try await shellGrid(in: cwd, terminal: terminal, name: "large")
        XCTAssertGreaterThan(resizedGrid[0], originalGrid[0])
        XCTAssertEqual(resizedGrid[1], originalGrid[1])

        XCTAssertTrue(divider.accessibilityPerformIncrement())
        try await waitFor("accessibility increment") { self.drawerHeight(in: host) == 416 }
        divider.setAccessibilityValue(NSNumber(value: 400))
        try await waitFor("accessibility value set") { self.drawerHeight(in: host) == 400 }

        window.setContentSize(NSSize(width: 800, height: 420))
        try await waitFor("composer budget cap") { self.drawerHeight(in: host) == 260 && terminal.bounds.height == 229 }
        let capped = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
        divider.mouseDown(with: try mouse(.leftMouseDown, in: window, at: capped))
        divider.mouseDragged(with: try mouse(.leftMouseDragged, in: window, at: capped.offsetBy(dy: 150)))
        divider.mouseUp(with: try mouse(.leftMouseUp, in: window, at: capped.offsetBy(dy: 150)))
        XCTAssertEqual(defaults.double(forKey: key), 400)
        window.setContentSize(NSSize(width: 800, height: 300))
        try await waitFor("available height below minimum") { self.drawerHeight(in: host) == 140 && terminal.bounds.height == 109 }
        window.setContentSize(NSSize(width: 800, height: 720))
        try await waitFor("restored preference after enlarging the host") {
            self.drawerHeight(in: host) == 400 && terminal.bounds.height == 369
        }
        XCTAssertTrue(window.firstResponder === terminal)
        print("Drawer fixture applied 280, 180, 540, 400, 416, 260 and 140 points. PTY grid \(originalGrid) → \(resizedGrid).")
    }

    @MainActor
    private func resizeDivider(in view: NSView) -> TerminalDrawerDividerView? {
        if let divider = view as? TerminalDrawerDividerView { return divider }
        return view.subviews.lazy.compactMap { self.resizeDivider(in: $0) }.first
    }

    @MainActor
    private func drawerHeight(in host: NSView) -> Int? {
        (resizeDivider(in: host)?.accessibilityValue() as? NSNumber)?.intValue
    }

    private func mouse(_ type: NSEvent.EventType, in window: NSWindow, at location: CGPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1))
    }

    @MainActor
    private func shellGrid(in cwd: URL, terminal: TerminalSessionView, name: String) async throws -> [Int] {
        let proof = cwd.appendingPathComponent("\(name)-grid")
        send("stty size > \(name)-grid\n", to: terminal)
        var grid: [Int] = []
        try await waitFor("shell grid in \(name)") {
            grid = (try? String(contentsOf: proof, encoding: .utf8))?.split(whereSeparator: \.isWhitespace).compactMap { Int($0) } ?? []
            return grid.count == 2
        }
        return grid
    }

    @MainActor
    private func waitFor(_ label: String, until predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard clock.now < end else {
                XCTFail("Timed out waiting for \(label).")
                throw FixtureFailure.timeout(label)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func focusedTerminal(in window: NSWindow, labeled label: String) async throws -> TerminalSessionView {
        try await waitFor("focus on \(label)") {
            guard let terminal = window.firstResponder as? TerminalSessionView, !terminal.isHidden else { return false }
            return terminal.accessibilityLabel() == label
        }
        return try XCTUnwrap(window.firstResponder as? TerminalSessionView)
    }

    @MainActor
    private func readyPID(of terminal: TerminalSessionView) async throws -> pid_t {
        try await waitFor("PTY startup marker") {
            terminal.process.shellPid > 0 && self.output(of: terminal).contains("READY-\(terminal.process.shellPid)")
        }
        return terminal.process.shellPid
    }

    @MainActor
    private func output(of terminal: TerminalSessionView) -> String {
        terminal.terminalContentSnapshot(region: .all)?.rows.map(\.text).joined(separator: "\n") ?? ""
    }

    @MainActor
    private func send(_ text: String, to terminal: TerminalSessionView) {
        terminal.send(source: terminal, data: Array(text.utf8)[...])
    }

    @MainActor
    private func readPID(at url: URL) async throws -> pid_t {
        var pid: pid_t?
        try await waitFor("PID in \(url.lastPathComponent)") {
            pid = (try? String(contentsOf: url, encoding: .utf8)).flatMap {
                pid_t($0.trimmingCharacters(in: .newlines))
            }
            return pid.map { $0 > 0 } == true
        }
        return try XCTUnwrap(pid)
    }

    @MainActor
    private func verifyDirectoryAndTTY(in directory: URL, terminal: TerminalSessionView, name: String) async throws -> String {
        let proof = directory.appendingPathComponent("\(name)-pty")
        send("pwd -P > \(name)-pty; tty >> \(name)-pty\n", to: terminal)
        var lines: [Substring] = []
        try await waitFor("cwd and tty in \(directory.lastPathComponent)") {
            lines = (try? String(contentsOf: proof, encoding: .utf8).split(separator: "\n")) ?? []
            return lines.count == 2
        }
        let resolved = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(resolved) }
        XCTAssertEqual(String(lines[0]), String(cString: resolved))
        XCTAssertTrue(lines[1].hasPrefix("/dev/tty"))
        return String(lines[1])
    }

    private func git(in directory: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureFailure.git(arguments) }
    }

    private enum FixtureFailure: Error {
        case timeout(String)
        case git([String])
    }
}

@MainActor
private final class DrawerFixture: ObservableObject {
    @Published var drawers: [ThreadTerminalDrawerState]
    @Published var selected: ThreadTerminalLocation

    init(selected: ThreadTerminalLocation) {
        self.selected = selected
        drawers = [.init(id: selected)]
    }
}

private struct DrawerFixtureView: View {
    @ObservedObject var fixture: DrawerFixture

    var body: some View {
        GeometryReader { geometry in
            let limits = TerminalDrawerHeight(viewport: geometry.size.height, reserved: 160)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach($fixture.drawers) { $drawer in
                    let location = drawer.id
                    ThreadTerminalDrawer(drawer: $drawer, selected: location == fixture.selected, limits: limits) {
                        fixture.drawers.removeAll { $0.id == location }
                    }
                }
            }
        }
    }
}

private extension CGPoint {
    func offsetBy(dy: CGFloat) -> CGPoint { CGPoint(x: x, y: y + dy) }
}

private final class TerminalOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
