import Darwin
import Foundation

struct SidebarMessageSearch: Equatable, Sendable {
    struct Thread: Hashable, Sendable {
        let projectID: UUID
        let threadID: UUID
    }

    struct Match: Sendable {
        let occurrence: TranscriptOccurrence
        var messageID: String { occurrence.messageID }
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
        return try await Self.readOffMain { try scan(root) }
    }

    static func occurrences(in root: URL, thread: Thread, term: TranscriptSearchTerm) async throws -> [TranscriptOccurrence] {
        try await readOffMain {
            let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard rootFD >= 0 else { throw WorkspaceHistory.accessError(errno) }
            defer { close(rootFD) }
            guard let file = try WorkspaceHistory.open(in: rootFD, projectID: thread.projectID,
                                                       threadID: thread.threadID) else { return [] }
            defer { try? file.close() }
            var matches: [TranscriptOccurrence] = []
            let valid = try visitBranch(in: file, threadID: thread.threadID) { id, message in
                for range in term.ranges(in: message.visibleText).reversed() {
                    matches.append(TranscriptOccurrence(messageID: id, range: range))
                }
            }
            guard valid else { throw WorkspaceError("The thread history is incomplete.") }
            return Array(matches.reversed())
        }
    }

    private static func readOffMain<T: Sendable>(_ read: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated, operation: read)
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
        var match: Match?
        let valid = try Self.visitBranch(in: file, threadID: threadID) { id, message in
            guard match == nil else { return }
            let text = message.visibleText
            guard let hit = term.ranges(in: text, firstOnly: true).first,
                  let range = Range((text as NSString).rangeOfComposedCharacterSequences(for: hit), in: text)
            else { return }
            let start = text.index(range.lowerBound, offsetBy: -24, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 48, limitedBy: text.endIndex) ?? text.endIndex
            let excerpt = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            match = Match(occurrence: TranscriptOccurrence(messageID: id, range: hit), excerpt: (start == text.startIndex ? "" : "…") +
                          excerpt + (end == text.endIndex ? "" : "…"))
        }
        return valid ? match : nil
    }

    private static func visitBranch(in file: FileHandle, threadID: UUID,
                                    visit: (String, Message) -> Void) throws -> Bool {
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

        guard hasHeader else { return false }

        // Pi reopens at the last entry and renders the path through parentId.
        var visited = Set<String>()
        while let id = leaf, let entry = entries[id] {
            try Task.checkCancellation()
            guard visited.insert(id).inserted else { return false }
            if let message = entry.message { visit(id, message) }
            leaf = entry.parentID
        }
        return leaf == nil
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
        let role: ChatMessage.Role

        var visibleText: String { String(TranscriptText.rendered(text, role: role).characters) }

        private enum Field: String, CodingKey { case role, content, workspaceInput }
        private struct WorkspaceInput: Decodable { let text: String }
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
            role = try fields.decode(ChatMessage.Role.self, forKey: .role)
            if let input = try? fields.decode(WorkspaceInput.self, forKey: .workspaceInput) {
                text = input.text
            } else if let plain = try? fields.decode(String.self, forKey: .content) {
                text = plain
            } else {
                text = try fields.decode([Block].self, forKey: .content).compactMap(\.text).joined()
            }
        }
    }
}
