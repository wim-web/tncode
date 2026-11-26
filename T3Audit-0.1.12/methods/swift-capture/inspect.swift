import AppKit
import ApplicationServices

func read(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, key as CFString, &value) == .success ? value : nil
}

func pair(_ el: AXUIElement, _ key: String) -> [Double]? {
    guard let raw = read(el, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = unsafeBitCast(raw, to: AXValue.self)
    switch AXValueGetType(value) {
    case .cgPoint:
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return [point.x, point.y].allSatisfy(\.isFinite) ? [point.x, point.y] : nil
    case .cgSize:
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return [size.width, size.height].allSatisfy(\.isFinite) ? [size.width, size.height] : nil
    default: return nil
    }
}

func attributes(_ el: AXUIElement, origin: [Double]?, restricted: Bool = false) -> [String: Any] {
    let keys = restricted
        ? [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("enabled", kAXEnabledAttribute)]
        : [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("id", kAXIdentifierAttribute),
           ("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute),
           ("placeholder", kAXPlaceholderValueAttribute), ("enabled", kAXEnabledAttribute),
           ("focused", kAXFocusedAttribute)]
    var result = [String: Any]()
    for (label, key) in keys {
        if let str = read(el, key) as? String, !str.isEmpty { result[label] = str }
        if let bool = read(el, key) as? Bool { result[label] = bool }
    }
    if let position = pair(el, kAXPositionAttribute), let size = pair(el, kAXSizeAttribute) {
        let offset = origin ?? [0, 0]
        result["rect"] = [position[0] - offset[0], position[1] - offset[1], size[0], size[1]]
    }
    return result
}

let args = CommandLine.arguments
guard args.count >= 4, let pid = pid_t(args[1]), pid > 0, AXIsProcessTrusted() else {
    fputs("AX access or valid PID unavailable.\n", stderr)
    exit(2)
}
var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN * 4))
let pathCount = pathBuffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
func canonical(_ path: String) -> String? {
    guard let value = realpath(path, nil) else { return nil }
    defer { free(value) }
    return String(cString: value)
}
guard pathCount > 0, let runningPath = String(bytes: pathBuffer.prefix(while: { $0 != 0 }), encoding: .utf8),
      let expectedPath = canonical(args[2]), canonical(runningPath) == expectedPath else {
    fputs("PID executable path does not match the exact requested bundle.\n", stderr)
    exit(2)
}

let root = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(root, 1.0)
func owned(_ el: AXUIElement) -> Bool {
    var owner: pid_t = 0
    return AXUIElementGetPid(el, &owner) == .success && owner == pid
}
let windows = (read(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter(owned)
guard let main = windows.first(where: { read($0, kAXTitleAttribute) as? String == "Pi Workspace" }) else {
    fputs("Pi Workspace AX window unavailable.\n", stderr)
    exit(3)
}
if args[3] == "resize" {
    var size = CGSize(width: 1080, height: 720)
    let val = AXValueCreate(.cgSize, &size)!
    let status = AXUIElementSetAttributeValue(main, kAXSizeAttribute as CFString, val)
    print("AXSize request \(size) status \(status.rawValue)")
    exit(status == .success ? 0 : 4)
}
let origin = pair(main, kAXPositionAttribute)
let restricted = args[3] == "panel"
var seen = Set<AXUIElement>()
var nodes: [[String: Any]] = []
func walk(_ el: AXUIElement, parent: Int?, depth: Int) {
    guard owned(el), seen.insert(el).inserted, depth <= (restricted ? 7 : 45) else { return }
    var info = attributes(el, origin: origin, restricted: restricted)
    let index = nodes.count
    info["index"] = index
    info["parent"] = parent
    nodes.append(info)
    if read(el, kAXIdentifierAttribute) as? String == "open-panel" { return }
    for child in read(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        walk(child, parent: index, depth: depth + 1)
    }
}
windows.forEach { walk($0, parent: nil, depth: 0) }
var result: [String: Any] = ["atUTC": ISO8601DateFormatter().string(from: Date()),
                             "pid": pid, "window": attributes(main, origin: nil), "nodes": nodes]
if let position = origin,
   let split = nodes.first(where: { $0["role"] as? String == "AXSplitGroup" }),
   let rect = split["rect"] as? [Double] {
    result["contentAX"] = [position[0] + rect[0], position[1] + rect[1], rect[2], rect[3]]
}
if let raw = read(root, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
    let focus = unsafeBitCast(raw, to: AXUIElement.self)
    if owned(focus) { result["focus"] = attributes(focus, origin: origin, restricted: restricted) }
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data + Data("\n".utf8))
