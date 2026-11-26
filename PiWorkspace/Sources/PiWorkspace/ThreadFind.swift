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
        case matches([TranscriptOccurrence], index: Int)

        var label: String? {
            switch self {
            case .empty: nil
            case .searching: "Searching…"
            case .failed: "Search failed"
            case .matches(let matches, let index):
                matches.isEmpty ? "0 matches" : "\(index + 1) of \(matches.count)"
            }
        }
    }

    struct Selection: Equatable {
        let id = UUID()
        let occurrence: TranscriptOccurrence
        var messageID: String { occurrence.messageID }
    }

    let thread: SidebarMessageSearch.Thread
    private(set) var query = ""
    private(set) var request: Request?
    private(set) var status: Status = .empty
    private(set) var selection: Selection?
    private(set) var focusRequest = UUID()
    private var preferredOccurrence: TranscriptOccurrence?

    init(thread: SidebarMessageSearch.Thread, term: TranscriptSearchTerm? = nil, occurrence: TranscriptOccurrence? = nil) {
        self.thread = thread
        if let term { search(term, startingAt: occurrence) }
    }

    var canStep: Bool {
        if case .matches(let matches, _) = status { return !matches.isEmpty }
        return false
    }

    mutating func refocus() {
        focusRequest = UUID()
    }

    mutating func editQuery(_ text: String) {
        guard !text.utf8.elementsEqual(query.utf8) else { return }
        search(.literal(text))
    }

    mutating func refresh() {
        guard let request else { return }
        preferredOccurrence = selection?.occurrence ?? preferredOccurrence
        self.request = Request(thread: thread, term: request.term)
        if status == .failed { status = .searching }
    }

    mutating func receive(_ matches: [TranscriptOccurrence], for request: Request) {
        guard request == self.request else { return }
        let index = preferredOccurrence.flatMap { matches.firstIndex(of: $0) } ?? 0
        status = .matches(matches, index: index)
        if matches.indices.contains(index) {
            let match = matches[index]
            if selection?.occurrence != match { selection = Selection(occurrence: match) }
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
        guard case .matches(let matches, let index) = status, !matches.isEmpty else { return }
        let next = (index + (backward ? matches.count - 1 : 1)) % matches.count
        preferredOccurrence = matches[next]
        selection = Selection(occurrence: matches[next])
        status = .matches(matches, index: next)
    }

    private mutating func search(_ term: TranscriptSearchTerm, startingAt occurrence: TranscriptOccurrence? = nil) {
        query = term.text
        preferredOccurrence = occurrence
        selection = occurrence.map { Selection(occurrence: $0) }
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
