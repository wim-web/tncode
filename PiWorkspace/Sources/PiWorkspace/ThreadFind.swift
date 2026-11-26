import Foundation

struct ThreadFindSession {
    struct Request: Equatable {
        let id = UUID()
        let thread: SidebarMessageSearch.Thread
        let term: TranscriptSearchTerm
    }

    enum Status: Equatable {
        case empty
        case searching
        case failed
        case matches([String], index: Int)

        var label: String? {
            switch self {
            case .empty: nil
            case .searching: "Searching…"
            case .failed: "Search failed"
            case .matches(let ids, let index):
                ids.isEmpty ? "0 matches" : "\(index + 1) of \(ids.count)"
            }
        }
    }

    struct Selection: Equatable {
        let id = UUID()
        let messageID: String
    }

    let thread: SidebarMessageSearch.Thread
    private(set) var query = ""
    private(set) var request: Request?
    private(set) var status: Status = .empty
    private(set) var selection: Selection?
    private(set) var focusRequest = UUID()
    private var preferredMessageID: String?

    init(thread: SidebarMessageSearch.Thread, term: TranscriptSearchTerm? = nil, messageID: String? = nil) {
        self.thread = thread
        if let term { search(term, startingAt: messageID) }
    }

    var canStep: Bool {
        if case .matches(let ids, _) = status { return !ids.isEmpty }
        return false
    }

    mutating func refocus() {
        focusRequest = UUID()
    }

    mutating func editQuery(_ text: String) {
        guard text != query else { return }
        search(.literal(text))
    }

    mutating func refresh() {
        guard let request else { return }
        preferredMessageID = selection?.messageID ?? preferredMessageID
        self.request = Request(thread: thread, term: request.term)
        if status == .failed { status = .searching }
    }

    mutating func receive(_ ids: [String], for request: Request) {
        guard request == self.request else { return }
        let index = preferredMessageID.flatMap { ids.firstIndex(of: $0) } ?? 0
        status = .matches(ids, index: index)
        if ids.indices.contains(index) {
            let id = ids[index]
            if selection?.messageID != id { selection = Selection(messageID: id) }
        } else {
            selection = nil
        }
    }

    mutating func fail(_ request: Request) {
        guard request == self.request else { return }
        status = .failed
        selection = nil
    }

    mutating func step(backward: Bool) {
        guard case .matches(let ids, let index) = status, !ids.isEmpty else { return }
        let next = (index + (backward ? ids.count - 1 : 1)) % ids.count
        preferredMessageID = ids[next]
        selection = Selection(messageID: ids[next])
        status = .matches(ids, index: next)
    }

    private mutating func search(_ term: TranscriptSearchTerm, startingAt messageID: String? = nil) {
        query = term.text
        preferredMessageID = messageID
        selection = messageID.map { Selection(messageID: $0) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            request = nil
            status = .empty
            return
        }
        let normalized: TranscriptSearchTerm
        if case .literal = term { normalized = .literal(trimmed) } else { normalized = term }
        request = Request(thread: thread, term: normalized)
        status = .searching
    }
}
