import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private let usage = """
Usage:
  ax trust
  ax check-copy TEST_PASTEBOARD < expected.txt
  ax release-test-pasteboard TEST_PASTEBOARD
  ax activate PID
  ax menu-command PID CHARACTER
  ax menu-item PID TITLE
  ax dump PID [--values] [--no-labels] [--depth N]
  ax get PID IDENTIFIER [--values] [--no-labels]
  ax frame PID IDENTIFIER
  ax web-frame PID DOM_IDENTIFIER
  ax size-window PID WINDOW_IDENTIFIER WIDTH HEIGHT
  ax drag PID IDENTIFIER FRACTION_X FRACTION_Y DELTA_X DELTA_Y
  ax press PID IDENTIFIER
  ax close-window PID WINDOW_IDENTIFIER
  ax select-folder PID ABSOLUTE_PATH
  ax confirm PID IDENTIFIER
  ax set PID IDENTIFIER < text.txt
  ax type PID IDENTIFIER [--replace] < text.txt
  ax key PID KEYCODE [cmd] [shift] [opt] [ctrl] [fn]
  ax key-focused PID IDENTIFIER KEYCODE [cmd] [shift] [opt] [ctrl] [fn]

dump/get show roles, identifiers, and labels. --values includes AXValue
where available, except for secure text fields. --no-labels hides AXTitle,
AXDescription, and AXPlaceholderValue. set/type read UTF-8 stdin verbatim.
type and key target PID. drag requires the target window to be frontmost along the entire path.
Common keycodes: Return 36, Escape 53,
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
    case menuItem(String)
    case dump(DisplayOptions)
    case get(String, DisplayOptions)
    case frame(String)
    case webFrame(String)
    case sizeWindow(String, CGSize)
    case drag(String, CGPoint, CGSize)
    case press(String)
    case closeWindow(String)
    case selectFolder(String)
    case confirm(String)
    case set(String)
    case type(String, replace: Bool)
    case key(CGKeyCode, CGEventFlags)
    case keyFocused(String, CGKeyCode, CGEventFlags)

    init(_ name: String, _ arguments: ArraySlice<String>) throws {
        let identifier = arguments.first
        switch (name, identifier) {
        case ("activate", nil):
            self = .activate
        case ("menu-command", let key?) where arguments.count == 1 && key.count == 1:
            self = .menuCommand(key)
        case ("menu-item", let title?) where arguments.count == 1:
            self = .menuItem(title)
        case ("dump", _):
            self = try .dump(DisplayOptions(arguments, allowDepth: true))
        case ("get", let id?):
            self = try .get(id, DisplayOptions(arguments.dropFirst(), allowDepth: false))
        case ("frame", let id?) where arguments.count == 1:
            self = .frame(id)
        case ("web-frame", let id?) where arguments.count == 1:
            self = .webFrame(id)
        case ("size-window", let id?) where arguments.count == 3:
            let sizes = arguments.dropFirst().compactMap { Double($0) }
            guard sizes.count == 2, sizes.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw Failure("size-window needs a positive width and height in points.")
            }
            self = .sizeWindow(id, CGSize(width: sizes[0], height: sizes[1]))
        case ("drag", let id?) where arguments.count == 5:
            let values = arguments.dropFirst().compactMap { Double($0) }
            guard values.count == 4, values.allSatisfy(\.isFinite),
                  (0...1).contains(values[0]), (0...1).contains(values[1]) else {
                throw Failure("drag requires two fractions and two distances in points.")
            }
            self = .drag(id, CGPoint(x: values[0], y: values[1]), CGSize(width: values[2], height: values[3]))
        case ("press", let id?) where arguments.count == 1:
            self = .press(id)
        case ("close-window", let id?) where arguments.count == 1:
            self = .closeWindow(id)
        case ("select-folder", let path?) where arguments.count == 1 && path.hasPrefix("/"):
            self = .selectFolder(path)
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
        case ("key-focused", let id?):
            guard case let .key(code, flags) = try Operation("key", arguments.dropFirst()) else {
                throw Failure("key-focused needs a focused element and a key.")
            }
            self = .keyFocused(id, code, flags)
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

private func frame(of element: AXUIElement) throws -> CGRect {
    var point = CGPoint.zero, size = CGSize.zero
    guard let p = attribute(kAXPositionAttribute, on: element), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = attribute(kAXSizeAttribute, on: element), CFGetTypeID(s) == AXValueGetTypeID(),
          AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else {
        throw Failure("The element has no accessible frame.")
    }
    return CGRect(origin: point, size: size)
}

private func selectFolder(_ path: String, in panel: AXUIElement) throws {
    let requested = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    for node in Tree(root: panel) {
        let raw = attribute(kAXURLAttribute, on: node.element)
        let url = (raw as? URL) ?? (raw as? String).flatMap { URL(string: $0) }
        guard let url, url.isFileURL, url.resolvingSymlinksInPath().standardizedFileURL.path == requested else { continue }
        var item = node.element
        while !CFEqual(item, panel), let raw = attribute(kAXParentAttribute, on: item),
              CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let parent = unsafeBitCast(raw, to: AXUIElement.self)
            let role = attribute(kAXRoleAttribute, on: parent) as? String
            let selection = role == kAXOutlineRole || role == kAXTableRole ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute
            if [kAXListRole, kAXTableRole, kAXOutlineRole].contains(role),
               AXUIElementSetAttributeValue(parent, selection as CFString, [item] as CFArray) == .success { return }
            item = parent
        }
    }
    throw Failure("The requested folder is not selectable in the open panel.")
}

private func drag(in rect: CGRect, from fraction: CGPoint, by delta: CGSize, to pid: pid_t) throws {
    let point = CGPoint(x: rect.minX + fraction.x * rect.width, y: rect.minY + fraction.y * rect.height)
    func targetOwns(_ point: CGPoint) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        let first = windows?.first { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.contains(point)
        }
        return first?[kCGWindowOwnerPID as String] as? Int32 == pid
    }
    let steps = 8
    let points = (0...steps).map { i in
        CGPoint(x: point.x + delta.width * CGFloat(i) / CGFloat(steps), y: point.y + delta.height * CGFloat(i) / CGFloat(steps))
    }
    guard !CGEventSource.buttonState(.combinedSessionState, button: .left), points.allSatisfy(targetOwns),
          let savedPosition = CGEvent(source: nil)?.location else {
        throw Failure("Drag needs an idle pointer and an unobstructed path in the frontmost target window.")
    }
    var last = point
    var pressed = false
    defer {
        if pressed, let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: last, mouseButton: .left) {
            if targetOwns(last) { up.post(tap: .cghidEventTap) } else { up.postToPid(pid) }
        }
        CGWarpMouseCursorPosition(savedPosition)
    }
    for (index, current) in points.enumerated() {
        guard targetOwns(current) else { throw Failure("The target window lost the drag.") }
        let type: CGEventType = index == 0 ? .leftMouseDown : .leftMouseDragged
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: current, mouseButton: .left) else {
            throw Failure("Could not create a mouse event.")
        }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
        pressed = true
        last = current
        Thread.sleep(forTimeInterval: 0.025)
    }
}

private func requireKeyboardAccess() throws {
    guard CGPreflightPostEventAccess() else {
        throw Failure("This process cannot post keyboard events in the current macOS session.")
    }
}

private func postKey(
    _ code: CGKeyCode, to pid: pid_t, flags: CGEventFlags = [], units: [UInt16] = [], frontmost: Bool = false
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
        if frontmost && NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            up.postToPid(pid)
            throw Failure("The selected application lost focus.")
        }
        event.postToPid(pid)
        if frontmost && event.type == .keyDown { Thread.sleep(forTimeInterval: 0.035) }
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
    if arguments.count == 2, ["check-copy", "release-test-pasteboard"].contains(arguments[0]) {
        guard arguments[1].hasPrefix("dev.piworkspace.verification.") else { throw Failure("A verification pasteboard is required.") }
        let board = NSPasteboard(name: .init(arguments[1]))
        if arguments[0] == "release-test-pasteboard" {
            board.releaseGlobally()
        } else if try board.string(forType: .string) != inputText() {
            throw Failure("The verification pasteboard did not contain the expected string.")
        }
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
    case .menuItem(let title):
        let matches = Tree(root: app).map(\.element).filter {
            attribute(kAXRoleAttribute, on: $0) as? String == kAXMenuItemRole &&
            attribute(kAXTitleAttribute, on: $0) as? String == title &&
            attribute(kAXEnabledAttribute, on: $0) as? Bool == true
        }
        guard matches.count == 1, let item = matches.first else { throw Failure("Expected exactly one enabled menu item matching the title.") }
        try requireSuccess(AXUIElementPerformAction(item, kAXPressAction as CFString), "Select menu item")
    case .dump(let options):
        for (node, depth) in Tree(root: app, maxDepth: options.maxDepth) {
            print(String(repeating: "  ", count: depth) + line(for: node, options: options))
        }
    case .get(let id, let options):
        print(try line(for: element(withID: id, in: app), options: options))
    case .frame(let id):
        let rect = try frame(of: element(withID: id, in: app))
        print("\(rect.minX) \(rect.minY) \(rect.width) \(rect.height)")
    case .keyFocused(let id, let code, let flags):
        try requireKeyboardAccess()
        let field = try element(withID: id, in: app)
        guard attribute(kAXFocusedAttribute, on: field) as? Bool == true else { throw Failure("The target field lacks focus.") }
        let characters: [CGKeyCode: UInt16] = [3: 0x66, 36: 0x0D, 48: 0x09, 51: 0x7F, 53: 0x1B,
                                                123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700]
        try postKey(code, to: pid, flags: flags, units: characters[code].map { [$0] } ?? [], frontmost: true)
    case .webFrame(let id):
        let matches = Tree(root: app).map(\.element).filter { attribute("AXDOMIdentifier", on: $0) as? String == id }
        guard matches.count == 1, let node = matches.first else { throw Failure("Expected one DOM element with this identifier.") }
        let rect = try frame(of: node)
        print("\(rect.minX) \(rect.minY) \(rect.width) \(rect.height)")
    case .sizeWindow(let id, let requested):
        let window = try element(withID: id, in: app)
        guard attribute(kAXRoleAttribute, on: window) as? String == kAXWindowRole else {
            throw Failure("size-window requires a window identifier.")
        }
        let rect = try frame(of: window)
        var display = CGMainDisplayID(), count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY), 1, &display, &count)
        let screen = CGDisplayBounds(count == 0 ? CGMainDisplayID() : display)
        var size = CGSize(width: min(requested.width, screen.width - 24), height: min(requested.height, screen.height - 84))
        var point = CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        guard let position = AXValueCreate(.cgPoint, &point), let dimensions = AXValueCreate(.cgSize, &size) else {
            throw Failure("Could not create the window frame.")
        }
        try requireSuccess(AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position), "Move target window")
        try requireSuccess(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions), "Resize target window")
    case .drag(let id, let fraction, let delta):
        try requireKeyboardAccess()
        try drag(in: frame(of: element(withID: id, in: app)), from: fraction, by: delta, to: pid)
    case .press(let id):
        let target = try element(withID: id, in: app)
        try requireSuccess(AXUIElementPerformAction(target, kAXPressAction as CFString), "AXPress")
    case .closeWindow(let id):
        let window = try element(withID: id, in: app)
        guard attribute(kAXRoleAttribute, on: window) as? String == kAXWindowRole,
              let raw = attribute(kAXCloseButtonAttribute, on: window), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw Failure("The specified window has no close button.")
        }
        try requireSuccess(AXUIElementPerformAction(unsafeBitCast(raw, to: AXUIElement.self), kAXPressAction as CFString), "Close window")
    case .selectFolder(let path):
        try selectFolder(path, in: element(withID: "open-panel", in: app))
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
            var selected = false
            if let current = attribute(kAXValueAttribute, on: target) as? String {
                var range = CFRange(location: 0, length: current.utf16.count)
                if let value = AXValueCreate(.cfRange, &range) {
                    selected = AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, value) == .success
                }
            }
            if !selected { try postKey(0, to: pid, flags: .maskCommand) }
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
