import AppKit
import Darwin
import SwiftTerm
import SwiftUI

struct ThreadTerminal: View {
    static let maxPanesPerGroup = 4

    enum Command { case new, split, splitVertical, close }

    let directory: String
    let number: Int
    let visible: Bool
    let focusRequest: Int?
    let onFocus: () -> Void
    let onCycle: (Int) -> Bool
    var identifier: String? = nil
    var onCommand: ((Command) -> Void)? = nil

    static func hasFocus(in window: NSWindow) -> Bool {
        window.firstResponder is TerminalSessionView
    }

    var body: some View {
        TerminalHost(terminal: self)
    }

    private struct TerminalHost: NSViewRepresentable {
        let terminal: ThreadTerminal

        func makeNSView(context: Context) -> TerminalSessionView {
            let view = TerminalSessionView(frame: NSRect(x: 0, y: 0, width: 360, height: TerminalDrawerHeight.defaultContent))
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.isHidden = true
            view.setAccessibilityRole(.textArea)
            view.setAccessibilityLabel("Terminal \(terminal.number)")
            view.start(in: terminal.directory)
            return view
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalSessionView, context: Context) -> CGSize? {
            proposal.replacingUnspecifiedDimensions()
        }

        func updateNSView(_ view: TerminalSessionView, context: Context) {
            view.onFocus = terminal.onFocus
            view.onCycle = terminal.onCycle
            view.onCommand = terminal.onCommand
            view.setAccessibilityIdentifier(terminal.identifier ??
                (terminal.focusRequest != nil ? "thread-terminal" : "terminal-pane-\(terminal.number)"))
            view.setPresentation(terminal.visible, focusRequest: terminal.focusRequest)
        }

        static func dismantleNSView(_ terminal: TerminalSessionView, coordinator: ()) {
            terminal.onFocus = nil
            terminal.onCycle = nil
            terminal.onCommand = nil
            terminal.setPresentation(false, focusRequest: nil)
            terminal.closeSession()
        }
    }
}

struct ThreadTerminalKeyboard: NSViewRepresentable {
    final class Coordinator { var monitor: Any? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak anchor] event in
            guard let window = anchor?.window, event.window === window,
                  let terminal = window.firstResponder as? TerminalSessionView,
                  terminal.handleShortcut(event) else { return event }
            return nil
        }
        return anchor
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
}

final class TerminalSessionView: LocalProcessTerminalView {
    var onFocus: (() -> Void)?
    var onCycle: ((Int) -> Bool)?
    var onCommand: ((ThreadTerminal.Command) -> Void)?
    private var presented = false
    private var focusRequest: Int?

    func closeSession() {
        if case let .success(descriptor?) = process.duplicatePrimaryDescriptor() {
            let shell = process.shellPid
            let foreground = tcgetpgrp(descriptor)
            _ = ioctl(descriptor, TIOCSIG, SIGHUP)
            // The shell can ignore SIGTERM while another job owns the foreground.
            if shell > 0, foreground != shell, getsid(shell) == shell {
                _ = kill(-shell, SIGHUP)
            }
            Darwin.close(descriptor)
        }
        terminate()
    }

    func setPresentation(_ presented: Bool, focusRequest: Int?) {
        guard self.presented != presented || self.focusRequest != focusRequest else { return }
        self.presented = presented
        self.focusRequest = focusRequest
        isHidden = !presented
        setAccessibilityElement(presented)
        updateFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { updateFocus() }
    }

    private func updateFocus() {
        let request = focusRequest
        let shown = presented
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presented == shown, self.focusRequest == request else { return }
            if shown && request != nil {
                self.window?.makeFirstResponder(self)
            } else if !shown {
                self.setAccessibilityFocused(false)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        setAccessibilityFocused(true)
        super.mouseDown(with: event)
    }

    func cycleFocus(for event: NSEvent) -> Bool {
        guard presented, window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift] else { return false }
        switch event.charactersIgnoringModifiers {
        case "[", "{": return onCycle?(-1) ?? false
        case "]", "}": return onCycle?(1) ?? false
        default: return false
        }
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        if cycleFocus(for: event) { return true }
        guard presented, window?.firstResponder === self, !event.isARepeat, let onCommand else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("n", .command): onCommand(.new)
        case ("d", .command): onCommand(.split)
        case ("d", [.command, .shift]): onCommand(.splitVertical)
        case ("w", .command): onCommand(.close)
        default: return false
        }
        return true
    }

    override func isAccessibilityFocused() -> Bool {
        presented && window?.firstResponder === self
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        if focused {
            if presented && window?.makeFirstResponder(self) == true { onFocus?() }
        } else if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func accessibilityValue() -> Any? {
        terminalContentSnapshot(region: .viewport)?.rows.map(\.text).joined(separator: "\n")
    }

    func start(in directory: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue, access(directory, X_OK) == 0 else {
            feed(text: "The workspace folder is unavailable.\r\n")
            return
        }

        let user = NSUserName()
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["SHELL"]
            ?? getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) }
        let shell = configured.flatMap {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        } ?? "/bin/zsh"
        startProcess(executable: shell, args: ["-l"], environment: [
            "HOME=\(NSHomeDirectory())",
            "USER=\(user)",
            "LOGNAME=\(user)",
            "SHELL=\(shell)",
            "PATH=\(environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")",
            "LANG=\(environment["LANG"] ?? "en_US.UTF-8")",
            "TERM=xterm-256color",
            "COLORTERM=truecolor"
        ], currentDirectory: directory)
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        feed(text: "\r\n[Shell exited. Close this terminal to start another.]\r\n")
    }
}
