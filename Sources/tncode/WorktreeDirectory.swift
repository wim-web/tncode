import Foundation

enum WorktreeDirectory {
    static let invalid = WorkspaceError(
        "Choose an absolute folder path below / in Settings → Worktrees."
    )

    static func resolve(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let expanded: String
        if path == "~" {
            expanded = home.path
        } else if path.hasPrefix("~/") || path.hasPrefix("~\\") {
            expanded = home.path + "/" + path.dropFirst(2)
        } else {
            expanded = path
        }
        guard expanded.hasPrefix("/"), !expanded.utf8.contains(0) else { throw invalid }
        // Resolve . and .. before following symlinks, as the reference server does.
        var components: [Substring] = []
        for part in expanded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(part)
            }
        }
        guard !components.isEmpty else { throw invalid }
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
    }

    // Finder's Copy as Pathname can provide a shell-quoted or escaped path.
    static func replacingPastedPath(previous: String, next: String) -> String {
        let isTyping = next.hasPrefix(previous)
            ? next.utf16.count == previous.utf16.count + 1
            : previous.hasPrefix(next)
        guard !isTyping else { return next }

        if let range = next.range(of: #"(?:'((?:[^']|'\\'')+)'|"([^"]+)")\s*$"#, options: .regularExpression),
           previous.hasPrefix(next[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)) {
            let quoted = next[range].trimmingCharacters(in: .whitespacesAndNewlines)
            let contents = String(quoted.dropFirst().dropLast())
            let path = quoted.hasPrefix("'") ? contents.replacingOccurrences(of: "'\\''", with: "'") : contents
            if isPastedFolderPath(path) { return path }
        }

        let afterFolder = (previous.hasSuffix("/") || previous.hasSuffix("\\")) && next.hasPrefix(previous)
        let path = afterFolder ? String(next.dropFirst(previous.count)) : next
        guard isPastedFolderPath(path) else { return next }
        if isWindowsPath(path) { return path }
        return path.replacingOccurrences(of: #"\\([\s'"\\()\[\]{}<>|&;$`!*?#~^=])"#,
                                         with: "$1", options: .regularExpression)
    }

    private static func isPastedFolderPath(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~/") || isWindowsPath(path)
    }

    private static func isWindowsPath(_ path: String) -> Bool {
        path.hasPrefix("\\\\") || path.range(of: #"^[A-Za-z]:([/\\]|$)"#, options: .regularExpression) != nil
    }
}
