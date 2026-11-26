import SwiftUI

struct SourceControlView: View {
    let directory: String
    @ObservedObject var model: WorkspaceModel
    @State private var state: GitRepositoryState?
    @State private var selected: GitFileChange?
    @State private var excludedPaths: Set<String> = []
    @State private var staged = false
    @State private var patch = ""
    @State private var commitMessage = ""
    @State private var error: String?
    @State private var patchError: String?
    @State private var loading = true
    @State private var refresh = 0

    private let refreshLabel = "Refresh Git changes"

    private struct ReadRequest: Hashable {
        let location: String
        let revision: Int
        let refresh: Int
    }

    private struct DiffRequest: Hashable {
        let key: ReadRequest
        let file: GitFileChange?
        let staged: Bool
    }

    private var request: ReadRequest {
        ReadRequest(location: directory, revision: model.repositoryRevision, refresh: refresh)
    }

    private var busy: Bool { model.operationsInProgress }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changes").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let state {
                    branchMenu(state)
                }
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(refreshLabel)
                    .accessibilityIdentifier("git-refresh")
                    .help(refreshLabel)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            Divider()
            if let state {
                files(state)
                Divider()
                diffHeader
                patchContent
                Divider()
                commitBar(state)
            } else if loading {
                ProgressView().controlSize(.small).padding(16)
            } else {
                Text("No Git repository in this workspace.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(12)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .accessibilityIdentifier("git-error")
            }
            if state == nil { Spacer() }
        }
        .frame(minWidth: 290, idealWidth: 360, maxHeight: .infinity)
        .task(id: request) { await loadState() }
        .task(id: DiffRequest(key: request, file: selected, staged: staged)) { await loadPatch() }
    }

    private func branchMenu(_ state: GitRepositoryState) -> some View {
        Menu {
            ForEach(state.branches, id: \.self) { branch in
                Button(branch) {
                    mutate { try await $0.switchBranch(branch) }
                }
                .disabled(branch == state.branch)
            }
        } label: {
            Label(state.branch ?? "Detached HEAD", systemImage: "arrow.triangle.branch")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.caption)
        .disabled(busy)
        .accessibilityIdentifier("git-branch")
    }

    private func files(_ state: GitRepositoryState) -> some View {
        let paths = Set(state.files.map(\.path))
        let trackedPaths = Set(state.files.filter { $0.indexStatus != "?" }.map(\.path))
        return VStack(alignment: .leading, spacing: 0) {
            if !paths.isEmpty {
                HStack {
                    Toggle("Include all files", sources: paths.map(inclusion), isOn: \.self)
                        .toggleStyle(.checkbox)
                        .disabled(busy)
                        .accessibilityIdentifier("git-include-all")
                    Spacer()
                    Text("\(paths.subtracting(excludedPaths).count) of \(paths.count) selected")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("git-selection-count")
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                if state.files.contains(where: { $0.isStaged && excludedPaths.contains($0.path) }) {
                    Text("Committing will unstage the excluded files.")
                        .font(.caption)
                        .padding(.horizontal, 14)
                }
            }
            fileRows(state.files, trackedPaths: trackedPaths)
        }
    }

    private func fileRows(_ files: [GitFileChange], trackedPaths: Set<String>) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if files.isEmpty {
                    Text("Working tree clean")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("git-clean")
                }
                ForEach(files) { file in
                    HStack(spacing: 7) {
                        let trackedRowOwnsInclusion = file.indexStatus == "?" && trackedPaths.contains(file.path)
                        if trackedRowOwnsInclusion {
                            Spacer().frame(width: 14)
                        } else {
                            Toggle("Include \(file.path)", isOn: inclusion(file.path))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .disabled(busy)
                                .accessibilityLabel("Include \(file.path)")
                                .accessibilityIdentifier("git-include-" + file.path)
                                .help("Include \(file.path) in the commit")
                        }
                        Button {
                            selected = file
                            staged = file.worktreeStatus == " " && file.isStaged
                        } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: String([file.indexStatus, file.worktreeStatus]))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(file.path)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(file.path)
                        .accessibilityIdentifier("git-file-" + file.path)
                        if file.worktreeStatus != " " {
                            fileAction("Stage", symbol: "plus", id: "git-stage-", file: file) {
                                try await $0.stage(file)
                            }
                        }
                        if file.isStaged {
                            fileAction("Unstage", symbol: "minus", id: "git-unstage-", file: file) {
                                try await $0.unstage(file)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(selected?.id == file.id ? Color.primary.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(8)
        }
        .frame(height: 124)
    }

    private func inclusion(_ path: String) -> Binding<Bool> {
        Binding {
            !excludedPaths.contains(path)
        } set: { included in
            if included {
                excludedPaths.remove(path)
            } else {
                excludedPaths.insert(path)
            }
        }
    }

    private func fileAction(
        _ title: String, symbol: String, id: String, file: GitFileChange,
        operation: @escaping (GitWorkspace) async throws -> Void
    ) -> some View {
        Button { mutate(operation) } label: { Image(systemName: symbol) }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(title)
            .accessibilityLabel(title + " " + file.path)
            .accessibilityIdentifier(id + file.path)
    }

    private var diffHeader: some View {
        HStack {
            Text(selected?.path ?? "All files")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if selected != nil {
                Button { selected = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show all changes")
            }
            Spacer()
            Picker("Changes", selection: $staged) {
                Text("Unstaged").tag(false)
                Text("Staged").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("git-diff-mode")
        }
        .padding(8)
    }

    private var patchContent: some View {
        ScrollView([.horizontal, .vertical]) {
            if let patchError {
                Text(patchError).font(.callout).foregroundStyle(.red)
                    .padding(10)
            } else if patch.isEmpty {
                Text("No changes to display")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(10)
            } else {
                let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        Text(line.isEmpty ? " " : String(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(diffColor(line))
                            .fixedSize()
                            .textSelection(.enabled)
                    }
                }
                .padding(9)
                .accessibilityIdentifier("git-patch")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private func commitBar(_ state: GitRepositoryState) -> some View {
        let paths = Set(state.files.map(\.path)).subtracting(excludedPaths)
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack {
            TextField("Commit message", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("git-commit-message")
            Button("Commit") {
                mutate { git in
                    try await git.commit(message: message, paths: paths)
                    commitMessage = ""
                }
            }
            .disabled(busy || paths.isEmpty || message.isEmpty)
            .help("Commit the current contents of the included files")
            .accessibilityIdentifier("git-commit")
        }
        .padding(9)
    }

    private func diffColor(_ line: Substring) -> Color {
        switch line.first {
        case "+": .green
        case "-": .red
        case "@": .secondary
        default: .primary
        }
    }

    private func mutate(_ operation: @escaping (GitWorkspace) async throws -> Void) {
        let git = GitWorkspace(path: directory)
        error = nil
        Task {
            do { try await model.performGitMutation { try await operation(git) } }
            catch let failure { error = failure.localizedDescription }
        }
    }

    private func loadState() async {
        let git = GitWorkspace(path: directory)
        defer { if !Task.isCancelled { loading = false } }
        do {
            let newState = try await git.state()
            guard !Task.isCancelled else { return }
            state = newState
            excludedPaths.formIntersection(newState.files.map(\.path))
            if let current = selected {
                selected = newState.files.first(where: { $0.id == current.id })
            }
        } catch {
            if !Task.isCancelled { state = nil }
        }
    }

    private func loadPatch() async {
        do {
            let result = try await GitWorkspace(path: directory).patch(for: selected, staged: staged)
            guard !Task.isCancelled else { return }
            patch = result
            patchError = nil
        } catch let failure {
            guard !Task.isCancelled else { return }
            patch = ""
            patchError = failure.localizedDescription
        }
    }
}
