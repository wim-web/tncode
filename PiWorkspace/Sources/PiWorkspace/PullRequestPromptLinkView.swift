import SwiftUI

struct PullRequestPromptLinkView: View {
    @ObservedObject var model: WorkspaceModel
    let review: PromptLinkReview
    let reference: GitHubPullRequestReference
    let didOpen: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lookupID: UUID?
    @State private var target: PullRequestPromptLinkTarget?
    @State private var clone: (ProjectPickerRequest, ProjectCloneRemote)?
    @State private var preparing = false
    @State private var error: String?

    private var alreadyOpened: Bool { review.alreadyOpened && lookupID == nil }
    private var numberLabel: String { "\(reference.repository.slug)#\(reference.number)" }

    private var title: String {
        if alreadyOpened { return "This link is open" }
        switch target {
        case .checkout: return "Check out pull request?"
        case .thread: return "Open linked pull request thread"
        case .missingProject: return "You don’t have \(reference.repository.slug)"
        case nil: return "Review pull request link"
        }
    }

    var body: some View {
        if let (request, remote) = clone {
            ProjectFolderView(request: request, cloneRemote: remote) { source in
                try await model.openProject(source, request: request)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("prompt-link-title")
                Text(numberLabel)
                    .accessibilityIdentifier("prompt-link-pull-request")
                details
                PromptLinkPreview(link: review.link)
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("prompt-link-action-error")
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(preparing)
                        .accessibilityIdentifier("cancel-prompt-link")
                    actions
                        .disabled(model.operationsInProgress || preparing)
                }
            }
            .padding(20)
            .frame(width: 525)
            .interactiveDismissDisabled(preparing)
            .task(id: lookupID) {
                guard !alreadyOpened else { return }
                do {
                    let resolved = try await model.resolvePullRequestPromptLink(review)
                    try Task.checkCancellation()
                    target = resolved
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                }
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        switch target {
        case let .checkout(checkout):
            Text(verbatim: checkout.details.pullRequest.title)
                .accessibilityIdentifier("prompt-link-pr-title")
            Text(verbatim: "\(checkout.details.headRef) · \(checkout.details.headOID)")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("prompt-link-pr-head")
            Text(verbatim: checkout.root)
                .textSelection(.enabled)
                .accessibilityIdentifier("prompt-link-pr-folder")
            Text("Check out this commit in a new worktree for \(checkout.project.title).")
                .foregroundStyle(.secondary)
        case let .thread(thread):
            Text(verbatim: thread.title)
                .accessibilityIdentifier("prompt-link-pr-thread")
            Text(verbatim: thread.directory)
                .textSelection(.enabled)
                .accessibilityIdentifier("prompt-link-pr-folder")
            if thread.needsReplacement(for: review.link.prompt) {
                Text("This thread already has a draft. Open it as is or replace its draft text with the linked prompt.")
                    .accessibilityIdentifier("prompt-link-pr-draft-conflict")
            }
        case .missingProject:
            Text("Clone the repository and open the link again, or open a draft with the pull request URL.")
                .accessibilityIdentifier("prompt-link-no-match")
        case nil:
            if !alreadyOpened && error == nil {
                ProgressView("Looking up the pull request…").controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if alreadyOpened {
            Button("Open It Again", action: refresh)
                .accessibilityIdentifier("reopen-prompt-link")
        } else {
            if error != nil {
                Button("Refresh", action: refresh)
                    .accessibilityIdentifier("prompt-link-pr-refresh")
            }
            switch target {
            case let .checkout(checkout):
                Button(preparing ? "Checking out…" : "Check out") { prepare(checkout) }
                    .accessibilityIdentifier("prompt-link-pr-checkout")
            case let .thread(thread):
                Button("Open Thread") { openThread(thread, replaceDraft: false) }
                    .accessibilityIdentifier("prompt-link-pr-open-thread")
                if thread.needsReplacement(for: review.link.prompt) {
                    Button("Replace Draft and Open") { openThread(thread, replaceDraft: true) }
                        .accessibilityIdentifier("prompt-link-pr-replace-draft")
                }
            case .missingProject:
                Button("Clone Repository") {
                    do { clone = try model.promptLinkCloneRequest(for: review) }
                    catch { self.error = error.localizedDescription }
                }
                .accessibilityIdentifier("prompt-link-clone")
                Button("Use without project") {
                    do {
                        try model.openPromptLinkDraft(review)
                        finish()
                    } catch { self.error = error.localizedDescription }
                }
                .accessibilityIdentifier("prompt-link-no-project")
            case nil:
                EmptyView()
            }
        }
    }

    private func refresh() {
        target = nil
        error = nil
        lookupID = UUID()
    }

    private func prepare(_ checkout: PullRequestPromptLinkTarget.Checkout) {
        guard !preparing else { return }
        preparing = true
        error = nil
        Task {
            defer { preparing = false }
            do {
                if let changed = try await model.preparePullRequestPromptLink(review, target: checkout) {
                    target = .checkout(changed)
                    error = "The pull request head changed. Review the new commit and confirm again."
                } else {
                    finish()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func openThread(_ thread: PullRequestPromptLinkTarget.Thread, replaceDraft: Bool) {
        guard !preparing else { return }
        preparing = true
        error = nil
        Task {
            defer { preparing = false }
            do {
                try await model.openPullRequestPromptLinkThread(review, target: thread, replaceDraft: replaceDraft)
                finish()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func finish() {
        didOpen()
        dismiss()
    }
}
