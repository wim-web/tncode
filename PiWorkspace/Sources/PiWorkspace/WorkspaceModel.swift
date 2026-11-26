import AppKit
import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
    enum Phase: Equatable {
        case closed, connecting, ready, running, stopping

        var isRunning: Bool { self == .running || self == .stopping }
    }

    @Published private(set) var workspace = Workspace()
    @Published private(set) var phase: Phase = .closed
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var partial = ""
    @Published private(set) var activity = ""
    @Published private(set) var gitMutationInProgress = false
    @Published private(set) var preparingWorktree = false
    @Published private(set) var repositoryRevision = 0
    @Published var draft = ""
    @Published var error: String?
    @Published var showingSettings = false
    @Published var showArchive = false
    @Published var projectPicker: ProjectPickerRequest?

    private var store: WorkspaceStore?
    private let vault: KeyVault
    private var process: PiProcess?
    private var firstPrompt: String?

    init(root: URL, keychainService: String) {
        vault = KeyVault(service: keychainService)
        do {
            let store = try WorkspaceStore(root: root)
            workspace = try store.load()
            self.store = store
        } catch {
            self.error = error.localizedDescription
        }
    }

    var projects: [Project] { workspace.projects.filter { $0.detached != true } }
    var project: Project? { projects.first { $0.id == workspace.selectedProject } }
    var conversation: Conversation? {
        guard let project else { return nil }
        return project.conversations.first { $0.id == project.selectedConversation }
    }
    var workingDirectory: String? {
        guard let project, let conversation else { return nil }
        return conversation.workingLocation.directory(in: project)
    }
    var operationsInProgress: Bool { phase.isRunning || gitMutationInProgress || preparingWorktree }
    var canChangeWorkspace: Bool {
        guard !operationsInProgress,
              let store, let project, let conversation, !conversation.archived else { return false }
        let history = store.history(project: project.id, conversation: conversation.id)
        do {
            return try !FileManager.default.contentsOfDirectory(atPath: history.path)
                .contains { $0.hasSuffix(".jsonl") }
        } catch let error as CocoaError {
            return error.code == .fileReadNoSuchFile
        } catch {
            return false
        }
    }
    var canSend: Bool {
        phase == .ready && !operationsInProgress && conversation?.archived == false &&
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start() {
        if process == nil { connect() }
    }

    func shutdown() {
        process?.close()
        process = nil
        phase = .closed
    }

    @discardableResult
    private func save(_ edit: (inout Workspace) -> Void) -> Bool {
        guard let store else { return false }
        var updated = workspace
        edit(&updated)
        do {
            try store.save(updated)
            workspace = updated
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func openFolder(relinking id: UUID? = nil, startThread: Bool = false) {
        guard !operationsInProgress else { return }
        projectPicker = ProjectPickerRequest(relinking: id, startThread: startThread,
                                             initialPath: projects.first(where: { $0.id == id })?.path ?? "")
    }

    func openProject(_ url: URL, request: ProjectPickerRequest? = nil) throws {
        guard !operationsInProgress else {
            throw WorkspaceError("Wait for the current operation before switching projects.")
        }
        let folder = url.resolvingSymlinksInPath().standardizedFileURL
        guard folder.isFileURL, (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw WorkspaceError("Choose an existing folder.")
        }
        let existing = workspace.projects.firstIndex { $0.path == folder.path }
        let index: Int?
        if let relinking = request?.relinking {
            index = workspace.projects.firstIndex { $0.id == relinking }
            guard let index, existing == nil || existing == index else {
                throw WorkspaceError("That folder already belongs to another project.")
            }
        } else {
            index = existing
        }
        let previous = project
        guard save({
            if let index {
                $0.projects[index].path = folder.path
                $0.projects[index].detached = false
                $0.selectedProject = $0.projects[index].id
            } else {
                let project = Project(id: UUID(), path: folder.path, title: folder.lastPathComponent)
                $0.projects.append(project)
                $0.selectedProject = project.id
            }
        }) else { throw WorkspaceError(error ?? "Could not save the project.") }
        if request?.startThread == true {
            addConversation()
        } else if previous?.id != project?.id || previous?.path != project?.path {
            draft = ""
            connect()
        }
    }

    func selectProject(_ id: UUID) {
        guard !operationsInProgress, workspace.selectedProject != id else { return }
        guard save({ $0.selectedProject = id }) else { return }
        draft = ""
        connect()
    }

    func removeProject(_ id: UUID) {
        guard !operationsInProgress,
              let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return }
        let selected = workspace.selectedProject == id
        guard save({
            $0.projects[index].detached = true
            if selected { $0.selectedProject = $0.projects.first { $0.detached != true }?.id }
        }) else { return }
        if selected {
            draft = ""
            connect()
        }
    }

    func renameProject(_ id: UUID, title: String) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return }
        save { $0.projects[index].title = title }
    }

    func addConversation(in requestedProject: UUID? = nil) {
        guard !operationsInProgress else { return }
        let projectID = requestedProject ?? project?.id ?? projects.first?.id
        guard let index = workspace.projects.firstIndex(where: { $0.id == projectID && $0.detached != true }) else {
            openFolder(startThread: true)
            return
        }
        let thread = Conversation(id: UUID(), title: "New thread", lastActiveAt: Date())
        guard save({
            $0.selectedProject = $0.projects[index].id
            $0.projects[index].conversations.insert(thread, at: 0)
            $0.projects[index].selectedConversation = thread.id
        }) else { return }
        draft = ""
        showArchive = false
        connect()
    }

    func selectConversation(_ id: UUID, in projectID: UUID) {
        guard !operationsInProgress,
              let index = workspace.projects.firstIndex(where: { $0.id == projectID && $0.detached != true }),
              workspace.projects[index].conversations.contains(where: { $0.id == id }),
              conversation?.id != id else { return }
        guard save({
            $0.selectedProject = projectID
            $0.projects[index].selectedConversation = id
        }) else { return }
        draft = ""
        connect()
    }

    func renameConversation(_ id: UUID, in projectID: UUID, title: String) {
        guard let p = workspace.projects.firstIndex(where: { $0.id == projectID }),
              let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == id }) else { return }
        save { $0.projects[p].conversations[t].title = title }
    }

    func archiveConversation(_ id: UUID, in projectID: UUID, archived: Bool) {
        guard !operationsInProgress, let p = workspace.projects.firstIndex(where: { $0.id == projectID }),
              let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == id }) else { return }
        if save({ $0.projects[p].conversations[t].archived = archived }), conversation?.id == id {
            showArchive = archived
        }
    }

    func moveConversation(_ id: UUID, in projectID: UUID, to shelf: ThreadShelf) {
        guard !operationsInProgress,
              let project = workspace.projects.firstIndex(where: { $0.id == projectID }),
              let thread = workspace.projects[project].conversations.firstIndex(where: { $0.id == id }),
              !workspace.projects[project].conversations[thread].archived else { return }
        save { $0.projects[project].conversations[thread].shelf = shelf }
    }

    func setEditing(_ enabled: Bool) {
        guard !operationsInProgress, let p = selectedProjectIndex else { return }
        if save({ $0.projects[p].allowEdits = enabled }) { connect() }
    }

    func hasKey(for settings: ModelSettings) -> Bool {
        guard let settings = try? settings.validated() else { return false }
        return (try? vault.exists(settings.account)) ?? false
    }

    func applySettings(_ settings: ModelSettings, newKey: String, removeKey: Bool) throws {
        guard !operationsInProgress, let store else {
            throw WorkspaceError("Wait for the current operation to finish.")
        }
        let settings = try settings.validated()
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if removeKey {
            try vault.remove(settings.account)
        } else if !key.isEmpty {
            try vault.save(KeyVault.validatedKey(key), account: settings.account)
        }
        var updated = workspace
        updated.model = settings
        try store.save(updated)
        workspace = updated
        connect()
    }

    func changeThreadLocation(_ choice: ThreadLocationChoice) async throws {
        guard canChangeWorkspace, let project, let conversation else {
            throw WorkspaceError("Choose the workspace before the first message.")
        }
        let git = GitWorkspace(path: project.path)
        let location: ThreadLocation = try await performGitMutation {
            switch choice {
            case .project:
                return .project
            case let .existing(path):
                guard let checkout = try await git.worktrees().first(where: { $0.path == path }) else {
                    throw WorkspaceError("This worktree is no longer registered with the repository.")
                }
                return .worktree(path: checkout.path, base: nil)
            case let .create(branch, base):
                let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
                return .newWorktree(branch: branch, base: base)
            }
        }
        try saveLocation(location, for: conversation.id)
        connect()
    }

    private func saveLocation(_ location: ThreadLocation, for conversationID: UUID) throws {
        guard let index = selectedProjectIndex,
              let thread = workspace.projects[index].conversations.firstIndex(where: { $0.id == conversationID }),
              save({ $0.projects[index].conversations[thread].location = location }) else {
            throw WorkspaceError("Could not save the thread workspace.")
        }
    }

    func performGitMutation<T>(_ operation: () async throws -> T) async throws -> T {
        guard !operationsInProgress else {
            throw WorkspaceError("Wait for the active operation before changing the checkout.")
        }
        return try await runGitMutation(operation)
    }

    private func runGitMutation<T>(_ operation: () async throws -> T) async throws -> T {
        gitMutationInProgress = true
        defer {
            gitMutationInProgress = false
            repositoryRevision += 1
        }
        return try await operation()
    }

    func send() {
        guard canSend, let process, let conversation else { return }
        do {
            guard let key = try vault.read(workspace.model.account) else {
                showingSettings = true
                return
            }
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.contains(key) else {
                draft = ""
                error = "Enter your API key in Model Settings."
                return
            }
            if case let .newWorktree(branch, base) = conversation.workingLocation {
                startWorktree(branch: branch, base: base, thread: conversation.id, prompt: text)
            } else {
                try send(text, using: process)
            }
        } catch {
            self.error = "Pi is unavailable. Reconnect to send your message."
            shutdown()
        }
    }

    private func startWorktree(branch: String, base: String, thread: UUID, prompt: String) {
        guard let store, let project else { return }
        preparingWorktree = true
        error = nil
        Task {
            do {
                let git = GitWorkspace(path: project.path)
                let path = try await runGitMutation {
                    let destination = try store.worktree(project: project.id, conversation: thread)
                    let canonical = destination.resolvingSymlinksInPath().standardizedFileURL.path
                    if let existing = try await git.worktrees().first(where: { $0.path == canonical && $0.branch == branch }) {
                        return existing.path
                    }
                    return try await git.createWorktree(at: canonical, branch: branch, base: base)
                }
                try saveLocation(.worktree(path: path, base: base), for: thread)
                firstPrompt = prompt
                connect()
                if phase != .connecting { clearWorktreePrompt() }
            } catch let failure {
                clearWorktreePrompt()
                error = failure.localizedDescription
            }
        }
    }

    private func clearWorktreePrompt() {
        preparingWorktree = false
        firstPrompt = nil
    }

    private func send(_ text: String, using process: PiProcess) throws {
        try process.send(SendPrompt(text: text))
        if let p = selectedProjectIndex, let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == conversation?.id }) {
            save {
                var thread = $0.projects[p].conversations[t]
                thread.lastActiveAt = Date()
                if thread.threadShelf == .settled { thread.shelf = .active }
                if ["New thread", "New conversation"].contains(thread.title) {
                    thread.title = String((text.split(whereSeparator: \.isNewline).first ?? Substring(text)).prefix(54))
                }
                $0.projects[p].conversations[t] = thread
            }
        }
        draft = ""
        partial = ""
        activity = ""
        error = nil
        phase = .running
    }

    func cancel() {
        guard phase == .running, let process else { return }
        do {
            try process.send(CancelPrompt())
            phase = .stopping
        } catch {
            self.error = "Pi disconnected while stopping the request."
            shutdown()
        }
    }

    private var selectedProjectIndex: Int? {
        workspace.projects.firstIndex { $0.id == workspace.selectedProject }
    }

    func connect() {
        shutdown()
        messages = []
        partial = ""
        activity = ""
        repositoryRevision += 1
        guard let store, let project, let conversation, let directory = workingDirectory else { return }
        error = nil
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "The thread’s workspace folder is no longer available."
            return
        }
        phase = .connecting
        do {
            let settings = try workspace.model.validated()
            let worker = try PiProcess(config: store.config, cwd: directory)
            process = worker
            worker.onEvent = { [weak self, weak worker] event in
                guard let self, let worker, self.process === worker else { return }
                self.receive(event, from: worker, account: settings.account)
            }
            worker.onClose = { [weak self, weak worker] in
                guard let self, let worker, self.process === worker else { return }
                self.shutdown()
                self.clearWorktreePrompt()
                if self.error == nil { self.error = "The Pi helper exited. Reconnect to this conversation." }
            }
            try worker.send(OpenConversation(
                cwd: directory,
                sessionDir: store.history(project: project.id, conversation: conversation.id).path,
                threadID: conversation.id.uuidString,
                config: settings,
                allowEdits: project.allowEdits
            ))
        } catch {
            shutdown()
            self.error = error.localizedDescription
        }
    }

    private func receive(_ event: PiEvent, from worker: PiProcess, account: String) {
        switch event {
        case let .credential(id, read):
            var result = CredentialResult(requestID: id)
            do {
                if read { result.key = try vault.read(account) }
                else { result.exists = try vault.exists(account) }
            } catch {
                result.error = true
            }
            do {
                try worker.send(result)
            } catch {
                shutdown()
                self.error = "The Pi helper disconnected during Keychain access."
            }
        case let .ready(history):
            messages = history
            phase = .ready
            if let firstPrompt {
                clearWorktreePrompt()
                do {
                    try send(firstPrompt, using: worker)
                } catch {
                    shutdown()
                    self.error = "The worktree was created. Reconnect to send your message."
                }
            }
        case let .history(history):
            messages = history
            partial = ""
        case let .partial(text):
            partial = text
            activity = ""
        case let .activity(tool):
            activity = tool
        case let .finished(history, error):
            messages = history
            partial = ""
            activity = ""
            self.error = error
            repositoryRevision += 1
            phase = .ready
        case let .fatal(error):
            shutdown()
            clearWorktreePrompt()
            self.error = error
        }
    }
}
