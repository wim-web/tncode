import SwiftUI

struct ThreadPullRequestsView: View {
    @ObservedObject var workspace: WorkspaceModel
    let scope: ThreadPullRequestScope
    let pasteboard: NSPasteboard
    @Environment(\.openURL) private var openURL
    @State private var showingLinkDialog = false
    @State private var selection: GitHubPullRequestReference?
    @State private var error: String?

    var body: some View {
        let links = workspace.pullRequestScope == scope ? workspace.conversation?.pullRequestLinks ?? [] : []
        VStack(spacing: 0) {
            HStack {
                Text("Linked pull requests").font(.headline)
                Spacer()
                Button { showingLinkDialog = true } label: {
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
            if links.isEmpty {
                Text("No linked pull requests")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("linked-pr-empty")
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(links) { row($0) }
                        }
                        .padding(4)
                    }
                    .frame(width: 250, alignment: .leading)
                    Divider()
                    if let selection, links.contains(where: { $0.id == selection }) {
                        PullRequestDetailsView(directory: scope.directory, repository: selection.repository, number: selection.number)
                            .id(selection)
                    } else {
                        Text(scope.canReadRepository ? "Select a pull request" : "Create the worktree to read pull request details.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("linked-items")
        .sheet(isPresented: $showingLinkDialog) {
            LinkThreadPullRequestDialog(workspace: workspace, scope: scope)
        }
    }

    private func row(_ link: ThreadPullRequestLink) -> some View {
        let reference = link.reference
        let identifier = "\(reference.repository.slug)-\(reference.number)"
        let selected = selection == reference
        return HStack(spacing: 6) {
            Button { selection = reference } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: link.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text(verbatim: "\(reference.repository.slug) #\(reference.number)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
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
                Button("Unlink from thread") { unlink(reference) }
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

    private func copy(_ text: String) {
        pasteboard.clearContents()
        error = pasteboard.setString(text, forType: .string) ? nil : "Couldn’t copy to the clipboard."
    }

    private func unlink(_ reference: GitHubPullRequestReference) {
        do {
            try workspace.unlinkPullRequest(reference, in: scope)
            if selection == reference { selection = nil }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct LinkThreadPullRequestDialog: View {
    private struct Request {
        let id = UUID()
        let input: String
        let repository: GitHubRepository
    }

    let workspace: WorkspaceModel
    let scope: ThreadPullRequestScope
    @Environment(\.dismiss) private var dismiss
    @FocusState private var referenceFocused: Bool
    @State private var reference = ""
    @State private var request: Request?
    @State private var repository: GitHubRepository?
    @State private var repositoryError: String?
    @State private var retry = 0
    @State private var error: String?

    var body: some View {
        let work = request
        VStack(alignment: .leading, spacing: 12) {
            Text("Link pull request").font(.title3.weight(.semibold))
            Text("Enter the URL or number of an existing pull request from this thread’s checkout.")
                .foregroundStyle(.secondary)
            if let repository {
                Text(verbatim: repository.cliName)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("linked-pr-repository")
            } else if let repositoryError {
                Text(repositoryError)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("linked-pr-repository-error")
                Button("Retry") { retry += 1 }
                    .accessibilityIdentifier("linked-pr-repository-retry")
            } else {
                ProgressView("Reading checkout…")
                    .controlSize(.small)
            }
            TextField("Pull request URL or #42", text: $reference)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Pull request URL or number")
                .accessibilityIdentifier("linked-pr-reference")
                .focused($referenceFocused)
                .disabled(repository == nil || work != nil)
                .onSubmit(submit)
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("linked-pr-link-error")
            }
            HStack {
                if work != nil {
                    ProgressView("Linking…")
                        .controlSize(.small)
                        .accessibilityIdentifier("linked-pr-linking")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(work != nil)
                    .accessibilityIdentifier("linked-pr-cancel")
                Button("Link", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(repository == nil || work != nil || reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("linked-pr-submit")
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(work != nil)
        .task(id: retry) {
            repositoryError = nil
            do {
                let resolved = try await workspace.pullRequestRepository(in: scope)
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
                try await workspace.linkPullRequest(work.input, in: scope, repository: work.repository)
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
