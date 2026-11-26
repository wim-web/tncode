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
    @Published private(set) var pendingToolApproval: ToolApproval?
    @Published private(set) var gitMutationInProgress = false
    @Published private(set) var preparingWorktree = false
    @Published private(set) var repositoryRevision = 0
    @Published private var composerText: [UUID: String] = [:]
    var draft: String {
        get { conversation.flatMap { composerText[$0.id] } ?? "" }
        set {
            guard let id = conversation?.id else { return }
            composerText[id] = newValue.isEmpty ? nil : newValue
        }
    }

    func showsInSidebar(_ thread: Conversation) -> Bool {
        thread.isDraft != true || composerText[thread.id] != nil
    }
    @Published var error: String?
    @Published var showingSettings = false
    @Published var showingWelcome = false
    @Published var showArchive = false
    @Published var projectPicker: ProjectPickerRequest?

    private var store: WorkspaceStore?
    private let vault: KeyVault
    private var process: PiProcess?
    private var activeTurnID: UUID?

    init(root: URL, keychainService: String) {
        vault = KeyVault(service: keychainService)
        do {
            let store = try WorkspaceStore(root: root)
            workspace = try store.load()
            self.store = store
            showingWelcome = workspace.projects.isEmpty && workspace.welcomeCompleted != true
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
        if let launch = conversation.worktreeLaunch, launch.stage != .createCheckout { return false }
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
        conversation?.worktreeLaunch == nil &&
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canRetryWorktree: Bool {
        guard !operationsInProgress, let conversation, !conversation.archived,
              let launch = conversation.worktreeLaunch else { return false }
        return !launch.awaitingHistory
    }

    func start() {
        guard !showingWelcome, process == nil else { return }
        let recent = projects.max { lhs, rhs in
            if lhs.lastActivity == rhs.lastActivity { return rhs.id == workspace.selectedProject && lhs.id != rhs.id }
            return lhs.lastActivity < rhs.lastActivity
        }
        if let recent { addConversation(in: recent.id) }
    }

    func finishWelcome() {
        guard save({ $0.welcomeCompleted = true }) else { return }
        showingWelcome = false
        if conversation == nil { start() }
    }

    func shutdown() {
        process?.close()
        process = nil
        activeTurnID = nil
        pendingToolApproval = nil
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
        let occupied = Set(composerText.keys)
        guard save({
            $0.welcomeCompleted = true
            if let index {
                $0.projects[index].path = folder.path
                $0.projects[index].detached = false
                $0.selectedProject = $0.projects[index].id
                if request?.startThread == true || $0.projects[index].selectedConversation == nil ||
                    (request?.relinking == nil && previous?.id != $0.selectedProject) {
                    $0.projects[index].selectDraft(occupied: occupied)
                }
            } else {
                var project = Project(id: UUID(), path: folder.path, title: folder.lastPathComponent, createdAt: Date())
                project.selectDraft(occupied: occupied)
                $0.projects.append(project)
                $0.selectedProject = project.id
            }
        }) else { throw WorkspaceError(error ?? "Could not save the project.") }
        showingWelcome = false
        if previous?.id != project?.id || previous?.path != project?.path ||
            previous?.selectedConversation != project?.selectedConversation || process == nil {
            showArchive = conversation?.archived == true
            connect()
        }
    }

    func selectProject(_ id: UUID) {
        guard !operationsInProgress, workspace.selectedProject != id else { return }
        guard save({ $0.selectedProject = id }) else { return }
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
        let occupied = Set(composerText.keys)
        guard save({
            $0.selectedProject = $0.projects[index].id
            $0.projects[index].selectDraft(occupied: occupied)
        }) else { return }
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

    func setToolPermission(_ permission: ToolPermission) {
        guard !operationsInProgress, let p = selectedProjectIndex,
              workspace.projects[p].toolPermission != permission else { return }
        if save({ $0.projects[p].toolPermission = permission }) { connect() }
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
        try saveThread(conversation.id) { thread in
            if thread.workingLocation != location, var launch = thread.worktreeLaunch {
                launch.stage = location.needsWorktree ? .createCheckout : .openThread
                launch.failure = nil
                thread.worktreeLaunch = launch
            }
            thread.location = location
        }
        connect()
    }

    private func saveThread(_ conversationID: UUID, _ edit: (inout Conversation) -> Void) throws {
        guard let index = selectedProjectIndex,
              let thread = workspace.projects[index].conversations.firstIndex(where: { $0.id == conversationID }),
              save({ edit(&$0.projects[index].conversations[thread]) }) else {
            throw WorkspaceError(error ?? "Could not save the thread.")
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
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard try canUsePrompt(text, fromComposer: true) else { return }
            if conversation.workingLocation.needsWorktree {
                let launch = WorktreeLaunch(prompt: text)
                try saveThread(conversation.id) {
                    $0.recordPrompt(text)
                    $0.worktreeLaunch = launch
                }
                draft = ""
                startWorktreeLaunch(launch, in: conversation)
            } else {
                try send(text, using: process)
            }
        } catch {
            if conversation.workingLocation.needsWorktree {
                self.error = error.localizedDescription
            } else {
                self.error = "Pi is unavailable. Reconnect to send your message."
                shutdown()
            }
        }
    }

    func retryWorktree() {
        guard canRetryWorktree, let conversation, let launch = conversation.worktreeLaunch else { return }
        do {
            guard try canUsePrompt(launch.prompt) else { return }
            startWorktreeLaunch(launch, in: conversation)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func canUsePrompt(_ text: String, fromComposer: Bool = false) throws -> Bool {
        guard let key = try vault.read(workspace.model.account) else {
            showingSettings = true
            return false
        }
        guard !text.contains(key) else {
            if fromComposer { draft = "" }
            error = "Enter your API key in Model Settings."
            return false
        }
        return true
    }

    private func startWorktreeLaunch(_ launch: WorktreeLaunch, in thread: Conversation) {
        guard let store, let project else { return }
        preparingWorktree = true
        error = nil
        Task {
            var stage = WorktreeLaunch.Stage.openThread
            do {
                var location = thread.workingLocation
                if case let .newWorktree(branch, base) = location {
                    stage = .createCheckout
                    let git = GitWorkspace(path: project.path)
                    let path = try await runGitMutation {
                        let destination = try store.worktree(project: project.id, conversation: thread.id)
                        let canonical = destination.resolvingSymlinksInPath().standardizedFileURL.path
                        if let existing = try await git.worktrees().first(where: { $0.path == canonical && $0.branch == branch }) {
                            return existing.path
                        }
                        return try await git.createWorktree(at: canonical, branch: branch, base: base)
                    }
                    location = .worktree(path: path, base: base)
                }
                try saveThread(thread.id) {
                    $0.location = location
                    $0.worktreeLaunch = WorktreeLaunch(prompt: launch.prompt, stage: .openThread)
                }
                connect()
            } catch let failure {
                failWorktreeLaunch(at: stage, message: failure.localizedDescription)
            }
        }
    }

    private func failWorktreeLaunch(at stage: WorktreeLaunch.Stage, message: String) {
        preparingWorktree = false
        guard let conversation, let launch = conversation.worktreeLaunch else { return }
        do {
            try saveThread(conversation.id) {
                $0.worktreeLaunch = WorktreeLaunch(prompt: launch.prompt, stage: stage, failure: message)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send(_ text: String, using process: PiProcess) throws {
        guard let id = conversation?.id else { throw WorkspaceError("Select a thread before sending.") }
        try saveThread(id) { $0.recordPrompt(text) }
        let turnID = UUID()
        try process.send(SendPrompt(turnID: turnID, text: text))
        activeTurnID = turnID
        draft = ""
        partial = ""
        activity = ""
        error = nil
        phase = .running
    }

    func cancel() {
        guard phase == .running, let process, let activeTurnID else { return }
        pendingToolApproval = nil
        do {
            try process.send(CancelPrompt(turnID: activeTurnID))
            phase = .stopping
        } catch {
            self.error = "Pi disconnected while stopping the request."
            shutdown()
        }
    }

    func respond(to requestID: String, with decision: ToolApprovalDecision) {
        guard phase == .running, let process, let approval = pendingToolApproval,
              approval.requestID == requestID, approval.turnID == activeTurnID,
              approval.threadID == conversation?.id else { return }
        pendingToolApproval = nil
        if decision == .decline { activity = "" }
        do {
            try process.send(ToolApprovalResult(approval, decision: decision))
        } catch {
            shutdown()
            self.error = "The Pi helper disconnected while sending the tool decision."
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
        if let launch = conversation.worktreeLaunch, !preparingWorktree, !launch.awaitingHistory { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            connectionFailed("The thread’s workspace folder is no longer available.")
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
                self.connectionFailed(self.error ?? "The Pi helper exited. Reconnect to this conversation.")
            }
            try worker.send(OpenConversation(
                cwd: directory,
                sessionDir: store.history(project: project.id, conversation: conversation.id).path,
                threadID: conversation.id.uuidString,
                config: settings,
                toolPermission: project.toolPermission
            ))
        } catch {
            connectionFailed(error.localizedDescription)
        }
    }

    private func connectionFailed(_ message: String) {
        shutdown()
        if preparingWorktree {
            failWorktreeLaunch(at: .openThread, message: message)
        } else {
            error = message
        }
    }

    private func submitWorktreePrompt(using worker: PiProcess) {
        guard let conversation, let launch = conversation.worktreeLaunch else { return }
        do {
            try saveThread(conversation.id) {
                $0.worktreeLaunch = WorktreeLaunch(prompt: launch.prompt, stage: .sendPrompt)
            }
            try send(launch.prompt, using: worker)
            preparingWorktree = false
        } catch {
            shutdown()
            failWorktreeLaunch(at: .sendPrompt, message: error.localizedDescription)
        }
    }

    @discardableResult
    private func confirmWorktreePrompt(in history: [ChatMessage]) -> Bool {
        guard let conversation, let launch = conversation.worktreeLaunch,
              history.first(where: { $0.role == .user })?.text == launch.prompt else { return false }
        preparingWorktree = false
        try? saveThread(conversation.id) { $0.worktreeLaunch = nil }
        return true
    }

    func dismissUnconfirmedWorktreePrompt() {
        guard phase == .ready, !operationsInProgress,
              let conversation, !conversation.archived,
              conversation.worktreeLaunch?.awaitingHistory == true else { return }
        try? saveThread(conversation.id) { $0.worktreeLaunch = nil }
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
                connectionFailed("The Pi helper disconnected during Keychain access.")
            }
        case let .ready(history):
            messages = history
            phase = .ready
            if !confirmWorktreePrompt(in: history), preparingWorktree {
                submitWorktreePrompt(using: worker)
            }
        case let .history(history):
            messages = history
            partial = ""
            confirmWorktreePrompt(in: history)
        case let .partial(text):
            partial = text
            activity = ""
        case let .activity(tool):
            activity = tool
        case let .toolApproval(approval):
            guard phase == .running, approval.turnID == activeTurnID,
                  approval.threadID == conversation?.id else { return }
            pendingToolApproval = approval
        case let .finished(history, error):
            pendingToolApproval = nil
            activeTurnID = nil
            messages = history
            partial = ""
            activity = ""
            repositoryRevision += 1
            phase = .ready
            self.error = error
            if !confirmWorktreePrompt(in: history), conversation?.worktreeLaunch?.awaitingHistory == true {
                self.error = nil
                failWorktreeLaunch(at: .sendPrompt, message: error ?? "Pi stopped before recording your message.")
            }
        case let .fatal(error):
            connectionFailed(error)
        }
    }
}
