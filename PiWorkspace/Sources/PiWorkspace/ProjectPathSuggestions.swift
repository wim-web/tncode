import Foundation

struct ProjectPathSuggestions {
    enum Row: Hashable {
        case parent
        case folder(String)
    }

    struct Listing {
        let directory: URL
        let names: [String]

        static func load(_ directory: URL) async throws -> Self {
            try Task.checkCancellation()
            let task = Task.detached {
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
                let manager = FileManager.default
                let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
                let names = try entries.compactMap { entry -> String? in
                    try Task.checkCancellation()
                    guard let properties = try? entry.resourceValues(forKeys: keys) else { return nil }
                    if properties.isDirectory == true { return entry.lastPathComponent }
                    guard properties.isSymbolicLink == true else { return nil }
                    var isDirectory: ObjCBool = false
                    return manager.fileExists(atPath: entry.path, isDirectory: &isDirectory) && isDirectory.boolValue
                        ? entry.lastPathComponent : nil
                }
                return Self(directory: directory, names: names.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                })
            }
            let listing = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            return listing
        }
    }

    let directory: URL
    private let prefix: String
    private let fragment: String

    init?(path: String, basePath: String?) {
        let query = path.drop(while: \.isWhitespace)
        guard !query.utf8.contains(0) else { return nil }
        if query == "~" || (query.isEmpty && basePath == nil) {
            prefix = "~/"
            fragment = ""
        } else if let separator = query.lastIndex(of: "/") {
            prefix = String(query[...separator])
            fragment = String(query[query.index(after: separator)...])
        } else {
            prefix = ""
            fragment = String(query)
        }
        guard let directory = try? ProjectFolder.resolve(prefix.isEmpty ? "." : prefix, relativeTo: basePath)
        else { return nil }
        self.directory = directory
    }

    private var parentPath: String? {
        let components = prefix.dropLast()
        if let separator = components.lastIndex(of: "/") {
            return String(components[...separator])
        }
        return components.isEmpty || components == "~" || components == "." || components == ".." ? nil : "./"
    }

    func rows(in listing: Listing?) -> [Row] {
        var rows: [Row] = parentPath == nil ? [] : [.parent]
        guard listing?.directory == directory, let names = listing?.names else { return rows }
        let showsHidden = fragment.hasPrefix(".")
        rows += names.filter { name in
            (showsHidden || !name.hasPrefix(".")) &&
                (fragment.isEmpty || name.range(of: fragment, options: [.anchored, .caseInsensitive]) != nil)
        }.map(Row.folder)
        return rows
    }

    func path(for row: Row) -> String? {
        switch row {
        case .parent: parentPath
        case .folder(let name): prefix + name + "/"
        }
    }

    func tabCompletion(in rows: [Row], highlighted: Row?) -> String? {
        if let highlighted, rows.contains(highlighted) { return path(for: highlighted) }
        let names = rows.compactMap { row -> String? in
            if case .folder(let name) = row { return name }
            return nil
        }
        guard let first = names.first else { return nil }
        if names.count == 1 { return path(for: .folder(first)) }
        let shared = names.dropFirst().reduce(first) { $0.commonPrefix(with: $1, options: .caseInsensitive) }
        return shared.count > fragment.count ? prefix + shared : nil
    }
}
