import SwiftUI

struct PullRequestsButton: View {
    let directory: String
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "arrow.triangle.branch")
        }
        .buttonStyle(.plain)
        .help("Pull Requests")
        .accessibilityLabel("Pull Requests")
        .accessibilityIdentifier("pull-requests")
        .sheet(isPresented: $presented) {
            PullRequestsView(directory: directory)
        }
    }
}

private enum PullRequestLoad<Value> {
    case loading
    case loaded(Value)
    case failed(String)
}

private struct PullRequestsView: View {
    let directory: String
    @Environment(\.dismiss) private var dismiss
    @State private var filter: PullRequestFilter = .open
    @State private var refresh = 0
    @State private var selection: Selection?
    @State private var listing: PullRequestLoad<GitHubPullRequestList> = .loading

    private struct Selection: Hashable {
        let repository: GitHubRepository
        let number: Int
    }

    private struct Request: Hashable {
        let filter: PullRequestFilter
        let refresh: Int
    }

    var body: some View {
        let request = Request(filter: filter, refresh: refresh)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pull Requests").font(.headline)
                    Text(directory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pr-checkout")
                }
                Spacer()
                Picker("State", selection: $filter) {
                    ForEach(PullRequestFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("pr-filter")
                Button { refresh += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh pull requests")
                .accessibilityLabel("Refresh pull requests")
                .accessibilityIdentifier("pr-refresh")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("pr-close")
            }
            .padding(16)
            Divider()
            switch listing {
            case .loading:
                ProgressView("Loading pull requests…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("pr-list-error")
            case .loaded(let list):
                HStack(spacing: 0) {
                    listColumn(list, filter: request.filter)
                        .frame(width: 240)
                    Divider()
                    if let selection, selection.repository == list.repository {
                        PullRequestDetailsView(directory: directory, repository: selection.repository,
                                               number: selection.number)
                            .id(selection)
                    } else {
                        Text(list.items.isEmpty ? "" : "Select a pull request")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 660, idealWidth: 730, minHeight: 425, idealHeight: 510)
        .task(id: request) { await load(request.filter) }
    }

    private func listColumn(_ list: GitHubPullRequestList, filter: PullRequestFilter) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: list.repository.slug)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("pr-repository")
                .padding(12)
            Divider()
            if list.items.isEmpty {
                Text(filter == .all ? "No pull requests" : "No \(filter.rawValue) pull requests")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("pr-list-empty")
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(list.items) { item in
                            let target = Selection(repository: list.repository, number: item.number)
                            Button { selection = target } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: item.title)
                                        .font(.callout.weight(.medium))
                                        .lineLimit(2)
                                    Text("#\(item.number) · \(item.stateLabel)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(selection == target ? Color.accentColor.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == target ? .isSelected : [])
                            .accessibilityIdentifier("pr-row-\(item.number)")
                        }
                    }
                    .padding(4)
                }
                if list.items.count == GitHubPullRequests.listLimit {
                    Text("Showing the latest \(GitHubPullRequests.listLimit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @MainActor
    private func load(_ filter: PullRequestFilter) async {
        guard !Task.isCancelled else { return }
        listing = .loading
        do {
            let list = try await GitHubPullRequests(directory: directory).list(filter)
            guard !Task.isCancelled else { return }
            if let selection,
               selection.repository != list.repository || !list.items.contains(where: { $0.number == selection.number }) {
                self.selection = nil
            }
            listing = .loaded(list)
        } catch {
            guard !Task.isCancelled else { return }
            listing = .failed(error.localizedDescription)
        }
    }
}

private struct PullRequestDetailsView: View {
    let directory: String
    let repository: GitHubRepository
    let number: Int
    @State private var content: PullRequestLoad<GitHubPullRequestDetails> = .loading

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView("Loading #\(number)…")
            case .failed(let message):
                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .accessibilityIdentifier("pr-detail-error")
            case .loaded(let details):
                ScrollView {
                    summary(details)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
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
        do {
            let details = try await GitHubPullRequests(directory: directory).details(for: number, in: repository)
            guard !Task.isCancelled else { return }
            content = .loaded(details)
        } catch {
            guard !Task.isCancelled else { return }
            content = .failed(error.localizedDescription)
        }
    }
}
