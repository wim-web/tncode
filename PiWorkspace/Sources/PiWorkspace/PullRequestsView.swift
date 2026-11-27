import SwiftUI

struct PullRequestsButton: View {
    let workspace: WorkspaceModel
    let scope: ThreadGitHubScope
    let pasteboard: NSPasteboard
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "arrow.triangle.branch")
        }
        .buttonStyle(.plain)
        .help("Pull Requests and Issues")
        .accessibilityLabel("Pull Requests and Issues")
        .accessibilityIdentifier("pull-requests")
        .sheet(isPresented: $presented) {
            GitHubBrowserView(workspace: workspace, scope: scope, pasteboard: pasteboard)
        }
    }
}

private enum GitHubDetailLoad<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

struct GitHubBrowserView: View {
    private enum Tab: Hashable {
        case pullRequests, issues, linkedItems
    }

    @ObservedObject var workspace: WorkspaceModel
    let scope: ThreadGitHubScope
    let pasteboard: NSPasteboard
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab
    @State private var linking: ThreadGitHubLinkRequest?
    @State private var issueLinkError: String?
    @StateObject private var pullRequests: GitHubBrowserModel
    @StateObject private var issues: GitHubBrowserModel
    private let reader: GitHubReader

    init(workspace: WorkspaceModel, scope: ThreadGitHubScope, pasteboard: NSPasteboard) {
        self.workspace = workspace
        self.scope = scope
        self.pasteboard = pasteboard
        _tab = State(initialValue: scope.canReadRepository ? .pullRequests : .linkedItems)
        let reader = workspace.gitHubReader(in: scope)
        self.reader = reader
        _pullRequests = StateObject(wrappedValue: .init(kind: .pullRequests, reader: reader))
        _issues = StateObject(wrappedValue: .init(kind: .issues, reader: reader))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if scope.canReadRepository {
                    tabButton("Pull Requests", for: .pullRequests, id: "github-tab-pull-requests")
                    tabButton("Issues", for: .issues, id: "github-tab-issues")
                }
                tabButton("Linked items", for: .linkedItems, id: "github-tab-linked-items")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("pr-close")
            }
            .padding([.horizontal, .top], 16)
            if tab == .linkedItems {
                ThreadLinkedItemsView(workspace: workspace, scope: scope, reader: reader, pasteboard: pasteboard) {
                    linking = $0
                }
            } else {
                if tab == .issues, let issueLinkError {
                    Text(issueLinkError)
                        .foregroundStyle(.red)
                        .padding(8)
                        .accessibilityIdentifier("issue-link-action-error")
                }
                GitHubListView(reader: reader, repositoryRevision: workspace.repositoryRevision,
                               model: tab == .pullRequests ? pullRequests : issues,
                               issueIsLinked: { reference in
                                   workspace.gitHubScope == scope
                                       && workspace.conversation?.issueLinks.contains(where: { $0.id == reference }) == true
                               },
                               changeIssueLink: changeIssueLink)
                .id(tab)
            }
        }
        .frame(minWidth: 660, idealWidth: 730, minHeight: 425, idealHeight: 510)
        .sheet(item: $linking) { link in
            LinkThreadGitHubItemDialog(workspace: workspace, scope: scope, link: link)
        }
        .onChange(of: issues.selection) { _, _ in issueLinkError = nil }
    }

    private func changeIssueLink(_ reference: GitHubIssueReference, isLinked: Bool) {
        issueLinkError = nil
        if isLinked {
            do {
                try workspace.unlinkIssue(reference, in: scope)
            } catch {
                issueLinkError = error.localizedDescription
            }
        } else {
            linking = .issue(reference)
        }
    }

    private func tabButton(_ title: String, for destination: Tab, id: String) -> some View {
        Button { tab = destination } label: {
            Text(title)
                .fontWeight(tab == destination ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(tab == destination ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == destination ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

private struct GitHubListView: View {
    let reader: GitHubReader
    let repositoryRevision: Int
    @ObservedObject var model: GitHubBrowserModel
    let issueIsLinked: (GitHubIssueReference) -> Bool
    let changeIssueLink: (GitHubIssueReference, Bool) -> Void

    private var prefix: String { model.kind.idPrefix }
    private var itemName: String { model.kind.itemName }

    var body: some View {
        let request = model.request
        VStack(alignment: .leading, spacing: 0) {
            controls
            Divider()
            switch model.listing {
            case .loading:
                ProgressView("Loading \(itemName)s…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("\(prefix)-list-loading")
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("\(prefix)-list-error")
                    Button("Retry") { model.refresh() }
                        .accessibilityIdentifier("\(prefix)-list-retry")
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let list, let paging):
                HStack(spacing: 0) {
                    listColumn(list, paging: paging)
                        .frame(width: 250)
                    Divider()
                    details
                }
            }
        }
        .task(id: request) { await model.load(request) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: reader.directory)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(prefix)-checkout")
            HStack(spacing: 8) {
                TextField("Search \(itemName)s, or label:bug", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search \(itemName)s")
                    .accessibilityIdentifier("\(prefix)-search")
                    .onSubmit { model.applySearch(filter: model.query.filter) }
                Button("Search") { model.applySearch(filter: model.query.filter) }
                    .accessibilityIdentifier("\(prefix)-search-submit")
                Picker("State", selection: Binding(
                    get: { model.query.filter },
                    set: { model.applySearch(filter: $0) }
                )) {
                    ForEach(model.kind.filters) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("\(prefix)-filter")
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh \(itemName)s")
                .accessibilityLabel("Refresh \(itemName)s")
                .accessibilityIdentifier("\(prefix)-refresh")
            }
            if model.kind == .pullRequests {
                HStack(spacing: 8) {
                    PullRequestFilterButton(kind: .author, model: model)
                    PullRequestFilterButton(kind: .label, model: model)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var details: some View {
        if let selection = model.selection {
            Group {
                switch model.kind {
                case .pullRequests:
                    PullRequestDetailsView(reader: reader, repository: selection.repository, number: selection.number)
                        .id(repositoryRevision)
                case .issues:
                    IssueDetailsView(number: selection.number, isLinked: issueIsLinked, changeLink: changeIssueLink) {
                        try await reader.issueDetails(for: selection.number, in: selection.repository)
                    }
                    .id(repositoryRevision)
                }
            }
            .id(selection)
        } else if case .loaded(let list, _) = model.listing {
            Text(list.items.isEmpty ? "" : "Select a \(itemName)")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func listColumn(_ list: GitHubListPage, paging: GitHubBrowserModel.Paging) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: list.repository.slug)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("\(prefix)-repository")
                .padding(12)
            Divider()
            if list.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.query.isSearching ? "No matching \(itemName)s" : "No \(itemName)s")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(prefix)-list-empty")
                    if !model.query.text.isEmpty {
                        Button("Clear search") {
                            model.searchText = ""
                            model.applySearch(filter: model.query.filter)
                        }
                        .accessibilityIdentifier("\(prefix)-search-clear")
                    }
                }
                .padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(list.items) { item in
                            row(item, repository: list.repository)
                        }
                    }
                    .padding(4)
                }
            }
            if list.next != nil {
                Divider()
                pageControls(paging)
                    .padding(12)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ item: GitHubListItem, repository: GitHubRepository) -> some View {
        let selected = model.selection?.repository == repository && model.selection?.number == item.number
        return Button { model.select(item, in: repository) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text("#\(item.number) · \(item.stateLabel)")
                    if let login = item.author?.login, !login.isEmpty {
                        Text(verbatim: "· @\(login)")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                let labels = item.labelNames
                if !labels.isEmpty {
                    Text(verbatim: labels.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(prefix)-row-\(item.number)")
    }

    @ViewBuilder
    private func pageControls(_ paging: GitHubBrowserModel.Paging) -> some View {
        switch paging {
        case .idle:
            Button("Load more \(itemName)s") { model.loadMore() }
                .accessibilityIdentifier("\(prefix)-load-more")
        case .loading:
            ProgressView("Loading more \(itemName)s…")
                .controlSize(.small)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(prefix)-page-error")
                Button("Retry") { model.loadMore() }
                    .accessibilityIdentifier("\(prefix)-page-retry")
            }
        }
    }
}

private struct PullRequestFilterButton: View {
    let kind: GitHubPullRequestFilterKind
    @ObservedObject var model: GitHubBrowserModel
    @State private var isPresented = false

    private var title: String { kind == .author ? "Author" : "Labels" }

    private var summary: String {
        switch kind {
        case .author:
            return model.query.pullRequestFilters?.author ?? "Anyone"
        case .label:
            let count = model.query.pullRequestFilters?.labels.count ?? 0
            return count == 0 ? "Any" : "\(count) selected"
        }
    }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: 6) {
                Text(title)
                Text(verbatim: summary).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }
        }
        .disabled(model.repository == nil)
        .accessibilityLabel(title)
        .accessibilityValue(summary)
        .accessibilityIdentifier("pr-\(kind.rawValue)-filter")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            if let repository = model.repository {
                PullRequestFilterChoices(kind: kind, model: model, repository: repository) {
                    isPresented = false
                }
                .id(repository)
            }
        }
        .onChange(of: model.repository) { isPresented = false }
    }
}

private struct PullRequestFilterChoices: View {
    private struct Request: Hashable {
        let text: String
        let retry: Int
    }

    private enum Options {
        case loaded(GitHubPullRequestFilterOptions)
        case failed(String)
    }

    let kind: GitHubPullRequestFilterKind
    @ObservedObject var model: GitHubBrowserModel
    let repository: GitHubRepository
    let dismiss: () -> Void
    @State private var text = ""
    @State private var retry = 0
    @State private var answer: (Request, Options)?
    @FocusState private var searchFocused: Bool

    private var prefix: String { "pr-\(kind.rawValue)" }

    private var selected: [String] {
        guard let filters = model.query.pullRequestFilters else { return [] }
        return kind == .author ? [filters.author].compactMap { $0 } : filters.labels
    }

    var body: some View {
        let request = Request(text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)), retry: retry)
        let options = answer?.0 == request ? answer?.1 : nil
        let values = choices(options, matching: request.text)
        VStack(alignment: .leading, spacing: 8) {
            TextField(kind == .author ? "Search authors" : "Search labels", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("\(prefix)-search")
            if kind == .author {
                Button { chooseAuthor(nil) } label: {
                    choice("Anyone", selected: selected.isEmpty)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.isEmpty ? .isSelected : [])
                .accessibilityIdentifier("pr-author-anyone")
            } else {
                Button("Clear labels") { model.clearLabels(in: repository) }
                    .disabled(selected.isEmpty)
                    .accessibilityIdentifier("pr-label-clear")
            }
            if !values.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(values, id: \.self) { value in
                            option(value)
                        }
                    }
                }
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            }
            switch options {
            case .none:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading choices")
                    .accessibilityIdentifier("\(prefix)-options-loading")
            case .loaded(let page):
                if values.isEmpty {
                    Text(kind == .author ? "No authors found" : "No labels found")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(prefix)-options-empty")
                }
                if page.hasMore {
                    Text("Type to narrow results").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(prefix)-options-error")
                Button("Retry") { retry += 1 }
                    .accessibilityIdentifier("\(prefix)-options-retry")
            }
        }
        .padding(12)
        .frame(width: 280, height: 300, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(prefix)-choices")
        .submitScope()
        .defaultFocus($searchFocused, true)
        .task(id: request) { await load(request) }
    }

    private func choices(_ options: Options?, matching text: String) -> [String] {
        let known = (model.loadedFilterValues[kind] ?? []).filter {
            text.isEmpty || $0.localizedCaseInsensitiveContains(text)
        }
        let hosted = if case .loaded(let page) = options { page.values } else { [String]() }
        let remaining = GitHubPullRequestFilterOptions.unique(hosted + known)
            .filter { value in !isSelected(value) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return selected + remaining
    }

    private func isSelected(_ value: String) -> Bool {
        selected.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    private func option(_ value: String) -> some View {
        let selected = isSelected(value)
        return Button {
            switch kind {
            case .author: chooseAuthor(value)
            case .label: model.toggleLabel(value, in: repository)
            }
        } label: {
            choice(value, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(prefix)-option-\(value)")
    }

    private func choice(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            Text(verbatim: title).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func chooseAuthor(_ author: String?) {
        model.setAuthor(author, in: repository)
        dismiss()
    }

    @MainActor
    private func load(_ request: Request) async {
        do {
            if !request.text.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            let page = try await model.filterOptions(kind, matching: request.text, in: repository)
            guard !Task.isCancelled else { return }
            answer = (request, .loaded(page))
        } catch {
            guard !Task.isCancelled else { return }
            answer = (request, .failed(error.localizedDescription))
        }
    }
}

struct IssueDetailsView: View {
    let number: Int
    var isLinked: ((GitHubIssueReference) -> Bool)? = nil
    var changeLink: ((GitHubIssueReference, Bool) -> Void)? = nil
    let read: () async throws -> GitHubIssueDetails
    @State private var refresh = 0
    @State private var content: GitHubDetailLoad<GitHubIssueDetails> = .loading

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView("Loading #\(number)…")
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("issue-detail-error")
                    Button("Retry") { refresh += 1 }
                        .accessibilityIdentifier("issue-detail-retry")
                }
                .padding(24)
            case .loaded(let issue):
                ScrollView {
                    summary(issue)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: refresh) { await load() }
    }

    private func summary(_ issue: GitHubIssueDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "#\(issue.number) \(issue.title)")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("issue-detail-title")
            HStack {
                Text(issue.state.capitalized)
                    .accessibilityIdentifier("issue-detail-state")
                if let login = issue.author?.login, !login.isEmpty {
                    Text(verbatim: "· @\(login)")
                        .accessibilityIdentifier("issue-detail-author")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if !issue.labels.isEmpty {
                Text(verbatim: issue.labels.map(\.name).joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("issue-detail-labels")
            }
            HStack {
                if let isLinked, let changeLink {
                    let linked = isLinked(issue.reference)
                    Button(linked ? "Unlink from thread" : "Link to thread") { changeLink(issue.reference, linked) }
                        .accessibilityIdentifier(linked ? "issue-unlink-from-thread" : "issue-link-to-thread")
                }
                Link(destination: issue.url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("issue-open")
                Spacer()
                Button { refresh += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh issue")
                .accessibilityLabel("Refresh issue")
                .accessibilityIdentifier("issue-detail-refresh")
            }
            Divider()
            Text("Description").font(.headline)
            if issue.body.isEmpty {
                Text("No description").foregroundStyle(.secondary)
            } else {
                Text(verbatim: issue.body)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("issue-detail-body")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    @MainActor
    private func load() async {
        guard !Task.isCancelled else { return }
        content = .loading
        do {
            let issue = try await read()
            guard !Task.isCancelled else { return }
            content = .loaded(issue)
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed(error.localizedDescription)
        }
    }
}

struct PullRequestDetailsView: View {
    let reader: GitHubReader
    let repository: GitHubRepository
    let number: Int
    @State private var retry = 0
    @State private var content: GitHubDetailLoad<GitHubPullRequestDetails> = .loading
    @State private var selectedCheckIndex: Int?
    @State private var showingCode = false

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView("Loading #\(number)…")
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("pr-detail-error")
                    Button("Retry") { retry += 1 }
                        .accessibilityIdentifier("pr-detail-retry")
                }
                .padding(24)
            case .loaded(let details):
                if let index = selectedCheckIndex, details.checks.indices.contains(index) {
                    PullRequestCheckLogView(
                        reader: reader, details: details, check: details.checks[index]
                    ) {
                        selectedCheckIndex = nil
                    } refresh: {
                        selectedCheckIndex = nil
                        retry += 1
                    }
                    .id(index)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Button("Summary") { showingCode = false }
                                .accessibilityAddTraits(showingCode ? [] : .isSelected)
                                .accessibilityIdentifier("pr-tab-summary")
                            Button("Code") { showingCode = true }
                                .accessibilityAddTraits(showingCode ? .isSelected : [])
                                .accessibilityIdentifier("pr-tab-code")
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        Divider()
                        if showingCode {
                            PullRequestCodeView(reader: reader, details: details) { retry += 1 }
                        } else {
                            ScrollView {
                                summary(details)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: retry) { await load() }
    }

    private func summary(_ details: GitHubPullRequestDetails) -> some View {
        let item = details.pullRequest
        return VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "#\(item.number) \(item.title)")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("pr-detail-title")
            HStack {
                Text(item.stateLabel)
                if let login = item.author?.login, !login.isEmpty {
                    Text(verbatim: "· @\(login)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(verbatim: "\(details.headRef) → \(details.baseRef)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Link(destination: details.url) {
                Label("Open on GitHub", systemImage: "arrow.up.right.square")
            }
            .accessibilityIdentifier("pr-open")
            Divider()
            Text("Checks").font(.headline)
            if details.checks.isEmpty {
                Text("No checks reported")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("pr-checks-empty")
            }
            ForEach(Array(details.checks.enumerated()), id: \.offset) { index, check in
                checkRow(check, index: index)
            }
            if !details.body.isEmpty {
                Divider()
                Text("Description").font(.headline)
                Text(verbatim: details.body).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private func checkRow(_ check: GitHubCheck, index: Int) -> some View {
        let title = [check.workflowName, check.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: check.name).font(.callout)
                if let workflow = check.workflowName, !workflow.isEmpty {
                    Text(verbatim: workflow).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(verbatim: check.status.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pr-check-status-\(index)")
            if check.hasFailureLog {
                Button("View log") { selectedCheckIndex = index }
                    .accessibilityLabel("View log for \(title)")
                    .accessibilityIdentifier("pr-check-log-\(index)")
            }
            if let url = check.url {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .help("Open check details")
                    .accessibilityLabel("Open check details for \(check.name)")
                    .accessibilityIdentifier("pr-check-open-\(index)")
            }
        }
    }

    @MainActor
    private func load() async {
        guard !Task.isCancelled else { return }
        content = .loading
        selectedCheckIndex = nil
        do {
            let details = try await reader.pullRequestDetails(for: number, in: repository)
            guard !Task.isCancelled else { return }
            content = .loaded(details)
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed(error.localizedDescription)
        }
    }
}

private struct PullRequestCheckLogView: View {
    let reader: GitHubReader
    let details: GitHubPullRequestDetails
    let check: GitHubCheck
    let back: () -> Void
    let refresh: () -> Void
    @State private var retry = 0
    @State private var result: Result<GitHubCheckLog, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: back) { Label("Back to checks", systemImage: "chevron.left") }
                    .accessibilityIdentifier("pr-check-log-back")
                Spacer()
                if let url = check.url {
                    Link(destination: url) { Label("Open check details", systemImage: "arrow.up.right.square") }
                        .accessibilityIdentifier("pr-check-log-open")
                }
            }
            Text(verbatim: check.name)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("pr-check-log-title")
            if let workflow = check.workflowName, !workflow.isEmpty {
                Text(verbatim: workflow)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            switch result {
            case nil:
                ProgressView("Loading job log…")
                    .accessibilityIdentifier("pr-check-log-loading")
            case .success(let log):
                if log.truncated {
                    Text("Showing the end of this log.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pr-check-log-truncated")
                }
                ScrollView {
                    Text(verbatim: log.text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("pr-check-log-text")
                }
            case .failure(let error):
                Text(error.localizedDescription)
                    .accessibilityIdentifier("pr-check-log-error")
                switch error as? GitHubCheckLogError {
                case .unsupported:
                    EmptyView()
                case .checkChanged, .checkoutChanged:
                    Button("Refresh pull request", action: refresh)
                        .accessibilityIdentifier("pr-check-log-refresh")
                default:
                    Button("Retry") { retry += 1 }
                        .accessibilityIdentifier("pr-check-log-retry")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: retry) { await load() }
    }

    @MainActor
    private func load() async {
        guard !Task.isCancelled else { return }
        result = nil
        do {
            let log = try await reader.checkLog(for: check, in: details)
            guard !Task.isCancelled else { return }
            result = .success(log)
        } catch {
            guard !Task.isCancelled else { return }
            result = .failure(error)
        }
    }
}
