import SwiftUI

struct PromptLinkView: View {
    @ObservedObject var model: WorkspaceModel
    let review: PromptLinkReview
    let didOpen: () -> Void

    private enum Lookup {
        case idle, searching, found([PromptLinkProject])
    }

    @Environment(\.dismiss) private var dismiss
    @State private var reopening = false
    @State private var lookup = Lookup.idle
    @State private var selection: PromptLinkProject?
    @State private var clone: (ProjectPickerRequest, ProjectCloneRemote)?
    @State private var error: String?

    private var alreadyOpened: Bool { review.alreadyOpened && !reopening }
    private var isSearching: Bool { if case .searching = lookup { true } else { false } }

    var body: some View {
        if let (request, remote) = clone {
            ProjectFolderView(request: request, cloneRemote: remote) { source in
                try await model.openProject(source, request: request)
                didOpen()
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(alreadyOpened ? "This link is open" : "Review shared prompt")
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("prompt-link-title")
                if let repository = review.link.repository {
                    Text("Repository: \(repository.slug)")
                        .accessibilityIdentifier("prompt-link-repository")
                }
                ScrollView {
                    Text(verbatim: review.link.prompt)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("prompt-link-preview")
                }
                .frame(maxHeight: 160)
                if review.link.removedHiddenCharacters {
                    Label("Hidden characters were removed. Review the prompt before sending it.",
                          systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("prompt-link-hidden-warning")
                }
                if review.link.modelHint != nil {
                    Text("If the requested model isn’t configured here, the draft uses the default model.")
                        .foregroundStyle(.secondary)
                }
                if !alreadyOpened, let repository = review.link.repository {
                    repositoryChoices(repository)
                }
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("prompt-link-action-error")
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.promptLinkReview = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancel-prompt-link")
                    if alreadyOpened {
                        Button("Open It Again") { reopening = true }
                            .accessibilityIdentifier("reopen-prompt-link")
                    } else {
                        Button("Use without project") { openScratchDraft() }
                            .disabled(model.operationsInProgress || selection != nil)
                            .accessibilityIdentifier("prompt-link-no-project")
                    }
                }
            }
            .padding(20)
            .frame(width: 485)
            .task(id: isSearching) {
                guard isSearching else { return }
                do {
                    lookup = .found(try await model.matchingPromptLinkProjects(for: review))
                } catch {
                    if !Task.isCancelled {
                        self.error = error.localizedDescription
                        lookup = .idle
                    }
                }
            }
            .task(id: selection?.id) {
                guard let selection else { return }
                do {
                    try await model.openPromptLinkDraft(review, in: selection)
                    didOpen()
                    dismiss()
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                    self.selection = nil
                    lookup = .idle
                }
            }
        }
    }

    @ViewBuilder
    private func repositoryChoices(_ repository: GitHubRepository) -> some View {
        switch lookup {
        case .idle:
            Button("Find Registered Project") {
                error = nil
                lookup = .searching
            }
            .accessibilityIdentifier("prompt-link-find-project")
        case .searching:
            ProgressView("Checking registered projects…").controlSize(.small)
        case let .found(projects):
            if projects.isEmpty {
                Text("No registered project matches this repository.")
                    .accessibilityIdentifier("prompt-link-no-match")
                Button("Clone \(repository.slug)") {
                    do { clone = try model.promptLinkCloneRequest(for: review) }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(model.operationsInProgress || selection != nil)
                .accessibilityIdentifier("prompt-link-clone")
            } else {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(projects) { project in
                            Button { selection = project } label: {
                                VStack(alignment: .leading) {
                                    Text(project.title)
                                    Text(project.path).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityIdentifier("prompt-link-project-\(project.id)")
                        }
                    }
                }
                .frame(maxHeight: 150)
                .disabled(model.operationsInProgress || selection != nil)
            }
        }
    }

    private func openScratchDraft() {
        do {
            try model.openPromptLinkDraft(review)
            didOpen()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
