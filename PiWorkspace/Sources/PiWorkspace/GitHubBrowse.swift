import Combine
import Foundation

enum GitHubBrowseKind: String, Hashable, Sendable {
    case pullRequests, issues

    var itemName: String { self == .pullRequests ? "pull request" : "issue" }
    var idPrefix: String { self == .pullRequests ? "pr" : "issue" }
    var filters: [GitHubStateFilter] { self == .pullRequests ? [.open, .merged, .closed, .all] : [.open, .closed, .all] }
}

enum GitHubStateFilter: String, Hashable, Identifiable, Sendable {
    case open, merged, closed, all

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct GitHubListQuery: Hashable, Sendable {
    let kind: GitHubBrowseKind
    let filter: GitHubStateFilter
    let text: String

    init(_ kind: GitHubBrowseKind, _ filter: GitHubStateFilter = .open, text: String = "") {
        self.kind = kind
        self.filter = filter
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate func search(in repository: GitHubRepository) throws -> String {
        let terms = try scopedSearchTerms()
        let type = kind == .pullRequests ? "is:pr" : "is:issue"
        let state = switch filter {
        case .all: ""
        case .closed where kind == .pullRequests: "is:closed is:unmerged"
        default: "is:\(filter.rawValue)"
        }
        return (["repo:\(repository.slug)", type, state, "sort:created-desc"] + terms)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func scopedSearchTerms() throws -> [String] {
        // Quote plain terms so that a query cannot replace the repository, type or state filters.
        let tokens = text.matches(of: #/(?:^|\s)(-?label:)?(?:"([^"\\\r\n]+)"|([^\s"\\]+))(?=\s|$)/#)
        var terms: [String] = []
        var end = text.startIndex
        for token in tokens {
            let (_, qualifier, phrase, word) = token.output
            guard text[end..<token.range.lowerBound].allSatisfy(\.isWhitespace),
                  let value = phrase ?? word, !value.contains("\0"),
                  value != "label:", value != "-label:" else {
                throw GitHubReader.ReadError.invalidSearch
            }
            terms.append("\(qualifier ?? "")\"\(value)\"")
            end = token.range.upperBound
        }
        guard text[end...].allSatisfy(\.isWhitespace) else { throw GitHubReader.ReadError.invalidSearch }
        return terms
    }
}

struct GitHubLabel: Decodable, Sendable {
    let name: String
}

struct GitHubListItem: Decodable, Identifiable, Sendable {
    fileprivate struct Repository: Decodable, Sendable {
        let nameWithOwner: String
    }

    fileprivate struct Labels: Decodable, Sendable {
        let nodes: [GitHubLabel]
    }

    let number: Int
    let title: String
    let state: String
    let isDraft: Bool?
    fileprivate let repository: Repository
    fileprivate let labels: Labels?

    var id: Int { number }
    var stateLabel: String { isDraft == true && state == "OPEN" ? "Draft" : state.capitalized }
    var labelNames: [String] { labels?.nodes.map(\.name) ?? [] }
}

struct GitHubListPage: Sendable {
    struct Next: Hashable, Sendable {
        fileprivate let repository: GitHubRepository
        fileprivate let query: GitHubListQuery
        fileprivate let cursor: String
    }

    let repository: GitHubRepository
    let items: [GitHubListItem]
    let next: Next?
}

struct GitHubIssueDetails: Sendable {
    let number: Int
    let title: String
    let state: String
    let author: GitHubAuthor?
    let labels: [GitHubLabel]
    let body: String
    let url: URL
}

extension GitHubReader {
    func list(_ query: GitHubListQuery, after next: GitHubListPage.Next? = nil) async throws -> GitHubListPage {
        let kind = query.kind
        guard kind.filters.contains(query.filter), next == nil || next?.query == query else {
            throw ReadError.invalidResponse(kind)
        }
        let repository = try await repository(matching: next?.repository)
        let node = kind == .pullRequests ? "PullRequest" : "Issue"
        let fields = """
            pageInfo { hasNextPage endCursor }
            nodes {
                ... on \(node) {
                    number title state \(kind == .pullRequests ? "isDraft" : "")
                    repository { nameWithOwner }
                    labels(first: 10) { nodes { name } }
                }
            }
            """
        let document: String
        let variables: [String]
        if query.text.isEmpty {
            let parts = repository.slug.split(separator: "/", maxSplits: 1)
            let states = query.filter == .all ? "" : "states: [\(query.filter.rawValue.uppercased())], "
            document = """
                query($owner: String!, $name: String!, $after: String) {
                    repository(owner: $owner, name: $name) {
                        items: \(kind.rawValue)(first: 50, after: $after, \(states)orderBy: {field: CREATED_AT, direction: DESC}) {
                            \(fields)
                        }
                    }
                }
                """
            variables = ["--raw-field", "owner=\(parts[0])", "--raw-field", "name=\(parts[1])"]
        } else {
            document = """
                query($search: String!, $after: String) {
                    items: search(query: $search, type: ISSUE, first: 50, after: $after) {
                        \(fields)
                    }
                }
                """
            variables = ["--raw-field", "search=\(try query.search(in: repository))"]
        }
        let cursor = next.map { ["--raw-field", "after=\($0.cursor)"] } ?? []
        let response: GraphQLResponse = try await read(
            ["api", "graphql", "--hostname", "github.com", "--raw-field", "query=\(document)"] + variables + cursor,
            for: kind
        )
        guard let page = response.data.repository?.items ?? response.data.items else { throw ReadError.invalidResponse(kind) }
        let items = page.nodes.compactMap { $0 }
        let filters = query.filter == .all ? kind.filters.filter { $0 != .all } : [query.filter]
        let states = Set(filters.map { $0.rawValue.uppercased() })
        guard Set(items.map(\.number)).count == items.count, items.allSatisfy({ item in
            item.number > 0 && states.contains(item.state)
                && item.repository.nameWithOwner.caseInsensitiveCompare(repository.slug) == .orderedSame
                && (item.isDraft != nil) == (kind == .pullRequests)
        }) else {
            throw ReadError.invalidResponse(kind)
        }
        let continuation: GitHubListPage.Next?
        if page.pageInfo.hasNextPage {
            guard let cursor = page.pageInfo.endCursor, !cursor.isEmpty, !cursor.contains("\0"), cursor != next?.cursor else {
                throw ReadError.invalidResponse(kind)
            }
            continuation = .init(repository: repository, query: query, cursor: cursor)
        } else {
            continuation = nil
        }
        return GitHubListPage(repository: repository, items: items, next: continuation)
    }

    func issueDetails(for number: Int, in expectedRepository: GitHubRepository) async throws -> GitHubIssueDetails {
        guard number > 0 else { throw ReadError.invalidResponse(.issues) }
        let repository = try await repository(matching: expectedRepository)
        let response: IssueResponse = try await read(
            ["issue", "view", String(number), "--json", "number,title,state,author,labels,body", "--repo", repository.cliName],
            for: .issues
        )
        guard response.number == number, ["OPEN", "CLOSED"].contains(response.state),
              let url = URL(string: "https://\(repository.cliName)/issues/\(number)") else {
            throw ReadError.invalidResponse(.issues)
        }
        return GitHubIssueDetails(number: number, title: response.title, state: response.state, author: response.author,
                                  labels: response.labels ?? [], body: response.body ?? "", url: url)
    }

    private struct GraphQLResponse: Decodable {
        struct Data: Decodable {
            struct Repository: Decodable {
                let items: Connection
            }

            let repository: Repository?
            let items: Connection?
        }

        struct Connection: Decodable {
            struct PageInfo: Decodable {
                let hasNextPage: Bool
                let endCursor: String?
            }

            let pageInfo: PageInfo
            let nodes: [GitHubListItem?]
        }

        let data: Data
    }

    private struct IssueResponse: Decodable {
        let number: Int
        let title: String
        let state: String
        let author: GitHubAuthor?
        let labels: [GitHubLabel]?
        let body: String?
    }
}

@MainActor
final class GitHubBrowserModel: ObservableObject {
    struct Selection: Hashable {
        let id = UUID()
        let repository: GitHubRepository
        let number: Int
    }

    enum Listing {
        case loading
        case loaded(GitHubListPage, Paging)
        case failed(String)
    }

    enum Paging {
        case idle
        case loading
        case failed(String)
    }

    struct Request: Hashable {
        let id = UUID()
        let query: GitHubListQuery
        let next: GitHubListPage.Next?
    }

    let kind: GitHubBrowseKind
    private let reader: GitHubReader
    @Published private(set) var query: GitHubListQuery
    @Published private(set) var request: Request?
    @Published private(set) var listing = Listing.loading
    @Published private(set) var selection: Selection?
    @Published var searchText = ""

    init(kind: GitHubBrowseKind, reader: GitHubReader) {
        self.kind = kind
        self.reader = reader
        query = GitHubListQuery(kind)
        refresh()
    }

    func applySearch(filter: GitHubStateFilter) {
        let updated = GitHubListQuery(kind, filter, text: searchText)
        guard query != updated else { return }
        query = updated
        selection = nil
        refresh()
    }

    func refresh() {
        listing = .loading
        request = Request(query: query, next: nil)
    }

    func select(_ item: GitHubListItem, in repository: GitHubRepository) {
        selection = Selection(repository: repository, number: item.number)
    }

    func loadMore() {
        guard request == nil, case .loaded(let page, _) = listing, let next = page.next else { return }
        listing = .loaded(page, .loading)
        request = Request(query: query, next: next)
    }

    func load(_ work: Request?) async {
        guard let work, work == request, !Task.isCancelled else { return }
        do {
            let page = try await reader.list(work.query, after: work.next)
            guard work == request, !Task.isCancelled else { return }
            if work.next != nil, case .loaded(let current, _) = listing {
                let existing = Set(current.items.map(\.number))
                let items = current.items + page.items.filter { !existing.contains($0.number) }
                listing = .loaded(.init(repository: page.repository, items: items, next: page.next), .idle)
            } else {
                if let selection {
                    self.selection = selection.repository == page.repository
                        && page.items.contains(where: { $0.number == selection.number })
                        ? Selection(repository: page.repository, number: selection.number)
                        : nil
                }
                listing = .loaded(page, .idle)
            }
        } catch {
            guard work == request, !Task.isCancelled else { return }
            if work.next != nil, case .loaded(let page, _) = listing {
                listing = .loaded(page, .failed(error.localizedDescription))
            } else {
                listing = .failed(error.localizedDescription)
            }
        }
        request = nil
    }
}
