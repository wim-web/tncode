import SwiftUI

struct ThreadLinkedItemsView: View {
    private enum Selection: Hashable {
        case pullRequest(GitHubPullRequestReference)
        case issue(GitHubIssueReference)
    }

    @ObservedObject var workspace: WorkspaceModel
    let scope: ThreadGitHubScope
    let reader: GitHubReader
    let pasteboard: NSPasteboard
    let onLink: (ThreadGitHubLinkRequest) -> Void
    @Environment(\.openURL) private var openURL
    @State private var selection: Selection?
    @State private var error: String?

    var body: some View {
        let thread = workspace.gitHubScope == scope ? workspace.conversation : nil
        let pullRequests = thread?.pullRequestLinks ?? []
        let issues = thread?.issueLinks ?? []
        VStack(spacing: 0) {
            HStack {
                Text("Linked items").font(.headline)
                Spacer()
                Button { onLink(.issue(nil)) } label: {
                    Label("Link issue", systemImage: "plus")
                }
                .disabled(!scope.canReadRepository)
                .accessibilityIdentifier("linked-issue-add")
                Button { onLink(.pullRequest) } label: {
                    Label("Link pull request", systemImage: "plus")
                }
                .disabled(!scope.canReadRepository)
                .accessibilityIdentifier("linked-pr-add")
            }
            .padding(16)
            Divider()
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(8)
                    .accessibilityIdentifier("linked-pr-error")
            }
            if pullRequests.isEmpty && issues.isEmpty {
                Text("No linked pull requests or issues")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("linked-pr-empty")
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            if !issues.isEmpty {
                                sectionHeading("Issues")
                                ForEach(issues) { issueRow($0) }
                            }
                            if !pullRequests.isEmpty {
                                if !issues.isEmpty { sectionHeading("Pull requests") }
                                ForEach(pullRequests) { pullRequestRow($0) }
                            }
                        }
                        .padding(4)
                    }
                    .frame(width: 250, alignment: .leading)
                    Divider()
                    switch selection {
                    case .pullRequest(let reference) where pullRequests.contains(where: { $0.id == reference }):
                        PullRequestDetailsView(reader: reader, repository: reference.repository, number: reference.number)
                            .id(workspace.repositoryRevision)
                            .id(reference)
                    case .issue(let reference) where issues.contains(where: { $0.id == reference }):
                        issueDetails(reference)
                            .id(reference)
                    default:
                        Text(scope.canReadRepository || !issues.isEmpty
                             ? "Select a linked item" : "Create the worktree to read pull request details.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("linked-items")
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    private func issueRow(_ link: ThreadIssueLink) -> some View {
        let reference = link.reference
        let selected = selection == .issue(reference)
        return Button { selection = .issue(reference) } label: {
            rowLabel(link.title, repository: reference.repository, number: reference.number)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("linked-issue-row-\(reference.repository.slug)-\(reference.number)")
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func issueDetails(_ reference: GitHubIssueReference) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: reference.repository.slug)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy link") { copy(reference.url.absoluteString) }
                    .accessibilityIdentifier("linked-issue-copy-link")
                Button("Unlink from thread") {
                    unlink(.issue(reference)) { try workspace.unlinkIssue(reference, in: scope) }
                }
                .accessibilityIdentifier("linked-issue-unlink")
            }
            .padding(12)
            Divider()
            IssueDetailsView(number: reference.number) { try await reader.linkedIssueDetails(for: reference) }
        }
    }

    private func pullRequestRow(_ link: ThreadPullRequestLink) -> some View {
        let reference = link.reference
        let identifier = "\(reference.repository.slug)-\(reference.number)"
        let selected = selection == .pullRequest(reference)
        return HStack(spacing: 6) {
            Button { selection = .pullRequest(reference) } label: {
                rowLabel(link.title, repository: reference.repository, number: reference.number)
            }
            .buttonStyle(.plain)
            .disabled(!scope.canReadRepository)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("linked-pr-row-\(identifier)")

            Menu {
                Button("Open on GitHub") { openURL(reference.url) }
                    .accessibilityIdentifier("linked-pr-open")
                Button("Copy link") { copy(reference.url.absoluteString) }
                    .accessibilityIdentifier("linked-pr-copy-link")
                Button("Copy PR number") { copy("#\(reference.number)") }
                    .accessibilityIdentifier("linked-pr-copy-number")
                Divider()
                Button("Unlink from thread") {
                    unlink(.pullRequest(reference)) { try workspace.unlinkPullRequest(reference, in: scope) }
                }
                    .accessibilityIdentifier("linked-pr-unlink")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(reference.repository.slug) #\(reference.number)")
            .accessibilityIdentifier("linked-pr-actions-\(identifier)")
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func rowLabel(_ title: String, repository: GitHubRepository, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(verbatim: "\(repository.slug) #\(number)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        error = pasteboard.setString(text, forType: .string) ? nil : "Couldn’t copy to the clipboard."
    }

    private func unlink(_ item: Selection, perform operation: () throws -> Void) {
        do {
            try operation()
            if selection == item { selection = nil }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum ThreadGitHubLinkRequest: Identifiable {
    case pullRequest
    case issue(GitHubIssueReference?)

    var kind: GitHubBrowseKind {
        switch self {
        case .pullRequest: .pullRequests
        case .issue: .issues
        }
    }

    var id: GitHubBrowseKind { kind }
}

struct LinkThreadGitHubItemDialog: View {
    private struct Request {
        let id = UUID()
        let input: String
        let repository: GitHubRepository
    }

    let workspace: WorkspaceModel
    let scope: ThreadGitHubScope
    let link: ThreadGitHubLinkRequest
    @Environment(\.dismiss) private var dismiss
    @FocusState private var referenceFocused: Bool
    @State private var reference = ""
    @State private var request: Request?
    @State private var repository: GitHubRepository?
    @State private var repositoryError: String?
    @State private var retry = 0
    @State private var error: String?

    init(workspace: WorkspaceModel, scope: ThreadGitHubScope, link: ThreadGitHubLinkRequest) {
        self.workspace = workspace
        self.scope = scope
        self.link = link
        if case .issue(let issue) = link { _reference = State(initialValue: issue?.url.absoluteString ?? "") }
    }

    private var prefix: String { "linked-\(link.kind.idPrefix)" }
    private var itemName: String { link.kind.itemName }
    private var fieldLabel: String { link.kind == .issues ? "Issue URL or number" : "Pull request URL or number" }

    var body: some View {
        let work = request
        VStack(alignment: .leading, spacing: 12) {
            Text("Link \(itemName)").font(.title3.weight(.semibold))
            Text("Enter the URL or number of an existing \(itemName) from this thread’s checkout.")
                .foregroundStyle(.secondary)
            if let repository {
                Text(verbatim: repository.cliName)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("\(prefix)-repository")
            } else if let repositoryError {
                Text(repositoryError)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(prefix)-repository-error")
                Button("Retry") { retry += 1 }
                    .accessibilityIdentifier("\(prefix)-repository-retry")
            } else {
                ProgressView("Reading checkout…")
                    .controlSize(.small)
            }
            TextField(link.kind == .issues ? "Issue URL or #42" : "Pull request URL or #42", text: $reference)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(fieldLabel)
                .accessibilityIdentifier("\(prefix)-reference")
                .focused($referenceFocused)
                .disabled(repository == nil || work != nil)
                .onSubmit(submit)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("\(prefix)-link-error")
            }
            HStack {
                if work != nil {
                    ProgressView("Linking…")
                        .controlSize(.small)
                        .accessibilityIdentifier("\(prefix)-linking")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(work != nil)
                    .accessibilityIdentifier("\(prefix)-cancel")
                Button("Link", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(repository == nil || work != nil || reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("\(prefix)-submit")
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(work != nil)
        .task(id: retry) {
            repositoryError = nil
            do {
                let resolved = try await workspace.gitHubRepository(in: scope)
                guard !Task.isCancelled else { return }
                repository = resolved
                referenceFocused = true
            } catch {
                guard !Task.isCancelled else { return }
                repositoryError = error.localizedDescription
            }
        }
        .task(id: work?.id) {
            guard let work, !Task.isCancelled else { return }
            do {
                switch link {
                case .pullRequest:
                    try await workspace.linkPullRequest(work.input, in: scope, repository: work.repository)
                case .issue:
                    try await workspace.linkIssue(work.input, in: scope, repository: work.repository)
                }
                guard !Task.isCancelled else { return }
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                request = nil
                referenceFocused = true
            }
        }
    }

    private func submit() {
        guard let repository, request == nil, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        error = nil
        request = Request(input: reference, repository: repository)
    }
}
