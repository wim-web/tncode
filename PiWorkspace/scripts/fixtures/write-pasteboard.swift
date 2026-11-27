import AppKit
import Darwin

// One item can advertise both an image and its plain-text alternative.
let args = Array(CommandLine.arguments.dropFirst())
guard (2...3).contains(args.count), args[0].hasPrefix("dev.piworkspace.verification."),
      args[1] == "png" || (args[1] == "text" && args.count == 2) ||
        (args[1] == "file" && args.count == 3 && args[2].hasPrefix("/private/tmp/pi-text-attachments-")) else {
    fputs("Usage: write-pasteboard VERIFICATION_BOARD text|png [PNG_TEXT_ALTERNATIVE] < payload\n", stderr)
    fputs("       write-pasteboard VERIFICATION_BOARD file FIXTURE_PATH\n", stderr)
    exit(2)
}
let board = NSPasteboard(name: .init(args[0]))
let item = NSPasteboardItem()
if args[1] == "png" {
    let bytes = FileHandle.standardInput.readDataToEndOfFile()
    guard item.setData(bytes, forType: .png) else { exit(1) }
    if args.count == 3, !item.setString(args[2], forType: .string) { exit(1) }
} else if args[1] == "file" {
    let path = args[2]
    guard let resolved = realpath(path, nil) else { exit(1) }
    defer { free(resolved) }
    guard String(cString: resolved) == path,
          item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL) else { exit(1) }
} else {
    let bytes = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: bytes, encoding: .utf8), item.setString(text, forType: .string) else { exit(1) }
}
board.clearContents()
guard board.writeObjects([item]) else { exit(1) }
