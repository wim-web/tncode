import AppKit
import ApplicationServices
import Foundation

private struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func processArguments(_ pid: pid_t) throws -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        throw Failure("Cannot read the fixture process arguments.")
    }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else {
        throw Failure("Cannot read the fixture process arguments.")
    }
    let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    return bytes.dropFirst(MemoryLayout<Int32>.size).split(separator: 0)
        .dropFirst().prefix(count).map { String(decoding: $0, as: UTF8.self) }
}

private func assertFixture(_ workspace: String, pid: pid_t) throws {
    let url = URL(fileURLWithPath: workspace, isDirectory: true)
    let root = url.deletingLastPathComponent()
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    let args = try processArguments(pid)
    guard workspace == url.resolvingSymlinksInPath().path,
          url.lastPathComponent == "workspace", root.deletingLastPathComponent().path == "/private/tmp",
          root.lastPathComponent.hasPrefix("pi-sidebar-pointer."),
          attributes[.ownerAccountID] as? UInt32 == getuid(), attributes[.posixPermissions] as? Int == 0o700,
          NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "dev.tncode.app",
          let index = args.firstIndex(of: "--workspace"), args.dropFirst(index + 1).first == workspace else {
        throw Failure("Use a tncode app launched with --workspace under a private pi-sidebar-pointer directory.")
    }
}

private func read(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

private func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = read(kAXPositionAttribute, from: element), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = read(kAXSizeAttribute, from: element), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &position),
          AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size), size.height > 0 else { return nil }
    return CGRect(origin: position, size: size)
}

private func frames(in app: AXUIElement, ids: Set<String>) -> [String: CGRect] {
    var result: [String: CGRect] = [:]
    var visited = Set<AXUIElement>()
    var pending = (read(kAXWindowsAttribute, from: app) as? [AXUIElement]) ?? []
    while let current = pending.popLast(), result.count < ids.count {
        guard visited.insert(current).inserted else { continue }
        if let id = read(kAXIdentifierAttribute, from: current) as? String, ids.contains(id) {
            result[id] = frame(current)
        }
        pending += (read(kAXChildrenAttribute, from: current) as? [AXUIElement]) ?? []
    }
    return result
}

private func waitForFrames(in app: AXUIElement, ids: Set<String>,
                           matching predicate: ([String: CGRect]) -> Bool = { _ in true }) throws -> [String: CGRect] {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    repeat {
        let result = frames(in: app, ids: ids)
        if result.count == ids.count, predicate(result) { return result }
        Thread.sleep(forTimeInterval: 0.03)
    } while ProcessInfo.processInfo.systemUptime < deadline
    let observed = frames(in: app, ids: ids).sorted { $0.value.midY < $1.value.midY }.map(\.key)
    throw Failure("Expected controls or row order were absent. Observed: \(observed.joined(separator: ", ")).")
}

private func owned(_ point: CGPoint, by pid: pid_t) -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
    let covering = windows.first { info in
        guard info[kCGWindowLayer as String] as? Int == 0, let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return frame.contains(point)
    }
    return covering?[kCGWindowOwnerPID as String] as? pid_t == pid
}

private func send(_ type: CGEventType, at point: CGPoint, to pid: pid_t) throws {
    guard owned(point, by: pid),
          let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
        throw Failure("The fixture no longer owns the unobstructed frontmost drag path.")
    }
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.post(tap: .cghidEventTap)
}

private func run() throws {
    guard ProcessInfo.processInfo.environment["TNCODE_TEST_DESKTOP"] == "dedicated" else {
        throw Failure("Run the pointer test in a separate test desktop with TNCODE_TEST_DESKTOP=dedicated.")
    }
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] {
        print("Usage: verify-sidebar-thread-pointer --isolated-session WORKSPACE PID SOURCE_ID TARGET_ID [EXPECTED_ROW_ID ...]")
        return
    }
    guard args.count >= 5, args[0] == "--isolated-session", let pid = pid_t(args[2]), pid > 0 else {
        throw Failure("Pass --help for the isolated fixture usage.")
    }
    try assertFixture(args[1], pid: pid)
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
          ![CGMouseButton.left, .right, .center].contains(where: { CGEventSource.buttonState(.combinedSessionState, button: $0) }) else {
        throw Failure("The isolated desktop needs Accessibility, event posting permission, and an idle pointer.")
    }
    let source = args[3], target = args[4], expected = Array(args.dropFirst(5))
    let app = AXUIElementCreateApplication(pid)
    let sourceFrames = try waitForFrames(in: app, ids: [source])
    guard let sourceFrame = sourceFrames[source] else { throw Failure("The source disappeared.") }
    let start = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
    let saved = CGEvent(source: nil)?.location
    var last = start
    var pressed = false
    defer {
        if pressed, let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                    mouseCursorPosition: last, mouseButton: .left) {
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            if owned(last, by: pid) { up.post(tap: .cghidEventTap) } else { up.postToPid(pid) }
        }
        if let saved, owned(last, by: pid), let cursor = CGEvent(source: nil)?.location,
           hypot(cursor.x - last.x, cursor.y - last.y) < 2 { CGWarpMouseCursorPosition(saved) }
    }

    try send(.mouseMoved, at: start, to: pid)
    Thread.sleep(forTimeInterval: 0.08)
    try send(.leftMouseDown, at: start, to: pid)
    pressed = true
    Thread.sleep(forTimeInterval: 0.1)
    last.y += 9
    try send(.leftMouseDragged, at: last, to: pid)
    let targetFrames = try waitForFrames(in: app, ids: [target, "sidebar-active-drop"])
    guard let targetFrame = targetFrames[target] else { throw Failure("The destination disappeared.") }
    let end = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    let initial = last
    for step in 1...12 {
        let ratio = CGFloat(step) / 12
        let point = CGPoint(x: initial.x + ratio * (end.x - initial.x),
                            y: initial.y + ratio * (end.y - initial.y))
        try send(.leftMouseDragged, at: point, to: pid)
        last = point
        Thread.sleep(forTimeInterval: 0.045)
    }
    try send(.leftMouseUp, at: end, to: pid)
    pressed = false
    print("Released \(source) on \(target) at (\(end.x), \(end.y)).")
    if !expected.isEmpty {
        let observed = try waitForFrames(in: app, ids: Set(expected)) {
            $0.sorted { $0.value.midY < $1.value.midY }.map(\.key) == expected
        }
        for (id, rect) in observed.sorted(by: { $0.value.midY < $1.value.midY }) {
            print("\(id) \(rect.midY)")
        }
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
