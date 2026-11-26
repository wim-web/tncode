import SwiftUI

struct PullRequestsButton: View {
    let workspace: WorkspaceModel
    let scope: ThreadPullRequestScope
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

private struct GitHubBrowserView: View {
    private enum Tab: Hashable {
        case pullRequests, issues, linkedItems
    }

    let workspace: WorkspaceModel
    let scope: ThreadPullRequestScope
    let pasteboard: NSPasteboard
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab
    @StateObject private var pullRequests: GitHubBrowserModel
    @StateObject private var issues: GitHubBrowserModel

    init(workspace: WorkspaceModel, scope: ThreadPullRequestScope, pasteboard: NSPasteboard) {
        self.workspace = workspace
        self.scope = scope
        self.pasteboard = pasteboard
        _tab = State(initialValue: scope.canReadRepository ? .pullRequests : .linkedItems)
        let reader = GitHubReader(directory: scope.directory)
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
                ThreadPullRequestsView(workspace: workspace, scope: scope, pasteboard: pasteboard)
            } else {
                GitHubListView(directory: scope.directory, model: tab == .pullRequests ? pullRequests : issues)
                    .id(tab)
            }
        }
        .frame(minWidth: 660, idealWidth: 730, minHeight: 425, idealHeight: 510)
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
    let directory: String
    @ObservedObject var model: GitHubBrowserModel

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
            Text(verbatim: directory)
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
        }
        .padding(16)
    }

    @ViewBuilder
    private var details: some View {
        if let selection = model.selection {
            Group {
                switch model.kind {
                case .pullRequests:
                    PullRequestDetailsView(directory: directory, repository: selection.repository, number: selection.number)
                case .issues:
                    IssueDetailsView(directory: directory, repository: selection.repository, number: selection.number)
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
                    Text(model.query.text.isEmpty ? "No \(itemName)s" : "No matching \(itemName)s")
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
                Text("#\(item.number) · \(item.stateLabel)")
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

private struct IssueDetailsView: View {
    let directory: String
    let repository: GitHubRepository
    let number: Int
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
            let issue = try await GitHubReader(directory: directory).issueDetails(for: number, in: repository)
            guard !Task.isCancelled else { return }
            content = .loaded(issue)
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed(error.localizedDescription)
        }
    }
}

struct PullRequestDetailsView: View {
    let directory: String
    let repository: GitHubRepository
    let number: Int
    @State private var retry = 0
    @State private var content: GitHubDetailLoad<GitHubPullRequestDetails> = .loading

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
                ScrollView {
                    summary(details)
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
        HStack(spacing: 8) {
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
        do {
            let details = try await GitHubReader(directory: directory).pullRequestDetails(for: number, in: repository)
            guard !Task.isCancelled else { return }
            content = .loaded(details)
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed(error.localizedDescription)
        }
    }
}
