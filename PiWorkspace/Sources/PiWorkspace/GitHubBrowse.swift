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

enum GitHubPullRequestFilterKind: String, Hashable, Sendable {
    case author, label
}

struct GitHubPullRequestFilters: Hashable, Sendable {
    let repository: GitHubRepository
    var author: String?
    var labels: [String] = []

    var isEmpty: Bool { author == nil && labels.isEmpty }

    fileprivate var qualifiers: [String] {
        let author = author.map { ["author:\(Self.quoted($0))"] } ?? []
        return author + labels.map { "label:\(Self.quoted($0))" }
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

struct GitHubListQuery: Hashable, Sendable {
    let kind: GitHubBrowseKind
    let filter: GitHubStateFilter
    let text: String
    let pullRequestFilters: GitHubPullRequestFilters?

    init(_ kind: GitHubBrowseKind, _ filter: GitHubStateFilter = .open, text: String = "",
         pullRequestFilters: GitHubPullRequestFilters? = nil) {
        self.kind = kind
        self.filter = filter
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pullRequestFilters = kind == .pullRequests && pullRequestFilters?.isEmpty == false ? pullRequestFilters : nil
    }

    var isSearching: Bool { !text.isEmpty || pullRequestFilters != nil }

    fileprivate func search(in repository: GitHubRepository) throws -> String {
        let terms = try scopedSearchTerms()
        let type = kind == .pullRequests ? "is:pr" : "is:issue"
        let state = switch filter {
        case .all: ""
        case .closed where kind == .pullRequests: "is:closed is:unmerged"
        default: "is:\(filter.rawValue)"
        }
        let qualifiers = pullRequestFilters?.qualifiers ?? []
        return (["repo:\(repository.slug)", type, state, "sort:created-desc"] + terms + qualifiers)
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
    let author: GitHubAuthor?
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

struct GitHubIssueReference: Codable, Hashable, Sendable {
    let repository: GitHubRepository
    let number: Int
    let url: URL

    init?(repository: GitHubRepository, number: Int) {
        guard number > 0, let url = URL(string: "https://\(repository.cliName)/issues/\(number)") else { return nil }
        self.repository = repository
        self.number = number
        self.url = url
    }

    init?(url: String) {
        guard let path = GitHubRepository.webPath(in: url)?.wholeMatch(of: #/\/([^\/]+)\/([^\/]+)\/issues\/([0-9]+)\/?/#),
              let repository = GitHubRepository(owner: path.1, name: path.2),
              let number = Int(path.3) else { return nil }
        self.init(repository: repository, number: number)
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let reference = Self(url: try value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid GitHub issue URL")
        }
        self = reference
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(url.absoluteString)
    }
}

struct GitHubIssueDetails: Sendable {
    let reference: GitHubIssueReference
    let title: String
    let state: String
    let author: GitHubAuthor?
    let labels: [GitHubLabel]
    let body: String

    var number: Int { reference.number }
    var url: URL { reference.url }
}

struct GitHubPullRequestFilterOptions: Sendable {
    let values: [String]
    let hasMore: Bool

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    fileprivate static func isValid(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

extension GitHubReader {
    func list(_ query: GitHubListQuery, after next: GitHubListPage.Next? = nil) async throws -> GitHubListPage {
        let kind = query.kind
        guard kind.filters.contains(query.filter), next == nil || next?.query == query else {
            throw ReadError.invalidResponse(kind)
        }
        let repository = try await repository(matching: next?.repository ?? query.pullRequestFilters?.repository)
        let node = kind == .pullRequests ? "PullRequest" : "Issue"
        let fields = """
            pageInfo { hasNextPage endCursor }
            nodes {
                ... on \(node) {
                    number title state \(kind == .pullRequests ? "isDraft author { login }" : "")
                    repository { nameWithOwner }
                    labels(first: 10) { nodes { name } }
                }
            }
            """
        let document: String
        let variables: [String]
        if !query.isSearching {
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
        _ = try await self.repository(matching: repository)
        return GitHubListPage(repository: repository, items: items, next: continuation)
    }

    func pullRequestFilterOptions(
        _ kind: GitHubPullRequestFilterKind, matching text: String, in expectedRepository: GitHubRepository
    ) async throws -> GitHubPullRequestFilterOptions {
        let repository = try await repository(matching: expectedRepository)
        let parts = repository.slug.split(separator: "/", maxSplits: 1)
        let connection = switch kind {
        case .author: "mentionableUsers(first: 50, query: $text) { pageInfo { hasNextPage } nodes { value: login } }"
        case .label: "labels(first: 100, query: $text, orderBy: {field: NAME, direction: ASC}) { pageInfo { hasNextPage } nodes { value: name } }"
        }
        let document = """
            query($owner: String!, $name: String!, $text: String) {
                repository(owner: $owner, name: $name) {
                    nameWithOwner
                    options: \(connection)
                }
            }
            """
        let filter = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let variables = filter.isEmpty ? [] : ["--raw-field", "text=\(filter.replacingOccurrences(of: "\0", with: ""))"]
        let response: FilterOptionsResponse = try await read(
            ["api", "graphql", "--hostname", "github.com", "--raw-field", "query=\(document)",
             "--raw-field", "owner=\(parts[0])", "--raw-field", "name=\(parts[1])"] + variables,
            for: .pullRequests
        )
        guard let result = response.data.repository,
              result.nameWithOwner.caseInsensitiveCompare(repository.slug) == .orderedSame else {
            throw ReadError.invalidResponse(.pullRequests)
        }
        _ = try await self.repository(matching: repository)
        let values = result.options.nodes.compactMap { $0?.value }.filter(GitHubPullRequestFilterOptions.isValid)
        return .init(values: GitHubPullRequestFilterOptions.unique(values), hasMore: result.options.pageInfo.hasNextPage)
    }

    func issueDetails(for number: Int, in expectedRepository: GitHubRepository) async throws -> GitHubIssueDetails {
        guard let reference = GitHubIssueReference(repository: expectedRepository, number: number) else {
            throw ReadError.invalidResponse(.issues)
        }
        _ = try await repository(matching: expectedRepository)
        let details = try await linkedIssueDetails(for: reference)
        _ = try await repository(matching: expectedRepository)
        return details
    }

    func linkedIssueDetails(for reference: GitHubIssueReference) async throws -> GitHubIssueDetails {
        // A saved link keeps its repository when the draft moves to another checkout.
        let response: IssueResponse = try await read(
            ["issue", "view", String(reference.number), "--json", "number,title,state,author,labels,body,url",
             "--repo", reference.repository.cliName],
            for: .issues
        )
        guard response.number == reference.number, ["OPEN", "CLOSED"].contains(response.state),
              GitHubIssueReference(url: response.url) == reference else {
            throw ReadError.invalidResponse(.issues)
        }
        return GitHubIssueDetails(reference: reference, title: response.title, state: response.state, author: response.author,
                                  labels: response.labels ?? [], body: response.body ?? "")
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

    private struct FilterOptionsResponse: Decodable {
        struct Data: Decodable {
            struct Repository: Decodable {
                struct Options: Decodable {
                    struct Node: Decodable { let value: String }
                    struct PageInfo: Decodable { let hasNextPage: Bool }

                    let nodes: [Node?]
                    let pageInfo: PageInfo
                }

                let nameWithOwner: String
                let options: Options
            }

            let repository: Repository?
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
        let url: String
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
    @Published private(set) var repository: GitHubRepository?
    @Published private(set) var loadedFilterValues: [GitHubPullRequestFilterKind: Set<String>] = [:]
    @Published var searchText = ""

    init(kind: GitHubBrowseKind, reader: GitHubReader) {
        self.kind = kind
        self.reader = reader
        query = GitHubListQuery(kind)
        refresh()
    }

    func applySearch(filter: GitHubStateFilter) {
        apply(.init(kind, filter, text: searchText, pullRequestFilters: query.pullRequestFilters))
    }

    func setAuthor(_ author: String?, in repository: GitHubRepository) {
        guard kind == .pullRequests, repository == self.repository,
              author.map(GitHubPullRequestFilterOptions.isValid) ?? true else { return }
        var filters = query.pullRequestFilters ?? GitHubPullRequestFilters(repository: repository)
        filters.author = author
        apply(.init(kind, query.filter, text: query.text, pullRequestFilters: filters))
    }

    func toggleLabel(_ label: String, in repository: GitHubRepository) {
        guard kind == .pullRequests, repository == self.repository,
              GitHubPullRequestFilterOptions.isValid(label) else { return }
        var filters = query.pullRequestFilters ?? GitHubPullRequestFilters(repository: repository)
        if let index = filters.labels.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
            filters.labels.remove(at: index)
        } else {
            filters.labels.append(label)
        }
        apply(.init(kind, query.filter, text: query.text, pullRequestFilters: filters))
    }

    func clearLabels(in repository: GitHubRepository) {
        guard repository == self.repository, var filters = query.pullRequestFilters else { return }
        filters.labels = []
        apply(.init(kind, query.filter, text: query.text, pullRequestFilters: filters))
    }

    func filterOptions(
        _ kind: GitHubPullRequestFilterKind, matching text: String, in repository: GitHubRepository
    ) async throws -> GitHubPullRequestFilterOptions {
        try await reader.pullRequestFilterOptions(kind, matching: text, in: repository)
    }

    private func apply(_ updated: GitHubListQuery) {
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
            if repository != page.repository {
                repository = page.repository
                loadedFilterValues = [:]
            }
            if kind == .pullRequests {
                loadedFilterValues[.author, default: []].formUnion(
                    page.items.compactMap { $0.author?.login }.filter(GitHubPullRequestFilterOptions.isValid)
                )
                loadedFilterValues[.label, default: []].formUnion(
                    page.items.flatMap(\.labelNames).filter(GitHubPullRequestFilterOptions.isValid)
                )
            }
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
            if case GitHubReader.ReadError.repositoryChanged = error,
               work.next == nil, work.query.pullRequestFilters != nil {
                repository = nil
                loadedFilterValues = [:]
                apply(.init(kind, query.filter, text: query.text))
                return
            }
            if work.next != nil, case .loaded(let page, _) = listing {
                listing = .loaded(page, .failed(error.localizedDescription))
            } else {
                listing = .failed(error.localizedDescription)
            }
        }
        request = nil
    }
}
