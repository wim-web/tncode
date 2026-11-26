import AppKit
import Darwin
import SwiftTerm
import SwiftUI

struct ThreadTerminal: View {
    let directory: String
    let visible: Bool

    var body: some View {
        TerminalHost(directory: directory, visible: visible)
    }

    private struct TerminalHost: NSViewRepresentable {
        let directory: String
        let visible: Bool

        func makeNSView(context: Context) -> TerminalSessionView {
            let terminal = TerminalSessionView(frame: .zero)
            terminal.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            terminal.setAccessibilityElement(true)
            terminal.setAccessibilityRole(.textArea)
            terminal.setAccessibilityLabel("Thread terminal")
            terminal.setAccessibilityIdentifier("thread-terminal")
            terminal.start(in: directory)
            return terminal
        }

        func updateNSView(_ terminal: TerminalSessionView, context: Context) {
            terminal.setPresented(visible)
        }

        static func dismantleNSView(_ terminal: TerminalSessionView, coordinator: ()) {
            terminal.terminate()
        }
    }
}

private final class TerminalSessionView: LocalProcessTerminalView {
    private var presented = false

    func setPresented(_ presented: Bool) {
        guard self.presented != presented else { return }
        self.presented = presented
        setAccessibilityElement(presented)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presented == presented else { return }
            self.setAccessibilityFocused(presented)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if presented { setAccessibilityFocused(true) }
    }

    override func isAccessibilityFocused() -> Bool {
        presented && window?.firstResponder === self
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        if focused && presented {
            window?.makeFirstResponder(self)
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
