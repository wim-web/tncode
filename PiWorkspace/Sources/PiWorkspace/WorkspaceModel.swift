import AppKit
import Combine
import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
    enum SidebarCommand { case newThread, search }
    let sidebarCommand = PassthroughSubject<SidebarCommand, Never>()

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
    private var composerSave: Task<Void, Never>?
    private var composerCredential: (account: String, key: String?)?

    var draft: String {
        get { conversation?.composerText ?? "" }
        set {
            guard let id = conversation?.id else { return }
            editDraft(newValue, in: id)
        }
    }

    func editDraft(_ text: String, in threadID: UUID) {
        guard let conversation, conversation.id == threadID, !conversation.archived,
              conversation.composerSubmission == nil, text != draft,
              let p = selectedProjectIndex,
              let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == threadID }) else { return }
        var text = text
        if !text.isEmpty {
            do {
                let account = ((try? effectiveModel.validated()) ?? effectiveModel).account
                if composerCredential?.account != account {
                    composerCredential = (account, try readCredential(account))
                }
                if let key = composerCredential?.key, text.contains(key) {
                    text = ""
                    error = "Enter your API key in Model Settings."
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        workspace.projects[p].conversations[t].composerText = text.isEmpty ? nil : text
        composerSave?.cancel()
        composerSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            self?.flushComposerEdits()
        }
    }

    private func flushComposerEdits() {
        guard composerSave != nil else { return }
        save { _ in }
    }

    func showsInSidebar(_ thread: Conversation) -> Bool {
        thread.isDraft != true || thread.composerText != nil
    }

    func searchMessages(_ search: SidebarMessageSearch) async throws -> [UUID: SidebarMessageSearch.Match] {
        guard let root = store?.root else { return [:] }
        return try await search.matches(in: root)
    }

    @Published var error: String?
    @Published private(set) var startupFailure: WorkspaceStoreError?
    @Published var showingSettings = false
    @Published var showingWelcome = false
    @Published var showArchive = false
    @Published var projectPicker: ProjectPickerRequest?

    let root: URL
    private var store: WorkspaceStore?
    private let vault: KeyVault
    private let readCredential: (String) throws -> String?
    private let makeProcess: (URL, String) throws -> PiProcess
    private var process: PiProcess?
    private var activeTurnID: UUID?

    init(root: URL, keychainService: String, readCredential: ((String) throws -> String?)? = nil,
         makeProcess: ((URL, String) throws -> PiProcess)? = nil) {
        self.root = root
        let vault = KeyVault(service: keychainService)
        self.vault = vault
        self.readCredential = readCredential ?? vault.read
        self.makeProcess = makeProcess ?? PiProcess.init(config:cwd:)
        openWorkspace()
    }

    func openWorkspace(restoringPrevious: Bool = false) {
        guard store == nil else { return }
        do {
            let store = try WorkspaceStore(root: root)
            workspace = try store.load(restoringPrevious: restoringPrevious)
            self.store = store
            showingWelcome = workspace.projects.isEmpty && workspace.welcomeCompleted != true
            startupFailure = nil
        } catch {
            startupFailure = error as? WorkspaceStoreError ?? .access(root, error)
        }
    }

    var threadProjects: [Project] { workspace.projects.filter { $0.detached != true } }
    var projects: [Project] { threadProjects.filter { !$0.isScratch } }
    var project: Project? { workspace.activeProject }
    var effectiveModel: ModelSettings { workspace.effectiveModel }
    var conversation: Conversation? {
        guard let project else { return nil }
        return project.conversations.first { $0.id == project.selectedConversation }
    }
    var workingDirectory: String? {
        guard let project, let conversation else { return nil }
        return conversation.workingLocation.directory(in: project)
    }
    var operationsInProgress: Bool { phase.isRunning || gitMutationInProgress || preparingWorktree }
    var canStartScratchThread: Bool { store != nil }
    var canChangeWorkspace: Bool {
        project?.isScratch == false && canChangeWorkingDirectory
    }
    var canSwitchDraftProject: Bool {
        conversation?.canDiscardDraft == true && canChangeWorkingDirectory
    }
    private var canChangeWorkingDirectory: Bool {
        guard !operationsInProgress,
              let store, let project, let conversation, !conversation.archived,
              conversation.composerSubmission == nil else { return false }
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
        conversation?.worktreeLaunch == nil && conversation?.composerSubmission == nil &&
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var canRetryWorktree: Bool {
        guard !operationsInProgress, let conversation, !conversation.archived,
              let launch = conversation.worktreeLaunch else { return false }
        return !launch.awaitingHistory
    }

    func start() {
        guard !showingWelcome, process == nil else { return }
        if let conversation, project?.isScratch == true || conversation.composerText != nil {
            showArchive = conversation.archived
            connect()
            return
        }
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

    func terminate() {
        flushComposerEdits()
        shutdown()
    }

    @discardableResult
    private func save(_ edit: (inout Workspace) -> Void) -> Bool {
        var updated = workspace
        edit(&updated)
        do {
            try persist(updated)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func persist(_ updated: Workspace) throws {
        guard let store else { throw WorkspaceError("Could not open the workspace.") }
        try store.save(updated)
        composerSave?.cancel()
        composerSave = nil
        composerCredential = nil
        workspace = updated
    }

    func openFolder(relinking id: UUID? = nil, startThread: Bool = false) {
        guard !operationsInProgress else { return }
        projectPicker = ProjectPickerRequest(relinking: id, startThread: startThread,
                                             initialPath: projects.first(where: { $0.id == id })?.path ?? "",
                                             basePath: project?.path)
    }

    func openProject(_ source: ProjectSource, request: ProjectPickerRequest) async throws {
        switch source {
        case .localFolder(let folder):
            try openProject(folder, request: request)
        case .newProject(let name, let parent):
            try checkCanOpenProject()
            let parent = try ProjectFolder.existing(at: parent)
            let folder = try await runGitMutation {
                try await GitWorkspace.createRepository(named: name, in: parent)
            }
            do {
                try openProject(folder, request: request)
            } catch {
                throw WorkspaceError("""
                    The repository was created at \(folder.path). \(error.localizedDescription)
                    After resolving the error, add the repository with Local folder.
                    """)
            }
        }
    }

    func openProject(_ url: URL, request: ProjectPickerRequest? = nil) throws {
        try checkCanOpenProject()
        let folder = try ProjectFolder.existing(at: url)
        try registerProject(folder, relinking: request?.relinking, startThread: request?.startThread == true)
    }

    func openDroppedProjects(_ urls: [URL]) throws -> Bool {
        try checkCanOpenProject()
        var opened = false
        for url in urls {
            guard let folder = try? ProjectFolder.existing(at: url) else { continue }
            try registerProject(folder)
            opened = true
        }
        return opened
    }

    private func checkCanOpenProject() throws {
        guard !operationsInProgress else {
            throw WorkspaceError("Wait for the current operation before switching projects.")
        }
        guard store != nil else {
            throw WorkspaceError(error ?? "Could not open the workspace.")
        }
    }

    private func registerProject(_ folder: URL, relinking: UUID? = nil, startThread: Bool = false) throws {
        let existing = workspace.projects.firstIndex { $0.path == folder.path }
        let index: Int?
        if let relinking {
            index = workspace.projects.firstIndex { $0.id == relinking }
            guard let index, existing == nil || existing == index else {
                throw WorkspaceError("That folder already belongs to another project.")
            }
        } else {
            index = existing
        }
        let previous = project
        guard save({
            $0.welcomeCompleted = true
            if let index {
                if $0.projects[index].isScratch {
                    $0.projects[index].kind = nil
                    $0.projects[index].title = $0.projects[index].conversations.first?.title ?? folder.lastPathComponent
                }
                $0.projects[index].path = folder.path
                $0.projects[index].detached = false
                $0.selectedProject = $0.projects[index].id
                if startThread || $0.projects[index].selectedConversation == nil ||
                    (relinking == nil && previous?.id != $0.selectedProject) {
                    $0.projects[index].selectDraft()
                }
            } else {
                var project = Project(id: UUID(), path: folder.path, title: folder.lastPathComponent, createdAt: Date())
                project.selectDraft()
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
        guard !operationsInProgress, workspace.selectedProject != id, projects.contains(where: { $0.id == id }) else { return }
        guard save({ $0.selectedProject = id }) else { return }
        connect()
    }

    func removeProject(_ id: UUID) {
        guard !operationsInProgress,
              let index = workspace.projects.firstIndex(where: { $0.id == id && !$0.isScratch }) else { return }
        let selected = workspace.selectedProject == id
        guard save({
            $0.projects[index].detached = true
            if selected { $0.selectedProject = $0.projects.first { $0.detached != true && !$0.isScratch }?.id }
        }) else { return }
        if selected {
            connect()
        }
    }

    func renameProject(_ id: UUID, title: String) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return }
        save { $0.projects[index].title = title }
    }

    func setProjectPinned(_ id: UUID, pinned: Bool) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id && $0.detached != true }) else { return }
        save { $0.projects[index].pinned = pinned }
    }

    func addConversation(in requestedProject: UUID? = nil) {
        guard !operationsInProgress else { return }
        let projectID = requestedProject ?? project?.id ?? projects.first?.id
        if projectID == nil || threadProjects.contains(where: { $0.id == projectID && $0.isScratch }) {
            startScratchThread()
            return
        }
        guard let index = workspace.projects.firstIndex(where: { $0.id == projectID && $0.detached != true }) else {
            openFolder(startThread: true)
            return
        }
        guard save({
            $0.selectedProject = $0.projects[index].id
            $0.projects[index].selectDraft()
        }) else { return }
        showArchive = false
        connect()
    }

    func startScratchThread() {
        guard !operationsInProgress, let store else { return }
        do {
            let thread = Conversation(id: UUID(), title: "New thread", isDraft: true)
            let scratch = try store.makeScratchProject(for: thread)
            guard save({
                $0.projects.append(scratch)
                $0.selectedProject = scratch.id
            }) else {
                store.discardEmptyScratchFolder(scratch)
                return
            }
            showArchive = false
            connect()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func convertScratchThread(_ id: UUID, in projectID: UUID) -> Bool {
        guard !operationsInProgress,
              let index = workspace.projects.firstIndex(where: { $0.id == projectID && $0.isScratch }),
              let thread = workspace.projects[index].conversations.first(where: { $0.id == id }) else { return false }
        let path = workspace.projects[index].path
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard folder.resolvingSymlinksInPath().path == path,
              (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            error = "The thread’s workspace folder is no longer available."
            return false
        }
        return save {
            $0.projects[index].kind = nil
            $0.projects[index].title = thread.title
        }
    }

    func switchDraftProject(to projectID: UUID?) {
        guard canSwitchDraftProject, let store, let source = selectedProjectIndex, let project,
              var thread = conversation, project.id != projectID else { return }
        let target = workspace.projects.firstIndex { $0.id == projectID && !$0.isScratch && $0.detached != true }
        guard projectID == nil ? !project.isScratch : target != nil else { return }
        if draft.isEmpty {
            if let projectID {
                addConversation(in: projectID)
            } else {
                startScratchThread()
            }
            return
        }

        do {
            if project.isScratch, try !FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty {
                throw WorkspaceError("Turn this thread into a project to keep its scratch files.")
            }
            thread.location = nil
            let scratch = target == nil ? try store.makeScratchProject(for: thread) : nil
            guard save({
                if let target {
                    $0.projects[target].conversations.insert(thread, at: 0)
                    $0.projects[target].selectedConversation = thread.id
                    $0.selectedProject = $0.projects[target].id
                } else if let scratch {
                    $0.projects.append(scratch)
                    $0.selectedProject = scratch.id
                }
                if project.isScratch {
                    $0.projects.remove(at: source)
                } else {
                    $0.projects[source].conversations.removeAll { $0.id == thread.id }
                    $0.projects[source].selectedConversation = $0.projects[source].conversations.first { !$0.archived }?.id
                }
            }) else {
                if let scratch { store.discardEmptyScratchFolder(scratch) }
                return
            }
            store.discardEmptyScratchFolder(project)
            showArchive = false
            connect()
        } catch {
            self.error = error.localizedDescription
        }
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

    func discardDraft(_ id: UUID, in projectID: UUID) {
        guard !operationsInProgress, let store,
              let p = workspace.projects.firstIndex(where: { $0.id == projectID && $0.detached != true }),
              let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == id && $0.canDiscardDraft })
        else { return }
        let project = workspace.projects[p]
        let isOpen = conversation?.id == id
        guard save({
            $0.projects[p].conversations.remove(at: t)
            if $0.projects[p].conversations.isEmpty && project.isScratch {
                $0.projects.remove(at: p)
                if $0.selectedProject == projectID {
                    $0.selectedProject = $0.projects.first { $0.detached != true }?.id
                }
            } else if project.selectedConversation == id {
                if isOpen {
                    $0.projects[p].selectDraft()
                } else {
                    $0.projects[p].selectedConversation = $0.projects[p].conversations.first { !$0.archived }?.id
                }
            }
        }) else { return }
        if project.isScratch && project.conversations.count == 1 { store.discardEmptyScratchFolder(project) }
        if isOpen {
            showArchive = conversation?.archived == true
            connect()
        }
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

    func applySettings(_ settings: ModelSettings, in scope: ModelSettingsScope,
                       newKey: String, removeKey: Bool) throws {
        guard !operationsInProgress, store != nil else {
            throw WorkspaceError("Wait for the current operation to finish.")
        }
        let settings = try settings.validated()
        var updated = workspace
        switch scope {
        case .workspace:
            updated.model = settings
        case .project(let id):
            let index = try modelSettingsProjectIndex(id)
            let inherited = try? workspace.model.validated()
            if updated.projects[index].modelOverride != nil || settings != inherited {
                updated.projects[index].modelOverride = settings
            }
        }

        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = !removeKey && !key.isEmpty ? try KeyVault.validatedKey(key) : nil
        try persist(updated)
        defer { connect() }
        do {
            if removeKey { try vault.remove(settings.account) }
            else if let replacement { try vault.save(replacement, account: settings.account) }
        } catch {
            throw WorkspaceError("Model settings were saved. \(error.localizedDescription)")
        }
    }

    func resetProjectModel(_ id: UUID) throws {
        guard !operationsInProgress, store != nil else {
            throw WorkspaceError("Wait for the current operation to finish.")
        }
        let index = try modelSettingsProjectIndex(id)
        guard workspace.projects[index].modelOverride != nil else { return }
        var updated = workspace
        updated.projects[index].modelOverride = nil
        try persist(updated)
        if project?.id == id { connect() }
    }

    private func modelSettingsProjectIndex(_ id: UUID) throws -> Int {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id && $0.detached != true }) else {
            throw WorkspaceError("That project is no longer open.")
        }
        return index
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
                startWorktreeLaunch(launch, in: conversation)
            } else {
                let submission = Conversation.ComposerSubmission(
                    previousUserMessageID: messages.last { $0.role == .user }?.id
                )
                try saveThread(conversation.id) { $0.composerSubmission = submission }
                try beginTurn(text, using: process)
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
        let settings = try effectiveModel.validated()
        guard let key = try readCredential(settings.account) else {
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
                        return try await git.createWorktree(at: canonical, branch: branch, base: base, for: thread.id)
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

    private func beginTurn(_ text: String, using process: PiProcess) throws {
        let turnID = UUID()
        try process.send(SendPrompt(turnID: turnID, text: text))
        activeTurnID = turnID
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
            let settings = try effectiveModel.validated()
            let worker = try makeProcess(store.config, directory)
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
            try beginTurn(launch.prompt, using: worker)
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

    private func reconcileComposerSubmission(in history: [ChatMessage], ended: Bool = false) {
        guard let conversation, let submission = conversation.composerSubmission else { return }
        let text = conversation.composerText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let latest = history.last { $0.role == .user }
        let accepted = latest.map { $0.id != submission.previousUserMessageID && $0.text == text } ?? false
        guard accepted || ended else { return }
        try? saveThread(conversation.id) {
            if accepted, let text { $0.recordPrompt(text) }
            else { $0.composerSubmission = nil }
        }
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
                if read { result.key = try readCredential(account) }
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
            reconcileComposerSubmission(in: history, ended: true)
            if !confirmWorktreePrompt(in: history), preparingWorktree {
                submitWorktreePrompt(using: worker)
            }
        case let .history(history):
            messages = history
            partial = ""
            reconcileComposerSubmission(in: history)
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
            reconcileComposerSubmission(in: history, ended: true)
            if !confirmWorktreePrompt(in: history), conversation?.worktreeLaunch?.awaitingHistory == true {
                self.error = nil
                failWorktreeLaunch(at: .sendPrompt, message: error ?? "Pi stopped before recording your message.")
            }
        case let .fatal(error):
            connectionFailed(error)
        }
    }
}
