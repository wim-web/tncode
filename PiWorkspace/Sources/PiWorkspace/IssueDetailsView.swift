import SwiftUI

@MainActor
final class GitHubIssueSessions: ObservableObject {
    private var sessions: [GitHubIssueReference: GitHubIssueSession] = [:]
    @Published private(set) var editedTitles: [GitHubIssueReference: String] = [:]

    private let store: () throws -> WorkspaceStore

    init(store: @escaping () throws -> WorkspaceStore) { self.store = store }

    func session(for reference: GitHubIssueReference) -> GitHubIssueSession {
        if let session = sessions[reference] { return session }
        let session = GitHubIssueSession(reference: reference, store: store) { [weak self] title in
            self?.editedTitles[reference] = title
        }
        sessions[reference] = session
        return session
    }
}

@MainActor
final class GitHubIssueSession: ObservableObject {
    enum Field { case title, description }

    struct Edit {
        let field: Field
        var text: String

        var change: GitHubIssueChange {
            switch field {
            case .title: .title(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .description: .description(text)
            }
        }
    }

    private enum Operation {
        case idle, sending, checking, unconfirmed(GitHubIssueReceipt)
        case restoreFailed, clearFailed(PendingIssueComment, rejection: String?)
    }

    @Published private(set) var operationError: String?
    @Published private(set) var revision = 0
    @Published private var operation = Operation.idle
    @Published var edit: Edit?
    @Published var comment = ""
    private let didEditTitle: (String) -> Void

    private let reference: GitHubIssueReference
    private let store: () throws -> WorkspaceStore

    init(reference: GitHubIssueReference, store: @escaping () throws -> WorkspaceStore, didEditTitle: @escaping (String) -> Void) {
        self.reference = reference
        self.store = store
        self.didEditTitle = didEditTitle
        restorePendingComment()
    }

    private func restorePendingComment() {
        do {
            if let pending = try store().pendingIssueComment(for: reference) {
                comment = pending.body
                operation = .unconfirmed(.comment(pending))
                operationError = GitHubIssueWriteError.commentUnconfirmed.localizedDescription
            } else {
                operation = .idle
                operationError = nil
            }
        } catch {
            operation = .restoreFailed
            operationError = "Couldn’t read the saved comment receipt. \(error.localizedDescription)"
        }
    }

    var busy: Bool {
        switch operation {
        case .sending, .checking: true
        default: false
        }
    }

    var needsCheck: Bool {
        switch operation {
        case .unconfirmed, .restoreFailed, .clearFailed: true
        default: false
        }
    }

    var locked: Bool { busy || needsCheck }

    func beginEditing(_ field: Field, text: String) {
        guard !locked else { return }
        operationError = nil
        edit = Edit(field: field, text: text)
    }

    func cancelEditing() {
        guard !locked else { return }
        operationError = nil
        edit = nil
    }

    func submit(_ change: GitHubIssueChange, expectedID: String,
                via reader: GitHubReader, isCurrent: @escaping @MainActor () -> Bool) {
        guard !locked, isCurrent() else { return }
        do {
            try change.validate()
        } catch {
            operationError = error.localizedDescription
            return
        }
        operation = .sending
        operationError = nil
        Task {
            do {
                _ = try await reader.repository(matching: reference.repository)
                let before = try await reader.issueSnapshot(for: reference)
                guard before.activity.id == expectedID else { throw GitHubIssueWriteError.selectionChanged }
                guard change.isComment || before.activity.viewerCanUpdate else { throw GitHubIssueWriteError.editDenied }
                _ = try await reader.repository(matching: reference.repository)
                guard isCurrent() else { throw GitHubIssueWriteError.selectionChanged }
                if change.matches(title: before.activity.title, body: before.activity.body) {
                    finish(change)
                    return
                }
                let receipt = try GitHubIssueReceipt(change: change, before: before)
                var recorded: PendingIssueComment?
                do {
                    try await reader.writeIssue(change, to: reference) { [self] in
                        guard isCurrent() else { throw GitHubIssueWriteError.selectionChanged }
                        if case .comment(let pending) = receipt {
                            do {
                                try store().setPendingIssueComment(pending, for: reference)
                            } catch {
                                throw WorkspaceError("Couldn’t save the comment receipt before posting. \(error.localizedDescription)")
                            }
                            recorded = pending
                        }
                    }
                    if let recorded { clear(recorded) } else { finish(change) }
                } catch GitHubIssueWriteError.acknowledgementLost {
                    if change.isComment && recorded == nil { throw GitHubIssueWriteError.acknowledgementLost }
                    await reconcile(receipt, via: reader, isCurrent: isCurrent)
                } catch {
                    if let recorded { clear(recorded, rejection: error.localizedDescription) } else { throw error }
                }
            } catch {
                fail(error)
            }
        }
    }

    func check(via reader: GitHubReader, isCurrent: @escaping @MainActor () -> Bool) {
        guard isCurrent() else { return }
        switch operation {
        case .restoreFailed:
            restorePendingComment()
        case .clearFailed(let pending, let rejection):
            clear(pending, rejection: rejection)
        case .unconfirmed(let receipt):
            operation = .checking
            operationError = nil
            Task { await reconcile(receipt, via: reader, isCurrent: isCurrent) }
        default:
            break
        }
    }

    private func reconcile(_ receipt: GitHubIssueReceipt, via reader: GitHubReader, isCurrent: @MainActor () -> Bool) async {
        operation = .checking
        do {
            _ = try await reader.repository(matching: reference.repository)
            let current = try await reader.issueSnapshot(for: reference)
            _ = try await reader.repository(matching: reference.repository)
            guard isCurrent() else { throw GitHubIssueWriteError.selectionChanged }
            switch receipt {
            case .comment(let pending):
                guard pending.isVisible(in: current) else { throw GitHubIssueWriteError.commentUnconfirmed }
                clear(pending)
            case .edit(let change, let issueID):
                guard current.activity.id == issueID else { throw GitHubIssueWriteError.selectionChanged }
                if change.matches(title: current.activity.title, body: current.activity.body) {
                    finish(change)
                } else {
                    fail(GitHubIssueWriteError.editUnconfirmed)
                    revision += 1
                }
            }
        } catch {
            operation = .unconfirmed(receipt)
            operationError = error.localizedDescription
        }
    }

    private func clear(_ pending: PendingIssueComment, rejection: String? = nil) {
        do {
            try store().setPendingIssueComment(nil, for: reference)
            if let rejection {
                operation = .idle
                operationError = rejection
            } else {
                finish(.comment(pending.body))
            }
        } catch {
            operation = .clearFailed(pending, rejection: rejection)
            operationError = "Couldn’t clear the saved comment receipt. \(error.localizedDescription)"
        }
    }

    private func finish(_ change: GitHubIssueChange) {
        if change.isComment {
            comment = ""
        } else {
            edit = nil
            if case .title(let title) = change { didEditTitle(title) }
        }
        operation = .idle
        operationError = nil
        revision += 1
    }

    private func fail(_ error: Error) {
        operation = .idle
        operationError = error.localizedDescription
    }
}

struct IssueDetailsView: View {
    private struct Loaded {
        let issue: GitHubIssueDetails
        let snapshot: GitHubIssueSnapshot?
        let writeBlocked: String?
    }

    private struct Reload: Hashable {
        let refresh: Int
        let revision: Int
    }

    let number: Int
    let reader: GitHubReader
    @ObservedObject var session: GitHubIssueSession
    let localSelectionIsCurrent: @MainActor () -> Bool
    var isLinked: ((GitHubIssueReference) -> Bool)? = nil
    var changeLink: ((GitHubIssueReference, Bool) -> Void)? = nil
    let read: () async throws -> GitHubIssueDetails
    @Environment(\.openURL) private var openURL
    @FocusState private var focus: GitHubIssueSession.Field?
    @State private var refresh = 0
    @State private var loaded: Loaded?
    @State private var loading = true
    @State private var readError: String?
    @State private var presentation = UUID()
    @State private var previewDescription = false

    var body: some View {
        Group {
            if let loaded {
                ScrollView {
                    summary(loaded)
                }
            } else if let readError {
                errorAndRetry(readError)
                    .padding(24)
            } else {
                ProgressView("Loading #\(number)…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: Reload(refresh: refresh, revision: session.revision)) { await load() }
        .onDisappear { presentation = UUID() }
    }

    private func summary(_ loaded: Loaded) -> some View {
        let issue = loaded.issue
        let activity = loaded.snapshot?.activity
        let canEdit = loaded.writeBlocked == nil && activity?.viewerCanUpdate == true
        let currentTitle = activity?.title ?? issue.title
        let currentBody = activity?.body ?? issue.body
        return VStack(alignment: .leading, spacing: 10) {
            if session.edit?.field == .title {
                TextField("Issue title", text: editText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .title)
                    .accessibilityIdentifier("issue-title-editor")
                    .disabled(session.locked)
                    .onSubmit { save(loaded) }
                    .onExitCommand { session.cancelEditing() }
                editActions("title", loaded: loaded)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "#\(issue.number) \(currentTitle)")
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("issue-detail-title")
                    if canEdit && session.edit == nil {
                        editButton("Edit title", id: "issue-edit-title") {
                            session.beginEditing(.title, text: currentTitle)
                            focus = .title
                        }
                    }
                }
            }
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
            issueActions(issue)
            if let readError { errorAndRetry(readError) }
            if let error = session.operationError {
                Text(error)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("issue-write-error")
            }
            if session.busy {
                ProgressView("Contacting GitHub…")
                    .controlSize(.small)
                    .accessibilityIdentifier("issue-write-progress")
            }
            if session.needsCheck {
                Button("Check result") {
                    session.check(via: reader, isCurrent: localSelectionIsCurrent)
                }
                .accessibilityIdentifier("issue-write-check")
            }
            Divider()
            HStack {
                Text("Description").font(.headline)
                Spacer()
                if canEdit && session.edit == nil {
                    editButton("Edit description", id: "issue-edit-description") {
                        previewDescription = false
                        session.beginEditing(.description, text: currentBody)
                        focus = .description
                    }
                }
            }
            if session.edit?.field == .description {
                descriptionEditor(loaded)
            } else if currentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("issue-detail-body-empty")
            } else {
                Text(verbatim: currentBody)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("issue-detail-body")
            }
            if let activity { comments(activity.comments, reference: issue.reference) }
            if let blocked = loaded.writeBlocked {
                Text(blocked)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("issue-write-blocked")
            }
            if activity != nil || !session.comment.isEmpty { composer(loaded) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var editText: Binding<String> {
        Binding(get: { session.edit?.text ?? "" }, set: { session.edit?.text = $0 })
    }

    private func editButton(_ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "pencil") }
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            .disabled(session.locked)
    }

    private func descriptionEditor(_ loaded: Loaded) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Markdown editor mode", selection: $previewDescription) {
                Text("Write").tag(false)
                Text("Preview").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("issue-description-mode")
            .disabled(session.locked)
            if previewDescription {
                let text = editText.wrappedValue
                if text.isEmpty {
                    Text("No description").foregroundStyle(.secondary)
                } else if let markdown = try? AttributedString(markdown: text) {
                    WorkspaceMarkdownView(markdown: markdown, openLink: { openURL($0) },
                                          accessibilityID: "issue-description-preview")
                        .id(text)
                        .frame(height: 104)
                } else {
                    Text(verbatim: text)
                }
            } else {
                TextEditor(text: editText)
                    .frame(height: 104)
                    .focused($focus, equals: .description)
                    .accessibilityLabel("Description")
                    .accessibilityIdentifier("issue-description-editor")
                    .disabled(session.locked)
                    .onExitCommand { session.cancelEditing() }
            }
            editActions("description", loaded: loaded)
        }
    }

    private func editActions(_ field: String, loaded: Loaded) -> some View {
        HStack {
            Button("Save") { save(loaded) }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("issue-\(field)-save")
                .disabled(session.locked || loaded.writeBlocked != nil)
            Button("Cancel") { session.cancelEditing() }
                .accessibilityIdentifier("issue-\(field)-cancel")
                .disabled(session.locked)
        }
    }

    private func issueActions(_ issue: GitHubIssueDetails) -> some View {
        HStack {
            if let isLinked, let changeLink {
                let linked = isLinked(issue.reference)
                Button(linked ? "Unlink from thread" : "Link to thread") { changeLink(issue.reference, linked) }
                    .accessibilityIdentifier(linked ? "issue-unlink-from-thread" : "issue-link-to-thread")
            }
            Link(destination: issue.url) {
                Label("Open on GitHub", systemImage: "arrow.up.right.square")
            }
            .accessibilityIdentifier("issue-open")
            Spacer()
            Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh issue")
                .accessibilityLabel("Refresh issue")
                .accessibilityIdentifier("issue-detail-refresh")
                .disabled(loading || session.busy)
        }
    }

    private func comments(_ comments: GitHubIssueActivity.Comments, reference: GitHubIssueReference) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(comments.totalCount > 0 ? "Activity (\(comments.totalCount))" : "Activity")
                .font(.headline)
                .accessibilityIdentifier("issue-activity")
            if comments.nodes.isEmpty {
                Text("No comments").foregroundStyle(.secondary)
            } else if comments.nodes.count < comments.totalCount {
                Text("Showing the latest \(comments.nodes.count) comments").foregroundStyle(.secondary)
            }
            ForEach(comments.nodes) { comment in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(comment.author.map { "@\($0.login)" } ?? "Unknown author")
                        if let url = URL(string: comment.url), GitHubIssueReference(url: comment.url) == reference {
                            Link(destination: url) { Text(comment.createdAt, style: .date) }
                        } else {
                            Text(comment.createdAt, style: .date)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(verbatim: comment.body)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("issue-comment-body-\(comment.id)")
                }
            }
        }
    }

    private func composer(_ loaded: Loaded) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $session.comment)
                .frame(height: 58)
                .accessibilityLabel("Add a comment")
                .accessibilityIdentifier("issue-comment-editor")
                .disabled(session.locked || loaded.writeBlocked != nil)
            Button("Comment") { submit(.comment(session.comment), loaded: loaded) }
                .keyboardShortcut(session.edit == nil ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .accessibilityIdentifier("issue-comment-submit")
                .disabled(session.locked || loaded.writeBlocked != nil
                          || session.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func errorAndRetry(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .accessibilityIdentifier("issue-detail-error")
            Button("Retry") { refresh += 1 }
                .accessibilityIdentifier("issue-detail-retry")
                .disabled(loading || session.busy)
        }
    }

    private func save(_ loaded: Loaded) {
        guard let change = session.edit?.change else { return }
        submit(change, loaded: loaded)
    }

    private func submit(_ change: GitHubIssueChange, loaded: Loaded) {
        guard loaded.writeBlocked == nil, let id = loaded.snapshot?.activity.id else { return }
        let shown = presentation
        session.submit(change, expectedID: id, via: reader) {
            presentation == shown && localSelectionIsCurrent()
        }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let issue = try await read()
            guard !Task.isCancelled else { return }
            let snapshot: GitHubIssueSnapshot
            do {
                snapshot = try await reader.issueSnapshot(for: issue.reference)
            } catch {
                guard !Task.isCancelled else { return }
                loaded = Loaded(issue: issue, snapshot: nil, writeBlocked: error.localizedDescription)
                readError = nil
                return
            }
            let repository = try? await reader.repository()
            guard !Task.isCancelled else { return }
            let blocked = repository == issue.reference.repository
                ? nil : "Writing is available for issues in the selected checkout’s GitHub repository."
            loaded = Loaded(issue: issue, snapshot: snapshot, writeBlocked: blocked)
            readError = nil
        } catch {
            guard !Task.isCancelled else { return }
            readError = error.localizedDescription
        }
    }
}
