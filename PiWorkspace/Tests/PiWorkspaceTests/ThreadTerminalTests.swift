import AppKit
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
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DrawerFixtureView(fixture: fixture))
        host.sizingOptions = []
        window.contentView = host
        defer { window.contentView = nil }

        let original = try await focusedTerminal(in: window, labeled: "Terminal 1")
        let originalPID = try await readyPID(of: original)
        let localTTY = try await verifyDirectoryAndTTY(in: local, terminal: original, name: "original")
        send("printf 'FIRST-%s\\n' \"$$\"\n", to: original)
        try await waitFor("original PTY output") { self.output(of: original).contains("FIRST-\(originalPID)") }
        send("cd nested\n", to: original)

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
        XCTAssertEqual(kill(originalPID, 0), 0)
        XCTAssertEqual(kill(rightPID, 0), 0)
        fixture.drawers[0].isOpen = true
        let restored = try await focusedTerminal(in: window, labeled: "Terminal 3")
        XCTAssertTrue(restored === right)

        fixture.drawers.append(.init(id: checkoutThread))
        fixture.selected = checkoutThread
        try await waitFor("original thread hidden") { original.isHidden && right.isHidden }
        let worktree = try await focusedTerminal(in: window, labeled: "Terminal 1")
        let worktreePID = try await readyPID(of: worktree)
        let checkoutTTY = try await verifyDirectoryAndTTY(in: checkout, terminal: worktree, name: "checkout")
        XCTAssertNotEqual(checkoutTTY, localTTY)

        fixture.selected = localThread
        let resumed = try await focusedTerminal(in: window, labeled: "Terminal 3")
        XCTAssertTrue(resumed === right)
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
        fixture.drawers[0].close(1)
        try await waitFor("worktree shell exits") { kill(worktreePID, 0) == -1 }
        XCTAssertFalse(fixture.drawers[0].isOpen)

        print("PTY fixture local \(originalPID) \(localTTY), worktree \(worktreePID) \(checkoutTTY). Closed shell \(rightPID), foreground \(foreground), background \(background).")
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
        VStack {
            Spacer()
            ForEach($fixture.drawers) { $drawer in
                let location = drawer.id
                ThreadTerminalDrawer(drawer: $drawer, selected: location == fixture.selected) {
                    fixture.drawers.removeAll { $0.id == location }
                }
            }
        }
    }
}
