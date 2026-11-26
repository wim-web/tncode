import AppKit

enum WorkspaceFileMentionDrag {
    static let type = NSPasteboard.PasteboardType("dev.piworkspace.file-mention")

    static func itemProvider(_ id: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func token(from pasteboard: NSPasteboard) -> UUID? {
        guard let data = pasteboard.data(forType: type), data.count == 36,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: text)
    }
}

enum WorkspaceFileMention {
    // T3 Code 0.1.12 composerTrigger.ts and the relative-path rules of markdownLinks.ts.
    private static let destinationCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*';/,:@$=+")
    private static let extensionlessNames: Set<String> = [
        "Makefile", "makefile", "GNUmakefile", "Dockerfile", "Containerfile", "Justfile", "justfile",
        "Rakefile", "Gemfile", "Procfile", "Brewfile", "Caddyfile", "Vagrantfile", "Jenkinsfile",
        "Podfile", "Fastfile", "BUILD", "WORKSPACE", "LICENSE", "LICENCE", "COPYING", "NOTICE",
        "AUTHORS", "CONTRIBUTORS", "CHANGELOG", "README", "CODEOWNERS"
    ]
    private static let component = #"\p{L}\p{M}\p{N}._$+@()\[\]\-"#
    private static let nameComponent = #"\p{L}\p{M}\p{N}._$+()\[\]\-"#
    private static let linePosition = #":[0-9]+(?::[0-9]+|-[0-9]+)?"#
    private static let relativePath = try! NSRegularExpression(pattern:
        "\\A(?:[\(component)]+(?: +[\(component)]+)*/)+"
        + "(?:[\(component)]+(?: +[\(component)]+)*(?:\(linePosition))?)?\\z")
    private static let fileName = try! NSRegularExpression(pattern:
        "\\A[\(nameComponent)]+(?: +[\(nameComponent)]+)*"
        + #"\.[\p{L}\p{M}\p{N}_-]+"# + "(?:\(linePosition))?\\z")
    private static let rootedPath = try! NSRegularExpression(pattern: #"\A(?:[A-Za-z][A-Za-z0-9+.\-]*:|[\\/])"#)
    private static let explicitRelativePath = try! NSRegularExpression(pattern: #"\A(?:~/|\.{1,2}/)"#)
    private static let elidedPath = try! NSRegularExpression(pattern: #"(?:\A|[\\/])(?:\.{3,}|…)(?:[\\/]|\z)"#)
    private static let trailingLinePosition = try! NSRegularExpression(pattern: linePosition + #"\z"#)

    static func serialize(_ path: String) -> String {
        let scalars = path.unicodeScalars
        let start = scalars.lastIndex { $0 == "/" || $0 == "\\" }.map { scalars.index(after: $0) } ?? scalars.startIndex
        let label = scalars[start...].reduce(into: "") { label, scalar in
            if "\\[]*_&".unicodeScalars.contains(scalar) { label += "\\" }
            label.unicodeScalars.append(scalar)
        }
        let destination = path.addingPercentEncoding(withAllowedCharacters: destinationCharacters) ?? path
        let prefix = needsRelativePrefix(path) ? "./" : ""
        return "[\(label)](\(prefix)\(destination))"
    }

    static func append(_ mention: String, to draft: String) -> String {
        let hasBoundary = draft.unicodeScalars.last.map {
            $0.properties.generalCategory == .spaceSeparator
                || (9...13).contains($0.value) || [0x2028, 0x2029, 0xFEFF].contains($0.value)
        } ?? true
        return draft + (hasBoundary ? "" : " ") + mention + " "
    }

    private static func needsRelativePrefix(_ path: String) -> Bool {
        guard !path.isEmpty, !matches(rootedPath, in: path), !recognizesRelativePath(path) else { return false }
        return !path.unicodeScalars.contains("\\") ||
            !recognizesRelativePath(path.replacingOccurrences(of: "\\", with: "/", options: .literal))
    }

    private static func recognizesRelativePath(_ path: String) -> Bool {
        let name = trailingLinePosition.stringByReplacingMatches(
            in: path, range: NSRange(location: 0, length: path.utf16.count), withTemplate: "")
        guard !matches(elidedPath, in: name) else { return false }
        return matches(explicitRelativePath, in: name) || extensionlessNames.contains(name)
            || matches(relativePath, in: path) || matches(fileName, in: name)
    }

    private static func matches(_ pattern: NSRegularExpression, in path: String) -> Bool {
        pattern.firstMatch(in: path, range: NSRange(location: 0, length: path.utf16.count)) != nil
    }
}
