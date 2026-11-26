import Darwin
import Foundation

enum TranscriptSearchTerm: Hashable, Sendable {
    case literal(String)
    case words([String])
    case phrase([String])

    var text: String {
        switch self {
        case .literal(let text): text
        case .words(let words), .phrase(let words): words.joined(separator: " ")
        }
    }

    static func quotedPhrase(in query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    init?(paletteQuery query: String) {
        let phrase = Self.quotedPhrase(in: query)
        let words = (phrase ?? query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.contains(where: { word in
            word.count >= 3 || (word.count == 2 && word.range(
                of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression
            ) != nil)
        }) else { return nil }
        self = phrase == nil ? .words(words) : .phrase(words)
    }

    func range(in message: String) -> Range<String.Index>? {
        switch self {
        case .literal(let text):
            return message.range(of: text, options: .caseInsensitive, locale: .current)
        case .phrase(let words):
            let pattern = words.map(NSRegularExpression.escapedPattern).joined(separator: #"\s{1,16}"#)
            return message.range(of: pattern, options: [.regularExpression, .caseInsensitive])
        case .words(let words):
            if let phrase = message.range(of: text, options: .caseInsensitive, locale: .current) { return phrase }
            var anchor: Range<String.Index>?
            var longest = 0
            for word in words {
                guard let range = message.range(of: word, options: .caseInsensitive, locale: .current) else { return nil }
                if word.count > longest {
                    anchor = range
                    longest = word.count
                }
            }
            return anchor
        }
    }
}

struct SidebarMessageSearch: Equatable, Sendable {
    struct Thread: Equatable, Sendable {
        let projectID: UUID
        let threadID: UUID
    }

    struct Match: Sendable {
        let messageID: String
        let excerpt: String
    }

    let term: TranscriptSearchTerm
    let threads: [Thread]

    init(query: String, threads: [Thread]) {
        self.init(term: .literal(query), threads: threads)
    }

    init(term: TranscriptSearchTerm, threads: [Thread]) {
        self.term = term
        self.threads = threads
    }

    func matches(in root: URL) async throws -> [UUID: Match] {
        try Task.checkCancellation()
        guard !term.text.isEmpty, !threads.isEmpty else { return [:] }
        let worker = Task.detached(priority: .userInitiated) { try scan(root) }
        return try await withTaskCancellationHandler {
            let matches = try await worker.value
            try Task.checkCancellation()
            return matches
        } onCancel: {
            worker.cancel()
        }
    }

    private func scan(_ root: URL) throws -> [UUID: Match] {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return [:] }
        defer { close(rootFD) }
        var matches: [UUID: Match] = [:]
        for thread in threads {
            try Task.checkCancellation()
            guard let file = try? WorkspaceHistory.open(in: rootFD, projectID: thread.projectID,
                                                        threadID: thread.threadID) else { continue }
            defer { try? file.close() }
            do {
                matches[thread.threadID] = try match(in: file, threadID: thread.threadID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return matches
    }

    private func match(in file: FileHandle, threadID: UUID) throws -> Match? {
        let decoder = JSONDecoder()
        var hasHeader = false
        var leaf: String?
        var entries: [String: Entry] = [:]
        try WorkspaceHistory.readLines(in: file) { line in
            guard let entry = try? decoder.decode(Entry.self, from: line) else { return }
            if entry.type == "session" {
                guard !hasHeader else { return }
                // V1 has no stable message IDs. Pi assigns IDs when it migrates the file.
                guard entry.id == threadID.uuidString, let version = entry.version, version >= 2 else {
                    throw WorkspaceError("Unsupported search history.")
                }
                hasHeader = true
            } else {
                leaf = entry.id
                if let id = entry.id { entries[id] = entry }
            }
        }

        guard hasHeader else { return nil }

        // Pi reopens at the last entry and renders the path through parentId.
        var visited = Set<String>()
        var match: Match?
        while let id = leaf, let entry = entries[id] {
            try Task.checkCancellation()
            guard visited.insert(id).inserted else { return nil }
            if match == nil, let text = entry.message?.text, let range = term.range(in: text) {
                let start = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(range.upperBound, offsetBy: 48, limitedBy: text.endIndex) ?? text.endIndex
                let excerpt = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
                match = Match(messageID: id, excerpt: (start == text.startIndex ? "" : "…") +
                              excerpt + (end == text.endIndex ? "" : "…"))
            }
            leaf = entry.parentID
        }
        return match
    }

    private struct Entry: Decodable {
        let type: String?
        let id: String?
        let version: Int?
        let parentID: String?
        let message: Message?

        private enum Field: String, CodingKey { case type, id, version, parentId, message }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            type = try? fields.decode(String.self, forKey: .type)
            id = try? fields.decode(String.self, forKey: .id)
            version = type == "session" ? try? fields.decode(Int.self, forKey: .version) : nil
            parentID = try? fields.decode(String.self, forKey: .parentId)
            message = type == "message" ? try? fields.decode(Message.self, forKey: .message) : nil
        }
    }

    private struct Message: Decodable {
        let text: String

        private enum Field: String, CodingKey { case role, content }
        private struct Block: Decodable {
            let text: String?

            private enum Field: String, CodingKey { case type, text }

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: Field.self)
                text = try fields.decode(String.self, forKey: .type) == "text"
                    ? try fields.decodeIfPresent(String.self, forKey: .text) : nil
            }
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            _ = try fields.decode(ChatMessage.Role.self, forKey: .role)
            if let plain = try? fields.decode(String.self, forKey: .content) {
                text = plain
            } else {
                text = try fields.decode([Block].self, forKey: .content).compactMap(\.text).joined()
            }
        }
    }
}
