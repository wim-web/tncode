import SwiftUI

struct ThreadLocationView: View {
    let project: Project
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var repository: GitRepositoryState?
    @State private var checkouts: [GitCheckout] = []
    @State private var base = ""
    @State private var branch = ""
    @State private var loading = true
    @State private var error: String?
    @FocusState private var branchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Thread workspace").font(.title3.weight(.semibold))
            Button {
                choose(.project)
            } label: {
                Label("Use Project Folder", systemImage: "folder")
            }
            .accessibilityIdentifier("use-project-workspace")

            if loading {
                ProgressView().controlSize(.small)
            } else if let repository {
                Divider()
                Text("New worktree").font(.callout.weight(.semibold))
                Picker("Base branch", selection: $base) {
                    ForEach(repository.branches, id: \.self) { name in Text(name).tag(name) }
                }
                .accessibilityIdentifier("worktree-base")
                TextField("New branch name", text: $branch)
                    .textFieldStyle(.roundedBorder)
                    .focused($branchFocused)
                    .accessibilityIdentifier("worktree-branch")
                Button("Use New Worktree") { choose(.create(branch: branch, base: base)) }
                    .buttonStyle(.borderedProminent)
                    .disabled(base.isEmpty || branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("create-worktree")

                let otherCheckouts = checkouts.filter { $0.path != project.path }
                if !otherCheckouts.isEmpty {
                    Divider()
                    Text("Existing worktrees").font(.callout.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(otherCheckouts, id: \.path) { checkout in
                                Button {
                                    choose(.existing(path: checkout.path))
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Label(checkout.branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
                                        Text(checkout.path)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 125)
                }
            } else {
                Text("Git worktrees are available in projects with a Git repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("workspace-error")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .disabled(model.gitMutationInProgress)
        .interactiveDismissDisabled(model.gitMutationInProgress)
        .padding(22)
        .frame(width: 435)
        .task {
            let git = GitWorkspace(path: project.path)
            do {
                let state = try await git.state()
                checkouts = try await git.worktrees()
                repository = state
                base = state.branch ?? state.branches.first ?? ""
                branch = "thread-" + (model.conversation?.id.uuidString.prefix(8).lowercased() ?? "work")
            } catch {
                repository = nil
            }
            loading = false
        }
        .onChange(of: loading) { _, loading in
            if !loading && repository != nil { branchFocused = true }
        }
    }

    private func choose(_ choice: ThreadLocationChoice) {
        Task {
            do {
                try await model.changeThreadLocation(choice)
                dismiss()
            } catch let failure {
                error = failure.localizedDescription
            }
        }
    }
}
