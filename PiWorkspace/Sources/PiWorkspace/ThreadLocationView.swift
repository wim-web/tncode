import SwiftUI

struct ThreadLocationView: View {
    let project: Project
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var refs: [GitBranchRef]?
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
            } else if let refs {
                Divider()
                Text("New worktree").font(.callout.weight(.semibold))
                Picker("Base branch", selection: $base) {
                    if !refs.contains(where: { $0.id == base }) {
                        Text(GitBranchRef.displayName(base)).tag(base)
                    }
                    ForEach(refs) { ref in Text(ref.name).tag(ref.id) }
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
                                .accessibilityIdentifier("existing-worktree-\(checkout.path)")
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
                let branches = try await git.branchRefs()
                let current = try await git.currentBranch()
                checkouts = try await git.worktrees()
                refs = branches
                base = current.flatMap { name in branches.first { !$0.isRemote && $0.name == name }?.id }
                    ?? branches.first?.id ?? ""
                branch = "thread-" + (model.conversation?.id.uuidString.prefix(8).lowercased() ?? "work")
                if case let .newWorktree(savedBranch, savedBase) = model.conversation?.workingLocation {
                    branch = savedBranch
                    base = branches.first { $0.id == savedBase }?.id
                        ?? branches.first { $0.name == savedBase }?.id ?? savedBase
                }
            } catch {
                refs = nil
            }
            loading = false
        }
        .onChange(of: loading) { _, loading in
            if !loading && refs != nil { branchFocused = true }
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
