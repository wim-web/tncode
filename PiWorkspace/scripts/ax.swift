import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

private let usage = """
Usage:
  ax trust
  ax check-copy TEST_PASTEBOARD < expected.txt
  ax release-test-pasteboard TEST_PASTEBOARD
  ax activate PID
  ax menu-command PID CHARACTER
  ax menu-item PID TITLE
  ax pick PID POPUP_IDENTIFIER OPTION_TITLE
  ax dump PID [--values] [--no-labels] [--depth N]
  ax get PID IDENTIFIER [--values] [--no-labels]
  ax selected-text PID TEXT_AREA_IDENTIFIER
  ax frame PID IDENTIFIER [--popover]
  ax web-frame PID DOM_IDENTIFIER
  ax size-window PID WINDOW_IDENTIFIER WIDTH HEIGHT
  ax drag PID IDENTIFIER FRACTION_X FRACTION_Y DELTA_X DELTA_Y
  ax drop-fixture PID WORKSPACE WINDOW_IDENTIFIER TARGET_IDENTIFIER FIXTURE_PATH
  ax press PID IDENTIFIER
  ax show-menu PID IDENTIFIER
  ax segment PID GROUP_IDENTIFIER LABEL
  ax close-window PID WINDOW_IDENTIFIER
  ax select-folder PID ABSOLUTE_PATH
  ax select-path PID ABSOLUTE_PATH
  ax confirm PID IDENTIFIER
  ax set PID IDENTIFIER < text.txt
  ax type PID IDENTIFIER [--replace] < text.txt
  ax key PID KEYCODE [cmd] [shift] [opt] [ctrl] [fn]
  ax key-focused PID IDENTIFIER KEYCODE [cmd] [shift] [opt] [ctrl] [fn]

dump/get show roles, identifiers, and labels. --values includes AXValue
where available, except for secure text fields. --no-labels hides AXTitle,
AXDescription, and AXPlaceholderValue. set/type read UTF-8 stdin verbatim.
type and key target PID. drag, drop-fixture and show-menu require an unobstructed frontmost window.
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
    case pick(String, String)
    case dump(DisplayOptions)
    case get(String, DisplayOptions)
    case selectedText(String)
    case frame(String, popover: Bool)
    case webFrame(String)
    case sizeWindow(String, CGSize)
    case drag(String, CGPoint, CGSize)
    case dropFixture(workspace: String, window: String, target: String, path: String)
    case press(String)
    case showMenu(String)
    case segment(String, String)
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
        case ("pick", let id?) where arguments.count == 2:
            self = .pick(id, arguments[arguments.startIndex + 1])
        case ("dump", _):
            self = try .dump(DisplayOptions(arguments, allowDepth: true))
        case ("get", let id?):
            self = try .get(id, DisplayOptions(arguments.dropFirst(), allowDepth: false))
        case ("selected-text", let id?) where arguments.count == 1:
            self = .selectedText(id)
        case ("frame", let id?) where arguments.count == 1 || arguments.dropFirst().elementsEqual(["--popover"]):
            self = .frame(id, popover: arguments.count == 2)
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
        case ("drop-fixture", let workspace?) where arguments.count == 4 && workspace.hasPrefix("/") && arguments.last?.hasPrefix("/") == true:
            self = .dropFixture(workspace: workspace, window: arguments[arguments.startIndex + 1],
                                target: arguments[arguments.startIndex + 2], path: arguments[arguments.startIndex + 3])
        case ("press", let id?) where arguments.count == 1:
            self = .press(id)
        case ("show-menu", let id?) where arguments.count == 1:
            self = .showMenu(id)
        case ("segment", let id?) where arguments.count == 2:
            self = .segment(id, arguments[arguments.startIndex + 1])
        case ("close-window", let id?) where arguments.count == 1:
            self = .closeWindow(id)
        case (let command, let path?) where ["select-folder", "select-path"].contains(command) && arguments.count == 1 && path.hasPrefix("/"):
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
        if role == kAXSplitterRole {
            if let minimum = attribute(kAXMinValueAttribute, on: element) as? NSNumber { parts.append("min=\(minimum)") }
            if let maximum = attribute(kAXMaxValueAttribute, on: element) as? NSNumber { parts.append("max=\(maximum)") }
        }
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
    private let skipMenuBar: Bool

    init(root: AXUIElement, maxDepth: Int? = nil, skipMenuBar: Bool = false) {
        pending = [(root, 0)]
        self.maxDepth = maxDepth
        self.skipMenuBar = skipMenuBar
    }

    mutating func next() -> (element: AXUIElement, depth: Int)? {
        while let node = pending.popLast() {
            guard seen.insert(node.element).inserted else { continue }
            if skipMenuBar, attribute(kAXRoleAttribute, on: node.element) as? String == kAXMenuBarRole { continue }
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
    throw Failure("The requested path is not selectable in the open panel.")
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

private func processArguments(_ pid: pid_t) throws -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        throw Failure("Could not read the destination process arguments.")
    }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else {
        throw Failure("Could not read the destination process arguments.")
    }
    let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    let strings = bytes[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: false)
    return strings.dropFirst().drop(while: \.isEmpty).prefix(count).map { String(decoding: $0, as: UTF8.self) }
}

private func dropFixtureURL(pid: pid_t, workspace: String, path: String) throws -> URL {
    func canonical(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true)
    let root = workspaceURL.deletingLastPathComponent()
    let values = try FileManager.default.attributesOfItem(atPath: root.path)
    let args = try processArguments(pid)
    guard canonical(workspace) == workspace, workspaceURL.lastPathComponent == "workspace",
          root.deletingLastPathComponent().path == "/private/tmp", root.lastPathComponent.hasPrefix("pi-drag-"),
          values[.ownerAccountID] as? UInt32 == getuid(),
          (values[.posixPermissions] as? UInt16) == 0o700,
          NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "dev.piworkspace.app",
          let index = args.firstIndex(of: "--workspace"), args.dropFirst(index + 1).first == workspace else {
        throw Failure("The destination must be a Pi Workspace process using this private drag fixture workspace.")
    }
    let url = URL(fileURLWithPath: path)
    let type = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
    guard canonical(path) == path, url.deletingLastPathComponent().path == root.path,
          path != workspace, type.isRegularFile == true || type.isDirectory == true else {
        throw Failure("The source must be a file or folder directly inside the private fixture root.")
    }
    return url
}

private struct DragWindow {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect

    static func at(_ point: CGPoint) -> DragWindow? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? CGWindowLevel,
                  layer >= CGWindowLevelForKey(.normalWindow), layer < CGWindowLevelForKey(.draggingWindow),
                  (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(point),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return DragWindow(id: id, pid: pid, frame: frame)
        }
        return nil
    }
}

private final class FixtureDragSource: NSView, NSDraggingSource {
    let url: URL
    let didStart = DispatchSemaphore(value: 0)
    let didEnd = DispatchSemaphore(value: 0)
    private var down: NSEvent?
    private(set) var started = false
    private(set) var operation: NSDragOperation?

    init(url: URL, size: CGSize) {
        self.url = url
        super.init(frame: CGRect(origin: .zero, size: size))
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = bounds.insetBy(dx: 5, dy: 10)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { down = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down, !started else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds.insetBy(dx: 8, dy: 5), contents: NSImage(named: NSImage.multipleDocumentsName))
        beginDraggingSession(with: [item], event: down, source: self).animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        started = true
        didStart.signal()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        self.operation = operation
        didEnd.signal()
    }
}

private func element(at point: CGPoint) -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 1.5)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success else {
        return nil
    }
    return hit
}

private func hitTest(_ target: AXUIElement, at point: CGPoint) -> Bool {
    var hit = element(at: point)
    var seen: Set<AXUIElement> = []
    while let current = hit, seen.insert(current).inserted {
        if CFEqual(current, target) { return true }
        guard let parent = attribute(kAXParentAttribute, on: current), CFGetTypeID(parent) == AXUIElementGetTypeID() else {
            return false
        }
        hit = unsafeBitCast(parent, to: AXUIElement.self)
    }
    return false
}

private func dropFixture(_ url: URL, in window: AXUIElement, target: AXUIElement, pid: pid_t) throws {
    let sourcePID = getpid()
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          ![CGMouseButton.left, .right, .center].contains(where: { CGEventSource.buttonState(.combinedSessionState, button: $0) }),
          let savedPosition = CGEvent(source: nil)?.location,
          let mainScreen = NSScreen.screens.first else {
        throw Failure("A frontmost fixture window and idle pointer are required.")
    }
    let windowFrame = try frame(of: window)
    let targetFrame = try frame(of: target).intersection(windowFrame)
    guard !targetFrame.isEmpty else { throw Failure("The named control is outside its workspace window.") }
    let center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    guard let destination = DragWindow.at(center), destination.pid == pid, destination.frame.integral == windowFrame.integral else {
        throw Failure("The named workspace window does not own the center of the destination.")
    }
    let points = [0.5, 0.25, 0.75].map { CGPoint(x: targetFrame.minX + targetFrame.width * $0, y: targetFrame.midY) }
    guard let end = points.first(where: { DragWindow.at($0)?.id == destination.id && hitTest(target, at: $0) }) else {
        let role = element(at: center).flatMap { attribute(kAXRoleAttribute, on: $0) as? String } ?? "unavailable"
        throw Failure("The named workspace owns the destination, but its accessibility hit is \(role) rather than the named control.")
    }
    let desktopTop = mainScreen.frame.maxY
    func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
    }
    let panelSize = CGSize(width: 100, height: 40)
    guard let screen = NSScreen.screens.first(where: { flip($0.visibleFrame).contains(end) }),
          let panelFrame = [(96.0, 0.0), (-96, 0), (0, 68), (0, -68)].map({ dx, dy in
              CGRect(x: end.x + dx - panelSize.width / 2, y: end.y + dy - panelSize.height / 2,
                     width: panelSize.width, height: panelSize.height)
          }).first(where: { windowFrame.insetBy(dx: 8, dy: 8).contains($0) && flip(screen.visibleFrame).contains($0) }) else {
        throw Failure("There is no room for a fixture source beside the drop target.")
    }
    let source = FixtureDragSource(url: url, size: panelSize)
    let panel = NSPanel(contentRect: flip(panelFrame), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.title = "Pi Workspace Drag Fixture"
    panel.isReleasedWhenClosed = false
    panel.level = .normal
    panel.contentView = source
    let start = CGPoint(x: panelFrame.midX, y: panelFrame.midY)
    let startDrag = CGPoint(x: start.x + 8, y: start.y)
    func pump(_ seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            guard let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) else { break }
            NSApp.sendEvent(event)
        }
    }
    @Sendable func sendMouse(_ type: CGEventType, at point: CGPoint, to sourceOnly: Bool = false) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            throw Failure("Could not create a fixture mouse event.")
        }
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        if sourceOnly { event.postToPid(sourcePID) }
        else { event.post(tap: .cghidEventTap) }
    }
    @Sendable func fixtureIsFrontmost() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return front == pid || front == sourcePID
    }
    defer { panel.close() }
    panel.orderFrontRegardless()
    pump(0.15)
    let panelID = CGWindowID(panel.windowNumber)
    @Sendable func check(_ point: CGPoint, windows: Set<CGWindowID>) throws {
        guard fixtureIsFrontmost(), let hit = DragWindow.at(point), windows.contains(hit.id),
              hit.id != destination.id || hit.frame == destination.frame else {
            throw Failure("The fixture lost its unobstructed drag path.")
        }
    }
    let steps = 12
    let path = (1...steps).map { step in
        let fraction = CGFloat(step) / CGFloat(steps)
        return CGPoint(x: startDrag.x + fraction * (end.x - startDrag.x), y: startDrag.y + fraction * (end.y - startDrag.y))
    }
    try check(start, windows: [panelID])
    try check(startDrag, windows: [panelID])
    try check(end, windows: [destination.id])
    for point in path { try check(point, windows: [panelID, destination.id]) }

    let outcome = OSAllocatedUnfairLock(initialState: Optional<Result<Void, Error>>.none)
    let started = source.didStart, ended = source.didEnd
    // AppKit can enter a nested tracking loop when the source starts the drag.
    DispatchQueue.global(qos: .userInitiated).async {
        let result = Result {
            var needsRelease = false
            defer {
                if needsRelease {
                    try? postKey(53, to: sourcePID)
                    let safe = fixtureIsFrontmost() && DragWindow.at(start)?.id == panelID
                    try? sendMouse(.leftMouseUp, at: start, to: !safe)
                    _ = ended.wait(timeout: .now() + 0.5)
                }
                CGWarpMouseCursorPosition(savedPosition)
            }
            try check(start, windows: [panelID])
            try sendMouse(.leftMouseDown, at: start)
            needsRelease = true
            Thread.sleep(forTimeInterval: 0.1)
            try check(startDrag, windows: [panelID])
            try sendMouse(.leftMouseDragged, at: startDrag)
            guard started.wait(timeout: .now() + 1) == .success else {
                throw Failure("AppKit did not start a drag session in the fixture source window.")
            }
            for point in path {
                try check(point, windows: [panelID, destination.id])
                try sendMouse(.leftMouseDragged, at: point)
                Thread.sleep(forTimeInterval: 0.035)
            }
            Thread.sleep(forTimeInterval: 0.25)
            guard hitTest(target, at: end) else { throw Failure("The drop point no longer hits the named AX target.") }
            try check(end, windows: [destination.id])
            try sendMouse(.leftMouseUp, at: end)
            guard ended.wait(timeout: .now() + 2) == .success else {
                throw Failure("The drag session did not end.")
            }
            needsRelease = false
        }
        outcome.withLock { $0 = result }
    }
    while outcome.withLock({ $0 == nil }) { pump(0.05) }
    try outcome.withLock { $0! }.get()
    guard source.operation?.contains(.copy) == true else {
        throw Failure("AppKit reported no accepted copy at the drop target.")
    }
    print("Native file drop copied \(url.lastPathComponent)")
}

private func requireKeyboardAccess() throws {
    guard CGPreflightPostEventAccess() else {
        throw Failure("This process cannot post keyboard events in the current macOS session.")
    }
}

private func activateForInput(_ app: AXUIElement, pid: pid_t) throws {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
    if let raw = attribute(kAXFocusedWindowAttribute, on: app), CFGetTypeID(raw) == AXUIElementGetTypeID() {
        _ = AXUIElementPerformAction(unsafeBitCast(raw, to: AXUIElement.self), kAXRaiseAction as CFString)
    }
    try requireSuccess(AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue),
                       "Activate the designated application")
    NSRunningApplication(processIdentifier: pid)?.activate()
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure("The designated application did not gain focus.") }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.025))
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
        try activateForInput(app, pid: pid)
    case .menuCommand(let key):
        try activateForInput(app, pid: pid)
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
        func enabledItems() -> [AXUIElement] {
            Tree(root: app).map(\.element).filter {
                attribute(kAXRoleAttribute, on: $0) as? String == kAXMenuItemRole &&
                attribute(kAXTitleAttribute, on: $0) as? String == title &&
                attribute(kAXEnabledAttribute, on: $0) as? Bool == true
            }
        }
        var matches = enabledItems()
        if matches.count != 1 {
            try activateForInput(app, pid: pid)
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            repeat {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
                matches = enabledItems()
            } while matches.count != 1 && ProcessInfo.processInfo.systemUptime < deadline
        }
        guard matches.count == 1, let item = matches.first else { throw Failure("Expected exactly one enabled menu item matching the title.") }
        try requireSuccess(AXUIElementPerformAction(item, kAXPressAction as CFString), "Select menu item")
    case .pick(let id, let title):
        let popup = try element(withID: id, in: app)
        guard [kAXPopUpButtonRole, kAXMenuButtonRole].contains(attribute(kAXRoleAttribute, on: popup) as? String ?? "") else {
            throw Failure("The requested control is not a popup or menu button.")
        }
        for attempt in 0..<2 {
            if attempt > 0 { try activateForInput(app, pid: pid) }
            try requireSuccess(AXUIElementPerformAction(popup, kAXPressAction as CFString), "Open \(id)")
            let deadline = ProcessInfo.processInfo.systemUptime + 0.9
            repeat {
                let choices = Tree(root: app, skipMenuBar: true).map(\.element).filter {
                    attribute(kAXRoleAttribute, on: $0) as? String == kAXMenuItemRole &&
                    attribute(kAXTitleAttribute, on: $0) as? String == title &&
                    attribute(kAXEnabledAttribute, on: $0) as? Bool == true
                }
                if choices.count == 1, let choice = choices.first {
                    try requireSuccess(AXUIElementPerformAction(choice, kAXPressAction as CFString), "Select \(title)")
                    return
                }
                guard choices.isEmpty else { throw Failure("Multiple presented menu choices are labeled \(title).") }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.045))
            } while ProcessInfo.processInfo.systemUptime < deadline
        }
        throw Failure("The popup \(id) did not present an enabled choice labeled \(title).")
    case .dump(let options):
        for (node, depth) in Tree(root: app, maxDepth: options.maxDepth) {
            print(String(repeating: "  ", count: depth) + line(for: node, options: options))
        }
    case .get(let id, let options):
        print(try line(for: element(withID: id, in: app), options: options))
    case .selectedText(let id):
        let target = try element(withID: id, in: app)
        guard attribute(kAXRoleAttribute, on: target) as? String == kAXTextAreaRole,
              let text = attribute(kAXSelectedTextAttribute, on: target) as? String else {
            throw Failure("The requested text area does not expose a selection.")
        }
        print(text, terminator: "")
    case .frame(let id, let popover):
        var target = try element(withID: id, in: app)
        if popover {
            var seen: Set<AXUIElement> = []
            while attribute(kAXRoleAttribute, on: target) as? String != "AXPopover" {
                guard seen.insert(target).inserted, let raw = attribute(kAXParentAttribute, on: target),
                      CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw Failure("The control has no enclosing popover.") }
                target = unsafeBitCast(raw, to: AXUIElement.self)
            }
        }
        let rect = try frame(of: target)
        print("\(rect.minX) \(rect.minY) \(rect.width) \(rect.height)")
    case .keyFocused(let id, let code, let flags):
        try requireKeyboardAccess()
        try activateForInput(app, pid: pid)
        let field = try element(withID: id, in: app)
        guard attribute(kAXFocusedAttribute, on: field) as? Bool == true else { throw Failure("The target field lacks focus.") }
        let characters: [CGKeyCode: UInt16] = [0: 0x61, 2: 0x64, 3: 0x66, 7: 0x78, 8: 0x63, 13: 0x77,
                                               16: 0x79, 17: 0x74, 18: 0x31, 19: 0x32, 20: 0x33, 21: 0x34,
                                               30: 0x5D, 32: 0x75, 33: 0x5B, 35: 0x70, 37: 0x6C,
                                               36: 0x0D, 40: 0x6B, 48: 0x09, 51: 0x7F, 53: 0x1B,
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
        guard ![CGMouseButton.left, .right, .center].contains(where: { CGEventSource.buttonState(.combinedSessionState, button: $0) }) else {
            throw Failure("A fixture drag requires an idle pointer.")
        }
        try activateForInput(app, pid: pid)
        try drag(in: frame(of: element(withID: id, in: app)), from: fraction, by: delta, to: pid)
    case .dropFixture(let workspace, let windowID, let targetID, let path):
        try requireKeyboardAccess()
        let url = try dropFixtureURL(pid: pid, workspace: workspace, path: path)
        let window = try element(withID: windowID, in: app)
        guard attribute(kAXRoleAttribute, on: window) as? String == kAXWindowRole else {
            throw Failure("drop-fixture requires a window identifier.")
        }
        let target = try element(withID: targetID, in: window)
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        guard ![CGMouseButton.left, .right, .center].contains(where: { CGEventSource.buttonState(.combinedSessionState, button: $0) }) else {
            throw Failure("A fixture drag requires an idle pointer.")
        }
        try activateForInput(app, pid: pid)
        try dropFixture(url, in: window, target: target, pid: pid)
    case .press(let id):
        var target = try? element(withID: id, in: app)
        if target == nil {
            try activateForInput(app, pid: pid)
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while target == nil, ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
                target = try? element(withID: id, in: app)
            }
        }
        guard let target else { throw Failure("No element has that identifier.") }
        try requireSuccess(AXUIElementPerformAction(target, kAXPressAction as CFString), "AXPress")
    case .showMenu(let id):
        try requireKeyboardAccess()
        guard ![CGMouseButton.left, .right, .center].contains(where: { CGEventSource.buttonState(.combinedSessionState, button: $0) }) else {
            throw Failure("Opening a context menu requires an idle pointer.")
        }
        try activateForInput(app, pid: pid)
        let target = try element(withID: id, in: app)
        let rect = try frame(of: target)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        guard DragWindow.at(point)?.pid == pid, hitTest(target, at: point),
              let previous = CGEvent(source: nil)?.location,
              let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
              let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right) else {
            throw Failure("The context menu target is not exposed at its own screen position.")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.09)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, DragWindow.at(point)?.pid == pid {
            up.post(tap: .cghidEventTap)
        } else {
            up.postToPid(pid)
        }
        if CGEvent(source: nil)?.location == point { CGWarpMouseCursorPosition(previous) }
    case .segment(let id, let title):
        let group = try element(withID: id, in: app)
        let matches = Tree(root: group).map(\.element).filter { item in
            attribute(kAXRoleAttribute, on: item) as? String == kAXRadioButtonRole &&
            [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute($0, on: item) as? String == title }
        }
        guard matches.count == 1, let segment = matches.first else {
            throw Failure("Expected one segment labeled \(title) in \(id).")
        }
        try requireSuccess(AXUIElementPerformAction(segment, kAXPressAction as CFString), "Select segment")
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
        if attribute(kAXFocusedAttribute, on: target) as? Bool != true {
            try requireSuccess(AXUIElementSetAttributeValue(target, focused, kCFBooleanTrue), "Set AXFocused")
        }
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
