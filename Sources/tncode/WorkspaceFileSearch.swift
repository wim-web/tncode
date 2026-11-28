import Foundation

struct WorkspaceFileSearch: Equatable, Sendable {
    enum Mode: Hashable, Sendable {
        case files
        case contents
    }

    struct Options: Equatable, Sendable {
        var caseSensitive = false
        var wholeWord = false
        var regex = false
    }

    struct Destination: Hashable, Sendable {
        let target: WorkspaceFileTarget
        let checkout: WorkspaceFileIdentity
        let line: Int?
    }

    struct Match: Sendable {
        let destination: Destination
        let snippet: String?
    }

    struct Results: Sendable {
        var matches: [Match] = []
        var limited = false
        var invalidRegex = false
    }

    static let queryLimit = 256
    private static let pathLimit = 200
    private static let matchLimit = 500
    private static let perFileLimit = 100
    private static let byteBudget = 32 * 1024 * 1024

    let location: WorkspaceFilesLocation
    let mode: Mode
    let query: String
    let options: Options

    func run() async throws -> Results {
        if mode == .contents {
            guard query.utf16.count <= Self.queryLimit,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Results() }
        }
        let files = WorkspaceFiles(directory: location.directory)
        let checkout = try await loadWorkspaceFiles { try files.directoryIdentity() }
        let git = GitWorkspace(path: location.directory)
        let listed = try await git.run(
            ["-c", "core.fsmonitor=false", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "."],
            outputLimit: 2 * 1024 * 1024, acceptedStatuses: [0, 128], cancellable: true, timeout: .seconds(5)
        )
        let listing = Self.paths(in: listed.output)
        let excluded: (paths: Set<String>, limited: Bool)
        if listed.status == 0, listing.paths.contains(where: { $0 == ".ignore" || $0.hasSuffix("/.ignore") }) {
            // `--exclude-per-directory` replaces the standard per-directory rules for this invocation.
            let ignored = try await git.run(
                ["-c", "core.fsmonitor=false", "ls-files", "--cached", "--others", "--ignored",
                 "--exclude-per-directory=.ignore", "-z", "--", "."],
                outputLimit: 2 * 1024 * 1024, cancellable: true, timeout: .seconds(5)
            )
            excluded = Self.paths(in: ignored.output)
        } else {
            excluded = ([], false)
        }
        return try await loadWorkspaceFiles {
            let paths: [String]
            let limited: Bool
            if listed.status == 0 {
                paths = listing.paths.subtracting(excluded.paths)
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                limited = listing.limited || excluded.limited
            } else {
                let tree = try files.tree()
                paths = tree.entries.filter { $0.kind == .file }.map(\.path)
                limited = tree.truncated
            }
            guard try files.directoryIdentity() == checkout else { throw WorkspaceFileError.changed }
            switch mode {
            case .files: return try searchPaths(paths, with: files, checkout: checkout, limited: limited)
            case .contents: return try searchContents(paths, with: files, checkout: checkout, limited: limited)
            }
        }
    }

    private static func paths(in output: WorkspaceCommand.Output) -> (paths: Set<String>, limited: Bool) {
        let bytes = output.bytes
        let complete = bytes.lastIndex(of: 0).map { bytes[..<$0] } ?? Data()
        let fields = complete.split(separator: 0, maxSplits: WorkspaceFiles.entryLimit)
        let paths = Set(fields.prefix(WorkspaceFiles.entryLimit).compactMap { String(bytes: $0, encoding: .utf8) })
        return (paths, output.truncated || fields.count > WorkspaceFiles.entryLimit)
    }

    private func searchPaths(_ paths: [String], with files: WorkspaceFiles,
                             checkout: WorkspaceFileIdentity, limited: Bool) throws -> Results {
        let term = String(query.prefix(Self.queryLimit)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fuzzy = term.drop(while: { "@./".contains($0) }).filter { !$0.isWhitespace }
        var ranked: [(path: String, rank: Int)] = []
        for path in paths {
            try Task.checkCancellation()
            if let rank = pathRank(path, for: term, fuzzy: fuzzy) { ranked.append((path, rank)) }
        }
        var result = Results(limited: limited)
        for entry in ranked.sorted(by: { $0.rank < $1.rank }) {
            try Task.checkCancellation()
            guard (try? files.fileURL(entry.path, checkout: checkout)) != nil else { continue }
            if result.matches.count == Self.pathLimit {
                result.limited = true
                break
            }
            result.matches.append(Match(destination: destination(entry.path, checkout), snippet: nil))
        }
        return result
    }

    private func pathRank(_ path: String, for term: String, fuzzy: String) -> Int? {
        let path = path.lowercased()
        let name = path.split(separator: "/").last ?? ""
        if path == term { return 0 }
        guard !fuzzy.isEmpty else { return 1 }
        if path == fuzzy { return 1 }
        if name == term || name == fuzzy { return 2 }
        if name.hasPrefix(fuzzy) { return 3 }
        if path.contains(fuzzy) { return 4 }
        var remaining = fuzzy[...]
        for character in path where character == remaining.first {
            remaining.removeFirst()
            if remaining.isEmpty { return 5 }
        }
        return nil
    }

    private func searchContents(_ paths: [String], with files: WorkspaceFiles,
                                checkout: WorkspaceFileIdentity, limited: Bool) throws -> Results {
        let flags: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
        let literal = NSRegularExpression.escapedPattern(for: query)
        let regex = options.regex ? try? NSRegularExpression(pattern: query, options: flags) : nil
        let pattern = try regex ?? NSRegularExpression(pattern: literal, options: flags)
        var result = Results(limited: limited, invalidRegex: options.regex && regex == nil)
        var budget = Self.byteBudget
        let deadline = ContinuousClock.now + .seconds(2)

        for path in paths {
            try Task.checkCancellation()
            guard budget > 0, ContinuousClock.now < deadline else {
                result.limited = true
                break
            }
            guard let source = try? files.searchText(path, checkout: checkout, budget: &budget) else { continue }
            if case .tooLarge = source { result.limited = true }
            guard case .text(let text) = source, !text.isEmpty else { continue }
            let lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
                .dropLast(text.utf8.last == 10 ? 1 : 0)
            var inFile = 0
            for (offset, bytes) in lines.enumerated() {
                try Task.checkCancellation()
                let line = String(decoding: bytes.last == 13 ? bytes.dropLast() : bytes[...], as: UTF8.self)
                let matched = matches(line, pattern: pattern, deadline: deadline)
                guard ContinuousClock.now < deadline else {
                    result.limited = true
                    return result
                }
                guard matched else { continue }
                if result.matches.count == Self.matchLimit {
                    result.limited = true
                    return result
                }
                let hit = destination(path, checkout, line: offset + 1)
                result.matches.append(Match(destination: hit, snippet: String(line.prefix(512))))
                inFile += 1
                if inFile == Self.perFileLimit { break }
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func matches(_ line: String, pattern: NSRegularExpression, deadline: ContinuousClock.Instant) -> Bool {
        let text = line as NSString
        var found = false
        pattern.enumerateMatches(in: line, options: .reportProgress, range: NSRange(location: 0, length: text.length)) {
            match, _, stop in
            if Task.isCancelled || ContinuousClock.now >= deadline {
                stop.pointee = true
            } else if let match, !options.wholeWord || Self.isWholeWord(match.range, in: text) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static func isWholeWord(_ range: NSRange, in line: NSString) -> Bool {
        guard range.length > 0 else { return false }
        func isWord(_ offset: Int) -> Bool {
            guard offset >= 0, offset < line.length else { return false }
            var units = [line.character(at: offset)]
            if (0xD800...0xDBFF).contains(units[0]), offset + 1 < line.length {
                units.append(line.character(at: offset + 1))
            } else if (0xDC00...0xDFFF).contains(units[0]), offset > 0 {
                units.insert(line.character(at: offset - 1), at: 0)
            }
            return String(decoding: units, as: UTF16.self).unicodeScalars.first.map {
                $0 == "_" || CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
            } ?? false
        }
        let end = NSMaxRange(range)
        return !(isWord(range.location - 1) && isWord(range.location)) && !(isWord(end - 1) && isWord(end))
    }

    private func destination(_ path: String, _ checkout: WorkspaceFileIdentity, line: Int? = nil) -> Destination {
        Destination(target: WorkspaceFileTarget(location: location, path: path), checkout: checkout, line: line)
    }
}
