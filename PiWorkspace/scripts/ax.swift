import ApplicationServices
import CoreGraphics
import Foundation

private let usage = """
Usage:
  ax trust
  ax activate PID
  ax menu-command PID CHARACTER
  ax dump PID [--values] [--no-labels] [--depth N]
  ax get PID IDENTIFIER [--values] [--no-labels]
  ax press PID IDENTIFIER
  ax confirm PID IDENTIFIER
  ax set PID IDENTIFIER < text.txt
  ax type PID IDENTIFIER [--replace] < text.txt
  ax key PID KEYCODE [cmd] [shift] [opt] [ctrl] [fn]

dump/get show roles, identifiers, and labels. --values includes AXValue
where available, except for secure text fields. --no-labels hides AXTitle,
AXDescription, and AXPlaceholderValue. set/type read UTF-8 stdin verbatim.
type and key send events only to PID. Common keycodes: Return 36, Escape 53,
Tab 48, Space 49, Left 123, Right 124, Down 125, Up 126, G 5.
"""

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct DisplayOptions {
    var values = false
    var labels = true
    var maxDepth: Int?

    init(_ arguments: ArraySlice<String>, allowDepth: Bool) throws {
        var next = arguments.makeIterator()
        while let option = next.next() {
            switch option {
            case "--values":
                values = true
            case "--no-labels":
                labels = false
            case "--depth" where allowDepth:
                guard let rawDepth = next.next(), let depth = Int(rawDepth), depth >= 0 else {
                    throw Failure("--depth requires a nonnegative integer.")
                }
                maxDepth = depth
            default:
                throw Failure("Invalid display option. See ax --help.")
            }
        }
    }
}

private enum Operation {
    case activate
    case menuCommand(String)
    case dump(DisplayOptions)
    case get(String, DisplayOptions)
    case press(String)
    case confirm(String)
    case set(String)
    case type(String, replace: Bool)
    case key(CGKeyCode, CGEventFlags)

    init(_ name: String, _ arguments: ArraySlice<String>) throws {
        let identifier = arguments.first
        switch (name, identifier) {
        case ("activate", nil):
            self = .activate
        case ("menu-command", let key?) where arguments.count == 1 && key.count == 1:
            self = .menuCommand(key)
        case ("dump", _):
            self = try .dump(DisplayOptions(arguments, allowDepth: true))
        case ("get", let id?):
            self = try .get(id, DisplayOptions(arguments.dropFirst(), allowDepth: false))
        case ("press", let id?) where arguments.count == 1:
            self = .press(id)
        case ("confirm", let id?) where arguments.count == 1:
            self = .confirm(id)
        case ("set", let id?) where arguments.count == 1:
            self = .set(id)
        case ("type", let id?) where arguments.count == 1:
            self = .type(id, replace: false)
        case ("type", let id?) where arguments.dropFirst().elementsEqual(["--replace"]):
            self = .type(id, replace: true)
        case ("key", let rawCode?):
            guard let code = UInt16(rawCode) else {
                throw Failure("KEYCODE must be an unsigned 16-bit integer.")
            }
            let modifiers: [String: CGEventFlags] = [
                "cmd": .maskCommand, "shift": .maskShift, "opt": .maskAlternate,
                "ctrl": .maskControl, "fn": .maskSecondaryFn
            ]
            var flags: CGEventFlags = []
            for argument in arguments.dropFirst() {
                guard let modifier = modifiers[argument] else {
                    throw Failure("Unknown key modifier. See ax --help.")
                }
                flags.insert(modifier)
            }
            self = .key(code, flags)
        default:
            throw Failure("Invalid command or arguments. See ax --help.")
        }
    }
}

private func requireSuccess(_ result: AXError, _ action: String) throws {
    guard result == .success else {
        throw Failure("\(action) failed (\(result), AX error \(result.rawValue)).")
    }
}

private func attribute(_ name: String, on element: AXUIElement) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else {
        return nil
    }
    return result
}

private func line(for element: AXUIElement, options: DisplayOptions) -> String {
    let fields = [
        ("role", kAXRoleAttribute),
        ("subrole", kAXSubroleAttribute),
        ("id", kAXIdentifierAttribute)
    ]
    let labelFields = [
        ("title", kAXTitleAttribute),
        ("description", kAXDescriptionAttribute),
        ("placeholder", kAXPlaceholderValueAttribute)
    ]
    var parts = (fields + (options.labels ? labelFields : [])).compactMap { label, name -> String? in
        guard let value = attribute(name, on: element) as? String, !value.isEmpty else { return nil }
        return "\(label)=\(value.debugDescription)"
    }
    if let enabled = attribute(kAXEnabledAttribute, on: element) as? Bool {
        parts.append("enabled=\(enabled)")
    }
    if attribute(kAXFocusedAttribute, on: element) as? Bool == true { parts.append("focused=true") }

    if options.values {
        let subrole = attribute(kAXSubroleAttribute, on: element) as? String
        let role = attribute(kAXRoleAttribute, on: element) as? String
        if subrole == kAXSecureTextFieldSubrole || role == kAXSecureTextFieldSubrole {
            parts.append("value=<secure>")
        } else if let value = attribute(kAXValueAttribute, on: element) {
            switch value {
            case let string as String: parts.append("value=\(string.debugDescription)")
            case let number as NSNumber: parts.append("value=\(number)")
            default: parts.append("value=<non-scalar>")
            }
        }
    }
    return parts.isEmpty ? "(unnamed element)" : parts.joined(separator: " ")
}

private struct Tree: Sequence, IteratorProtocol {
    private var pending: [(element: AXUIElement, depth: Int)]
    private var seen: Set<AXUIElement> = []
    private let maxDepth: Int?

    init(root: AXUIElement, maxDepth: Int? = nil) {
        pending = [(root, 0)]
        self.maxDepth = maxDepth
    }

    mutating func next() -> (element: AXUIElement, depth: Int)? {
        while let node = pending.popLast() {
            guard seen.insert(node.element).inserted else { continue }
            if maxDepth.map({ node.depth < $0 }) ?? true {
                var children = attribute(kAXChildrenAttribute, on: node.element) as? [AXUIElement] ?? []
                if node.depth == 0 {
                    children += attribute(kAXWindowsAttribute, on: node.element) as? [AXUIElement] ?? []
                }
                pending.append(contentsOf: children.reversed().map { ($0, node.depth + 1) })
            }
            return node
        }
        return nil
    }
}

private func element(withID identifier: String, in app: AXUIElement) throws -> AXUIElement {
    var match: AXUIElement?
    for node in Tree(root: app) {
        guard attribute(kAXIdentifierAttribute, on: node.element) as? String == identifier else {
            continue
        }
        guard match == nil else { throw Failure("More than one element has that identifier.") }
        match = node.element
    }
    guard let match else { throw Failure("No element has that identifier.") }
    return match
}

private func inputText() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
        throw Failure("Text on stdin must be UTF-8.")
    }
    return text
}

private func requireKeyboardAccess() throws {
    guard CGPreflightPostEventAccess() else {
        throw Failure("This process cannot post keyboard events in the current macOS session.")
    }
}

private func postKey(
    _ code: CGKeyCode, to pid: pid_t, flags: CGEventFlags = [], units: [UInt16] = []
) throws {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
        throw Failure("Could not create a keyboard event.")
    }

    for event in [down, up] {
        event.flags = flags
        if !units.isEmpty {
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
        }
        event.postToPid(pid)
    }
}

private func run(_ arguments: [String]) throws {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
        print(usage)
        return
    }
    if arguments == ["trust"] {
        print("accessibility=\(AXIsProcessTrusted()) keyboard=\(CGPreflightPostEventAccess())")
        return
    }
    guard arguments.count >= 2, let pid = pid_t(arguments[1]), pid > 0 else {
        throw Failure("A positive PID is required. See ax --help.")
    }
    let operation = try Operation(arguments[0], arguments.dropFirst(2))
    guard kill(pid, 0) == 0 else { throw Failure("The specified PID is unavailable.") }

    if case let .key(code, flags) = operation {
        try requireKeyboardAccess()
        try postKey(code, to: pid, flags: flags)
        return
    }
    guard AXIsProcessTrusted() else {
        throw Failure("This process lacks macOS Accessibility access. Run ax trust to check.")
    }

    let app = AXUIElementCreateApplication(pid)
    try requireSuccess(AXUIElementSetMessagingTimeout(app, 1.5), "Set AX timeout")
    var role: CFTypeRef?
    let roleResult = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
    try requireSuccess(roleResult, "Read application role")

    switch operation {
    case .activate:
        try requireSuccess(AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue),
                           "Activate the selected application")
    case .menuCommand(let key):
        let matches = Tree(root: app).map(\.element).filter { item in
            attribute(kAXRoleAttribute, on: item) as? String == kAXMenuItemRole &&
            (attribute(kAXMenuItemCmdCharAttribute, on: item) as? String)?.lowercased() == key.lowercased() &&
            attribute(kAXMenuItemCmdModifiersAttribute, on: item) as? Int == 0 &&
            attribute(kAXEnabledAttribute, on: item) as? Bool == true
        }
        guard matches.count == 1, let command = matches.first else {
            throw Failure("Expected one enabled menu command for Command-\(key), found \(matches.count).")
        }
        try requireSuccess(AXUIElementPerformAction(command, kAXPressAction as CFString), "Invoke menu command")
    case .dump(let options):
        for (node, depth) in Tree(root: app, maxDepth: options.maxDepth) {
            print(String(repeating: "  ", count: depth) + line(for: node, options: options))
        }
    case .get(let id, let options):
        print(try line(for: element(withID: id, in: app), options: options))
    case .press(let id):
        let target = try element(withID: id, in: app)
        try requireSuccess(AXUIElementPerformAction(target, kAXPressAction as CFString), "AXPress")
    case .confirm(let id):
        let target = try element(withID: id, in: app)
        try requireSuccess(AXUIElementPerformAction(target, kAXConfirmAction as CFString), "AXConfirm")
    case .set(let id):
        let target = try element(withID: id, in: app)
        let text = try inputText()
        let result = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, text as CFString)
        try requireSuccess(result, "Set AXValue")
    case .type(let id, let replace):
        try requireKeyboardAccess()
        let target = try element(withID: id, in: app)
        let text = try inputText()
        let focused = kAXFocusedAttribute as CFString
        try requireSuccess(AXUIElementSetAttributeValue(target, focused, kCFBooleanTrue), "Set AXFocused")
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while attribute(kAXFocusedAttribute, on: target) as? Bool != true {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure("Could not confirm keyboard focus on the specified element.")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if replace {
            try postKey(0, to: pid, flags: .maskCommand)
        }
        var units: [UInt16] = []
        for scalar in text.unicodeScalars {
            let next = Array(String(scalar).utf16)
            if units.count + next.count > 12 {
                try postKey(0, to: pid, units: units)
                Thread.sleep(forTimeInterval: 0.1)
                units.removeAll(keepingCapacity: true)
            }
            units.append(contentsOf: next)
        }
        if !units.isEmpty { try postKey(0, to: pid, units: units) }
    case .key:
        break
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("ax: \(error)\n".utf8))
    exit(1)
}
