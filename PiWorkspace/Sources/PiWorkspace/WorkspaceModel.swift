import AppKit
import Combine
import Foundation

@MainActor
final class WorkspaceModel: ObservableObject {
    enum SidebarCommand { case newThread, search, commandPalette }
    let sidebarCommand = PassthroughSubject<SidebarCommand, Never>()

    enum Phase: Equatable {
        case closed, connecting, ready, running, stopping

        var isRunning: Bool { self == .running || self == .stopping }
    }

    private struct QueueEdit {
        let id: UUID
        let sessionID = UUID()
        var text: String
        var attachments: [ComposerAttachment]?
    }

    private struct QueueDelivery {
        var paused = true
        var mode = PiInputMode.waiting
        var inFlight: Set<UUID> = []
        var skipAfterTurn: UUID?
    }

    private struct SnoozeUndo {
        let deadlines: [ThreadSnoozeTarget: Date]
        let expiresAt: Date
    }

    private struct ForkRequest {
        let destination: PendingConversationFork
        let child: Conversation
    }

    struct PendingAgentQuestion {
        let request: AgentQuestionRequest
        var submitting = false
        var error: String?
    }

    @Published private(set) var workspace = Workspace()
    @Published private(set) var phase: Phase = .closed
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var partial = ""
    @Published private(set) var activity = ""
    @Published private(set) var pendingToolApproval: ToolApproval?
    @Published private(set) var pendingAgentQuestion: PendingAgentQuestion?
    @Published private(set) var gitMutationInProgress = false
    @Published private(set) var preparingWorktree = false
    @Published private(set) var repositoryRevision = 0
    @Published private(set) var composerSaveError: String?
    @Published private(set) var supportsImageInput = false
    @Published var showingQuitSaveFailure = false
    @Published private(set) var quitFileSaveError: String?
    @Published private(set) var snoozeClock: Date
    @Published private(set) var snoozeUndoCount = 0
    let fileSaves = WorkspaceFileSaves()
    private let now: () -> Date
    private var snoozeTimer: Timer?
    private(set) var nextSnoozeUpdate: Date?
    private var snoozeUndo: SnoozeUndo?
    private var composerDirty = false
    private var worktreeTask: Task<Void, Never>?
    private var projectCloneTask: Task<Void, Error>?
    private var composerSave: Task<Void, Never>?
    private var composerCredential: (account: String, key: String?)?
    private var composerDraftGenerations: [UUID: UUID] = [:]
    private var pendingAttachmentImports: [ComposerAttachmentTarget: Int] = [:]
    private var threadSelectionRevision = 0

    private(set) var composerRevision = 0
    @Published private var queueEdit: QueueEdit? {
        didSet {
            if oldValue?.sessionID != queueEdit?.sessionID { composerRevision += 1 }
        }
    }
    @Published private var queueDelivery = QueueDelivery()
    @Published private var forkRequest: ForkRequest?

    var draft: String {
        get { queueEdit?.text ?? conversation?.composerText ?? "" }
        set {
            guard let id = conversation?.id else { return }
            editDraft(newValue, in: id)
        }
    }

    func editDraft(_ text: String, in threadID: UUID) {
        guard let conversation, conversation.id == threadID, !conversation.archived,
              conversation.worktreeLaunch == nil, conversation.composerSubmission == nil, text != draft,
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
        composerRevision += 1
        if queueEdit != nil {
            queueEdit?.text = text
            return
        }
        workspace.projects[p].conversations[t].composerText = text.isEmpty ? nil : text
        composerDirty = true
        composerSave?.cancel()
        composerSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            self?.savePendingComposer()
        }
    }

    @discardableResult
    func savePendingComposer() -> Bool {
        guard composerDirty else { return true }
        do {
            try persist(workspace)
            return true
        } catch {
            composerSaveError = error.localizedDescription
            return false
        }
    }

    func savePendingEditsForQuit() -> Bool {
        let composerSaved = savePendingComposer()
        quitFileSaveError = fileSaves.flushAll()
        return composerSaved && quitFileSaveError == nil
    }

    var editingQueuedMessageID: UUID? { queueEdit?.id }
    func attachmentTarget(for threadID: UUID) -> ComposerAttachmentTarget {
        .init(threadID: threadID, queueEditID: conversation?.id == threadID ? queueEdit?.sessionID : nil,
              draftGeneration: composerDraftGenerations[threadID])
    }
    var composerAttachments: [ComposerAttachment] {
        if let queueEdit { return queueEdit.attachments ?? [] }
        return conversation?.composerAttachments ?? []
    }

    func readSentImage(threadID: UUID, messageID: String, attachmentID: UUID) async -> ComposerAttachment.Payload? {
        guard let process, conversation?.id == threadID, !Task.isCancelled else { return nil }
        let request = ReadSentImage(requestID: UUID(), messageID: messageID, attachmentID: attachmentID)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                sentImageRequests[request.requestID] = continuation
                do {
                    try process.send(request)
                } catch {
                    sentImageRequests.removeValue(forKey: request.requestID)?.resume(returning: nil)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.sentImageRequests.removeValue(forKey: request.requestID)?.resume(returning: nil)
            }
        }
    }

    var canEditAttachments: Bool { canUseQueue }
    var attachmentSendError: String? { attachmentSendError(for: composerAttachments) }

    var stashedPrompts: [StashedPrompt] { workspace.stashedPrompts ?? [] }
    var canMoveStashedPrompt: Bool { canUseQueue && queueEdit == nil && pendingAgentQuestion == nil }
    var hasStashablePrompt: Bool { !StashedPrompt.trimmed(draft).isEmpty || !composerAttachments.isEmpty }
    var isImportingComposerAttachments: Bool {
        guard let id = conversation?.id else { return false }
        return pendingAttachmentImports[attachmentTarget(for: id)] != nil
    }

    @discardableResult
    func stashCurrentPrompt() -> Bool {
        guard canMoveStashedPrompt, let thread = conversation,
              attachmentImportsFinished(), hasStashablePrompt else { return false }
        let attachments = thread.composerAttachments ?? []
        guard attachments.allSatisfy({ $0.payload != nil }) else {
            error = "Attach unavailable files again or remove them before stashing."
            return false
        }
        let prompt = StashedPrompt(prompt: StashedPrompt.trimmed(draft), attachments: attachments)
        let limit = StashedPrompt.maxCount
        let evictsOldest = stashedPrompts.count >= limit
        let entries = [prompt] + stashedPrompts.prefix(limit - 1)
        guard saveStash(entries, threadID: thread.id, text: "", attachments: []) else { return false }
        if evictsOldest { error = "The stash holds \(limit) prompts. The oldest prompt was removed." }
        return true
    }

    @discardableResult
    func restoreStashedPrompt(_ id: UUID, to scope: DraftProjectScope) -> Bool {
        guard canMoveStashedPrompt, draftProjectScope == scope, let thread = conversation,
              let entry = stashedPrompts.first(where: { $0.id == id }),
              attachmentImportsFinished() else { return false }

        var attachments = thread.composerAttachments ?? []
        for attachment in entry.attachments where !attachments.contains(attachment) {
            if attachments.contains(where: { $0.id == attachment.id }) {
                attachments.append(ComposerAttachment(name: attachment.name, payload: attachment.payload))
            } else {
                attachments.append(attachment)
            }
        }
        guard attachments.count <= ComposerAttachment.maxCount,
              attachments.reduce(0, { $0 + ($1.payload?.data.count ?? 0) }) <= ComposerAttachment.maxBytes else {
            error = "This prompt is still in the stash. Remove some composer attachments and try again."
            return false
        }
        let text = entry.appending(to: draft)
        do {
            let key = try readCredential(((try? effectiveModel.validated()) ?? effectiveModel).account)
            if let key, !key.isEmpty {
                if entry.prompt.contains(key) || entry.attachments.contains(where: { $0.name.contains(key) }) {
                    throw WorkspaceError("Remove the API key before restoring this prompt.")
                }
                for attachment in entry.attachments {
                    try Self.validateAttachment(attachment.payload, key: key, alongside: [])
                }
            }
        } catch {
            self.error = error.localizedDescription
            return false
        }
        return saveStash(stashedPrompts.filter { $0.id != id }, threadID: thread.id, text: text, attachments: attachments)
    }

    @discardableResult
    func deleteStashedPrompt(_ id: UUID) -> Bool {
        guard stashedPrompts.contains(where: { $0.id == id }) else { return false }
        let entries = stashedPrompts.filter { $0.id != id }
        error = nil
        return save { $0.stashedPrompts = entries.isEmpty ? nil : entries }
    }

    private func saveStash(_ entries: [StashedPrompt], threadID: UUID, text: String,
                           attachments: [ComposerAttachment]) -> Bool {
        guard let p = selectedProjectIndex,
              let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == threadID }) else { return false }
        error = nil
        guard save({ workspace in
            workspace.stashedPrompts = entries.isEmpty ? nil : entries
            workspace.projects[p].conversations[t].composerText = text.isEmpty ? nil : text
            workspace.projects[p].conversations[t].composerAttachments = attachments.isEmpty ? nil : attachments
        }) else { return false }
        composerDraftGenerations[threadID] = UUID()
        return true
    }

    private func attachmentImportsFinished() -> Bool {
        guard !isImportingComposerAttachments else {
            error = "Wait for attachments to finish pasting, then try again."
            return false
        }
        return true
    }

    private func attachmentSendError(for attachments: [ComposerAttachment]) -> String? {
        if attachments.contains(where: { $0.payload == nil }) {
            return "Attach the unavailable files again or remove them to send."
        }
        if (phase == .ready || phase.isRunning) && !supportsImageInput &&
            attachments.contains(where: { $0.payload?.isImage == true }) {
            return "This model does not support image input. Choose an image-capable model or remove the images."
        }
        return nil
    }

    // Return false to let the field editor replace its selection using AppKit.
    func foldPastedText(_ text: String, inlineLength: Int, in target: ComposerAttachmentTarget,
                        didAttach: ((ComposerAttachment) -> Void)? = nil) -> Bool {
        guard conversation?.id == target.threadID, attachmentTarget(for: target.threadID) == target,
              canEditAttachments else { return true }
        guard !text.isEmpty else { return false }
        if inlineLength <= ComposerAttachmentInput.inlinePasteUTF16Limit {
            let bytes = text.utf8.count
            let attachments = composerAttachments
            guard bytes >= ComposerAttachmentInput.pastedTextThreshold, bytes <= ComposerAttachment.maxTextBytes,
                  attachments.count < ComposerAttachment.maxCount, !text.utf8.contains(0),
                  attachments.reduce(bytes, { $0 + ($1.payload?.data.count ?? 0) }) <= ComposerAttachment.maxBytes else {
                return false
            }
        }
        if attach([.pastedText(text)], to: target), let attachment = composerAttachments.last {
            didAttach?(attachment)
        }
        return true
    }

    @discardableResult
    func attach(_ inputs: [ComposerAttachmentInput], to target: ComposerAttachmentTarget,
                replacing attachmentID: UUID? = nil) -> Bool {
        editAttachments(in: target) { attachments, settings in
            let key = try readCredential(((try? settings.validated()) ?? settings).account)
            let replacement = attachmentID.flatMap { id in attachments.firstIndex { $0.id == id } }
            guard attachmentID == nil || replacement != nil else { return }
            for input in inputs {
                guard replacement != nil || attachments.count < ComposerAttachment.maxCount else {
                    throw WorkspaceError("Attach up to \(ComposerAttachment.maxCount) files per message.")
                }
                let name = input.name(among: attachments)
                if let key, !key.isEmpty, name.contains(key) {
                    throw WorkspaceError("Enter your API key in Model Settings.")
                }
                let payload: ComposerAttachment.Payload?
                do {
                    payload = try input.load()
                } catch {
                    self.error = "\(name): \(error.localizedDescription)"
                    guard replacement == nil, input.keepsUnavailableFile(after: error) else { continue }
                    payload = nil
                }
                try Self.validateAttachment(payload, key: key, alongside: attachments.filter { $0.id != attachmentID })
                let storedName = input.nameForStorage(name, payload: payload)
                if storedName != name, let key, !key.isEmpty, storedName.contains(key) {
                    throw WorkspaceError("Enter your API key in Model Settings.")
                }
                let attachment = ComposerAttachment(id: attachmentID ?? UUID(), name: storedName, payload: payload)
                if let replacement {
                    attachments[replacement] = attachment
                    return
                }
                attachments.append(attachment)
            }
        }
    }

    func pasteAttachments(_ providers: [NSItemProvider], to target: ComposerAttachmentTarget) {
        guard canEditAttachments, conversation?.id == target.threadID,
              attachmentTarget(for: target.threadID) == target, !providers.isEmpty else { return }
        pendingAttachmentImports[target, default: 0] += 1
        let inputs = Array(providers.prefix(ComposerAttachment.maxCount + 1))
        Task {
            defer {
                let remaining = pendingAttachmentImports[target, default: 1] - 1
                pendingAttachmentImports[target] = remaining == 0 ? nil : remaining
            }
            var items: [ComposerAttachmentInput] = []
            for provider in inputs {
                let loaded = await withCheckedContinuation { continuation in
                    _ = provider.loadTransferable(type: ComposerAttachmentInput.self) { result in
                        continuation.resume(returning: result)
                    }
                }
                if case .success(let item) = loaded { items.append(item) }
            }
            let attached = !items.isEmpty && attach(items, to: target)
            guard conversation?.id == target.threadID, error == nil else { return }
            if items.count < inputs.count {
                error = "Some pasted files or images could not be read."
            } else if !attached && !items.isEmpty {
                error = "The attachment target is no longer editable."
            }
        }
    }

    func removeAttachment(_ id: UUID, in target: ComposerAttachmentTarget) {
        _ = editAttachments(in: target) { attachments, _ in attachments.removeAll { $0.id == id } }
    }

    private static func validateAttachment(_ payload: ComposerAttachment.Payload?, key: String?,
                                           alongside attachments: [ComposerAttachment]) throws {
        guard let payload else { return }
        let total = attachments.reduce(payload.data.count) { $0 + ($1.payload?.data.count ?? 0) }
        guard total <= ComposerAttachment.maxBytes else { throw WorkspaceError("Attachments must total 4 MB or less.") }
        if let key, !key.isEmpty, !payload.isImage, String(decoding: payload.data, as: UTF8.self).contains(key) {
            throw WorkspaceError("Enter your API key in Model Settings.")
        }
    }

    private func editAttachments(in target: ComposerAttachmentTarget,
                                 _ edit: (inout [ComposerAttachment], ModelSettings) throws -> Void) -> Bool {
        guard let p = workspace.projects.firstIndex(where: {
            $0.detached != true && $0.conversations.contains { $0.id == target.threadID }
        }), let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == target.threadID }) else { return false }
        let project = workspace.projects[p]
        let thread = project.conversations[t]
        guard target.draftGeneration == composerDraftGenerations[thread.id],
              !thread.archived, thread.worktreeLaunch == nil, thread.composerSubmission == nil else { return false }
        if let id = target.queueEditID {
            guard conversation?.id == thread.id, queueEdit?.sessionID == id else { return false }
        }
        let original = target.queueEditID == nil ? thread.composerAttachments ?? [] : queueEdit?.attachments ?? []
        var attachments = original
        error = nil
        do { try edit(&attachments, project.modelOverride ?? workspace.model) }
        catch { self.error = error.localizedDescription }
        guard attachments != original else { return false }
        let updated = attachments.isEmpty ? nil : attachments
        if target.queueEditID != nil {
            queueEdit?.attachments = updated
        } else {
            workspace.projects[p].conversations[t].composerAttachments = updated
            composerDirty = true
            savePendingComposer()
        }
        return true
    }
    var queuedMessages: [QueuedMessage] {
        guard let queue = conversation?.queuedMessages, !queue.isEmpty else { return [] }
        let recorded = Set(messages.compactMap(\.queuedID))
        return queue.filter {
            !recorded.contains($0.id) && !queueDelivery.inFlight.contains($0.id)
        }
    }
    var queuePaused: Bool { queueDelivery.paused }
    var canEditQueue: Bool { canUseQueue && phase != .connecting && forkRequest == nil }
    var canStartEditingQueuedMessage: Bool { canEditQueue && queueEdit == nil && pendingAgentQuestion == nil }
    var canSteer: Bool { phase == .running && queueDelivery.mode == .steer && pendingAgentQuestion == nil }
    var canSkipCompaction: Bool { phase == .running && queueDelivery.mode == .compacting }
    var canStartQueuedMessage: Bool { phase == .ready && !operationsInProgress && canUseQueue }
    var canQueueDraft: Bool {
        canUseQueue && queueEdit == nil && hasPrompt && attachmentSendError == nil &&
            (phase == .running || (canStartQueuedMessage && !queuedMessages.isEmpty))
    }
    var canUpdateQueuedMessage: Bool { queueEdit != nil && hasPrompt && attachmentSendError == nil }
    private var canUseQueue: Bool {
        conversation?.archived == false && conversation?.worktreeLaunch == nil && conversation?.composerSubmission == nil
    }
    private var promptText: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasPrompt: Bool { !promptText.isEmpty || !composerAttachments.isEmpty }

    func showsInSidebar(_ thread: Conversation) -> Bool {
        thread.isDraft != true || thread.hasDraftContent || thread.worktreeLaunch != nil
    }

    func searchMessages(_ search: SidebarMessageSearch) async throws -> [UUID: SidebarMessageSearch.Match] {
        guard let root = store?.root else { return [:] }
        return try await search.matches(in: root)
    }

    @Published var error: String?
    @Published var threadLinkError: String?
    @Published private(set) var startupFailure: WorkspaceStoreError?
    @Published var settingsRequest: SettingsRequest?
    @Published private(set) var showingWelcome = false
    @Published var showArchive = false
    @Published var projectPicker: ProjectPickerRequest?
    @Published var showingCommandPalette = false
    @Published var threadFind: ThreadFindSession?

    let root: URL
    private var store: WorkspaceStore?
    private let vault: KeyVault
    private let readCredential: (String) throws -> String?
    private let makeProcess: (URL, String) throws -> any PiConnection
    private let makeGitHubReader: (String) -> GitHubReader
    private var process: (any PiConnection)?
    private var pendingThreadLink: (worker: any PiConnection, result: CheckedContinuation<Bool, Never>)?
    private var sentImageRequests: [UUID: CheckedContinuation<ComposerAttachment.Payload?, Never>] = [:]
    private var activeTurnID: UUID?

    init(root: URL, keychainService: String, now: @escaping () -> Date = Date.init,
         readCredential: ((String) throws -> String?)? = nil,
         makeProcess: ((URL, String) throws -> any PiConnection)? = nil,
         makeGitHubReader: @escaping (String) -> GitHubReader = { GitHubReader(directory: $0) }) {
        self.root = root
        self.now = now
        snoozeClock = now()
        let vault = KeyVault(service: keychainService)
        self.vault = vault
        self.readCredential = readCredential ?? vault.read
        self.makeProcess = makeProcess ?? { try PiProcess(config: $0, cwd: $1) }
        self.makeGitHubReader = makeGitHubReader
        openWorkspace()
    }

    deinit {
        snoozeTimer?.invalidate()
    }

    func openWorkspace(restoringPrevious: Bool = false) {
        guard store == nil else { return }
        do {
            let store = try WorkspaceStore(root: root)
            workspace = try store.load(restoringPrevious: restoringPrevious)
            try? store.recoverFork(in: workspace)
            self.store = store
            refreshSnoozes()
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
    var threadFindScope: SidebarMessageSearch.Thread? {
        guard let project, let thread = conversation, thread.isDraft != true || thread.archived else { return nil }
        return .init(projectID: project.id, threadID: thread.id)
    }
    var activeThreadFind: ThreadFindSession? {
        guard threadFind?.thread == threadFindScope else { return nil }
        return threadFind
    }
    var workingDirectory: String? {
        guard let project, let conversation else { return nil }
        return conversation.workingLocation.directory(in: project)
    }
    var pullRequestScope: ThreadPullRequestScope? {
        guard let project, let conversation else { return nil }
        return ThreadPullRequestScope(project: project, thread: conversation)
    }
    var operationsInProgress: Bool { phase.isRunning || gitMutationInProgress || preparingWorktree || forkRequest != nil }
    var showingSettings: Bool { settingsRequest != nil }
    var canOpenModelSettings: Bool { startupFailure == nil && !phase.isRunning }

    func openSettings(_ page: SettingsPage = .general, anchor: SettingsAnchor? = nil, projectID: UUID? = nil) {
        guard settingsRequest == nil else { return }
        let project = projects.first { $0.id == (projectID ?? self.project?.id) }
        guard page != .project || project != nil else { return }
        settingsRequest = SettingsRequest(page: page, anchor: anchor, projectID: project?.id)
    }

    var canOpenCommandPalette: Bool {
        store != nil && !showingWelcome && !operationsInProgress &&
            !showingSettings && !showingQuitSaveFailure && projectPicker == nil
    }
    var canStartScratchThread: Bool { store != nil }
    var canChangeWorkspace: Bool {
        project?.isScratch == false && canChangeWorkingDirectory
    }
    var canSwitchDraftProject: Bool {
        conversation?.canDiscardDraft == true && canChangeWorkingDirectory
    }
    var draftProjectScope: DraftProjectScope? {
        guard let project, let conversation else { return nil }
        return DraftProjectScope(projectID: project.id, threadID: conversation.id, revision: threadSelectionRevision)
    }
    private var canChangeWorkingDirectory: Bool {
        guard !operationsInProgress,
              let store, let project, let conversation, !conversation.archived,
              conversation.composerSubmission == nil else { return false }
        if let launch = conversation.worktreeLaunch, launch.stage != .createCheckout || !launch.canInterrupt {
            return false
        }
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
        phase == .ready && !operationsInProgress && canUseQueue && queueEdit == nil && hasPrompt && attachmentSendError == nil
    }
    var canRetryWorktree: Bool {
        guard !operationsInProgress, let conversation, !conversation.archived,
              let launch = conversation.worktreeLaunch else { return false }
        return !launch.awaitingHistory
    }
    var canInterruptWorktree: Bool {
        !phase.isRunning && (!gitMutationInProgress || worktreeTask != nil) &&
        conversation?.archived == false && conversation?.worktreeLaunch?.canInterrupt == true
    }
    var canWorkLocally: Bool {
        canInterruptWorktree && conversation?.workingLocation != .project
    }

    func start() {
        guard !showingWelcome, process == nil else { return }
        if let conversation, project?.isScratch == true || conversation.forkOrigin != nil || conversation.hasDraftContent ||
            conversation.composerSubmission != nil || conversation.worktreeLaunch != nil ||
            (conversation.isDraft == true && conversation.workingLocation != .project) ||
            !(conversation.queuedMessages ?? []).isEmpty {
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

    var canOpenWelcome: Bool {
        store != nil && !operationsInProgress && !showingCommandPalette && projectPicker == nil
    }

    func openWelcome() {
        guard canOpenWelcome, !showingSettings else { return }
        showingWelcome = true
    }

    func finishWelcome() {
        guard workspace.welcomeCompleted == true || save({ $0.welcomeCompleted = true }) else { return }
        showingWelcome = false
    }

    func shutdown() {
        rejectPendingThreadLink()
        process?.close()
        process = nil
        let requests = sentImageRequests
        sentImageRequests.removeAll()
        for continuation in requests.values { continuation.resume(returning: nil) }
        if forkRequest != nil {
            forkRequest = nil
            try? store?.recoverFork(in: workspace)
        }
        activeTurnID = nil
        pendingToolApproval = nil
        pendingAgentQuestion = nil
        queueDelivery = QueueDelivery()
        queueEdit = nil
        supportsImageInput = false
        phase = .closed
    }

    @discardableResult
    func terminate() -> Bool {
        guard savePendingEditsForQuit() else { return false }
        worktreeTask?.cancel()
        worktreeTask = nil
        preparingWorktree = false
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        nextSnoozeUpdate = nil
        shutdown()
        return true
    }

    func cancelProjectCloneForQuit() -> Task<Void, Error>? {
        projectCloneTask?.cancel()
        return projectCloneTask
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
        if queueEdit != nil, updated.selectedProject != workspace.selectedProject ||
            updated.activeProject?.selectedConversation != conversation?.id {
            throw WorkspaceError("Update or cancel the queued message edit before switching threads.")
        }
        try store.save(updated)
        composerSave?.cancel()
        composerSave = nil
        composerDirty = false
        composerSaveError = nil
        composerCredential = nil
        let previousScope = pullRequestScope
        let previousDraft = draft
        workspace = updated
        if pullRequestScope != previousScope || !draft.utf8.elementsEqual(previousDraft.utf8) { composerRevision += 1 }
        if pullRequestScope != previousScope { threadSelectionRevision += 1 }
        refreshSnoozes()
    }

    func updateAddProjectBaseDirectory(_ input: String) throws {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.utf8.contains(0) else { throw WorkspaceError("Enter a folder path.") }
        let preference = path.isEmpty ? nil : path
        guard preference != workspace.addProjectBaseDirectory else { return }
        var updated = workspace
        updated.addProjectBaseDirectory = preference
        try persist(updated)
    }

    func updateWorktreesDirectory(_ input: String) throws {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.utf8.contains(0) else { throw WorktreeDirectory.invalid }
        let preference = path.isEmpty ? nil : path
        guard preference != workspace.worktreesDirectory else { return }
        var updated = workspace
        updated.worktreesDirectory = preference
        try persist(updated)
    }

    func updateNewWorktreesStartFromRemote(_ enabled: Bool) throws {
        guard workspace.startNewWorktreesFromRemote != enabled else { return }
        var updated = workspace
        updated.newWorktreesStartFromRemote = enabled ? nil : false
        try persist(updated)
    }

    func openFolder(relinking id: UUID? = nil, startThread: Bool = false, draftOrigin: DraftProjectScope? = nil) {
        guard !operationsInProgress, draftOrigin == nil ||
              (id == nil && !startThread && draftOrigin == draftProjectScope && canSwitchDraftProject) else { return }
        let initialPath = if let id {
            projects.first(where: { $0.id == id })?.path ?? ""
        } else {
            ProjectFolder.addProjectInitialPath(workspace.addProjectBaseDirectory)
        }
        projectPicker = ProjectPickerRequest(relinking: id, startThread: startThread,
                                             initialPath: initialPath, basePath: project?.path, draftOrigin: draftOrigin)
    }

    func openProject(_ source: ProjectSource, request: ProjectPickerRequest) async throws {
        try checkDraftProjectRequest(request)
        switch source {
        case .localFolder(let url):
            try openProject(url, request: request)
        case .newProject(let name, let parent):
            try checkCanOpenProject()
            let parent = try ProjectFolder.existing(at: parent)
            let folder = try await runGitMutation {
                try await GitWorkspace.createRepository(named: name, in: parent)
            }
            try registerCreatedRepository(folder, request: request)
        case .clone(let remote, let destination):
            try checkCanOpenProject()
            guard request.relinking == nil else {
                throw WorkspaceError("Choose a local folder to relink this project.")
            }
            let target = try GitWorkspace.CloneDestination(destination)
            let ignoresCase = (try? target.folder.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == false
            let owner = workspace.projects.first {
                if $0.path == target.folder.path { return true }
                guard ignoresCase, $0.path.caseInsensitiveCompare(target.folder.path) == .orderedSame else { return false }
                return !target.alreadyExists || target.matchesDirectory(at: $0.path)
            }
            if owner != nil && !target.alreadyExists {
                throw WorkspaceError("The destination already belongs to a project. Choose another destination.")
            }
            try await runGitMutation {
                let clone = Task {
                    let folder = try await GitWorkspace.cloneRepository(from: remote.argument, to: target)
                    let registeredFolder = owner.map { URL(fileURLWithPath: $0.path, isDirectory: true) } ?? folder
                    try registerCreatedRepository(registeredFolder, request: request)
                }
                projectCloneTask = clone
                defer { projectCloneTask = nil }
                try await withTaskCancellationHandler {
                    try await clone.value
                } onCancel: {
                    clone.cancel()
                }
            }
        }
    }

    private func registerCreatedRepository(_ folder: URL, request: ProjectPickerRequest) throws {
        do {
            let existing = try ProjectFolder.existing(at: folder)
            guard existing.path == folder.path else {
                throw WorkspaceError("The destination changed before it could be added.")
            }
            try registerProject(existing, request: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WorkspaceError("""
                The repository is ready at \(folder.path). \(error.localizedDescription)
                After resolving the error, add the repository with Local folder.
                """)
        }
    }

    func openProject(_ url: URL, request: ProjectPickerRequest? = nil) throws {
        try checkCanOpenProject()
        let folder = try ProjectFolder.existing(at: url)
        try registerProject(folder, request: request)
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

    private func registerProject(_ folder: URL, request: ProjectPickerRequest? = nil) throws {
        try checkDraftProjectRequest(request)
        let draftOrigin = request?.draftOrigin
        let relinking = request?.relinking
        let startThread = request?.startThread == true
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
                guard draftOrigin == nil else { return }
                $0.selectedProject = $0.projects[index].id
                if startThread || $0.projects[index].selectedConversation == nil ||
                    (relinking == nil && previous?.id != $0.selectedProject) {
                    $0.projects[index].selectDraft()
                }
            } else {
                var project = Project(id: UUID(), path: folder.path, title: folder.lastPathComponent, createdAt: Date())
                project.selectDraft()
                $0.projects.append(project)
                if draftOrigin == nil { $0.selectedProject = project.id }
            }
        }) else { throw WorkspaceError(error ?? "Could not save the project.") }
        showingWelcome = false
        if draftOrigin == nil && (previous?.id != project?.id || previous?.path != project?.path ||
            previous?.selectedConversation != project?.selectedConversation || process == nil) {
            showArchive = conversation?.archived == true
            connect()
        }
    }

    private func checkDraftProjectRequest(_ request: ProjectPickerRequest?) throws {
        guard let request, let origin = request.draftOrigin else { return }
        guard projectPicker?.id == request.id, draftProjectScope == origin else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func selectProject(_ id: UUID) {
        guard !operationsInProgress, workspace.selectedProject != id, projects.contains(where: { $0.id == id }) else { return }
        guard save({ $0.selectedProject = id }) else { return }
        connect()
    }

    func selectProjectFromPalette(_ id: UUID) {
        guard !operationsInProgress, let project = projects.first(where: { $0.id == id }) else { return }
        let latest = SidebarThread.matching(in: [project], search: "", archived: false).first {
            $0.thread.threadShelf != .settled && $0.thread.isDraft != true &&
                $0.thread.snoozeStatus(at: snoozeClock)?.isSnoozed != true
        }
        if let latest {
            selectConversation(latest.id, in: id)
            if conversation?.id == latest.id { showArchive = false }
        } else {
            addConversation(in: id)
        }
    }

    func showHome() {
        guard !operationsInProgress, workspace.selectedProject != nil,
              save({ $0.selectedProject = nil }) else { return }
        error = nil
        connect()
    }

    func requestCommandPalette() {
        guard canOpenCommandPalette else { return }
        sidebarCommand.send(.commandPalette)
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

    @discardableResult
    func renameProject(_ id: UUID, title: String) -> Bool {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id && $0.detached != true }) else { return false }
        return save { $0.projects[index].title = title }
    }

    func copyProjectPath(_ id: UUID, to pasteboard: NSPasteboard) throws {
        guard let project = projects.first(where: { $0.id == id }), project.folderIsAvailable else {
            throw WorkspaceError("The project folder is no longer available.")
        }
        pasteboard.clearContents()
        guard pasteboard.setString(project.path, forType: .string) else {
            throw WorkspaceError("Couldn’t copy the project path to the clipboard.")
        }
    }

    var sidebarProjectFilter: SidebarProjectFilter {
        SidebarProjectFilter(selection: Set(projects.filter { $0.inSidebarScope == true }.map(\.id)))
    }

    func updateSidebarScope(_ edit: (inout SidebarProjectFilter) -> Void) {
        var filter = sidebarProjectFilter
        edit(&filter)
        guard filter.selection.isSubset(of: projects.map(\.id)) else { return }
        let stored = workspace.projects.filter { $0.inSidebarScope == true }.map(\.id)
        guard Set(stored) != filter.selection else { return }
        save { workspace in
            for index in workspace.projects.indices {
                let id = workspace.projects[index].id
                workspace.projects[index].inSidebarScope = filter.selection.contains(id) ? true : nil
            }
        }
    }

    func setSidebarFolderCollapsed(_ collapsed: Bool, for id: UUID) {
        guard let index = workspace.projects.firstIndex(where: { $0.id == id && !$0.isScratch && $0.detached != true }),
              (workspace.projects[index].sidebarFolderCollapsed == true) != collapsed else { return }
        save { $0.projects[index].sidebarFolderCollapsed = collapsed ? true : nil }
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
        startScratchThread(updating: { _ in })
    }

    private func startScratchThread(updating edit: (inout Workspace) -> Void) {
        guard !operationsInProgress, let store else { return }
        do {
            let thread = Conversation(id: UUID(), title: "New thread", isDraft: true)
            let scratch = try store.makeScratchProject(for: thread)
            guard save({
                edit(&$0)
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

    func switchDraftProject(to projectID: UUID?, from scope: DraftProjectScope? = nil) {
        guard canSwitchDraftProject, let store, let source = selectedProjectIndex, let project,
              var thread = conversation, project.id != projectID,
              scope == nil || scope == draftProjectScope else { return }
        let target = workspace.projects.firstIndex { $0.id == projectID && !$0.isScratch && $0.detached != true }
        guard projectID == nil ? !project.isScratch : target != nil else { return }
        if let target, (try? ProjectFolder.existing(at: URL(fileURLWithPath: workspace.projects[target].path))) == nil {
            error = "The project folder is no longer available."
            return
        }
        if !thread.hasDraftContent, let target {
            guard save({
                $0.projects[target].openSavedDraft()
                $0.selectedProject = $0.projects[target].id
            }) else { return }
            showArchive = false
            connect()
            return
        }
        if !thread.hasDraftContent {
            startScratchThread()
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
              project?.id != projectID || conversation?.id != id else { return }
        do {
            try persistSelection(id, at: index)
            connect()
        } catch { self.error = error.localizedDescription }
    }

    private func persistSelection(_ id: UUID, at projectIndex: Int) throws {
        var updated = workspace
        updated.selectedProject = updated.projects[projectIndex].id
        updated.projects[projectIndex].selectedConversation = id
        if let index = updated.projects[projectIndex].conversations.firstIndex(where: { $0.id == id }),
           case .woke = updated.projects[projectIndex].conversations[index].snoozeStatus(at: now()) {
            updated.projects[projectIndex].conversations[index].snoozedUntil = nil
        }
        try persist(updated)
    }

    func copyThreadReference(_ id: UUID, in projectID: UUID, to pasteboard: NSPasteboard) throws {
        guard let thread = threadProjects.first(where: { $0.id == projectID })?.conversations.first(where: { $0.id == id }),
              thread.isDraft != true else {
            throw WorkspaceError("This thread doesn’t have a link.")
        }
        let workspaceID = workspace.threadLinkID ?? UUID()
        if workspace.threadLinkID == nil {
            var updated = workspace
            updated.threadLinkID = workspaceID
            try persist(updated)
        }
        let link = ThreadLink(workspaceID: workspaceID, root: root, projectID: projectID, threadID: id)
        try ThreadReference(link: link, title: thread.title).copy(to: pasteboard)
    }

    @discardableResult
    func openThreadLink(_ text: String) async -> Bool {
        rejectPendingThreadLink()
        do {
            guard let link = ThreadLink(text: text) else { throw WorkspaceError("Enter a Pi Workspace thread link.") }
            guard let store else { throw WorkspaceError("Finish opening the workspace and try the thread link again.") }
            let (index, thread) = try linkedThread(link)
            let project = workspace.projects[index]
            if self.project?.id == project.id, conversation?.id == thread.id, phase != .closed {
                if phase == .connecting, let process {
                    return await withCheckedContinuation { pendingThreadLink = (process, $0) }
                }
                finishOpeningThreadLink()
                return true
            }
            let command = try linkedOpenCommand(project: project, thread: thread, store: store)
            try WorkspaceHistory.checkThread(in: root, projectID: project.id, threadID: thread.id)
            let worker = try makeProcess(store.config, command.cwd)
            return await withCheckedContinuation { result in
                pendingThreadLink = (worker, result)
                worker.onClose = { [weak self, weak worker] in
                    guard let self, let worker, self.pendingThreadLink?.worker === worker else { return }
                    self.rejectPendingThreadLink("The Pi helper exited while opening the linked thread.")
                }
                worker.onEvent = { [weak self, weak worker] event in
                    guard let self, let worker else { return }
                    self.receiveOpeningThreadLink(event, link: link, command: command, store: store, worker: worker)
                }
                do { try worker.send(command) }
                catch { rejectPendingThreadLink(error.localizedDescription) }
            }
        } catch {
            threadLinkError = error.localizedDescription
            return false
        }
    }

    private func receiveOpeningThreadLink(_ event: PiEvent, link: ThreadLink, command: OpenConversation,
                                          store: WorkspaceStore, worker: any PiConnection) {
        guard let pending = pendingThreadLink, pending.worker === worker else { return }
        do {
            switch event {
            case let .credential(id, read):
                try replyToCredential(id, read: read, account: command.config.account, worker: worker)
            case .ready:
                let (index, thread) = try linkedThread(link)
                guard try linkedOpenCommand(project: workspace.projects[index], thread: thread, store: store) == command else {
                    throw WorkspaceError("The linked thread changed. Open the link again.")
                }
                try persistSelection(thread.id, at: index)
                pendingThreadLink = nil
                resetConnection()
                error = nil
                attach(worker, account: command.config.account)
                receive(event, from: worker, account: command.config.account)
                finishOpeningThreadLink()
                pending.result.resume(returning: true)
            case let .fatal(message):
                rejectPendingThreadLink(message)
            default: break
            }
        } catch { rejectPendingThreadLink(error.localizedDescription) }
    }

    private func rejectPendingThreadLink(_ message: String? = nil) {
        guard let pending = pendingThreadLink else { return }
        pendingThreadLink = nil
        if pending.worker !== process { pending.worker.close() }
        if let message { threadLinkError = message }
        pending.result.resume(returning: false)
    }

    private func finishOpeningThreadLink() {
        threadLinkError = nil
        showingWelcome = false
        showArchive = false
    }

    func openThreadLink(from pasteboard: NSPasteboard) async {
        await openThreadLink(pasteboard.string(forType: .string) ?? "")
    }

    private func linkedThread(_ link: ThreadLink) throws -> (Int, Conversation) {
        guard let workspaceID = workspace.threadLinkID,
              link.workspace == ThreadLink.workspaceScope(id: workspaceID, root: root) else {
            throw WorkspaceError("This thread link belongs to a different Pi Workspace.")
        }
        guard let index = workspace.projects.firstIndex(where: { $0.id == link.projectID && $0.detached != true }),
              let thread = workspace.projects[index].conversations.first(where: { $0.id == link.threadID }),
              thread.isDraft != true else { throw WorkspaceError("The linked thread is unavailable.") }
        guard !thread.archived else { throw WorkspaceError("The linked thread is archived. Restore it from the archive and try again.") }
        return (index, thread)
    }

    private func linkedOpenCommand(project: Project, thread: Conversation, store: WorkspaceStore) throws -> OpenConversation {
        guard !operationsInProgress, queueEdit == nil else {
            throw WorkspaceError("Finish the current operation or queued message edit and try the thread link again.")
        }
        let directory = thread.workingLocation.directory(in: project)
        var isDirectory: ObjCBool = false
        guard !thread.workingLocation.needsWorktree, thread.worktreeLaunch == nil,
              directory.hasPrefix("/"), !directory.utf8.contains(0),
              FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkspaceError("The linked thread’s checkout is unavailable.")
        }
        var command = try openCommand(project: project, thread: thread, store: store)
        command.requireHistory = true
        return command
    }

    func canOpenForkLink(_ id: UUID) -> Bool {
        !operationsInProgress && project?.conversations.contains { $0.id == id } == true
    }

    func pullRequestRepository(in scope: ThreadPullRequestScope) async throws -> GitHubRepository {
        guard scope == pullRequestScope, scope.canReadRepository else {
            throw WorkspaceError("Reopen Linked items for the current thread.")
        }
        return try await makeGitHubReader(scope.directory).repository()
    }

    func linkPullRequest(_ input: String, in scope: ThreadPullRequestScope, repository: GitHubRepository) async throws {
        guard scope == pullRequestScope, scope.canReadRepository else {
            throw WorkspaceError("Reopen Linked items for the current thread.")
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = GitHubPullRequestReference(url: text)
        let digits = text.wholeMatch(of: #/#?([0-9]+)/#)?.1
        guard let number = url?.number ?? digits.flatMap({ Int($0) }), number > 0 else {
            throw WorkspaceError("Enter a GitHub pull request URL or a positive number such as #42.")
        }
        let revision = threadSelectionRevision
        let reader = makeGitHubReader(scope.directory)
        if let url, url.repository != repository {
            throw WorkspaceError("This thread’s checkout uses \(repository.slug). Enter a pull request from that repository.")
        }
        let details: GitHubPullRequestDetails
        do {
            details = try await reader.pullRequestDetails(for: number, in: repository)
        } catch GitHubReader.ReadError.repositoryChanged {
            throw WorkspaceError("The checkout’s GitHub repository changed. Reopen Link pull request to use the current checkout.")
        }
        try Task.checkCancellation()
        guard scope == pullRequestScope, revision == threadSelectionRevision, let conversation else {
            throw WorkspaceError("The selected thread or checkout changed. Reopen Linked items and try again.")
        }
        guard !conversation.pullRequestLinks.contains(where: { $0.id == details.reference }) else { return }
        try saveThread(scope.threadID) { thread in
            thread.linkedPullRequests = thread.pullRequestLinks + [
                ThreadPullRequestLink(reference: details.reference, title: details.pullRequest.title)
            ]
        }
    }

    func unlinkPullRequest(_ reference: GitHubPullRequestReference, in scope: ThreadPullRequestScope) throws {
        guard scope == pullRequestScope, let conversation else {
            throw WorkspaceError("Reopen Linked items for the current thread.")
        }
        let remaining = conversation.pullRequestLinks.filter { $0.id != reference }
        guard remaining.count != conversation.pullRequestLinks.count else { return }
        try saveThread(scope.threadID) { $0.linkedPullRequests = remaining.isEmpty ? nil : remaining }
    }

    func openForkLink(_ id: UUID) {
        guard canOpenForkLink(id), let project else { return }
        selectConversation(id, in: project.id)
        if conversation?.id == id { showArchive = conversation?.archived == true }
    }

    func canForkResponse(_ message: ChatMessage) -> Bool {
        message.canFork == true && phase == .ready && !operationsInProgress && canUseQueue && queueEdit == nil
            && conversation?.workingLocation.needsWorktree == false
    }

    func forkResponse(_ messageID: String) {
        guard let message = messages.first(where: { $0.id == messageID }), canForkResponse(message),
              let project, let source = conversation, let store, let process else { return }
        let destination = PendingConversationFork(projectID: project.id, threadID: UUID())
        let child = Conversation(id: destination.threadID, title: source.title + " fork",
                                 lastActiveAt: Date(), location: source.location, isDraft: false,
                                 forkOrigin: .init(threadID: source.id, messageID: messageID))
        do {
            try store.prepareFork(destination, in: workspace)
            error = nil
            forkRequest = ForkRequest(destination: destination, child: child)
            try process.send(ForkConversation(threadID: child.id, messageID: messageID))
        } catch {
            forkRequest = nil
            try? store.recoverFork(in: workspace)
            self.error = "Could not create the conversation fork. \(error.localizedDescription)"
        }
    }

    private func finishFork(_ threadID: UUID, failure: String?) {
        guard let request = forkRequest, request.child.id == threadID, let store else { return }
        forkRequest = nil
        do {
            if let failure { throw WorkspaceError(failure) }
            guard let index = selectedProjectIndex, project?.id == request.destination.projectID,
                  conversation?.id == request.child.forkOrigin?.threadID,
                  try store.forkHasHistory(request.destination) else {
                throw WorkspaceError("The fork history was not saved. Try again.")
            }
            var updated = workspace
            updated.projects[index].conversations.insert(request.child, at: 0)
            updated.projects[index].selectedConversation = threadID
            try persist(updated)
        } catch {
            try? store.recoverFork(in: workspace)
            self.error = error.localizedDescription
            return
        }
        try? store.recoverFork(in: workspace)
        showArchive = false
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
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let p = workspace.projects.firstIndex(where: { $0.id == projectID }),
              let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == id }) else { return }
        save { $0.projects[p].conversations[t].title = title }
    }

    func canChangeArchive(for id: UUID) -> Bool {
        conversation?.id != id || (!operationsInProgress && queueEdit == nil)
    }

    func archiveConversation(_ id: UUID, in projectID: UUID, archived: Bool) {
        guard canChangeArchive(for: id), let p = workspace.projects.firstIndex(where: { $0.id == projectID }),
              let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == id }),
              workspace.projects[p].conversations[t].archived != archived else { return }
        let isOpen = project?.id == projectID && conversation?.id == id
        if archived && isOpen && workspace.projects[p].isScratch {
            startScratchThread(updating: { $0.projects[p].conversations[t].archived = true })
            return
        }
        guard save({
            $0.projects[p].conversations[t].archived = archived
            if archived && isOpen { $0.projects[p].selectDraft() }
        }), isOpen else { return }
        showArchive = false
        if archived { connect() }
    }

    func moveConversation(_ id: UUID, in projectID: UUID, to shelf: ThreadShelf) {
        guard !operationsInProgress,
              let project = workspace.projects.firstIndex(where: { $0.id == projectID }),
              let thread = workspace.projects[project].conversations.firstIndex(where: { $0.id == id }),
              !workspace.projects[project].conversations[thread].archived else { return }
        save {
            $0.projects[project].conversations[thread].shelf = shelf
            if shelf == .pinned || shelf == .settled {
                $0.projects[project].conversations[thread].snoozedUntil = nil
            }
        }
    }

    var snoozePresets: [ThreadSnoozeSchedule.Preset] {
        ThreadSnoozeSchedule.presets(at: now())
    }

    var initialCustomSnoozeDate: Date { now().addingTimeInterval(3600) }

    func setSnoozedShelfExpanded(_ expanded: Bool) {
        save { $0.snoozedShelfExpanded = expanded }
    }

    func canSnooze(_ target: ThreadSnoozeTarget) -> Bool {
        guard let (p, t) = snoozeIndices(target) else { return false }
        let thread = workspace.projects[p].conversations[t]
        guard thread.isDraft != true, !thread.archived, thread.worktreeLaunch == nil,
              thread.composerSubmission == nil, thread.snoozeStatus(at: now())?.isSnoozed != true else { return false }
        if target.projectID == project?.id, target.threadID == conversation?.id {
            return pendingToolApproval == nil && queueDelivery.inFlight.isEmpty &&
                (queueDelivery.paused || queuedMessages.isEmpty)
        }
        return true
    }

    @discardableResult
    func snooze(_ target: ThreadSnoozeTarget, preset: ThreadSnoozeSchedule.Preset) -> Bool {
        let current = now()
        do {
            let deadline = preset.deadline(at: current)
            guard ThreadSnoozeSchedule.isFuture(deadline, after: current) else {
                throw WorkspaceError("That snooze time has passed. Choose another time.")
            }
            try snooze(target, until: deadline)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func snooze(_ target: ThreadSnoozeTarget, date: String, time: String) throws {
        guard let deadline = ThreadSnoozeSchedule.deadline(date: date, time: time, after: now()) else {
            throw WorkspaceError("Choose a valid date and time in the future.")
        }
        try snooze(target, until: deadline)
    }

    func snooze(_ target: ThreadSnoozeTarget, amount: String, unit: ThreadSnoozeSchedule.Unit) throws {
        guard let deadline = ThreadSnoozeSchedule.deadline(amount: amount, unit: unit, after: now()) else {
            throw WorkspaceError("Enter a positive duration.")
        }
        try snooze(target, until: deadline)
    }

    private func snooze(_ target: ThreadSnoozeTarget, until deadline: Date) throws {
        let current = now()
        guard ThreadSnoozeSchedule.isFuture(deadline, after: current), canSnooze(target),
              let (p, t) = snoozeIndices(target) else {
            throw WorkspaceError("This thread can no longer be snoozed at that time.")
        }
        var updated = workspace
        updated.projects[p].conversations[t].snoozedUntil = deadline
        try persist(updated)
        var deadlines = snoozeUndo?.deadlines ?? [:]
        deadlines[target] = deadline
        snoozeUndo = SnoozeUndo(deadlines: deadlines, expiresAt: now().addingTimeInterval(5))
        refreshSnoozes()
    }

    func advanceAfterSidebarSnooze(_ target: ThreadSnoozeTarget, next: ThreadSnoozeTarget?) {
        guard project?.id == target.projectID, conversation?.id == target.threadID,
              canChangeArchive(for: target.threadID),
              conversation?.snoozeStatus(at: now())?.isSnoozed == true else { return }
        if let next {
            selectConversation(next.threadID, in: next.projectID)
        } else {
            addConversation(in: target.projectID)
        }
    }

    func wakeThread(_ target: ThreadSnoozeTarget, until deadline: Date) {
        guard let (p, t) = snoozeIndices(target),
              workspace.projects[p].conversations[t].snoozeStatus(at: now()) == .snoozed(until: deadline) else { return }
        save { $0.projects[p].conversations[t].snoozedUntil = nil }
    }

    func dismissWoke(_ target: ThreadSnoozeTarget, at deadline: Date) {
        guard let (p, t) = snoozeIndices(target),
              workspace.projects[p].conversations[t].snoozeStatus(at: now()) == .woke(at: deadline) else { return }
        save { $0.projects[p].conversations[t].snoozedUntil = nil }
    }

    func undoSnooze() {
        refreshSnoozes()
        guard let notice = snoozeUndo else { return }
        save { updated in
            for target in notice.deadlines.keys {
                guard let (p, t) = snoozeIndices(target) else { continue }
                updated.projects[p].conversations[t].snoozedUntil = nil
            }
        }
    }

    func refreshSnoozes() {
        let current = now()
        if let notice = snoozeUndo {
            let valid = notice.deadlines.filter { target, deadline in
                guard let (p, t) = snoozeIndices(target) else { return false }
                return workspace.projects[p].conversations[t].snoozeStatus(at: current) == .snoozed(until: deadline)
            }
            snoozeUndo = notice.expiresAt > current && !valid.isEmpty
                ? SnoozeUndo(deadlines: valid, expiresAt: notice.expiresAt) : nil
        }
        let undoCount = snoozeUndo?.deadlines.count ?? 0
        if snoozeUndoCount != undoCount { snoozeUndoCount = undoCount }

        let nextWake = threadProjects.lazy.flatMap(\.conversations).compactMap { thread -> Date? in
            guard case let .snoozed(until: deadline) = thread.snoozeStatus(at: current) else { return nil }
            return deadline
        }.min()
        if snoozeClock != current { snoozeClock = current }
        let nextUpdate = [nextWake, snoozeUndo?.expiresAt].compactMap { $0 }.min()
        if nextSnoozeUpdate == nextUpdate, snoozeTimer?.isValid == true { return }
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        nextSnoozeUpdate = nextUpdate
        if let nextUpdate {
            let timer = Timer(timeInterval: nextUpdate.timeIntervalSince(current), repeats: false) { [weak self] timer in
                MainActor.assumeIsolated {
                    timer.invalidate()
                    self?.refreshSnoozes()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            snoozeTimer = timer
        }
    }

    private func snoozeIndices(_ target: ThreadSnoozeTarget) -> (Int, Int)? {
        guard let p = workspace.projects.firstIndex(where: { $0.id == target.projectID && $0.detached != true }),
              let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == target.threadID }) else { return nil }
        return (p, t)
    }

    private func wakeForRuntimeRequest() {
        guard let thread = conversation, let deadline = thread.snoozedUntil else { return }
        let current = now()
        guard deadline > current else { return }
        try? saveThread(thread.id) { $0.snoozedUntil = current }
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
        let affectsActiveProject: Bool
        switch scope {
        case .workspace:
            updated.model = settings
            affectsActiveProject = true
        case .project(let id):
            let index = try modelSettingsProjectIndex(id)
            let inherited = try? workspace.model.validated()
            if updated.projects[index].modelOverride != nil || settings != inherited {
                updated.projects[index].modelOverride = settings
            }
            affectsActiveProject = project?.id == id
        }

        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = !removeKey && !key.isEmpty ? try KeyVault.validatedKey(key) : nil
        try persist(updated)
        defer {
            if affectsActiveProject || removeKey || replacement != nil { connect() }
        }
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
            let location: ThreadLocation
            switch choice {
            case .project:
                location = .project
            case let .existing(path):
                guard let checkout = try await git.worktrees().first(where: { $0.path == path }) else {
                    throw WorkspaceError("This worktree is no longer registered with the repository.")
                }
                location = .worktree(path: checkout.path, base: nil)
            case let .create(branch, base):
                let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
                location = .newWorktree(branch: branch, base: base)
            }
            if location != conversation.workingLocation, let checkout = conversation.worktreeLaunch?.checkout,
               checkout.path != location.directory(in: project) {
                try await git.discardPendingCheckout(checkout, attached: false)
            }
            return location
        }
        try saveThread(conversation.id) { thread in
            if !location.needsWorktree {
                thread.worktreeStartsFromRemote = nil
            } else if !thread.workingLocation.needsWorktree {
                thread.worktreeStartsFromRemote = workspace.startNewWorktreesFromRemote
            }
            if thread.workingLocation != location, var launch = thread.worktreeLaunch {
                launch.stage = location.needsWorktree ? .createCheckout : .openThread
                launch.failure = nil
                launch.checkout = nil
                launch.id = UUID()
                thread.worktreeLaunch = launch
            }
            thread.location = location
        }
        if let thread = self.project?.conversations.first(where: { $0.id == conversation.id }),
           let files = WorkspaceFilesLocation(thread: thread, project: project) {
            fileSaves.recoverMovedDrafts(in: files)
        }
        connect()
    }

    struct BranchPickerScope: Equatable, Identifiable {
        let projectID: UUID
        let threadID: UUID
        let location: ThreadLocation
        let directory: String

        var id: UUID { threadID }
    }

    var branchPickerScope: BranchPickerScope? {
        guard let project, !project.isScratch, let conversation else { return nil }
        let location = conversation.workingLocation
        return BranchPickerScope(projectID: project.id, threadID: conversation.id, location: location,
                                 directory: location.directory(in: project))
    }

    var branchChangeBlocked: String? {
        if phase.isRunning { return "Stop the current turn to switch branches or worktrees." }
        if operationsInProgress { return "Wait for the active operation to finish." }
        guard let conversation, !conversation.archived else { return "Restore the thread to change its branch." }
        if conversation.worktreeLaunch != nil { return "Finish or cancel worktree setup before changing branches." }
        if conversation.composerSubmission != nil { return "Wait for the current message to finish saving." }
        return nil
    }

    enum BranchChoice {
        case existing(String)
        case create(name: String, base: String)
    }

    func updateWorktreeStartsFromRemote(_ enabled: Bool, in scope: BranchPickerScope) throws {
        guard branchPickerScope == scope, scope.location.needsWorktree else {
            throw WorkspaceError("The selected thread or checkout changed. Open the branch picker again.")
        }
        if let reason = branchChangeBlocked { throw WorkspaceError(reason) }
        try saveThread(scope.threadID) { $0.worktreeStartsFromRemote = enabled }
    }

    func changeThreadBranch(_ choice: BranchChoice, in scope: BranchPickerScope) async throws {
        guard branchPickerScope == scope, let project else {
            throw WorkspaceError("The selected thread or checkout changed. Open the branch picker again.")
        }
        if let reason = branchChangeBlocked { throw WorkspaceError(reason) }

        let pending = Set(workspace.projects.flatMap(\.conversations).flatMap { thread -> [String] in
            guard let launch = thread.worktreeLaunch else { return [] }
            if let checkout = launch.checkout { return [checkout.path] }
            if case let .worktree(path, _) = thread.workingLocation { return [path] }
            return []
        }.map(GitWorkspace.canonicalCheckoutPath))
        let git = GitWorkspace(path: scope.directory)
        try await performGitMutation {
            switch choice {
            case let .existing(refID):
                if case let .newWorktree(branch, _) = scope.location {
                    guard try await git.branchRefs().contains(where: { $0.id.utf8.elementsEqual(refID.utf8) }) else {
                        throw WorkspaceError("The selected base branch is no longer available.")
                    }
                    try saveThread(scope.threadID) { $0.location = .newWorktree(branch: branch, base: refID) }
                } else if let destination = try await git.switchBranch(to: refID, protecting: pending,
                                                                       beforeSwitch: fileSaves.flushBeforeSwitchingBranch) {
                    guard queueEdit == nil else {
                        throw WorkspaceError("Finish editing the queued message before moving this thread.")
                    }
                    let location: ThreadLocation = destination == GitWorkspace.canonicalCheckoutPath(project.path)
                        ? .project : .worktree(path: destination, base: nil)
                    try saveThread(scope.threadID) { $0.location = location }
                    if let thread = conversation, let files = WorkspaceFilesLocation(thread: thread, project: project) {
                        fileSaves.recoverMovedDrafts(in: files)
                    }
                    connect()
                }
            case let .create(name, base):
                guard !scope.location.needsWorktree else {
                    throw WorkspaceError("Use Thread workspace to name the branch that will be created on first send.")
                }
                try await git.createBranch(name, from: base, protecting: pending,
                                           beforeSwitch: fileSaves.flushBeforeSwitchingBranch)
            }
        }
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
        let text = promptText
        let attachments = conversation.composerAttachments
        let submissionID = attachments == nil ? nil : UUID()
        do {
            guard try canUsePrompt(text, attachments: attachments, fromComposer: true) else { return }
            if conversation.workingLocation.needsWorktree {
                let launch = WorktreeLaunch(prompt: text, originalDraft: draft)
                try saveThread(conversation.id) {
                    $0.composerText = nil
                    $0.worktreeLaunch = launch
                }
                startWorktreeLaunch(launch, in: conversation)
                return
            }
            let submission = Conversation.ComposerSubmission(
                previousUserMessageID: messages.last { $0.role == .user }?.id, id: submissionID
            )
            try saveThread(conversation.id) { $0.composerSubmission = submission }
        } catch {
            self.error = error.localizedDescription
            return
        }
        do {
            if queuedMessages.isEmpty { queueDelivery.paused = false }
            try beginTurn(text, using: process, submissionID: submissionID, attachments: attachments)
        } catch {
            self.error = "Pi is unavailable. Reconnect to send your message."
            shutdown()
        }
    }

    func queueDraft(steering: Bool = false) {
        guard canQueueDraft, !steering || canSteer else { return }
        do {
            let text = promptText
            let attachments = conversation?.composerAttachments
            guard try canUsePrompt(text, attachments: attachments, fromComposer: true) else { return }
            let item = QueuedMessage(text: text, attachments: attachments)
            guard let id = conversation?.id else { return }
            try saveThread(id) { thread in
                thread.queuedMessages = (thread.queuedMessages ?? []) + [item]
                thread.composerText = nil
                thread.composerAttachments = nil
            }
            error = nil
            if steering { sendQueuedMessageNow(item.id) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func editQueuedMessage(_ id: UUID) {
        guard canStartEditingQueuedMessage, let item = queuedMessages.first(where: { $0.id == id }) else { return }
        queueEdit = QueueEdit(id: id, text: item.text, attachments: item.attachments)
    }

    func updateQueuedMessage() {
        guard canUpdateQueuedMessage, let edit = queueEdit else { return }
        do {
            let text = promptText
            guard try canUsePrompt(text, attachments: edit.attachments, fromComposer: true) else { return }
            try saveQueue { queue in
                guard let index = queue.firstIndex(where: { $0.id == edit.id }) else { return }
                queue[index].text = text
                queue[index].attachments = edit.attachments
            }
            cancelQueuedMessageEdit()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancelQueuedMessageEdit() {
        guard queueEdit != nil else { return }
        queueEdit = nil
        drainQueue()
    }

    func removeQueuedMessage(_ id: UUID) {
        guard canEditQueue, queueEdit?.id != id, queuedMessages.contains(where: { $0.id == id }) else { return }
        try? saveQueue { $0.removeAll { $0.id == id } }
    }

    func moveQueuedMessageToFront(_ id: UUID) {
        guard canEditQueue, queueEdit?.id != id, queuedMessages.first?.id != id,
              let item = queuedMessages.first(where: { $0.id == id }) else { return }
        do {
            try saveQueue { queue in
                queue.removeAll { $0.id == id }
                queue.insert(item, at: 0)
            }
            drainQueue()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resumeQueuedMessages() {
        guard queueDelivery.paused, canStartQueuedMessage, let item = queuedMessages.first,
              queueEdit?.id != item.id else { return }
        startQueuedMessage(item)
    }

    func sendQueuedMessageNow(_ id: UUID) {
        guard canUseQueue, queueEdit?.id != id, let item = queuedMessages.first(where: { $0.id == id }) else { return }
        if canStartQueuedMessage {
            startQueuedMessage(item)
            return
        }
        guard let process, let activeTurnID, canSteer || canSkipCompaction else { return }
        guard validateQueuedPrompt(item) else { return }
        do {
            let skipping = canSkipCompaction
            try process.send(SendQueuedInput(type: skipping ? .skipCompaction : .steer, turnID: activeTurnID,
                                             queuedID: item.id, text: skipping ? nil : item.text,
                                             attachments: skipping ? nil : item.attachments))
            queueDelivery.inFlight.insert(item.id)
            if skipping { queueDelivery.mode = .waiting }
        } catch {
            connectionFailed("Pi disconnected while sending a queued message. Reconnect to try again.")
        }
    }

    private func saveQueue(_ edit: (inout [QueuedMessage]) -> Void) throws {
        guard let id = conversation?.id else { throw WorkspaceError("Select a thread first.") }
        try saveThread(id) {
            var queue = $0.queuedMessages ?? []
            edit(&queue)
            $0.queuedMessages = queue.isEmpty ? nil : queue
        }
    }

    private func reconcileQueue(_ history: [ChatMessage]) {
        let recorded = Set(history.compactMap(\.queuedID))
        guard conversation?.queuedMessages?.contains(where: { recorded.contains($0.id) }) == true else { return }
        do {
            try saveQueue { $0.removeAll { recorded.contains($0.id) } }
        } catch {
            queueDelivery.paused = true
        }
    }

    private func startQueuedMessage(_ item: QueuedMessage, skippingCompaction: Bool = false) {
        guard canStartQueuedMessage, let process else { return }
        queueDelivery.paused = true
        guard validateQueuedPrompt(item) else { return }
        do {
            try beginTurn(item.text, using: process, queuedID: item.id, skippingCompaction: skippingCompaction,
                          attachments: item.attachments)
            queueDelivery.inFlight.insert(item.id)
            queueDelivery.paused = false
        } catch {
            connectionFailed("Could not send the queued message. Reconnect to try again.")
        }
    }

    private func validateQueuedPrompt(_ item: QueuedMessage) -> Bool {
        do {
            return try canUsePrompt(item.text, attachments: item.attachments)
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func drainQueue() {
        guard canStartQueuedMessage, !queueDelivery.paused,
              let first = queuedMessages.first, queueEdit?.id != first.id else { return }
        startQueuedMessage(first)
    }

    func retryWorktree() {
        guard canRetryWorktree, let conversation, let launch = conversation.worktreeLaunch else { return }
        if launch.interruption != nil {
            finishWorktreeInterruption()
            return
        }
        do {
            guard try canUsePrompt(launch.prompt, attachments: conversation.composerAttachments) else { return }
            startWorktreeLaunch(launch, in: conversation)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func canUsePrompt(_ text: String, attachments: [ComposerAttachment]? = nil,
                              fromComposer: Bool = false) throws -> Bool {
        if let reason = attachmentSendError(for: attachments ?? []) { throw WorkspaceError(reason) }
        let settings = try effectiveModel.validated()
        guard let key = try readCredential(settings.account) else {
            openSettings(.model, anchor: .apiKey)
            return false
        }
        guard key.isEmpty || !text.contains(key) else {
            if fromComposer { draft = "" }
            error = "Enter your API key in Model Settings."
            return false
        }
        if !key.isEmpty, (attachments ?? []).contains(where: {
            $0.name.contains(key) || ($0.payload.map { !$0.isImage && String(decoding: $0.data, as: UTF8.self).contains(key) } ?? false)
        }) {
            throw WorkspaceError("Remove the attachment that contains your API key.")
        }
        return true
    }

    private func startWorktreeLaunch(_ launch: WorktreeLaunch, in thread: Conversation) {
        guard let store, let project else { return }
        // Older launches without an ID may already have created a checkout under the default root.
        let worktreesDirectory = launch.id == nil ? nil : workspace.worktreesDirectory
        shutdown()
        preparingWorktree = true
        error = nil
        worktreeTask = Task {
            let stage: WorktreeLaunch.Stage = thread.workingLocation.needsWorktree ? .createCheckout : .openThread
            var failure: Error?
            do {
                try Task.checkCancellation()
                var location = thread.workingLocation
                if case let .newWorktree(branch, base) = location {
                    let git = GitWorkspace(path: project.path)
                    let path = try await runGitMutation {
                        let checkout: GitWorkspace.PendingCheckout
                        if let pinned = launch.checkout {
                            checkout = pinned
                        } else {
                            let target = try store.worktree(project: project.id, conversation: thread.id,
                                                            directory: worktreesDirectory)
                            checkout = try await git.pinWorktree(at: target.path, branch: branch, base: base,
                                                                owner: launch.id ?? thread.id, legacy: launch.id == nil,
                                                                startFromRemote: thread.worktreeStartsFromRemote == true)
                            try Task.checkCancellation()
                            try saveThread(thread.id) { $0.worktreeLaunch?.checkout = checkout }
                        }
                        return try await git.createWorktree(checkout, legacy: launch.id == nil)
                    }
                    location = .worktree(path: path, base: base)
                }
                try Task.checkCancellation()
                try saveThread(thread.id) {
                    $0.location = location
                    $0.worktreeLaunch?.stage = .openThread
                    $0.worktreeLaunch?.failure = nil
                }
            } catch {
                failure = error
            }
            guard worktreeTask != nil else { return }
            worktreeTask = nil
            if conversation?.worktreeLaunch?.interruption != nil {
                finishWorktreeInterruption()
            } else if let failure {
                failWorktreeLaunch(at: stage, message: failure.localizedDescription)
            } else {
                connect()
            }
        }
    }

    func interruptWorktree(_ interruption: WorktreeLaunch.Interruption, threadID: UUID, launchID: UUID?) {
        guard canInterruptWorktree, let conversation, conversation.id == threadID,
              conversation.worktreeLaunch?.id == launchID,
              interruption == .cancel || canWorkLocally else { return }
        do {
            try saveThread(conversation.id) {
                $0.worktreeLaunch?.interruption = interruption
                $0.worktreeLaunch?.failure = nil
            }
        } catch { return }
        shutdown()
        if let worktreeTask {
            worktreeTask.cancel()
        } else {
            finishWorktreeInterruption()
        }
    }

    private func finishWorktreeInterruption() {
        guard worktreeTask == nil, let project, let conversation,
              let launch = conversation.worktreeLaunch, let interruption = launch.interruption else { return }
        preparingWorktree = true
        error = nil
        worktreeTask = Task {
            do {
                if let checkout = launch.checkout {
                    try await runGitMutation {
                        try await GitWorkspace(path: project.path)
                            .discardPendingCheckout(checkout, attached: !conversation.workingLocation.needsWorktree)
                    }
                }
                try Task.checkCancellation()
                try saveThread(conversation.id) { thread in
                    if interruption == .workLocally {
                        thread.location = .project
                        thread.worktreeStartsFromRemote = nil
                        thread.worktreeLaunch?.id = UUID()
                        thread.worktreeLaunch?.stage = .openThread
                        thread.worktreeLaunch?.checkout = nil
                        thread.worktreeLaunch?.interruption = nil
                        thread.worktreeLaunch?.failure = nil
                    } else {
                        if let checkout = launch.checkout,
                           case let .worktree(path, base) = thread.workingLocation, path == checkout.path {
                            thread.location = .newWorktree(branch: checkout.branch, base: base ?? checkout.head)
                        }
                        thread.composerText = thread.composerText ?? launch.originalDraft ?? launch.prompt
                        thread.worktreeLaunch = nil
                    }
                }
                worktreeTask = nil
                preparingWorktree = false
                if interruption == .workLocally {
                    retryWorktree()
                } else {
                    connect()
                }
            } catch {
                guard worktreeTask != nil else { return }
                worktreeTask = nil
                failWorktreeLaunch(at: launch.stage, message: error.localizedDescription)
            }
        }
    }

    private func failWorktreeLaunch(at stage: WorktreeLaunch.Stage, message: String) {
        defer { preparingWorktree = false }
        guard let conversation, conversation.worktreeLaunch != nil else { return }
        do {
            try saveThread(conversation.id) {
                $0.worktreeLaunch?.stage = stage
                $0.worktreeLaunch?.failure = message
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func beginTurn(_ text: String, using process: any PiConnection, queuedID: UUID? = nil,
                           skippingCompaction: Bool = false, submissionID: UUID? = nil,
                           attachments: [ComposerAttachment]? = nil) throws {
        let turnID = UUID()
        try process.send(SendPrompt(turnID: turnID, text: text, queuedID: queuedID,
                                    skipCompaction: skippingCompaction ? true : nil, submissionID: submissionID,
                                    attachments: attachments))
        activeTurnID = turnID
        partial = ""
        activity = ""
        error = nil
        phase = .running
        if let thread = conversation, thread.snoozedUntil != nil {
            try? saveThread(thread.id) { $0.snoozedUntil = nil }
        }
    }

    func cancel() {
        guard phase == .running, let process, let activeTurnID else { return }
        pendingToolApproval = nil
        pendingAgentQuestion = nil
        queueDelivery.paused = true
        queueDelivery.skipAfterTurn = nil
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

    func respond(to scope: AgentQuestionScope, with decision: AgentQuestionReply.Decision) {
        guard phase == .running, let process, let pending = pendingAgentQuestion,
              pending.request.scope == scope, scope.turnID == activeTurnID,
              scope.threadID == conversation?.id, !pending.submitting else { return }
        if case .answer(let answers) = decision {
            let text = answers.compactMap { answer -> String? in
                if case .text(let text) = answer.value { return text }
                return nil
            }
            if !text.isEmpty {
                do {
                    if let key = try readCredential(effectiveModel.validated().account), !key.isEmpty,
                       text.contains(where: { $0.contains(key) }) {
                        pendingAgentQuestion?.error = "Remove the API key from your answer."
                        return
                    }
                } catch {
                    pendingAgentQuestion?.error = error.localizedDescription
                    return
                }
            }
        }
        pendingAgentQuestion?.error = nil
        pendingAgentQuestion?.submitting = true
        do {
            try process.send(AgentQuestionReply(scope: scope, decision: decision))
        } catch {
            connectionFailed("The Pi helper disconnected while sending the question response.")
        }
    }

    private var selectedProjectIndex: Int? {
        workspace.projects.firstIndex { $0.id == workspace.selectedProject }
    }

    private func resetConnection() {
        shutdown()
        messages = []
        partial = ""
        activity = ""
        repositoryRevision += 1
    }

    func connect() {
        guard worktreeTask == nil, forkRequest == nil else { return }
        resetConnection()
        guard let store, let project, let conversation, let directory = workingDirectory else { return }
        error = nil
        if conversation.worktreeLaunch?.interruption != nil {
            finishWorktreeInterruption()
            return
        }
        if let launch = conversation.worktreeLaunch, !preparingWorktree, !launch.awaitingHistory { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            connectionFailed("The thread’s workspace folder is no longer available.")
            return
        }
        do {
            let command = try openCommand(project: project, thread: conversation, store: store)
            let worker = try makeProcess(store.config, directory)
            attach(worker, account: command.config.account)
            try worker.send(command)
        } catch {
            connectionFailed(error.localizedDescription)
        }
    }

    private func openCommand(project: Project, thread: Conversation, store: WorkspaceStore) throws -> OpenConversation {
        try OpenConversation(cwd: thread.workingLocation.directory(in: project),
                             sessionDir: store.history(project: project.id, conversation: thread.id).path,
                             threadID: thread.id.uuidString, config: (project.modelOverride ?? workspace.model).validated(),
                             toolPermission: project.toolPermission, forkMessageID: thread.forkOrigin?.messageID)
    }

    private func attach(_ worker: any PiConnection, account: String) {
        phase = .connecting
        process = worker
        worker.onEvent = { [weak self, weak worker] event in
            guard let self, let worker, self.process === worker else { return }
            self.receive(event, from: worker, account: account)
        }
        worker.onClose = { [weak self, weak worker] in
            guard let self, let worker, self.process === worker else { return }
            self.connectionFailed(self.error ?? "The Pi helper exited. Reconnect to this conversation.")
        }
    }

    private func connectionFailed(_ message: String) {
        if let pending = pendingThreadLink, pending.worker === process { rejectPendingThreadLink(message) }
        shutdown()
        if preparingWorktree {
            failWorktreeLaunch(at: .openThread, message: message)
        } else {
            error = message
        }
    }

    private func submitWorktreePrompt(using worker: any PiConnection) {
        guard let conversation, let launch = conversation.worktreeLaunch,
              launch.stage == .openThread, launch.canInterrupt else { return }
        do {
            guard try canUsePrompt(launch.prompt, attachments: conversation.composerAttachments) else {
                throw WorkspaceError("Save an API key for this provider in Settings.")
            }
            try saveThread(conversation.id) {
                $0.worktreeLaunch?.stage = .sendPrompt
            }
        } catch {
            shutdown()
            failWorktreeLaunch(at: .openThread, message: error.localizedDescription)
            return
        }
        preparingWorktree = false
        do {
            let attachments = conversation.composerAttachments
            try beginTurn(launch.prompt, using: worker, submissionID: attachments == nil ? nil : launch.id,
                          attachments: attachments)
            queueDelivery.paused = false
        } catch {
            connectionFailed("Pi disconnected while sending the message. Reconnect to check its history.")
        }
    }

    @discardableResult
    private func confirmWorktreePrompt(in history: [ChatMessage]) -> Bool {
        guard let conversation, let launch = conversation.worktreeLaunch else { return false }
        let accepted = if conversation.composerAttachments != nil, let id = launch.id {
            history.contains { $0.role == .user && $0.submissionID == id }
        } else {
            history.first(where: { $0.role == .user })?.text == launch.prompt
        }
        guard accepted else { return false }
        preparingWorktree = false
        try? saveThread(conversation.id) {
            let nextDraft = $0.composerText
            $0.recordPrompt(launch.prompt)
            $0.composerText = nextDraft
            $0.worktreeLaunch = nil
        }
        return true
    }

    private func reconcileComposerSubmission(in history: [ChatMessage], ended: Bool = false) {
        guard let conversation, let submission = conversation.composerSubmission else { return }
        let text = conversation.composerText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latest = history.last { $0.role == .user }
        let accepted = if let id = submission.id {
            history.contains { $0.role == .user && $0.submissionID == id }
        } else {
            latest.map { $0.id != submission.previousUserMessageID && $0.text == text } ?? false
        }
        guard accepted || ended else { return }
        guard let p = selectedProjectIndex,
              let t = workspace.projects[p].conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        if accepted {
            workspace.projects[p].conversations[t].recordPrompt(text)
        } else {
            workspace.projects[p].conversations[t].composerSubmission = nil
        }
        composerDirty = true
        savePendingComposer()
    }

    func dismissUnconfirmedWorktreePrompt() {
        guard phase == .ready, !operationsInProgress,
              let conversation, !conversation.archived,
              conversation.worktreeLaunch?.awaitingHistory == true else { return }
        try? saveThread(conversation.id) {
            if $0.composerAttachments != nil, let launch = $0.worktreeLaunch {
                $0.composerText = launch.originalDraft
            }
            $0.worktreeLaunch = nil
        }
    }

    private func replyToCredential(_ id: String, read: Bool, account: String, worker: any PiConnection) throws {
        var result = CredentialResult(requestID: id)
        do {
            if read { result.key = try readCredential(account) }
            else { result.exists = try vault.exists(account) }
        } catch {
            result.error = true
        }
        try worker.send(result)
    }

    private func receive(_ event: PiEvent, from worker: any PiConnection, account: String) {
        switch event {
        case let .sentImage(requestID, image):
            sentImageRequests.removeValue(forKey: requestID)?.resume(returning: image)
        case let .credential(id, read):
            do {
                try replyToCredential(id, read: read, account: account, worker: worker)
            } catch {
                connectionFailed("The Pi helper disconnected during Keychain access.")
            }
        case let .ready(history, supportsImages):
            guard phase == .connecting else { return }
            messages = history
            supportsImageInput = supportsImages
            reconcileQueue(history)
            phase = .ready
            if let pending = pendingThreadLink, pending.worker === worker {
                pendingThreadLink = nil
                finishOpeningThreadLink()
                pending.result.resume(returning: true)
            }
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
            wakeForRuntimeRequest()
        case let .agentQuestion(request):
            guard phase == .running, request.scope.turnID == activeTurnID,
                  request.scope.threadID == conversation?.id,
                  !request.questions.isEmpty, pendingAgentQuestion == nil else { return }
            pendingAgentQuestion = PendingAgentQuestion(request: request)
            wakeForRuntimeRequest()
        case let .agentQuestionEnded(end):
            guard pendingAgentQuestion?.request.scope == end.scope else { return }
            pendingAgentQuestion = nil
            activity = ""
            if end.status == .expired {
                queueDelivery.paused = true
                queueDelivery.skipAfterTurn = nil
                phase = .stopping
                error = "The question expired and Pi stopped the turn. Send a new message to try again."
            }
        case let .agentQuestionRejected(scope):
            guard pendingAgentQuestion?.request.scope == scope else { return }
            pendingAgentQuestion?.submitting = false
            pendingAgentQuestion?.error = "Pi rejected the response. Review your answers and try again."
        case let .inputMode(turnID, mode):
            guard activeTurnID == turnID, phase == .running else { return }
            queueDelivery.mode = mode
        case let .queueRejected(turnID, queuedID, reason):
            guard activeTurnID == turnID, queueDelivery.inFlight.remove(queuedID) != nil else { return }
            queueDelivery.paused = true
            if phase == .running {
                error = (reason ?? "The turn reached a different stage.") + " The message stayed in the queue."
            }
        case let .compactionSkipped(turnID, queuedID):
            guard activeTurnID == turnID, phase == .running, queueDelivery.inFlight.contains(queuedID) else { return }
            queueDelivery.skipAfterTurn = queuedID
        case let .forked(threadID, error):
            finishFork(threadID, failure: error)
        case let .finished(turnID, history, error):
            guard activeTurnID == turnID else { return }
            let skipped = queueDelivery.skipAfterTurn
            let recorded = Set(history.compactMap(\.queuedID))
            var undelivered = queueDelivery.inFlight.subtracting(recorded)
            if let skipped { undelivered.remove(skipped) }
            queueDelivery.inFlight.removeAll()
            queueDelivery.skipAfterTurn = nil
            queueDelivery.mode = .waiting
            if error != nil || !undelivered.isEmpty { queueDelivery.paused = true }
            if let error { self.error = error }
            else if !undelivered.isEmpty && phase == .running { self.error = "The message stayed in the queue." }
            pendingToolApproval = nil
            pendingAgentQuestion = nil
            activeTurnID = nil
            messages = history
            partial = ""
            activity = ""
            repositoryRevision += 1
            phase = .ready
            if error != nil { wakeForRuntimeRequest() }
            reconcileComposerSubmission(in: history, ended: true)
            reconcileQueue(history)
            if !confirmWorktreePrompt(in: history), conversation?.worktreeLaunch?.awaitingHistory == true {
                self.error = nil
                failWorktreeLaunch(at: .sendPrompt, message: error ?? "Pi stopped before recording your message.")
            }
            if let skipped, let item = queuedMessages.first(where: { $0.id == skipped }) {
                startQueuedMessage(item, skippingCompaction: true)
            } else {
                drainQueue()
            }
        case let .fatal(error):
            connectionFailed(error)
        }
    }
}
