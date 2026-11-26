import AppKit
import ApplicationServices
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let pid = Int32(args[1]), let width = Double(args[2]),
      let height = Double(args[3]), (780...1600).contains(width), (600...1000).contains(height),
      NSRunningApplication(processIdentifier: pid)?.bundleURL?.path == "/Applications/T3 Code (Beta).app" else { exit(2) }
let app = AXUIElementCreateApplication(pid)
var raw: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
      let windows = raw as? [AXUIElement] else { exit(3) }
func rect(_ e: AXUIElement) -> CGSize {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e,kAXSizeAttribute as CFString,&value) == .success,
          let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return .zero }
    var size = CGSize.zero
    AXValueGetValue(value as! AXValue,.cgSize,&size)
    return size
}
let candidates = windows.filter { w in
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(w,kAXSubroleAttribute as CFString,&role)
    return (role as? String) == "AXStandardWindow" && rect(w).height >= 600
}
guard candidates.count == 1, let window=candidates.first else {
    print("Window sizes",windows.map(rect));exit(5)
}
var size = CGSize(width: width, height: height)
guard let value = AXValueCreate(.cgSize, &size),
      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success else { exit(4) }

Thread.sleep(forTimeInterval:0.15)
print("Requested",size,"AX",rect(window))
