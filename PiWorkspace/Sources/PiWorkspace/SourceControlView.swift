import AppKit
import SwiftUI

struct SourceControlView: View {
    let location: WorkspaceFilesLocation
    @ObservedObject var model: WorkspaceModel
    let openBranch: () -> Void
    let copyBranch: (String) -> Void
    let openFile: (String) -> Void
    @AppStorage(DiffPreferences.wordWrap) private var defaultWordWrap = DiffPreferences.defaultWordWrap
    @AppStorage(DiffPreferences.ignoreWhitespace) private var defaultIgnoreWhitespace = DiffPreferences.defaultIgnoreWhitespace
    @State private var wordWrapOverride: Bool?
    @State private var state: GitRepositoryState?
    @State private var selected: GitFileChange?
    @State private var excludedPaths: Set<String> = []
    @State private var stage = Stage.all
    @State private var commitMessage = ""
    @State private var commitGeneration: Task<Void, Never>?
    @State private var error: String?
    @State private var loading = true
    @State private var refresh = 0
    @State private var scope = GitChangesScope.changes
    @State private var baseRef: String?
    @State private var comparisonSelection: GitChangesFile?
    @State private var scopeRevision = 0
    @State private var fileRevision = 0
    @State private var chooser: Chooser?
    @State private var refSearch = ""
    @State private var checkoutResult: (ReadRequest, GitChangesCheckout)?
    @State private var checkoutError: (ReadRequest, String)?
    @State private var reviewResult: (ReviewRequest, Review)?
    @State private var reviewError: (ReviewRequest, String)?
    @State private var historyResult: (HistoryRequest, [GitChangesCommit])?
    @State private var historyError: (HistoryRequest, String)?
    @State private var patchResult: (DiffRequest, String)?
    @State private var patchError: (DiffRequest, String)?

    private let refreshLabel = "Refresh Git changes"

    private struct ReadRequest: Hashable {
        let location: String
        let revision: Int
        let refresh: Int
    }

    private enum Stage: Hashable {
        case all, unstaged, staged
    }

    private enum Chooser {
        case scope, base
    }

    private struct HistoryRequest: Hashable {
        let key: ReadRequest
        let baseRef: String?
    }

    private struct ReviewRequest: Hashable {
        let key: ReadRequest
        let scope: GitChangesScope
        let baseRef: String?
        let scopeRevision: Int
        let ignoringWhitespace: Bool
    }

    private struct Review {
        let target: GitChangesTarget
        let files: [GitChangesFile]
    }

    private struct DiffRequest: Hashable {
        let key: ReviewRequest
        let reviewFile: GitChangesFile?
        let workingFile: GitFileChange?
        let stage: Stage
        let fileRevision: Int
        let hasFileSelection: Bool
    }

    private var request: ReadRequest {
        ReadRequest(location: directory, revision: model.repositoryRevision, refresh: refresh)
    }

    private var directory: String { location.directory }
    private var busy: Bool { model.operationsInProgress || commitGeneration != nil }
    private var wraps: Bool { wordWrapOverride ?? defaultWordWrap }
    private var ignoringWhitespace: Bool { model.changesIgnoreWhitespaceOverride ?? defaultIgnoreWhitespace }

    private var checkout: GitChangesCheckout? {
        checkoutResult?.0 == request ? checkoutResult?.1 : nil
    }

    private var historyRequest: HistoryRequest? {
        guard checkout != nil, chooser == .scope else { return nil }
        return HistoryRequest(key: request, baseRef: baseRef)
    }

    private var reviewRequest: ReviewRequest? {
        guard checkout != nil else { return nil }
        return ReviewRequest(key: request, scope: scope, baseRef: scope == .changes ? baseRef : nil,
                             scopeRevision: scopeRevision, ignoringWhitespace: ignoringWhitespace)
    }

    private var review: Review? {
        guard let reviewRequest, reviewResult?.0 == reviewRequest else { return nil }
        return reviewResult?.1
    }

    private var reviewFile: GitChangesFile? {
        let selectedID = scope == .uncommitted ? selected?.id : comparisonSelection?.id
        return review?.files.first { $0.id == selectedID }
    }

    private var diffRequest: DiffRequest? {
        guard let reviewRequest, review != nil else { return nil }
        return DiffRequest(key: reviewRequest, reviewFile: reviewFile, workingFile: selected, stage: stage,
                           fileRevision: fileRevision, hasFileSelection: selected != nil || comparisonSelection != nil)
    }

    var body: some View {
        let read = request
        let activeCheckout = checkout
        let history = historyRequest
        let comparison = reviewRequest
        let activeReview = review
        let diff = diffRequest
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Changes").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let state {
                    ThreadBranchButton(branch: state.branch, open: openBranch, copy: copyBranch)
                        .font(.caption)
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
                comparisonControls
                if scope == .uncommitted {
                    files(state)
                } else if let activeReview {
                    comparisonFiles(activeReview.files)
                }
                Divider()
                diffHeader
                patchContent
                if scope == .changes && !state.files.isEmpty {
                    Divider()
                    Text("Working Tree").font(.caption.weight(.medium))
                        .padding(.horizontal, 12).padding(.top, 8)
                    files(state)
                }
                if managesWorkingTree {
                    Divider()
                    commitBar(state)
                }
            } else if loading {
                ProgressView().controlSize(.small).padding(16)
            } else if checkoutError?.0 == read, let message = checkoutError?.1 {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(12)
                    .accessibilityIdentifier("git-review-error")
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
        .onDisappear { commitGeneration?.cancel() }
        .task(id: read) { await loadCheckout(read) }
        .task(id: history) {
            if let history, let activeCheckout { await loadHistory(history, checkout: activeCheckout) }
        }
        .task(id: comparison) {
            if let comparison, let activeCheckout { await loadReview(comparison, checkout: activeCheckout) }
        }
        .task(id: diff) {
            if let diff, let activeReview { await loadPatch(diff, review: activeReview) }
        }
    }

    private var managesWorkingTree: Bool {
        if case .commit = scope { return false }
        return true
    }

    private var comparisonControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    chooser = chooser == .scope ? nil : .scope
                } label: {
                    Label(scope.label, systemImage: "chevron.down")
                }
                .accessibilityLabel("Diff scope: \(scope.label)")
                .accessibilityIdentifier("git-review-scope")
                if case .commit(let commit) = scope {
                    commitLink(commit, id: "git-review-open-selected-commit")
                }
                Spacer()
                let wrapHelp = wraps ? "Disable line wrapping" : "Enable line wrapping"
                diffToggle(wraps ? "Disable diff line wrapping" : "Enable diff line wrapping",
                           help: wrapHelp, icon: "text.word.spacing", id: "git-review-word-wrap", active: wraps) {
                    wordWrapOverride = !wraps
                }
                let whitespaceLabel = ignoringWhitespace ? "Show whitespace changes" : "Hide whitespace changes"
                diffToggle(whitespaceLabel, help: whitespaceLabel, icon: "paragraphsign",
                           id: "git-review-whitespace", active: ignoringWhitespace) {
                    model.changesIgnoreWhitespaceOverride = !ignoringWhitespace
                }
            }
            if scope == .changes {
                let head = checkout?.headLabel ?? state?.branch ?? "HEAD"
                HStack {
                    Text(head).lineLimit(1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(head)
                        .accessibilityIdentifier("git-review-head")
                    Text("vs").foregroundStyle(.secondary)
                    baseButton
                    Spacer(minLength: 0)
                }
            }
            switch chooser {
            case .scope: scopeChoices
            case .base: baseChoices
            case nil: EmptyView()
            }
        }
        .font(.caption)
        .padding(8)
    }

    private func diffToggle(_ label: String, help: String, icon: String, id: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 22, height: 20)
                .background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "On" : "Off")
        .accessibilityIdentifier(id)
    }

    private var baseButton: some View {
        let label = baseRef.map { ref in
            GitBranchRef.displayName(ref) + (ref.hasPrefix("refs/remotes/") ? " (Remote)" : "")
        } ??
            (checkout?.automaticRef.map { "Automatic (\(GitBranchRef.displayName($0)))" } ?? "Automatic (HEAD)")
        return Button {
            refSearch = ""
            chooser = chooser == .base ? nil : .base
        } label: {
            Label(label, systemImage: "chevron.down").lineLimit(1)
        }
        .accessibilityLabel("Change comparison target. Currently \(label)")
        .accessibilityIdentifier("git-review-base")
    }

    private var scopeChoices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                choice("Changes", id: "git-review-scope-changes") { selectScope(.changes) }
                choice("Uncommitted", id: "git-review-scope-uncommitted") { selectScope(.uncommitted) }
                if let historyRequest {
                    if historyResult?.0 == historyRequest, let commits = historyResult?.1 {
                        ForEach(commits) { commit in
                            HStack {
                                choice(commit.label, id: "git-review-commit-" + commit.id) {
                                    selectScope(.commit(commit))
                                }
                                commitLink(commit, id: "git-review-open-commit-" + commit.id)
                            }
                        }
                    } else if historyError?.0 == historyRequest, let message = historyError?.1 {
                        Text(message).foregroundStyle(.red)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 124)
    }

    @ViewBuilder
    private func commitLink(_ commit: GitChangesCommit, id: String) -> some View {
        if let repository = checkout?.repository, let url = commit.webURL(in: repository) {
            Link(destination: url) {
                Image(systemName: "arrow.up.right.square")
            }
            .help(url.absoluteString)
            .accessibilityLabel("Open commit \(commit.shortID)")
            .accessibilityIdentifier(id)
        }
    }

    private var baseChoices: some View {
        let query = refSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = checkout?.baseChoices.filter { $0.matches(query) } ?? []
        return VStack(alignment: .leading, spacing: 4) {
            TextField("Search refs…", text: $refSearch)
                .accessibilityIdentifier("git-review-ref-search")
            if candidates.contains(where: { $0.remote != nil }) {
                HStack {
                    Text("Branch")
                    Spacer()
                    Text("Remote")
                }
                .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if query.isEmpty {
                        choice("Automatic", id: "git-review-base-automatic") { selectBase(nil) }
                    } else if candidates.isEmpty {
                        Text("No matching refs.").foregroundStyle(.secondary)
                    }
                    ForEach(candidates, content: baseChoice)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 124)
        }
    }

    private func baseChoice(_ candidate: GitChangesBaseChoice) -> some View {
        let primary = candidate.primary
        let useRemote = candidate.remote.map { baseRef?.utf8.elementsEqual($0.id.utf8) == true } ?? false
        return HStack {
            choice(candidate.label, id: "git-review-base-" + primary.id) {
                selectBase(((useRemote ? candidate.remote : nil) ?? primary).id)
            }
            if let remote = candidate.remote {
                let label = "Use remote version of \(primary.name)"
                Toggle(label, isOn: Binding(get: { useRemote }, set: { remoteOn in
                    selectBase(remoteOn ? remote.id : primary.id, keepChooser: true)
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(label)
                .accessibilityLabel(label)
                .accessibilityIdentifier("git-review-base-remote-" + primary.id)
            }
        }
    }

    private func choice(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .help(label)
    }

    private func selectScope(_ next: GitChangesScope) {
        scope = next
        comparisonSelection = nil
        selected = nil
        stage = .all
        scopeRevision += 1
        chooser = nil
    }

    private func selectBase(_ ref: String?, keepChooser: Bool = false) {
        baseRef = ref
        selectScope(.changes)
        if keepChooser { chooser = .base }
    }

    private func comparisonFiles(_ files: [GitChangesFile]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(files) { file in
                    let label = file.previousPath.map { "\($0) → \(file.path)" } ?? file.path
                    choice("\(file.status)  \(label)", id: "git-review-file-" + (file.isUntracked ? "untracked-" : "") + file.path) {
                        comparisonSelection = file
                        fileRevision += 1
                    }
                    .padding(4)
                    .background(comparisonSelection?.id == file.id ? Color.primary.opacity(0.08) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxHeight: files.isEmpty ? 0 : 100)
    }

    private func files(_ state: GitRepositoryState) -> some View {
        let paths = Set(state.files.map(\.path))
        let trackedPaths = Set(state.files.filter { $0.indexStatus != "?" }.map(\.path))
        let selectionCount = "\(paths.subtracting(excludedPaths).count) of \(paths.count) selected"
        return VStack(alignment: .leading, spacing: 0) {
            if !paths.isEmpty {
                HStack {
                    Toggle("Include all files", sources: paths.map(inclusion), isOn: \.self)
                        .toggleStyle(.checkbox)
                        .disabled(busy)
                        .accessibilityIdentifier("git-include-all")
                    Spacer()
                    Text(selectionCount)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(selectionCount)
                        .accessibilityIdentifier("git-selection-count")
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                if !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   state.files.contains(where: { $0.isStaged && excludedPaths.contains($0.path) }) {
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
                            if scope != .uncommitted { selectScope(.uncommitted) }
                            selected = file
                            stage = file.worktreeStatus == " " && file.isStaged ? .staged : .unstaged
                            fileRevision += 1
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
            if let path = selected?.path ?? comparisonSelection?.path {
                if managesWorkingTree, let relative = state?.workspacePath(for: path) {
                    Button { openFile(relative) } label: {
                        Text(path).lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Open Source File")
                    .accessibilityIdentifier("git-open-source")
                } else {
                    Text(path).lineLimit(1).truncationMode(.middle)
                }
                Button {
                    selected = nil
                    comparisonSelection = nil
                    fileRevision += 1
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show all changes")
                    .accessibilityIdentifier("git-review-all-files")
            } else {
                Text("All files").font(.caption.weight(.medium))
            }
            Spacer()
            if scope == .uncommitted {
                Picker("Changes", selection: Binding(get: { stage }, set: {
                    stage = $0
                    fileRevision += 1
                })) {
                    Text("All").tag(Stage.all)
                    Text("Unstaged").tag(Stage.unstaged)
                    Text("Staged").tag(Stage.staged)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("git-diff-mode")
            }
        }
        .font(.caption.weight(.medium))
        .padding(8)
    }

    private var patchContent: some View {
        Group {
            if checkoutError?.0 == request, let message = checkoutError?.1 {
                reviewFailure(message)
            } else if let reviewRequest, reviewError?.0 == reviewRequest, let message = reviewError?.1 {
                reviewFailure(message)
            } else if let diffRequest, patchError?.0 == diffRequest, let message = patchError?.1 {
                reviewFailure(message)
            } else if let diffRequest, patchResult?.0 == diffRequest, let patch = patchResult?.1 {
                if patch.isEmpty {
                    Text("No changes to display").font(.callout).foregroundStyle(.secondary)
                        .padding(10)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("No changes to display")
                        .accessibilityIdentifier("git-review-empty")
                } else {
                    ScrollView(wraps ? .vertical : [.horizontal, .vertical]) {
                        patchLines(patch)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
                    .padding(10)
                    .accessibilityIdentifier("git-review-loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private func reviewFailure(_ message: String) -> some View {
        Text(message).font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true).padding(10)
            .accessibilityIdentifier("git-review-error")
    }

    private func patchLines(_ patch: String) -> some View {
        let lines = patch.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let rawLine = lines[index]
                let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine
                Text(line.isEmpty ? " " : String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(diffColor(line.first))
                    .fixedSize(horizontal: !wraps, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(9)
        .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
        .accessibilityIdentifier("git-patch")
        .id(diffRequest)
    }

    private func commitBar(_ state: GitRepositoryState) -> some View {
        let paths = Set(state.files.map(\.path)).subtracting(excludedPaths)
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return Group {
            if let generation = commitGeneration, !model.gitMutationInProgress {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Generating commit message…")
                        .font(.callout)
                        .accessibilityIdentifier("git-commit-generating")
                    Spacer()
                    Button("Cancel") { generation.cancel() }
                        .accessibilityIdentifier("git-commit-cancel")
                }
            } else {
                HStack {
                    CommitMessageField(message: $commitMessage)
                        .disabled(busy)
                        .accessibilityIdentifier("git-commit-message")
                    Button("Commit") {
                        if message.isEmpty, let checkout {
                            generateAndCommit(paths, checkout: checkout)
                        } else if !message.isEmpty {
                            mutate { git in
                                try await git.commit(message: message, paths: paths)
                                commitMessage = ""
                            }
                        }
                    }
                    .disabled(busy || paths.isEmpty || checkout == nil)
                    .help("Commit the current contents of the included files")
                    .accessibilityIdentifier("git-commit")
                }
            }
        }
        .padding(9)
    }

    private func generateAndCommit(_ paths: Set<String>, checkout: GitChangesCheckout) {
        let git = GitWorkspace(path: directory)
        let inheritedModel = model.effectiveModel
        let writing = model.commitWritingSettings
        let revision = model.repositoryRevision
        func verifyLocation() throws {
            try Task.checkCancellation()
            guard let project = model.project, let thread = model.conversation,
                  WorkspaceFilesLocation(thread: thread, project: project) == location,
                  model.repositoryRevision == revision else {
                throw WorkspaceError("The checkout changed. Review the changes and try again.")
            }
        }
        error = nil
        commitGeneration = Task {
            defer { commitGeneration = nil }
            do {
                let context = try await git.commitContext(paths: paths, checkout: checkout.revision,
                                                          includeRelatedSubjects: writing.style == .repository)
                try verifyLocation()
                let message = try await model.generateCommitMessage(context, writing: writing, inheritedModel: inheritedModel)
                try verifyLocation()
                try await model.performGitMutation {
                    try await git.commit(message: message, paths: paths, generatedFrom: context)
                }
                commitMessage = ""
            } catch is CancellationError {
            } catch let failure {
                error = failure.localizedDescription
            }
        }
    }

    private func diffColor(_ prefix: Unicode.Scalar?) -> Color {
        switch prefix {
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

    private func loadCheckout(_ key: ReadRequest) async {
        let git = GitWorkspace(path: key.location)
        defer { if !Task.isCancelled, key == request { loading = false } }
        do {
            let checkout = try await git.changesCheckout()
            let newState = try await git.state()
            try await git.verifyChangesCheckout(checkout)
            guard !Task.isCancelled, key == request else { return }
            state = newState
            checkoutResult = (key, checkout)
            checkoutError = nil
            excludedPaths.formIntersection(newState.files.map(\.path))
            if let current = selected {
                selected = newState.files.first(where: { $0.id == current.id })
            }
        } catch let failure {
            guard !Task.isCancelled, key == request else { return }
            state = nil
            checkoutResult = nil
            checkoutError = (key, failure.localizedDescription)
        }
    }

    private func loadHistory(_ key: HistoryRequest, checkout: GitChangesCheckout) async {
        do {
            let commits = try await GitWorkspace(path: key.key.location).changesCommits(checkout, selectedBase: key.baseRef)
            guard !Task.isCancelled, key == historyRequest else { return }
            historyResult = (key, commits)
            historyError = nil
        } catch {
            guard !Task.isCancelled, key == historyRequest else { return }
            historyResult = nil
            historyError = (key, error.localizedDescription)
        }
    }

    private func loadReview(_ key: ReviewRequest, checkout: GitChangesCheckout) async {
        do {
            let git = GitWorkspace(path: key.key.location)
            let target = try await git.changesTarget(key.scope, checkout: checkout, selectedBase: key.baseRef)
            let files = try await git.changedFiles(in: target, ignoringWhitespace: key.ignoringWhitespace && key.scope != .uncommitted)
            guard !Task.isCancelled, key == reviewRequest else { return }
            reviewResult = (key, Review(target: target, files: files))
            reviewError = nil
        } catch {
            guard !Task.isCancelled, key == reviewRequest else { return }
            reviewResult = nil
            reviewError = (key, error.localizedDescription)
        }
    }

    private func loadPatch(_ key: DiffRequest, review: Review) async {
        do {
            let git = GitWorkspace(path: key.key.key.location)
            let patch: String
            if key.key.scope == .uncommitted && key.stage != .all {
                patch = try await git.patch(for: key.workingFile, staged: key.stage == .staged,
                                            ignoringWhitespace: key.key.ignoringWhitespace, cancellable: true)
                try await git.verifyChangesCheckout(review.target.checkout)
            } else if key.hasFileSelection && key.reviewFile == nil {
                patch = ""
            } else {
                patch = try await git.changesPatch(in: review.target, file: key.reviewFile, files: review.files,
                                                   ignoringWhitespace: key.key.ignoringWhitespace)
            }
            guard !Task.isCancelled, key == diffRequest else { return }
            patchResult = (key, patch)
            patchError = nil
        } catch {
            guard !Task.isCancelled, key == diffRequest else { return }
            patchResult = nil
            patchError = (key, error.localizedDescription)
        }
    }
}

private struct CommitMessageField: NSViewRepresentable {
    @Binding var message: String

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.bezelStyle = .roundedBezel
        field.placeholderString = "Leave empty to auto-generate"
        field.setAccessibilityLabel("Commit message")
        field.setAccessibilityIdentifier("git-commit-message")
        field.delegate = field
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        field.isEnabled = context.environment.isEnabled
        field.messageChanged = { message = $0 }
        if field.stringValue != message { field.stringValue = message }
    }

    final class Field: NSTextField, NSTextFieldDelegate {
        var messageChanged: ((String) -> Void)?

        func controlTextDidChange(_ notification: Notification) {
            messageChanged?(stringValue)
        }

        override func setAccessibilityValue(_ value: Any?) {
            guard isEnabled, let text = value as? String else { return }
            super.setAccessibilityValue(value)
            messageChanged?(text)
        }
    }
}
