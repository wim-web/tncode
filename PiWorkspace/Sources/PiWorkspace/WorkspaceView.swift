import AppKit
import Carbon
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct DroppedProjectFolder: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw WorkspaceError("Choose a local folder.")
            }
            return Self(url: url)
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    let chatWidthMode: ChatWidth
    var browserDefaults: UserDefaults = .standard
    var workspacePasteboard: NSPasteboard = .general
    var attachmentSavePicker: ChatFileSavePicker = .native
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SidebarPreference.groupByProject) private var grouped = false
    @AppStorage(ComposerSendShortcut.key) private var sendShortcut = ComposerSendShortcut.initial
    @AppStorage(ComposerFollowUp.key) private var followUpBehavior = ComposerFollowUp.initial
    @State private var sidebarWidth = WorkspaceLayout.defaultSidebarWidth
    @GestureState private var sidebarDrag: CGFloat = 0
    @State private var rightPanelWidths: [UUID: CGFloat] = [:]
    @GestureState private var rightPanelDrag: CGFloat = 0
    @State private var query = ""
    @State private var showingSidebarFilters = false
    @State private var highlightedSearchThread: UUID?
    @State private var messageSearchResult: (key: MessageSearchKey, matches: [UUID: SidebarMessageSearch.Match])?
    @FocusState private var searchFocused: Bool
    @FocusState private var findFocused: Bool
    @State private var findSelection: ComposerTextField.FindSelection?
    @State private var showingDetails = false
    @State private var browserPanels: [UUID: ThreadBrowserPreview] = [:]
    @State private var rightPanels: [UUID: WorkspaceRightPanelState] = [:]
    @State private var addingPanelSurface: UUID?
    @State private var closingPanelTerminals: PanelTerminalClose?
    @State private var deletingSideChat: SideChatDeletion?
    @State private var selectedFiles: [WorkspaceFilesLocation: String] = [:]
    @State private var fileLineReveal: WorkspaceFileLineReveal?
    @State private var choosingWorkspace = false
    @State private var choosingBranch: WorkspaceModel.BranchPickerScope?
    @State private var loadedBranch: (scope: WorkspaceModel.BranchPickerScope, branch: String?)?
    @State private var restoreBranchComposerFocus = false
    @State private var terminalWorkspaceChange: UUID?
    @State private var choosingThreadProject = false
    @State private var focusAfterThreadChoice: DraftProjectScope?
    @State private var draftProjectPicker: DraftProjectPickerPresentation?
    @State private var composerModelPicker: ComposerModelPresentation?
    @State private var paletteChoosingProject = false
    @State private var paletteAction: CommandPaletteAction?
    @State private var paletteReturnFocus: PaletteReturnFocus?
    @State private var openTerminals: [ThreadTerminalDrawerState] = []
    @State private var terminalDrawerReservedHeight: CGFloat = 0
    @State private var settledExpanded = false
    @State private var customSnooze: SnoozeRequest?
    @State private var openOptionsAfterSnooze = false
    @State private var rename: RenameTarget?
    @State private var title = ""
    @State private var removingProject: Project?
    @State private var archiveConfirmation: ArchiveRequest?
    @State private var archiveFailure: ArchiveFailure?
    @State private var notice: Notice?
    @State private var checkoutsWithBranches: Set<String> = []
    @State private var copyTask: Task<Void, Never>?
    @FocusState private var focusedComposer: UUID?
    @FocusState private var focusedDraftProject: UUID?
    @State private var focusScratchHeadline: DraftProjectScope?
    @State private var composerFileMentionRevision: Int?
    @State private var showingComposerStash = false
    @FocusState private var welcomeFocus: WelcomeFocus?
    @State private var focusAfterPicker: DraftProjectScope?
    @State private var focusAfterPromptLink: DraftProjectScope?
    @State private var targetingProjectDrop = false
    @State private var targetingAttachmentRow: UUID?
    @State private var targetingComposerDrop = false
    @State private var imagePreview: ChatImagePreview?
    @State private var filePreview: ChatAttachment.Opener?
    @State private var fileSaveRequest: FileSaveRequest?
    @FocusState private var focusedAttachmentOpener: ChatAttachment.Opener?
    @FocusState private var focusedFileDownload: ChatAttachment.Opener?

    private struct FilePreviewContent: Equatable {
        let name: String
        var payload: ComposerAttachment.Payload?
    }

    private struct FileSaveRequest {
        let id = UUID()
        let opener: ChatAttachment.Opener
        let content: FilePreviewContent
        let fromPreview: Bool
        let threadRevision: Int
    }

    private struct ComposerModelPresentation {
        let scope: DraftProjectScope
        let options: [ComposerModelOption]
    }

    private struct ComposerModelAnchor: PreferenceKey {
        static var defaultValue: Anchor<CGRect>? { nil }
        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            value = nextValue() ?? value
        }
    }

    private struct PanelTerminalClose: Identifiable {
        enum Target {
            case tabs([WorkspacePanelTab])
            case pane(WorkspacePanelTab, Int)
        }

        let id = UUID()
        let thread: UUID
        let target: Target
        let panes: [Int]

        var title: String {
            if panes.count == 1, let pane = panes.first { return "Close Terminal \(pane)?" }
            return "Close \(panes.count) Terminals?"
        }
    }

    private struct Notice {
        let id: UUID
        let message: String
        let accessibilityID: String
    }

    private struct SnoozeRequest: Identifiable {
        let target: ThreadSnoozeTarget
        let fromSidebar: Bool
        var id: ThreadSnoozeTarget { target }
    }

    private struct ArchiveRequest {
        let projectID: UUID
        let threadID: UUID
        let title: String
    }

    private struct ArchiveFailure {
        let request: ArchiveRequest
        let message: String
    }

    private enum RenameTarget {
        case project(UUID)
        case conversation(UUID, project: UUID)

        var fieldLabel: String {
            switch self {
            case .project: "Project name"
            case .conversation: "Thread title"
            }
        }
    }

    private enum PaletteReturnFocus {
        case search
        case composer(UUID)
        case threadFind
    }

    private struct DraftProjectPickerPresentation: Identifiable {
        let id = UUID()
        let scope: DraftProjectScope
        let restoreComposerFocus: Bool
    }

    private enum WelcomeFocus: Hashable {
        case finish, addProject
    }

    private struct MessageSearchKey: Equatable {
        let search: SidebarMessageSearch
        let latestMessageID: String?
    }

    private struct BranchReadRequest: Equatable {
        let scope: WorkspaceModel.BranchPickerScope?
        let revision: Int
    }

    private struct CopyBranchReadRequest: Equatable {
        let paths: Set<String>
        let revision: Int
    }

    private struct SearchRow: Identifiable {
        let thread: SidebarThread
        let match: SidebarMessageSearch.Match?
        var id: String { thread.id.uuidString + "/" + (match?.messageID ?? "") }
    }

    private struct SnoozedRow: Identifiable {
        let link: SidebarThread
        let deadline: Date
        var id: String { "snoozed-\(link.id)" }
    }

    private enum TranscriptAnchor: Hashable {
        case message(String)
        case latest
    }

    private var projectFilter: SidebarProjectFilter { model.sidebarProjectFilter }
    private var orderedProjects: [Project] { SidebarProjectFilter.orderedProjects(model.projects) }
    private var filteredProjects: [Project] { projectFilter.projects(in: orderedProjects) }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var threads: [SidebarThread] {
        let scope = projectFilter.selection.isEmpty ? model.threadProjects : filteredProjects
        return SidebarThread.matching(in: scope, search: "", archived: model.showArchive)
            .filter { $0.project.isScratch || model.showsInSidebar($0.thread) }
    }

    private var rail: Color { colorScheme == .dark ? Color(white: 3 / 255) : Color(white: 0.955) }
    private var canvas: Color { colorScheme == .dark ? .black : Color(nsColor: .textBackgroundColor) }
    private var workspaceEdge: Color? { colorScheme == .dark ? Color(white: 20 / 255) : nil }
    private var emptyStateForeground: Color { Color(white: colorScheme == .dark ? 0.63 : 0.41) }
    private var surface: Color { colorScheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.042) }
    private let accent = Color(red: 0.24, green: 0.48, blue: 0.70)

    var body: some View {
        workspaceBody
            .overlayPreferenceValue(ComposerModelAnchor.self) { anchor in
                if let anchor, let picker = composerModelPicker, imagePreview == nil, filePreview == nil {
                    composerModelOverlay(picker, anchoredAt: anchor)
                }
            }
            .onChange(of: model.canChooseComposerModel) { _, canChoose in
                if !canChoose { composerModelPicker = nil }
            }
            .onChange(of: model.showingSettings) { _, showing in
                if showing { composerModelPicker = nil }
            }
    }

    private func workspaceSurface(images: [ChatImagePreview.ImageItem], imageIndex: Int?,
                                  fileContent: FilePreviewContent?) -> some View {
        let blocked = model.showingWelcome || imageIndex != nil || fileContent != nil || deletingSideChat != nil
        let saveRequest = fileSavePanelRequest
        return ZStack {
            GeometryReader { window in
                let viewportWidth = window.size.width
                let width = WorkspaceLayout.sidebarWidth(in: viewportWidth, preferred: sidebarWidth, drag: sidebarDrag)
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: width)
                    WorkspaceDivider(label: "Resize sidebar", width: width, drag: $sidebarDrag,
                                     color: workspaceEdge) { translation in
                        sidebarWidth = WorkspaceLayout.sidebarWidth(
                            in: viewportWidth, preferred: sidebarWidth, drag: translation)
                    }
                    .zIndex(1)
                    detail(viewport: window.size)
                }
            }
            .opacity(model.showingWelcome ? 0 : 1)
            .accessibilityHidden(blocked)
            .disabled(blocked)
            if model.showingWelcome { welcome }
            if let imagePreview, let imageIndex {
                ChatImagePreviewDialog(items: images, index: imageIndex, close: closeImagePreview,
                                       navigate: navigateImagePreview, load: { item in
                    if case .sent(let threadID, let messageID) = imagePreview.opener.owner {
                        return await model.readSentImage(threadID: threadID, messageID: messageID, attachmentID: item.id)
                    }
                    return item.payload
                }, pasteboard: workspacePasteboard)
            }
            if let filePreview, let fileContent {
                filePreviewDialog(filePreview, content: fileContent)
                    .id(filePreview)
            }
            if let request = deletingSideChat {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                SideChatDeleteConfirmation(request: request) { confirmed in
                    finishSideChatDeletion(request, confirmed: confirmed)
                }
            }
        }
        .onChange(of: imageIndex) { _, index in
            if index == nil { closeImagePreview() }
        }
        .onChange(of: fileContent) { _, content in
            if content == nil { filePreview = nil }
        }
        .onChange(of: saveRequest?.id) { _, id in
            if id == nil { fileSaveRequest = nil }
        }
        .background(ChatFileSavePanel(request: saveRequest, picker: attachmentSavePicker))
        .tint(accent)
        .background {
            WindowKeyMonitor { event, window in
                guard imageIndex == nil else { return false }
                if fileContent != nil {
                    if event.keyCode == kVK_Escape, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                        closeFilePreview()
                        return true
                    }
                    return false
                }
                if let request = deletingSideChat {
                    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                    if modifiers.isEmpty && event.keyCode == kVK_Escape {
                        finishSideChatDeletion(request, confirmed: false)
                        return true
                    }
                    return modifiers.contains(.command)
                }
                if showingComposerStash, event.keyCode == kVK_Escape,
                   event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                   acceptsWorkspaceKeys(in: window),
                   (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true {
                    showingComposerStash = false
                    return true
                }
                if handleFindKey(event, in: window) { return true }
                guard !event.isARepeat else { return false }
                if case .toggle? = CommandPaletteSession.Key(event) {
                    return openCommandPalette(in: window)
                }
                if handleNewThreadKey(event, in: window) { return true }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if handleRightPanelKey(event, modifiers: modifiers, in: window) { return true }
                if modifiers == .command, event.keyCode == kVK_Return, acceptsWorkspaceKeys(in: window),
                   let editor = window.firstResponder as? ComposerTextField.Editor,
                   let id = editor.owner?.composerTarget?.threadID, let parent = model.conversation?.id,
                   rightPanels[parent]?.visibleTab == .sideChat(id), let project = model.project {
                    if !editor.hasMarkedText() {
                        model.sendSideChat(.init(projectID: project.id, parentID: parent, id: id))
                    }
                    return true
                }
                if modifiers == .command {
                    switch event.charactersIgnoringModifiers {
                    case "[": return navigate(.back, in: window)
                    case "]": return navigate(.forward, in: window)
                    default: break
                    }
                }
                if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "s",
                   acceptsWorkspaceKeys(in: window),
                   (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true {
                    if WorkspaceFilesView.saveFocusedFile(in: window) { return true }
                    guard let editor = window.firstResponder as? ComposerTextField.Editor,
                          let target = editor.owner?.composerTarget, model.conversation?.id == target.threadID,
                          model.attachmentTarget(for: target.threadID) == target, model.conversation?.archived == false,
                          model.pendingToolApproval == nil, model.pendingAgentQuestion == nil else { return false }
                    return handleComposerStashShortcut()
                }
                if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "u",
                   acceptsWorkspaceCommands(in: window) {
                    model.openSettings(.usage)
                    return true
                }
                guard modifiers == [.command, .shift], acceptsWorkspaceCommands(in: window) else { return false }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "x" where model.canChangeWorkspace:
                    chooseWorkspace()
                    return true
                case "g" where branchDisplay != nil:
                    return openBranchPicker()
                default:
                    return false
                }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .background(ThreadTerminalKeyboard())
    }

    private var workspaceContent: some View {
        let findRequest = model.activeThreadFind?.request
        let images = imagePreview.map { previewImages(for: $0.opener.owner) } ?? []
        let imageIndex = imagePreview?.index(in: images)
        let fileContent = filePreview.flatMap { filePreviewContent(for: $0) }
        return workspaceSurface(images: images, imageIndex: imageIndex, fileContent: fileContent)
        .onReceive(model.sidebarCommand) { command in
            if imageIndex == nil && fileContent == nil && deletingSideChat == nil { handleSidebarCommand(command) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSnoozes()
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing) {
                if let archiveFailure {
                    archiveFailureNotice(archiveFailure)
                }
                if let notice {
                    Text(notice.message)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier(notice.accessibilityID)
                        .task(id: notice.id) {
                            try? await Task.sleep(for: .seconds(3))
                            if !Task.isCancelled { self.notice = nil }
                        }
                }
            }
        }
        .onChange(of: model.threadFindScope) { _, scope in
            findSelection = nil
            if model.threadFind?.thread != scope { model.threadFind = nil }
        }
        .onChange(of: model.draftProjectScope) { _, scope in
            if focusScratchHeadline != scope { focusScratchHeadline = nil }
            if let draftProjectPicker, draftProjectPicker.scope != scope { self.draftProjectPicker = nil }
            if composerModelPicker?.scope != scope { composerModelPicker = nil }
            showingComposerStash = false
        }
        .onChange(of: model.conversation?.id) { _, _ in
            addingPanelSurface = nil
            deletingSideChat = nil
        }
        .onChange(of: model.threadSelectionRevision) { _, _ in
            filePreview = nil
            fileSaveRequest = nil
        }
        .onChange(of: model.sideChatToOpen) { _, request in
            if let scope = request?.scope, model.conversation?.id == scope.parentID {
                rightPanels[scope.parentID, default: .init()].show(.sideChat(scope.id))
            }
        }
        .onChange(of: model.messages.last?.id) { _, _ in
            if model.activeThreadFind != nil { model.threadFind?.refresh() }
        }
        .task(id: findRequest) {
            if let findRequest { await loadFindMatches(findRequest) }
        }
        .onChange(of: model.showingWelcome) { _, showing in
            if showing {
                searchFocused = false
                focusedComposer = nil
            } else if model.projectPicker == nil {
                focusCurrentComposer()
            }
        }
    }

    private func handleSidebarCommand(_ command: WorkspaceModel.SidebarCommand) {
        switch command {
        case .commandPalette: openCommandPalette()
        case .newThread, .newScratchThread:
            guard let window = NSApp.mainWindow, acceptsWorkspaceKeys(in: window),
                  !model.operationsInProgress else { return }
            if command == .newThread {
                openNewThread(in: window)
            } else {
                startScratchThread()
            }
        case .search:
            guard !model.showingWelcome, !model.showingCommandPalette,
                  NSApp.mainWindow?.attachedSheet == nil else { return }
            searchFocused = true
        }
    }

    private var workspaceBody: some View {
        let branchRequest = copyBranchReadRequest
        return workspaceContent
        .sheet(isPresented: $model.showingCommandPalette, onDismiss: finishCommandPalette) {
            CommandPaletteView(contents: paletteContents, latestMessageID: model.messages.last?.id,
                               choosingProject: paletteChoosingProject,
                               filesLocation: paletteFilesLocation, activeFilesLocation: { paletteFilesLocation },
                               searchMessages: model.searchMessages) { action in
                guard model.showingCommandPalette else { return }
                paletteAction = action
                model.showingCommandPalette = false
            }
        }
        .task(id: branchRequest) {
            var checkouts: Set<String> = []
            for path in branchRequest.paths {
                if Task.isCancelled { return }
                if let branch = try? await GitWorkspace(path: path).currentBranch(), !branch.isEmpty {
                    checkouts.insert(path)
                }
            }
            if !Task.isCancelled { checkoutsWithBranches = checkouts }
        }
        .sheet(isPresented: $choosingWorkspace) {
            if let project = model.project { ThreadLocationView(project: project, model: model) }
        }
        .sheet(item: $customSnooze, onDismiss: {
            guard openOptionsAfterSnooze else { return }
            openOptionsAfterSnooze = false
            model.openSettings(.threads, anchor: .snoozeOptions)
        }) { request in
            CustomSnoozeView(model: model, target: request.target, editOptions: {
                openOptionsAfterSnooze = true
                customSnooze = nil
            }) { confirmed in
                customSnooze = nil
                if confirmed { finishSnooze(request) }
            }
        }
        .sheet(item: $choosingBranch, onDismiss: {
            if restoreBranchComposerFocus { focusCurrentComposer() }
            restoreBranchComposerFocus = false
        }) { scope in
            BranchPickerView(scope: scope, model: model, pasteboard: workspacePasteboard) { choosingBranch = nil }
        }
        .task(id: BranchReadRequest(scope: model.branchPickerScope, revision: model.repositoryRevision)) {
            guard let scope = model.branchPickerScope else { return }
            do {
                let branch = try await GitWorkspace(path: scope.directory).currentBranch()
                if !Task.isCancelled { loadedBranch = (scope, branch) }
            } catch {
                if !Task.isCancelled { loadedBranch = nil }
            }
        }
        .confirmationDialog("Close this thread’s terminals?", isPresented: Binding(
            get: { terminalWorkspaceChange != nil },
            set: { if !$0 { terminalWorkspaceChange = nil } }
        ), presenting: terminalWorkspaceChange) { thread in
            Button("Close Terminal and Choose Workspace", role: .destructive) {
                guard model.conversation?.id == thread else { return }
                openTerminals.removeAll { $0.id.thread == thread }
                closePanelTerminals(in: thread)
                choosingWorkspace = true
            }
        } message: { _ in
            Text("Workspace changes require a new terminal in the selected folder.")
        }
        .sheet(item: $closingPanelTerminals) { request in
            VStack(alignment: .leading, spacing: 14) {
                Text(request.title).font(.headline)
                Text("This stops the selected shells and clears their output.")
                HStack {
                    Spacer()
                    Button("Cancel") { closingPanelTerminals = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancel-close-right-terminal")
                    Button("Close", role: .destructive) {
                        closingPanelTerminals = nil
                        switch request.target {
                        case .tabs(let tabs): closeRightPanelTabs(tabs, in: request.thread)
                        case .pane(let tab, let pane): rightPanels[request.thread]?.closePane(pane, in: tab)
                        }
                    }
                    .accessibilityIdentifier("confirm-close-right-terminal")
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .sheet(isPresented: $choosingThreadProject, onDismiss: {
            if let scope = focusAfterThreadChoice, scope == model.draftProjectScope {
                focusedComposer = scope.threadID
            }
            focusAfterThreadChoice = nil
        }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start a thread in").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredProjects) { project in
                            Button(project.title) {
                                focusAfterThreadChoice = startThread(in: project.id)
                                choosingThreadProject = false
                            }
                            .accessibilityIdentifier("new-thread-project-\(project.id)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(240, CGFloat(filteredProjects.count) * 32))
                if model.canStartScratchThread {
                    Button("No project") {
                        choosingThreadProject = false
                        startScratchThread()
                    }
                    .accessibilityIdentifier("new-thread-no-project")
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { choosingThreadProject = false }
                }
            }
            .padding(20)
            .frame(width: 340)
        }
        .sheet(item: $model.promptLinkReview, onDismiss: {
            if let scope = focusAfterPromptLink, scope == model.draftProjectScope {
                focusCurrentComposer()
            }
            focusAfterPromptLink = nil
        }) { review in
            PromptLinkView(model: model, review: review) {
                focusAfterPromptLink = model.draftProjectScope
                if model.project?.isScratch == true {
                    model.updateSidebarScope { $0.clear() }
                } else {
                    revealOpenedProject()
                }
                searchFocused = false
                clearSearch()
            }
        }
        .sheet(item: $model.projectPicker, onDismiss: {
            if let focusAfterPicker, focusAfterPicker == model.draftProjectScope {
                focusedComposer = focusAfterPicker.threadID
            }
            if model.showingWelcome { welcomeFocus = .addProject }
            focusAfterPicker = nil
        }) { request in
            ProjectFolderView(request: request) { source in
                try await model.openProject(source, request: request)
                guard request.draftOrigin == nil else { return }
                focusAfterPicker = model.draftProjectScope
                revealOpenedProject()
                if request.relinking == nil {
                    searchFocused = false
                    clearSearch()
                }
            }
        }
        .alert("Rename", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField(rename?.fieldLabel ?? "Name", text: $title)
                .accessibilityIdentifier("rename-title")
            Button("Cancel", role: .cancel) { rename = nil }
                .accessibilityIdentifier("cancel-rename")
            Button("Save") { saveTitle() }
                .accessibilityIdentifier("save-rename")
                .keyboardShortcut(.defaultAction)
        }
        .alert("Archive thread \"\(archiveConfirmation?.title ?? "")\"?",
               isPresented: Binding(get: { archiveConfirmation != nil },
                                    set: { if !$0 { archiveConfirmation = nil } }),
               presenting: archiveConfirmation) { request in
            Button("Cancel", role: .cancel) { archiveConfirmation = nil }
                .accessibilityIdentifier("cancel-archive-thread")
            Button("Confirm") { archive(request) }
                .accessibilityIdentifier("confirm-archive-thread")
        }
        .confirmationDialog("Remove project from the sidebar?",
                            isPresented: Binding(get: { removingProject != nil },
                                                 set: { if !$0 { removingProject = nil } }),
                            presenting: removingProject) { project in
            Button("Remove Project", role: .destructive) {
                model.removeProject(project.id)
            }
        } message: { _ in
            Text("The folder and its threads stay on disk.")
        }
    }

    private func finishSideChatDeletion(_ request: SideChatDeletion, confirmed: Bool) {
        deletingSideChat = nil
        let scope = request.scope
        guard scope.parentID == model.conversation?.id, scope.projectID == model.project?.id else { return }
        if confirmed { model.deleteSideChat(scope) }
        if model.sideChat(scope) == nil {
            rightPanels[scope.parentID]?.close([.sideChat(scope.id)])
            focusedComposer = scope.parentID
        } else {
            focusedComposer = scope.id
        }
    }

    private var welcome: some View {
        let ready = model.hasKey(for: model.workspace.model)
        let returning = model.workspace.welcomeCompleted == true || !model.workspace.projects.isEmpty
        return VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Pi Workspace")
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("welcome-title")
            Text("Connect a model to send messages with Pi. You can open projects before setting up a model.")
                .foregroundStyle(.secondary)
            LabeledContent("Model", value: model.workspace.model.model)
            HStack {
                Button("Model Settings…") { model.openSettings(.model) }
                    .accessibilityIdentifier("model-settings")
                Button("Add Project…") { model.openFolder() }
                    .focused($welcomeFocus, equals: .addProject)
                    .accessibilityIdentifier("welcome-add-project")
                    .disabled(model.operationsInProgress)
            }
            if !returning, let error = model.error { Text(error).foregroundStyle(.red) }
            Button(returning ? "Close" : ready ? "Start" : "Start without an agent", action: model.finishWelcome)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(returning ? .cancelAction : .defaultAction)
                .focused($welcomeFocus, equals: .finish)
                .accessibilityIdentifier(returning ? "welcome-close" : "start-workspace")
        }
        .defaultFocus($welcomeFocus, .finish)
        .padding(32)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvas)
    }

    private var sidebar: some View {
        let scopedThreads = threads
        let titleMatches = scopedThreads.filter { $0.matchesTitle(searchTerm) }
        let messageCandidates = scopedThreads.filter { !$0.matchesTitle(searchTerm) }
        let key = MessageSearchKey(
            search: SidebarMessageSearch(query: searchTerm, threads: messageCandidates.map {
                SidebarMessageSearch.Thread(projectID: $0.project.id, threadID: $0.id)
            }),
            latestMessageID: searchTerm.isEmpty ? nil : model.messages.last?.id
        )
        let messageMatches = messageSearchResult?.key == key ? messageSearchResult?.matches : nil
        let searchRows = titleMatches.map { SearchRow(thread: $0, match: nil) } + messageCandidates.compactMap { link in
            messageMatches?[link.id].map { SearchRow(thread: link, match: $0) }
        }
        let visibleThreads = searchRows.map(\.thread)
        let highlightedID = searchResult(in: visibleThreads)?.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: model.showHome) {
                    Text("Pi Workspace")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pi Workspace home")
                .accessibilityIdentifier("sidebar-home")
                .disabled(model.operationsInProgress || model.editingQueuedMessageID != nil)
                HStack(spacing: 0) {
                    navigationButton(.back)
                    navigationButton(.forward)
                }
                Spacer(minLength: 0)
                Button { model.openFolder() } label: {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 25, height: 25)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .help("Add Project")
                    .accessibilityLabel("Add Project")
                    .accessibilityIdentifier("open-project")
                    .disabled(model.operationsInProgress)
                Button { newThread() } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 25, height: 25)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .help("New Thread")
                    .accessibilityLabel("New Thread")
                    .accessibilityIdentifier("new-conversation")
                    .disabled(model.operationsInProgress)
            }
            .padding(.horizontal, 14)
            .frame(height: WorkspaceLayout.headerHeight)

            sidebarSearch(visibleThreads, messageMatches: messageMatches ?? [:])

            if model.showArchive {
                Button {
                    model.showArchive = false
                } label: {
                    Label("Archived threads", systemImage: "archivebox")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 15)
                .padding(.bottom, 6)
            }

            ScrollViewReader { reader in
                ScrollView {
                    if searchTerm.isEmpty && !model.showArchive && model.projects.isEmpty && visibleThreads.isEmpty {
                        sidebarEmptyState
                    } else if searchTerm.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            threadShelves(visibleThreads)
                            if visibleThreads.isEmpty && !projectFilter.selection.isEmpty {
                                VStack(spacing: 6) {
                                    Text("No threads in the selected projects")
                                        .foregroundStyle(.secondary)
                                    Button("Show All Projects") { model.updateSidebarScope { $0.clear() } }
                                        .accessibilityIdentifier("sidebar-clear-project-scope")
                                }
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                                .padding(7)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    } else if searchRows.isEmpty {
                        Text(messageMatches == nil && !messageCandidates.isEmpty ? "Searching thread messages…" : "No matching threads")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(7)
                            .accessibilityIdentifier("thread-search-status")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(searchRows) { result in
                                if let match = result.match {
                                    Button { openThread(result.thread, messageMatch: match) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(result.thread.project.title).font(.caption).foregroundStyle(.secondary)
                                            Text(result.thread.thread.title).font(.callout).lineLimit(1)
                                            Text(verbatim: match.excerpt).font(.caption).lineLimit(2)
                                        }
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(result.thread.id == highlightedID ? accent.opacity(0.18) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 7))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(model.operationsInProgress && model.conversation?.id != result.thread.id)
                                    .accessibilityIdentifier("message-search-result-\(result.thread.id)-\(match.messageID)")
                                    .contextMenu { threadActions(result.thread.thread, project: result.thread.project, fromSidebar: true) }
                                } else {
                                    threadRow(result.thread, showProject: true, highlighted: result.thread.id == highlightedID)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .onChange(of: highlightedSearchThread) { _, id in
                    if let row = searchRows.first(where: { $0.thread.id == id }) { reader.scrollTo(row.id) }
                }
                .onChange(of: searchTerm) { _, term in
                    if !term.isEmpty, let row = searchRows.first { reader.scrollTo(row.id, anchor: .top) }
                }
            }

            if model.snoozeUndoCount > 0 {
                HStack {
                    let count = model.snoozeUndoCount
                    Text(count == 1 ? "Snoozed 1 thread" : "Snoozed \(count) threads")
                        .accessibilityIdentifier("snooze-undo-notice")
                    Spacer()
                    Button("Undo", action: model.undoSnooze)
                        .accessibilityIdentifier("undo-snooze")
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            Divider()
            Button { model.openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityIdentifier("model-settings")
            .padding(13)
        }
        .background(alignment: .top) {
            if colorScheme == .dark { sidebarHeaderBackdrop }
        }
        .background(rail)
        .task(id: key) {
            guard !key.search.term.text.isEmpty else { return }
            do {
                if !key.search.threads.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
                let matches = try await model.searchMessages(key.search)
                try Task.checkCancellation()
                messageSearchResult = (key, matches)
            } catch is CancellationError {
                return
            } catch { model.error = error.localizedDescription }
        }
        .contentShape(Rectangle())
        .overlay {
            if targetingProjectDrop && targetingAttachmentRow == nil && !model.operationsInProgress {
                Label("Drop folders to add projects", systemImage: "folder.badge.plus")
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(accent, lineWidth: 2)
                    }
                    .padding(5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .dropDestination(for: DroppedProjectFolder.self) { items, _ in
            openDroppedProjects(items.map(\.url))
        } isTargeted: {
            targetingProjectDrop = $0
        }
    }

    private func navigationButton(_ direction: WorkspaceModel.NavigationDirection) -> some View {
        let back = direction == .back
        let label = back ? "Go back" : "Go forward"
        return Button { model.navigate(direction) } label: {
            Image(systemName: back ? "arrow.left" : "arrow.right")
                .frame(width: 25, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(back ? "Go back (⌘[)" : "Go forward (⌘])")
        .accessibilityLabel(label)
        .accessibilityIdentifier(back ? "workspace-history-back" : "workspace-history-forward")
        .disabled(!model.canNavigate(direction))
    }

    private var sidebarHeaderBackdrop: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 57 / 255, green: 77 / 255, blue: 153 / 255), location: 0),
                .init(color: Color(red: 17 / 255, green: 34 / 255, blue: 114 / 255), location: 0.15),
                .init(color: Color(red: 48 / 255, green: 84 / 255, blue: 168 / 255), location: 0.50),
                .init(color: Color(red: 115 / 255, green: 153 / 255, blue: 211 / 255), location: 0.72),
                .init(color: Color(red: 64 / 255, green: 106 / 255, blue: 190 / 255), location: 1)
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0.38),
                .init(color: .black.opacity(0.72), location: 0.58),
                .init(color: .black.opacity(0.28), location: 0.78),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(height: 66)
        .accessibilityHidden(true)
    }

    private var sidebarEmptyState: some View {
        VStack(spacing: 8) {
            Text("No projects yet")
                .font(.system(size: 12))
                .frame(minHeight: 16)
            Button {
                model.openFolder()
            } label: {
                Label("Add project", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.16))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar-add-project")
            .disabled(model.operationsInProgress)
        }
        .foregroundStyle(emptyStateForeground)
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
        .padding(.bottom, 24)
    }

    private func openDroppedProjects(_ urls: [URL]) -> Bool {
        do {
            guard try model.openDroppedProjects(urls) else { return false }
            revealOpenedProject()
            focusedComposer = model.conversation?.id
            return true
        } catch {
            model.error = error.localizedDescription
            return false
        }
    }

    private func revealOpenedProject() {
        guard let id = model.project?.id else { return }
        if !projectFilter.selection.isEmpty, !projectFilter.selection.contains(id) {
            model.updateSidebarScope { $0.clear() }
        }
        model.setSidebarFolderCollapsed(false, for: id)
    }

    private func sidebarSearch(_ results: [SidebarThread],
                               messageMatches: [UUID: SidebarMessageSearch.Match]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search threads", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityIdentifier("thread-search")
                .onChange(of: query) { _, _ in highlightedSearchThread = nil }
                .onSubmit {
                    if !searchTerm.isEmpty, let result = searchResult(in: results) {
                        openThread(result, messageMatch: messageMatches[result.id])
                    }
                }
                .onExitCommand(perform: query.isEmpty ? nil : clearSearch)
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    return moveSearchHighlight(in: results, by: press.key == .upArrow ? -1 : 1)
                }
            if !query.isEmpty {
                Button {
                    clearSearch()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear thread search")
                .accessibilityIdentifier("clear-thread-search")
            }
            sidebarOptions
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(height: 29)
        .background(surface, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func threadShelves(_ threads: [SidebarThread]) -> some View {
        let awake = threads.filter { $0.thread.snoozeStatus(at: model.snoozeClock)?.isSnoozed != true }
        let active = model.showArchive ? threads : awake.filter { $0.thread.threadShelf == .active }
        let pinned = model.showArchive ? [] : awake.filter { $0.thread.threadShelf == .pinned }
        let settled = model.showArchive ? [] : awake.filter { $0.thread.threadShelf == .settled }
        let snoozed = threads.compactMap { link -> SnoozedRow? in
            guard case let .snoozed(until: deadline) = link.thread.snoozeStatus(at: model.snoozeClock) else { return nil }
            return SnoozedRow(link: link, deadline: deadline)
        }.sorted { $0.deadline < $1.deadline }
        if !pinned.isEmpty {
            Text("Pinned").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .padding(.leading, 7).padding(.bottom, 4)
            ForEach(pinned) { link in threadRow(link, showProject: true) }
        }
        if grouped {
            ForEach(active.filter { $0.project.isScratch }) { link in threadRow(link, showProject: true) }
            let threadsByProject = Dictionary(grouping: active, by: { $0.project.id })
            ForEach(filteredProjects) { project in
                let items = threadsByProject[project.id, default: []]
                if !items.isEmpty || (!model.showArchive &&
                    (project.pinned == true || project.inSidebarScope == true)) {
                    projectGroup(project, items: items)
                }
            }
        } else {
            ForEach(active) { link in threadRow(link, showProject: true) }
        }
        if !snoozed.isEmpty {
            let expanded = model.workspace.snoozedShelfExpanded == true
            Button {
                model.setSnoozedShelfExpanded(!expanded)
            } label: {
                Label("Snoozed", systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(snoozed.count.formatted()).font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.leading, 5)
            .accessibilityIdentifier("snoozed-shelf")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            ForEach(snoozed.filter { expanded || $0.link.id == model.conversation?.id }) { row in
                threadRow(row.link, showProject: true, status: .snoozed(until: row.deadline))
            }
        }
        if !settled.isEmpty {
            DisclosureGroup(isExpanded: $settledExpanded) {
                ForEach(settled) { link in threadRow(link, showProject: true) }
            } label: {
                Text("Settled").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            .padding(.leading, 5)
        }
    }

    private var sidebarOptions: some View {
        Button { showingSidebarFilters.toggle() } label: {
            Image(systemName: projectFilter.selection.isEmpty ?
                  "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Thread filters")
        .accessibilityLabel("Thread filters")
        .accessibilityIdentifier("thread-filters")
        .popover(isPresented: $showingSidebarFilters, arrowEdge: .bottom) {
            SidebarProjectScopePicker(model: model, grouped: $grouped, dismiss: { showingSidebarFilters = false }) {
                projectFolderActions($0)
            }
        }
    }

    private func projectGroup(_ project: Project, items: [SidebarThread]) -> some View {
        let expanded = project.sidebarFolderCollapsed != true
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                Button {
                    model.setSidebarFolderCollapsed(expanded, for: project.id)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Image(systemName: project.pinned == true ? "pin.fill" : "folder")
                        Text(project.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-group-\(project.id)")
                .accessibilityAddTraits(expanded ? .isSelected : [])
                Button { openProjectSettings(project.id) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .help("Project settings for \(project.title)")
                    .accessibilityLabel("Project settings for \(project.title)")
                    .accessibilityIdentifier("project-group-settings-\(project.id)")
                Button { startThread(in: project.id) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain)
                    .help("New Thread in \(project.title)")
                    .accessibilityLabel("New Thread in \(project.title)")
                    .accessibilityIdentifier("project-new-thread-\(project.id)")
                    .disabled(model.operationsInProgress)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .contextMenu { projectActions(project) }

            if expanded {
                ForEach(items) { link in threadRow(link, showProject: false).padding(.leading, 13) }
            }
        }
    }

    private func threadRow(_ link: SidebarThread, showProject: Bool, highlighted: Bool = false,
                           status: ThreadSnoozeStatus? = nil) -> some View {
        let selected = model.conversation?.id == link.id
        let emphasized = searchTerm.isEmpty ? selected : highlighted
        let acceptsAttachments = !link.thread.archived && link.thread.worktreeLaunch == nil &&
            link.thread.composerSubmission == nil && (!model.operationsInProgress || selected)
        return HStack(spacing: 5) {
            threadSelectionButton(link, showProject: showProject, emphasized: emphasized, acceptsAttachments: acceptsAttachments)
            snoozeRowStatus(link, status: status ?? link.thread.snoozeStatus(at: model.snoozeClock))
        }
        .accessibilityElement(children: .contain)
    }

    private func threadSelectionButton(_ link: SidebarThread, showProject: Bool, emphasized: Bool,
                                       acceptsAttachments: Bool) -> some View {
        let selected = model.conversation?.id == link.id
        return Button {
            openThread(link)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if showProject {
                    HStack(spacing: 5) {
                        Image(systemName: link.project.isScratch ? "doc" : "folder")
                            .font(.system(size: 9, weight: .medium))
                        Text(link.project.title).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Text(link.thread.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, showProject ? 8 : 6)
            .background(emphasized || targetingAttachmentRow == link.id ? accent.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread-row-\(link.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(model.operationsInProgress && !selected)
        .contextMenu { threadActions(link.thread, project: link.project, fromSidebar: true) }
        .attachmentDropDestination(canDrop: acceptsAttachments || !model.operationsInProgress) { items in
            let urls = items.compactMap(ComposerAttachmentInput.fileURL(from:))
            if !model.operationsInProgress && urls.count == items.count &&
                urls.allSatisfy({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
                return openDroppedProjects(urls)
            }
            let attachments = ComposerAttachmentInput.readAttachments(from: items)
            guard acceptsAttachments, !attachments.isEmpty,
                  model.attach(attachments, to: ComposerAttachmentTarget(threadID: link.id)) else {
                return false
            }
            openThread(link)
            return true
        } isTargeted: { targeted in
            if targeted && acceptsAttachments { targetingAttachmentRow = link.id }
            else if targetingAttachmentRow == link.id { targetingAttachmentRow = nil }
        }
    }

    @ViewBuilder
    private func snoozeRowStatus(_ link: SidebarThread, status: ThreadSnoozeStatus?) -> some View {
        let target = ThreadSnoozeTarget(projectID: link.project.id, threadID: link.id)
        switch status {
        case let .snoozed(until: deadline):
            let time = ThreadSnoozeSchedule.deadlineLabel(deadline, after: model.snoozeClock)
            HStack(spacing: 5) {
                Text(time).lineLimit(1)
                    .accessibilityIdentifier("snooze-deadline-\(link.id)")
                Button {
                    model.wakeThread(target, until: deadline)
                } label: {
                    Image(systemName: "clock").frame(width: 19, height: 19)
                }
                .buttonStyle(.plain)
                .help("Wake thread now")
                .accessibilityLabel("Wake thread now")
                .accessibilityIdentifier("wake-snoozed-thread-\(link.id)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .layoutPriority(1)
        case let .woke(at: deadline):
            Button {
                model.dismissWoke(target, at: deadline)
            } label: {
                Label("Woke", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("Dismiss Woke notification")
            .accessibilityLabel("Dismiss Woke notification")
            .accessibilityIdentifier("dismiss-woke-\(link.id)")
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func projectActions(_ project: Project) -> some View {
        Button("New Thread") { startThread(in: project.id) }
            .disabled(model.operationsInProgress)
        projectFolderActions(project)
        Button("Rename Project…") { beginRename(.project(project.id), title: project.title) }
        Button("Relink Folder…") { model.openFolder(relinking: project.id) }
            .disabled(model.phase.isRunning)
        Button("Remove Project…") { removingProject = project }
            .disabled(model.phase.isRunning)
    }

    @ViewBuilder
    private func projectFolderActions(_ project: Project) -> some View {
        Button("Copy path") {
            copyTask?.cancel()
            do { try model.copyProjectPath(project.id, to: workspacePasteboard) }
            catch { model.error = error.localizedDescription }
        }
        .accessibilityIdentifier("project-copy-path")
        Button(project.pinned == true ? "Unpin Project" : "Pin Project") {
            model.setProjectPinned(project.id, pinned: project.pinned != true)
        }
        .accessibilityIdentifier("toggle-project-pin-\(project.id)")
        Button("Project settings") { openProjectSettings(project.id) }
            .accessibilityIdentifier("project-settings")
    }

    private func openProjectSettings(_ id: UUID) {
        showingSidebarFilters = false
        model.openSettings(.project, projectID: id)
    }

    @ViewBuilder
    private func threadActions(_ thread: Conversation, project: Project, fromSidebar: Bool = false) -> some View {
        if thread.isDraft == true && !thread.archived {
            draftActions(thread, project: project)
        } else {
            Button("Find in thread") {
                openThread(SidebarThread(project: project, thread: thread))
                let scope = SidebarMessageSearch.Thread(projectID: project.id, threadID: thread.id)
                if model.threadFindScope == scope { openFind(in: scope) }
            }
            .accessibilityIdentifier("find-in-thread")
            .disabled(model.operationsInProgress && model.conversation?.id != thread.id)
            submittedThreadActions(thread, project: project, fromSidebar: fromSidebar)
        }
    }

    @ViewBuilder
    private func draftActions(_ thread: Conversation, project: Project) -> some View {
        threadCopyMenu(thread, project: project)
        if project.isScratch {
            turnIntoProject(thread, project: project)
        } else {
            Button("Project settings") { openProjectSettings(project.id) }
                .accessibilityIdentifier("draft-project-settings")
        }
        Divider()
        Button("Discard draft", role: .destructive) { model.discardDraft(thread.id, in: project.id) }
            .accessibilityIdentifier("discard-draft")
            .disabled(model.operationsInProgress || !thread.canDiscardDraft)
    }

    private var copyBranchReadRequest: CopyBranchReadRequest {
        var paths = Set(threads.compactMap {
            ThreadCopyTarget(project: $0.project, thread: $0.thread).branchReadPath
        })
        if let project = model.project, let thread = model.conversation,
           let path = ThreadCopyTarget(project: project, thread: thread).branchReadPath {
            paths.insert(path)
        }
        return CopyBranchReadRequest(paths: paths, revision: model.repositoryRevision)
    }

    private func copy(_ field: ThreadCopyTarget.Field, from target: ThreadCopyTarget) {
        copyTask?.cancel()
        copyTask = Task {
            do {
                try await target.copy(field, to: workspacePasteboard)
            } catch {
                if !Task.isCancelled { model.error = error.localizedDescription }
            }
        }
    }

    private func threadCopyMenu(_ thread: Conversation, project: Project) -> some View {
        let target = ThreadCopyTarget(project: project, thread: thread)
        let hasBranch = target.branchReadPath.map(checkoutsWithBranches.contains) ?? (target.draftBase?.isEmpty == false)
        let prefix = target.isDraft ? "draft-copy" : "thread-copy"
        return Menu("Copy") {
            if !target.isDraft || !target.path.isEmpty {
                Button("Path") { copy(.path, from: target) }
                    .accessibilityIdentifier(prefix + "-path")
            }
            if hasBranch {
                Button("Branch") { copy(.branch, from: target) }
                    .accessibilityIdentifier(prefix + "-branch")
            }
            if target.isDraft {
                Button("Draft Link") {
                    copyTask?.cancel()
                    do { try model.copyDraftLink(thread.id, in: project.id, to: workspacePasteboard) }
                    catch { model.error = error.localizedDescription }
                }
                .accessibilityIdentifier("draft-copy-link")
            } else {
                if thread.isDraft != true {
                    Button("Thread") {
                        copyTask?.cancel()
                        do { try model.copyThreadReference(thread.id, in: project.id, to: workspacePasteboard) }
                        catch { model.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("thread-copy-reference")
                }
                Button("Thread ID") { copy(.id, from: target) }
                    .accessibilityIdentifier("thread-copy-id")
            }
        }
        .accessibilityIdentifier(prefix)
    }

    private func turnIntoProject(_ thread: Conversation, project: Project) -> some View {
        Button("Turn into project") {
            if model.convertScratchThread(thread.id, in: project.id) {
                notice = Notice(id: project.id, message: "Project created", accessibilityID: "project-created")
            }
        }
        .accessibilityIdentifier("turn-into-project")
        .disabled(model.operationsInProgress)
    }

    @ViewBuilder
    private func submittedThreadActions(_ thread: Conversation, project: Project, fromSidebar: Bool) -> some View {
        if !project.isScratch {
            let included = projectFilter.selection.contains(project.id)
            Button(included ? "Show All Projects" : "Filter by \(project.title)") {
                model.updateSidebarScope {
                    if included { $0.clear() }
                    else { $0.selectOnly(project.id) }
                }
            }
            .accessibilityIdentifier("thread-project-scope")
        }
        Button("Rename Thread…") { beginRename(.conversation(thread.id, project: project.id), title: thread.title) }
            .accessibilityIdentifier("rename-thread")
        if project.isScratch {
            turnIntoProject(thread, project: project)
        } else {
            Button("Project settings") { openProjectSettings(project.id) }
                .accessibilityIdentifier("thread-project-settings")
        }
        if !thread.archived {
            Button(thread.threadShelf == .pinned ? "Unpin Thread" : "Pin Thread") {
                model.moveConversation(thread.id, in: project.id,
                                       to: thread.threadShelf == .pinned ? .active : .pinned)
            }
            .disabled(model.operationsInProgress)
            Button(thread.threadShelf == .settled ? "Unsettle Thread" : "Settle Thread") {
                model.moveConversation(thread.id, in: project.id,
                                       to: thread.threadShelf == .settled ? .active : .settled)
            }
            .disabled(model.operationsInProgress)
            threadSnoozeMenu(thread, project: project, fromSidebar: fromSidebar)
        }
        threadCopyMenu(thread, project: project)
        Button(thread.archived ? "Restore Thread" : "Archive Thread") {
            if thread.archived {
                restoreThread(thread.id, in: project.id)
            } else {
                guard archiveConfirmation == nil else { return }
                let request = ArchiveRequest(projectID: project.id, threadID: thread.id, title: thread.title)
                if model.confirmsThreadArchive {
                    archiveConfirmation = request
                } else {
                    archive(request)
                }
            }
        }
        .accessibilityIdentifier(thread.archived ? "restore-thread" : "archive-thread")
        .disabled(!model.canChangeArchive(for: thread.id))
    }

    private func archive(_ request: ArchiveRequest) {
        archiveFailure = nil
        do {
            try model.archiveConversation(request.threadID, in: request.projectID, archived: true)
        } catch {
            archiveFailure = ArchiveFailure(request: request, message: error.localizedDescription)
        }
    }

    private func restoreThread(_ threadID: UUID, in projectID: UUID) {
        do {
            try model.archiveConversation(threadID, in: projectID, archived: false)
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func archiveFailureNotice(_ failure: ArchiveFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Failed to archive thread \"\(failure.request.title)\"")
                .font(.callout.weight(.semibold))
                .accessibilityIdentifier("archive-thread-error")
            Text(failure.message).font(.caption)
            HStack {
                Button("Retry") { archive(failure.request) }
                    .disabled(!model.canChangeArchive(for: failure.request.threadID))
                    .accessibilityIdentifier("retry-archive-thread")
                Button("Dismiss") { archiveFailure = nil }
                    .accessibilityIdentifier("dismiss-archive-thread-error")
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    @ViewBuilder
    private func threadSnoozeMenu(_ thread: Conversation, project: Project, fromSidebar: Bool) -> some View {
        let target = ThreadSnoozeTarget(projectID: project.id, threadID: thread.id)
        let request = SnoozeRequest(target: target, fromSidebar: fromSidebar)
        if case let .snoozed(until: deadline) = thread.snoozeStatus(at: model.snoozeClock) {
            Button("Wake thread") { model.wakeThread(target, until: deadline) }
                .accessibilityIdentifier("wake-thread")
        } else {
            Menu("Snooze") {
                let presets = model.snoozePresets
                ForEach(presets) { preset in
                    let time = ThreadSnoozeSchedule.deadlineLabel(preset.shownDeadline, after: model.snoozeClock)
                    Button("\(preset.label) · \(time)") {
                        if model.snooze(target, preset: preset) { finishSnooze(request) }
                    }
                    .accessibilityIdentifier("snooze-preset-\(preset.id)")
                }
                if !presets.isEmpty { Divider() }
                Button("Custom…") { customSnooze = request }
                    .accessibilityIdentifier("open-custom-snooze")
            }
            .accessibilityIdentifier("snooze-thread")
            .disabled(!model.canSnooze(target))
        }
    }

    private func finishSnooze(_ request: SnoozeRequest) {
        guard request.fromSidebar, model.conversation?.id == request.target.threadID else { return }
        let candidates = threads.filter {
            $0.id == request.target.threadID || ($0.thread.isDraft != true && $0.thread.threadShelf != .settled &&
                $0.thread.snoozeStatus(at: model.snoozeClock)?.isSnoozed != true)
        }
        let pinned = candidates.filter { $0.thread.threadShelf == .pinned }
        let active = candidates.filter { $0.thread.threadShelf == .active }
        let ordered = pinned + (grouped
            ? active.filter { $0.project.isScratch } + filteredProjects.flatMap { project in
                active.filter { $0.project.id == project.id }
            }
            : active)
        let index = ordered.firstIndex { $0.id == request.target.threadID }
        let next = index.flatMap { ordered.dropFirst($0 + 1).first }
            ?? ordered.first { $0.id != request.target.threadID }
        model.advanceAfterSidebarSnooze(request.target, next: next.map {
            ThreadSnoozeTarget(projectID: $0.project.id, threadID: $0.id)
        })
    }

    private func detail(viewport: CGSize) -> some View {
        let limits = TerminalDrawerHeight(viewport: viewport.height,
                                          reserved: WorkspaceLayout.headerHeight + terminalDrawerReservedHeight)
        return VStack(spacing: 0) {
            GeometryReader { workspace in
                if model.failedStartupDraftProject != nil {
                    VStack(spacing: 12) {
                        Text("Couldn’t start a new thread")
                            .font(.title2.weight(.semibold))
                            .accessibilityIdentifier("startup-draft-error")
                        Text("The project is still available. Try opening the draft again.")
                            .foregroundStyle(.secondary)
                        Button("Try again", action: model.retryStartupDraft)
                            .accessibilityIdentifier("startup-draft-retry")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let project = model.project, let thread = model.conversation {
                    threadWorkspace(project, thread, viewportWidth: viewport.width, size: workspace.size)
                } else {
                    readyScreen
                }
            }
            terminalDrawer(limits: limits)
        }
        .background(canvas)
        .onPreferenceChange(TerminalDrawerReservedHeight.self) { terminalDrawerReservedHeight = $0 }
        .overlayPreferenceValue(RightPanelBounds.self) { bounds in
            GeometryReader { geometry in
                rightTerminalGroups(in: bounds.terminal.map { geometry[$0] })
                if let panel = bounds.panel, let thread = model.conversation, addingPanelSurface == thread.id {
                    let frame = geometry[panel]
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { addingPanelSurface = nil }
                            .accessibilityHidden(true)
                        panelSurfaceMenu(thread)
                            .frame(width: 160, alignment: .leading)
                            .offset(x: frame.maxX - 168, y: frame.minY + 33)
                    }
                }
            }
        }
        .onChange(of: activeTerminal) { _, location in
            guard let thread = model.conversation?.id, let previous = rightPanels[thread]?.location,
                  previous != location else { return }
            closePanelTerminals(in: thread)
        }
    }

    private func threadWorkspace(_ project: Project, _ thread: Conversation, viewportWidth: CGFloat, size: CGSize) -> some View {
        let browser = browserPanel(for: thread.id)
        let panel = rightPanels[thread.id] ?? WorkspaceRightPanelState()
        let preferredWidth = rightPanelWidths[thread.id] ?? WorkspaceLayout.defaultRightPanelWidth
        let layout = WorkspaceLayout(
            viewportWidth: viewportWidth,
            workspaceSize: size,
            preferredRightPanelWidth: panel.isOpen ? preferredWidth : nil,
            rightPanelDrag: rightPanelDrag,
            showingDetails: showingDetails,
            miniPlayer: browser.wrappedValue.miniPlayer?.placement,
            chatWidthMode: chatWidthMode
        )
        return VStack(spacing: 0) {
            header(project, thread, panel: panel, detailsFitInline: layout.detailsFitInline)
                .overlay(alignment: .bottom) { Divider() }

            // Keep the conversation in the same slot as the panel opens, closes, or overlays it.
            conversation(project, thread, layout: layout)
                .frame(width: layout.chatWidth)
                .overlay(alignment: .topTrailing) {
                    if showingDetails && layout.detailsFitInline {
                        inspector(project, thread, width: WorkspaceLayout.detailsWidth)
                            .anchorPreference(key: BrowserMiniPlayerObstacles.self, value: .bounds) { [.details: $0] }
                            .frame(maxHeight: layout.detailsHeight, alignment: .topLeading)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(WorkspaceLayout.detailsInset)
                    }
                }
                .overlayPreferenceValue(BrowserMiniPlayerObstacles.self) { anchors in
                    if let mini = browser.wrappedValue.miniPlayer {
                        GeometryReader { geometry in
                            BrowserMiniPlayer(tab: mini.tab, placement: mini.placement, canvas: geometry.size,
                                              obstacles: anchors.values.map { geometry[$0] }) { placement in
                                browser.wrappedValue.placeMiniPlayer(placement, for: mini.tab.id)
                            } dock: {
                                browser.wrappedValue.dockTab(mini.tab.id)
                            } popOut: {
                                browser.wrappedValue.openWindow(for: mini.tab.id)
                            } close: {
                                browser.wrappedValue.closeMiniPlayer(for: mini.tab.id)
                            }
                            .id(mini.tab.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if panel.isOpen {
                        HStack(spacing: 0) {
                            if layout.rightPanelOverlaysChat {
                                Divider().frame(width: WorkspaceLayout.dividerWidth)
                            } else {
                                WorkspaceDivider(label: "Resize right panel", width: layout.rightPanelWidth,
                                                 drag: $rightPanelDrag, expandsToRight: false) { translation in
                                    rightPanelWidths[thread.id] = layout.resizedRightPanelWidth(drag: translation)
                                }
                                .zIndex(1)
                            }
                            rightPanel(project, thread, panel: panel, browser: browser)
                            .frame(width: layout.rightPanelWidth - WorkspaceLayout.dividerWidth)
                            .frame(maxHeight: .infinity)
                            .clipped()
                        }
                        .background(canvas)
                    }
                }
        }
        .background {
            if !model.showingWelcome, let tab = browser.wrappedValue.floatingTab {
                BrowserFloatingWindow(session: tab) {
                    browser.wrappedValue.dockTab(tab.id)
                } dismiss: {
                    browser.wrappedValue.dismissFloatingWindow(for: tab.id)
                }
                .id(tab.id)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
    }

    private func rightPanel(_ project: Project, _ thread: Conversation, panel: WorkspaceRightPanelState,
                            browser: Binding<ThreadBrowserPreview>) -> some View {
        VStack(spacing: 0) {
            WorkspacePanelTabs(panel: panel, select: { tab in
                rightPanels[thread.id]?.show(tab)
            }, close: { tabs in
                requestRightPanelClose(tabs, in: thread.id)
            }, move: { tab, target in
                rightPanels[thread.id]?.move(tab, to: target)
            }, hide: {
                rightPanels[thread.id]?.isOpen = false
            }, titleForTab: { tab in
                guard case .sideChat(let id) = tab else { return tab.title }
                return thread.sideChats?.first { $0.id == id }?.title ?? tab.title
            }, addButton: {
                addPanelSurfaceButton(thread)
            })
            switch panel.selected {
            case .files:
                filesPanel(project, thread)
            case .browser:
                BrowserPreviewView(preview: browser)
            case .changes:
                if let location = WorkspaceFilesLocation(thread: thread, project: project) {
                    SourceControlView(directory: location.directory, model: model, openBranch: {
                        openBranchPicker()
                    }, copyBranch: copyBranch) { path in
                        guard selectedFilesLocation == location else { return }
                        fileLineReveal = nil
                        selectedFiles[location] = path
                        rightPanels[thread.id]?.show(.files)
                    }
                    .id(location)
                }
            case .terminal(let number):
                if let group = panel.terminals[.terminal(number)] {
                    rightTerminalSurface(group, tab: .terminal(number), thread: thread.id)
                }
            case .sideChat(let id):
                sideChatPanel(.init(projectID: project.id, parentID: thread.id, id: id), parent: thread)
            case nil:
                Spacer()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .transformAnchorPreference(key: RightPanelBounds.self, value: .bounds) { $0.panel = $1 }
    }

    @ViewBuilder
    private func sideChatPanel(_ scope: SideChatScope, parent: Conversation) -> some View {
        if let child = model.sideChat(scope) {
            Group {
                if let session = model.sideChatSession(scope) {
                    SideChatPane(model: model, session: session, child: child, parentTitle: parent.title,
                                 pasteboard: workspacePasteboard, focus: $focusedComposer, openParent: {
                        if rightPanels[scope.parentID]?.visibleTab == .sideChat(scope.id) {
                            rightPanels[scope.parentID]?.isOpen = false
                            focusedComposer = scope.parentID
                        }
                    }, delete: {
                        deletingSideChat = SideChatDeletion(scope: scope, title: child.title)
                    }, close: {
                        closeRightPanelTabs([.sideChat(scope.id)], in: scope.parentID)
                    })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: scope) { model.loadSideChat(scope) }
            .id(scope.id)
        }
    }

    private func browserPanel(for thread: UUID) -> Binding<ThreadBrowserPreview> {
        Binding {
            browserPanels[thread] ?? ThreadBrowserPreview(searchDefaults: browserDefaults)
        } set: { preview in
            let visibilityChanged = (browserPanels[thread]?.isVisible ?? false) != preview.isVisible
            browserPanels[thread] = preview
            if visibilityChanged {
                if preview.isVisible { rightPanels[thread, default: .init()].show(.browser) }
                else { rightPanels[thread]?.close([.browser]) }
            }
        }
    }

    private var selectedFilesLocation: WorkspaceFilesLocation? {
        guard let project = model.project, let thread = model.conversation else { return nil }
        return WorkspaceFilesLocation(thread: thread, project: project)
    }

    private var paletteFilesLocation: WorkspaceFilesLocation? {
        model.project?.isScratch == false ? selectedFilesLocation : nil
    }

    @ViewBuilder
    private func filesPanel(_ project: Project, _ thread: Conversation) -> some View {
        if let location = WorkspaceFilesLocation(thread: thread, project: project) {
            WorkspaceFilesView(location: location, saves: model.fileSaves, pasteboard: workspacePasteboard,
                               activeLocation: { rightPanels[thread.id]?.visibleTab == .files ? selectedFilesLocation : nil },
                               close: { rightPanels[thread.id]?.close([.files]) },
                               canAddToComposer: model.canAddFileMention(from: location),
                               addToComposer: { target in
                                   if try model.addFileMention(target) {
                                       focusComposerAfterFileMention(in: target.location.threadID)
                                   }
                               },
                               beginMentionDrag: model.beginFileMentionDrag,
                               selection: Binding(get: { selectedFiles[location] },
                                                  set: {
                                                      fileLineReveal = nil
                                                      selectedFiles[location] = $0
                                                  }), lineReveal: fileLineReveal)
                .id(location)
        } else {
            Text("Files will be available when the worktree is ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .accessibilityIdentifier("files-pending-worktree")
        }
    }

    @ViewBuilder
    private var readyScreen: some View {
        if let project = model.project {
            VStack(spacing: 12) {
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                }
                Text(project.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                Button("New Thread") { newThread() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.operationsInProgress)
                Menu("Project Actions") { projectActions(project) }
                    .fixedSize()
                    .accessibilityIdentifier("project-actions")
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyHome
                .padding(20)
        }
    }

    private var emptyHome: some View {
        let description: LocalizedStringKey = model.canStartScratchThread
            ? "Add a project, or start without one."
            : "Add a project to start your first thread."
        return VStack(spacing: 4) {
            Text("What should we work on?")
                .font(.system(size: 30, weight: .semibold))
                .frame(minHeight: 36)
                .accessibilityAddTraits(.isHeader)
            Text(description)
                .foregroundStyle(emptyStateForeground)
                .frame(minHeight: 20)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { emptyHomeActions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 8) { emptyHomeActions }
            }
            .padding(.top, 20)
            .disabled(model.operationsInProgress)
            if let error = model.error {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
        }
        .font(.system(size: 14))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 448)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, WorkspaceLayout.headerHeight)
    }

    @ViewBuilder
    private var emptyHomeActions: some View {
        let addFill = colorScheme == .dark ? Color(red: 52 / 255, green: 107 / 255, blue: 241 / 255) : accent
        Button {
            model.openFolder()
        } label: {
            emptyHomeActionLabel("Add project", icon: "plus")
                .foregroundStyle(.white)
                .background(addFill, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("empty-open-project")
        if model.canStartScratchThread {
            Button(action: startScratchThread) {
                emptyHomeActionLabel("Start without a project", icon: "message")
                    .background(colorScheme == .dark ? Color(white: 9 / 255) : surface,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.16))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("start-without-project")
        }
    }

    private func emptyHomeActionLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
    }

    private func header(_ project: Project, _ thread: Conversation, panel: WorkspaceRightPanelState,
                        detailsFitInline: Bool) -> some View {
        let filesAreVisible = panel.visibleTab == .files
        let browserIsVisible = panel.visibleTab == .browser
        return HStack(spacing: 8) {
            let canSwitchProject = canChooseDraftProject(thread.id)
            if !project.isScratch {
                Button { startThread(in: project.id) } label: {
                    Label(project.title, systemImage: "folder")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help("New thread in \(project.title)")
                .accessibilityLabel("New thread in \(project.title)")
                .accessibilityIdentifier("thread-project-new-thread")
                .disabled(model.operationsInProgress)
            }
            if canSwitchProject || !project.isScratch {
                Menu {
                    if canSwitchProject {
                        Button("Draft project…") { openDraftProjectPicker(for: thread.id) }
                            .accessibilityIdentifier("draft-project-picker")
                    }
                    if !project.isScratch {
                        projectActions(project)
                    }
                } label: {
                    if project.isScratch {
                        Label(project.title, systemImage: "doc")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.primary)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Project actions for \(project.title)")
                .accessibilityIdentifier("thread-project")
            } else {
                Label(project.title, systemImage: "doc")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Text("/").foregroundStyle(.tertiary).accessibilityHidden(true)
            Menu {
                threadActions(thread, project: project)
            } label: {
                Text(thread.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.primary)
            .accessibilityIdentifier("conversation-title")
            Spacer()
            if let scope = model.gitHubScope, scope.canReadRepository || thread.hasGitHubLinks {
                PullRequestsButton(workspace: model, scope: scope, pasteboard: workspacePasteboard)
                    .id(scope)
            }
            Button {
                toggleChanges(in: thread.id)
            } label: {
                Image(systemName: panel.visibleTab == .changes ? "doc.text.fill" : "doc.text")
            }
            .buttonStyle(.plain)
            .help("Changes (⌘D)")
            .accessibilityLabel("Changes")
            .accessibilityIdentifier("toggle-changes")
            .disabled(thread.workingLocation.needsWorktree)

            Button {
                if filesAreVisible {
                    closeRightPanelTabs([.files], in: thread.id)
                } else {
                    rightPanels[thread.id, default: .init()].show(.files)
                }
            } label: {
                Image(systemName: filesAreVisible ? "folder.fill" : "folder")
            }
            .buttonStyle(.plain)
            .help(filesAreVisible ? "Hide Files" : "Show Files")
            .accessibilityLabel("Files")
            .accessibilityAddTraits(filesAreVisible ? .isSelected : [])
            .accessibilityIdentifier("toggle-files")

            Button {
                if browserIsVisible {
                    browserPanel(for: thread.id).wrappedValue.isVisible = false
                } else {
                    showPanelBrowser(in: thread.id)
                }
            } label: {
                Image(systemName: "globe")
                    .foregroundStyle(browserIsVisible ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .help(browserIsVisible ? "Hide Browser" : "Show Browser")
            .accessibilityLabel("Browser")
            .accessibilityAddTraits(browserIsVisible ? .isSelected : [])
            .accessibilityIdentifier("toggle-browser")

            Button(action: toggleTerminal) {
                Image(systemName: terminalIsVisible ? "terminal.fill" : "terminal")
            }
            .buttonStyle(.plain)
            .help("Terminal")
            .accessibilityLabel("Terminal")
            .accessibilityIdentifier("toggle-terminal")
            .disabled(thread.workingLocation.needsWorktree)

            if !panel.isOpen {
                addPanelSurfaceButton(thread)
            }
            panelIcon(panel.isOpen ? "Hide Right Panel" : "Show Right Panel", icon: "sidebar.right",
                      id: "toggle-right-panel") {
                rightPanels[thread.id, default: .init()].isOpen.toggle()
            }

            Button { showingDetails.toggle() } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .help("Thread Details")
            .accessibilityLabel(showingDetails ? "Hide Thread Details" : "Show Thread Details")
            .accessibilityIdentifier("thread-details")
            .popover(isPresented: Binding(
                get: { showingDetails && !detailsFitInline },
                set: { if !detailsFitInline { showingDetails = $0 } }
            ), arrowEdge: .top) {
                inspector(project, thread, width: 296)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .frame(height: WorkspaceLayout.headerHeight)
    }

    private func conversation(_ project: Project, _ thread: Conversation, layout: WorkspaceLayout) -> some View {
        let find = model.activeThreadFind
        let legacyDraft = model.phase == .ready && model.messages.isEmpty && thread.worktreeLaunch == nil
        let drafting = !thread.archived && (thread.isDraft ?? legacyDraft)
        return VStack(spacing: 0) {
            if let find { transcriptFind(find) }
            if drafting {
                DraftComposerLayout {
                    draftHeadline(project, thread: thread)
                        .font(.system(size: 27, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .reservesRoomAboveTerminal(terminalIsVisible, inset: DraftComposerLayout.bottomInset)
                    composer(project, thread, width: layout.composerWidth)
                        .reservesRoomAboveTerminal(terminalIsVisible)
                }
            } else {
                transcript(find?.selection, project: project, thread: thread)
                composer(project, thread, width: layout.composerWidth).padding(.vertical, 12)
                    .reservesRoomAboveTerminal(terminalIsVisible)
            }
        }
        .frame(width: layout.composerWidth)
        .padding(.leading, layout.composerLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func draftHeadline(_ project: Project, thread: Conversation) -> some View {
        VStack(spacing: 8) {
            if canChooseDraftProject(thread.id) {
                if project.isScratch { Text("What should we work on?") }
                HStack(spacing: 4) {
                    if !project.isScratch { Text("What should we build in") }
                    Button { openDraftProjectPicker(for: thread.id) } label: {
                        HStack(spacing: 5) {
                            Text(project.title).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .font(project.isScratch ? .callout.weight(.medium) : nil)
                    .help("Choose a project")
                    .focusable()
                    .focused($focusedDraftProject, equals: thread.id)
                    .accessibilityIdentifier("draft-project-trigger")
                    .task(id: focusScratchHeadline) {
                        guard let request = focusScratchHeadline, project.isScratch, request.threadID == thread.id else { return }
                        await Task.yield()
                        if !Task.isCancelled && model.draftProjectScope == request {
                            focusedDraftProject = thread.id
                        }
                    }
                    .onChange(of: focusedDraftProject) { _, id in
                        if id == thread.id { focusScratchHeadline = nil }
                    }
                    if !project.isScratch { Text("?").padding(.leading, -4) }
                }
                if !project.isScratch {
                    Button("or start without a project") {
                        guard let source = model.draftProjectScope, source.threadID == thread.id else { return }
                        model.switchDraftProject(to: nil, from: source)
                        if model.project?.isScratch == true, let destination = model.draftProjectScope {
                            revealOpenedProject()
                            focusedComposer = nil
                            focusScratchHeadline = destination
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("draft-start-without-project")
                }
            } else {
                Text(project.isScratch ? "What should we work on?" : "What should we build in \(project.title)?")
            }
        }
        .popover(item: Binding(
            get: { draftProjectPicker },
            set: { if $0 == nil, let session = draftProjectPicker { finishDraftProjectPicker(session, with: nil) } }
        ), arrowEdge: .bottom) { session in
            DraftProjectPicker(model: model) {
                finishDraftProjectPicker(session, with: $0)
            }
            .id(session.id)
        }
    }

    private func inspector(_ project: Project, _ thread: Conversation, width: CGFloat) -> some View {
        let path = thread.workingLocation.directory(in: project)
        return VStack(alignment: .leading, spacing: 11) {
            Text("Thread details").font(.system(size: 13, weight: .semibold))
            Divider()
            Label(thread.workingLocation.label, systemImage: "desktopcomputer")
                .font(.callout.weight(.medium))
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
            } label: {
                Label("Show in Finder", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .font(.callout)
            Divider()
            Text("Model").font(.callout.weight(.medium))
            Text(model.effectiveModel.model)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("thread-model")
            if let chats = thread.sideChats, !chats.isEmpty {
                Divider()
                Text("Side chats").font(.callout.weight(.medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(chats) { chat in
                            Button {
                                model.openSideChat(.init(projectID: project.id, parentID: thread.id, id: chat.id))
                            } label: {
                                Label(chat.title, systemImage: "bubble.left.and.bubble.right")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Open side chat: \(chat.title)")
                            .accessibilityIdentifier("open-side-chat-\(chat.id)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(15)
        .frame(width: width, alignment: .leading)
        .accessibilityIdentifier("workspace-details")
    }

    private var activeTerminal: ThreadTerminalLocation? {
        guard let thread = model.conversation, !thread.workingLocation.needsWorktree,
              let path = model.workingDirectory else { return nil }
        return ThreadTerminalLocation(thread: thread.id, path: path)
    }

    private var terminalIsVisible: Bool {
        openTerminals.contains { $0.id == activeTerminal && $0.isOpen }
    }

    private func toggleTerminal() {
        guard let activeTerminal else { return }
        if !terminalIsVisible { focusedComposer = nil }
        if let index = openTerminals.firstIndex(where: { $0.id == activeTerminal }) {
            openTerminals[index].isOpen.toggle()
        } else {
            openTerminals.append(ThreadTerminalDrawerState(id: activeTerminal, firstPane: nextTerminalNumber(at: activeTerminal)))
        }
    }

    private func nextTerminalNumber(at location: ThreadTerminalLocation) -> Int {
        let drawer = openTerminals.first { $0.id == location }
        return max(drawer?.nextNumber ?? 1, rightPanels[location.thread]?.nextNumber ?? 1)
    }

    private func terminalDrawer(limits: TerminalDrawerHeight) -> some View {
        VStack(spacing: 0) {
            ForEach($openTerminals) { $drawer in
                let location = drawer.id
                ThreadTerminalDrawer(drawer: $drawer, selected: location == activeTerminal, limits: limits,
                                     allocateNumber: { nextTerminalNumber(at: location) }) {
                    openTerminals.removeAll { $0.id == location }
                }
            }
        }
    }

    private func addPanelSurfaceButton(_ thread: Conversation) -> some View {
        panelIcon("Add Panel Surface", icon: "plus", id: "add-panel-surface") {
            rightPanels[thread.id, default: .init()].isOpen = true
            addingPanelSurface = thread.id
        }
    }

    private func panelSurfaceMenu(_ thread: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            panelSurfaceButton(.browser) {
                browserPanel(for: thread.id).wrappedValue.addTab(profile: .standard)
                rightPanels[thread.id, default: .init()].show(.browser)
            }
            Button {
                addingPanelSurface = nil
                addRightTerminal(in: thread.id)
            } label: {
                HStack {
                    Label("Terminal", systemImage: "terminal")
                    Spacer()
                    Text("T").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("add-panel-terminal")
            .disabled(activeTerminal?.thread != thread.id)
            panelSurfaceButton(.files) { rightPanels[thread.id, default: .init()].show(.files) }
            panelSurfaceButton(.changes) { rightPanels[thread.id, default: .init()].show(.changes) }
                .disabled(thread.workingLocation.needsWorktree)
            Button {
                addingPanelSurface = nil
                model.startSideChat(in: thread.id)
            } label: {
                HStack {
                    Label("Side chat", systemImage: "bubble.left.and.bubble.right")
                    Spacer()
                    Text("S").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("add-panel-side-chat")
            .disabled(!model.canStartSideChat)
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary).allowsHitTesting(false) }
        .shadow(radius: 6, y: 3)
    }

    private func panelSurfaceButton(_ tab: WorkspacePanelTab, action: @escaping () -> Void) -> some View {
        Button {
            addingPanelSurface = nil
            action()
        } label: {
            Label(tab.title, systemImage: tab.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("add-panel-\(tab.id)")
    }

    private func showPanelBrowser(in thread: UUID) {
        let browser = browserPanel(for: thread)
        if browser.wrappedValue.isVisible {
            rightPanels[thread, default: .init()].show(.browser)
        } else {
            browser.wrappedValue.togglePanel()
        }
    }

    private func addRightTerminal(in thread: UUID) {
        guard let location = activeTerminal, location.thread == thread else { return }
        focusedComposer = nil
        let number = nextTerminalNumber(at: location)
        rightPanels[thread, default: .init()].addTerminal(number, at: location)
    }

    private func rightTerminalSurface(_ group: WorkspaceRightPanelState.TerminalGroup,
                                      tab: WorkspacePanelTab, thread: UUID) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                panelIcon("New Terminal", icon: "plus", id: "new-right-terminal") { addRightTerminal(in: thread) }
                panelIcon("Split Terminal Horizontally", icon: "rectangle.split.2x1", id: "split-right-terminal-horizontal") {
                    handleRightTerminalCommand(.split, tab: tab, thread: thread)
                }
                .disabled(!group.canSplit)
                panelIcon("Split Terminal Vertically", icon: "rectangle.split.1x2", id: "split-right-terminal-vertical") {
                    handleRightTerminalCommand(.splitVertical, tab: tab, thread: thread)
                }
                .disabled(!group.canSplit)
                panelIcon("Close Terminal Pane", icon: "xmark", id: "close-right-terminal-pane") {
                    handleRightTerminalCommand(.close, tab: tab, thread: thread)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: TerminalDrawerHeight.toolbar)
            Divider()
            Color.clear
                .anchorPreference(key: RightPanelBounds.self, value: .bounds) { .init(terminal: $0) }
        }
    }

    private func rightTerminalGroups(in bounds: CGRect?) -> some View {
        ZStack {
            // Keep the PTY views mounted when the panel or its thread is out of sight.
            ForEach(rightPanels.keys.sorted(), id: \.self) { thread in
                if let panel = rightPanels[thread], let location = panel.location {
                    ForEach(panel.tabs) { tab in
                        if let group = panel.terminals[tab] {
                            let visible = location == activeTerminal && panel.visibleTab == tab
                            WorkspaceTerminalGroupView(group: group, directory: location.path,
                                                       bounds: visible ? bounds : nil, focusRequest: panel.focusRequest,
                                                       select: { rightPanels[thread]?.selectPane($0, in: tab) },
                                                       cycle: { rightPanels[thread]?.cycle(by: $0) ?? false },
                                                       command: { handleRightTerminalCommand($0, tab: tab, thread: thread) })
                        }
                    }
                }
            }
        }
    }

    private func handleRightTerminalCommand(_ command: ThreadTerminal.Command, tab: WorkspacePanelTab, thread: UUID) {
        guard let location = activeTerminal, location.thread == thread, rightPanels[thread]?.visibleTab == tab,
              let group = rightPanels[thread]?.terminals[tab] else { return }
        switch command {
        case .new:
            addRightTerminal(in: thread)
        case .split, .splitVertical:
            let number = nextTerminalNumber(at: location)
            rightPanels[thread]?.split(command == .split ? .horizontal : .vertical, allocating: number)
        case .close:
            closingPanelTerminals = PanelTerminalClose(thread: thread, target: .pane(tab, group.selectedPane),
                                                       panes: [group.selectedPane])
        }
    }

    private func requestRightPanelClose(_ tabs: [WorkspacePanelTab], in thread: UUID) {
        let panes = tabs.flatMap { rightPanels[thread]?.terminals[$0]?.panes ?? [] }
        if panes.isEmpty {
            closeRightPanelTabs(tabs, in: thread)
        } else {
            closingPanelTerminals = PanelTerminalClose(thread: thread, target: .tabs(tabs), panes: panes)
        }
    }

    private func closeRightPanelTabs(_ tabs: [WorkspacePanelTab], in thread: UUID) {
        if let project = model.project, thread == model.conversation?.id {
            for case .sideChat(let id) in tabs {
                model.closeSideChat(.init(projectID: project.id, parentID: thread, id: id))
                if focusedComposer == id { focusedComposer = thread }
            }
        }
        if tabs.contains(.browser), var browser = browserPanels[thread] {
            for tab in browser.tabs where tab.surface == .panel { browser.closeTab(tab.id) }
            browser.isVisible = false
            browserPanels[thread] = browser
        }
        rightPanels[thread]?.close(tabs)
    }

    private func closePanelTerminals(in thread: UUID) {
        guard let panel = rightPanels[thread] else { return }
        rightPanels[thread]?.close(Array(panel.terminals.keys))
    }

    private func toggleChanges(in thread: UUID) {
        if rightPanels[thread]?.visibleTab == .changes {
            closeRightPanelTabs([.changes], in: thread)
        } else {
            rightPanels[thread, default: .init()].show(.changes)
        }
    }

    private func handleRightPanelKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> Bool {
        guard let thread = model.conversation?.id, window.attachedSheet == nil, !model.showingSettings,
              NSApp.modalWindow == nil, !model.showingWelcome, !model.showingCommandPalette,
              model.projectPicker == nil else { return false }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
            guard model.conversation?.workingLocation.needsWorktree == false, acceptsWorkspaceKeys(in: window),
                  closingPanelTerminals == nil, !documentHasFocus(in: window),
                  (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
            if case .sideChat(let sideChat) = rightPanels[thread]?.visibleTab,
               (window.firstResponder as? ComposerTextField.Editor)?.owner?.composerTarget?.threadID == sideChat {
                return false
            }
            toggleChanges(in: thread)
            return true
        }
        if addingPanelSurface == thread, modifiers.isEmpty {
            switch event.keyCode {
            case UInt16(kVK_Escape):
                addingPanelSurface = nil
                return true
            case UInt16(kVK_ANSI_T) where activeTerminal?.thread == thread:
                addingPanelSurface = nil
                addRightTerminal(in: thread)
                return true
            case UInt16(kVK_ANSI_S) where model.canStartSideChat:
                addingPanelSurface = nil
                model.startSideChat(in: thread)
                return true
            default: break
            }
        }
        if modifiers == [.command, .option], event.keyCode == kVK_ANSI_B {
            addingPanelSurface = nil
            rightPanels[thread, default: .init()].isOpen.toggle()
            return true
        }
        if modifiers == .command, event.keyCode == kVK_ANSI_T, rightPanels[thread]?.isOpen == true,
           acceptsWorkspaceKeys(in: window) {
            addingPanelSurface = thread
            return true
        }
        return false
    }

    private func transcript(_ selection: ThreadFindSession.Selection?, project: Project, thread: Conversation) -> some View {
        let target = selection.flatMap { match in model.messages.contains { $0.id == match.messageID } ? match : nil }
        let forks = Dictionary(grouping: project.conversations.filter { $0.forkOrigin?.threadID == thread.id }) {
            $0.forkOrigin?.messageID
        }
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 23) {
                    if selection != nil, target == nil, model.phase != .connecting {
                        Text("The matching message is no longer available.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.messages) { message in
                        let isMatch = message.id == target?.messageID
                        VStack(alignment: .leading, spacing: 8) {
                            messageRow(message.text, role: message.role, attachments: message.attachments ?? [],
                                       attachmentOwner: .sent(thread: thread.id, message: message.id),
                                       selection: isMatch ? target : nil)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("transcript-message-\(message.id)")
                                .accessibilityAddTraits(isMatch ? .isSelected : [])
                            if let incomplete = message.incompleteReply {
                                Text(incomplete == .interrupted
                                     ? "Pi skips this interrupted reply in future model requests."
                                     : "This reply reached a token limit. Pi may skip it when continuing.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            if message.canFork == true && !thread.archived {
                                Button { model.forkResponse(message.id) } label: {
                                    Image(systemName: "arrow.triangle.branch")
                                }
                                .buttonStyle(.borderless)
                                .help("Fork from this response")
                                .accessibilityLabel("Fork from this response")
                                .accessibilityIdentifier("fork-from-response-\(message.id)")
                                .disabled(!model.canForkResponse(message))
                            }
                            if let origin = thread.forkOrigin, origin.messageID == message.id {
                                forkHistoryLink("Open source conversation", threadID: origin.threadID, source: true)
                            }
                            ForEach(forks[message.id] ?? []) { child in
                                forkHistoryLink("Open fork", threadID: child.id, source: false)
                                    .help(child.title)
                            }
                        }
                        .id(TranscriptAnchor.message(message.id))
                    }
                    if let origin = thread.forkOrigin, model.phase == .closed,
                       !model.messages.contains(where: { $0.id == origin.messageID }) {
                        forkHistoryLink("Open source conversation", threadID: origin.threadID, source: true)
                    }
                    if !model.partial.isEmpty {
                        messageRow(model.partial, role: .assistant)
                            .accessibilityIdentifier("streaming-reply")
                    }
                    Color.clear.frame(height: 1).id(TranscriptAnchor.latest)
                }
                .padding(.vertical, 22)
                .padding(.horizontal, WorkspaceLayout.editorInset)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("transcript")
            .onChange(of: target?.messageID, initial: true) { _, id in
                if let id { reader.scrollTo(TranscriptAnchor.message(id), anchor: .center) }
            }
            .onChange(of: model.messages.count) { _, _ in
                if target == nil, imagePreview == nil { reader.scrollTo(TranscriptAnchor.latest, anchor: .bottom) }
            }
            .onChange(of: model.partial) { _, _ in
                if target == nil, imagePreview == nil { reader.scrollTo(TranscriptAnchor.latest, anchor: .bottom) }
            }
        }
    }

    private func transcriptFind(_ find: ThreadFindSession) -> some View {
        HStack(spacing: 8) {
            TextField("Find in thread", text: Binding(get: { model.activeThreadFind?.query ?? "" }, set: { text in
                if model.activeThreadFind?.thread == find.thread { model.threadFind?.editQuery(text) }
            }))
            .textFieldStyle(.roundedBorder)
            .focused($findFocused)
            .accessibilityIdentifier("thread-find-query")
            if let label = find.status.label {
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("thread-find-match-count")
            }
            if find.status == .failed {
                Button("Retry") { model.threadFind?.refresh() }
                    .accessibilityIdentifier("thread-find-retry")
            }
            Button {
                model.threadFind?.step(backward: true)
            } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Previous match")
                .accessibilityIdentifier("thread-find-previous")
                .disabled(!find.canStep)
            Button {
                model.threadFind?.step(backward: false)
            } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Next match")
                .accessibilityIdentifier("thread-find-next")
                .disabled(!find.canStep)
            Button(action: closeFind) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close find")
            .accessibilityIdentifier("thread-find-close")
        }
        .font(.callout)
        .padding(.horizontal, WorkspaceLayout.editorInset)
        .padding(.top, 8)
        .task(id: find.focusRequest) {
            await Task.yield()
            guard !Task.isCancelled, model.activeThreadFind?.focusRequest == find.focusRequest,
                  !model.showingSettings, !model.showingCommandPalette else { return }
            findFocused = true
        }
    }

    private func forkHistoryLink(_ title: String, threadID: UUID, source: Bool) -> some View {
        Button { model.openForkLink(threadID) } label: {
            Label(title, systemImage: "arrow.triangle.branch")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(source ? "open-source-conversation" : "open-fork-\(threadID)")
        .disabled(!model.canOpenForkLink(threadID))
    }

    private func previewImages(for owner: ChatAttachment.Owner) -> [ChatImagePreview.ImageItem] {
        guard model.conversation?.id == owner.threadID, !model.showingWelcome else { return [] }
        switch owner {
        case .composer(let target):
            guard target == model.attachmentTarget(for: target.threadID) else { return [] }
            return model.composerAttachments.compactMap(ChatImagePreview.ImageItem.init)
        case .queued(_, let message):
            let attachments = model.queuedMessages.first { $0.id == message }?.attachments ?? []
            return attachments.compactMap(ChatImagePreview.ImageItem.init)
        case .sent(_, let message):
            let attachments = model.messages.first { $0.id == message }?.attachments ?? []
            return attachments.compactMap(ChatImagePreview.ImageItem.init)
        }
    }

    private func openImagePreview(_ opener: ChatAttachment.Opener) {
        let selection = ChatImagePreview(opener)
        guard selection.index(in: previewImages(for: opener.owner)) != nil else { return }
        imagePreview = selection
    }

    private func navigateImagePreview(_ direction: Int) {
        guard let selection = imagePreview else { return }
        let images = previewImages(for: selection.opener.owner)
        guard images.count > 1, let index = selection.index(in: images) else { return }
        let next = (index + direction + images.count) % images.count
        imagePreview?.selectedID = images[next].id
    }

    private func closeImagePreview() {
        guard let selection = imagePreview else { return }
        imagePreview = nil
        Task { @MainActor in
            guard imagePreview == nil, previewImages(for: selection.opener.owner).contains(where: {
                $0.id == selection.opener.attachmentID
            }) else { return }
            focusedAttachmentOpener = selection.opener
        }
    }

    private func filePreviewContent(for opener: ChatAttachment.Opener) -> FilePreviewContent? {
        guard model.conversation?.id == opener.owner.threadID, !model.showingWelcome else { return nil }
        let attachment: ComposerAttachment?
        switch opener.owner {
        case .composer(let target):
            guard model.attachmentTarget(for: target.threadID) == target else { return nil }
            attachment = model.composerAttachments.first { $0.id == opener.attachmentID }
        case .queued(_, let messageID):
            attachment = model.queuedMessages.first { $0.id == messageID }?
                .attachments?.first { $0.id == opener.attachmentID }
        case .sent(let threadID, let messageID):
            return model.sentTextFile(threadID: threadID, messageID: messageID, attachmentID: opener.attachmentID)
                .map { FilePreviewContent(name: $0.name) }
        }
        guard let attachment, let payload = attachment.payload, payload.mimeType == "text/plain" else { return nil }
        return FilePreviewContent(name: attachment.name, payload: payload)
    }

    private func openFilePreview(_ opener: ChatAttachment.Opener) {
        guard filePreviewContent(for: opener) != nil else { return }
        filePreview = opener
    }

    private func closeFilePreview() {
        guard let opener = filePreview else { return }
        let revision = model.threadSelectionRevision
        filePreview = nil
        Task { @MainActor in
            guard filePreview == nil, revision == model.threadSelectionRevision,
                  filePreviewContent(for: opener) != nil else { return }
            focusedAttachmentOpener = opener
        }
    }

    private func filePreviewDialog(_ opener: ChatAttachment.Opener, content: FilePreviewContent) -> some View {
        let revision = model.threadSelectionRevision
        let origin: String
        var remove: (() -> Void)?
        var load: (() async -> ComposerAttachment.Payload?)?
        switch opener.owner {
        case .composer(let target):
            origin = target.queueEditID == nil ? "Draft" : "Queue Edit"
            if model.canEditAttachments {
                remove = {
                    guard filePreview == opener, revision == model.threadSelectionRevision,
                          filePreviewContent(for: opener) == content else { return }
                    model.removeAttachment(opener.attachmentID, in: target)
                    guard filePreviewContent(for: opener) == nil else { return }
                    filePreview = nil
                    Task { @MainActor in
                        guard revision == model.threadSelectionRevision, model.conversation?.id == target.threadID,
                              model.attachmentTarget(for: target.threadID) == target else { return }
                        focusedComposer = target.threadID
                    }
                }
            }
        case .queued:
            origin = "Queued"
        case .sent(let threadID, let messageID):
            origin = "Sent"
            load = { await model.readSentFile(threadID: threadID, messageID: messageID, attachmentID: opener.attachmentID) }
        }
        return ChatFilePreview(name: content.name, origin: origin, localText: content.payload?.text, load: load,
                               remove: remove, save: { saveFile(opener, fromPreview: true) }, close: closeFilePreview)
    }

    private func sentFileCard(_ file: SentAttachment, owner: ChatAttachment.Owner) -> some View {
        let opener = ChatAttachment.Opener(owner: owner, attachmentID: file.id)
        let label = Label(file.name, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
        return HStack {
            if file.hasText == true {
                ChatAttachmentPreviewButton(opener: opener, name: file.name, identifier: "sent-attachment-\(file.id)",
                                            focus: $focusedAttachmentOpener, open: openFilePreview) { label }
                Button { saveFile(opener, fromPreview: false) } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .focusable()
                .focused($focusedFileDownload, equals: opener)
                .help("Download \(file.name)")
                .accessibilityLabel("Download \(file.name)")
                .accessibilityIdentifier("download-sent-attachment-\(file.id)")
            } else {
                label.accessibilityIdentifier("sent-attachment-\(file.id)")
                Text("Attachment unavailable").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private func saveFile(_ opener: ChatAttachment.Opener, fromPreview: Bool) {
        guard fileSaveRequest == nil, let content = filePreviewContent(for: opener),
              !fromPreview || filePreview == opener else { return }
        if !fromPreview { focusedFileDownload = opener }
        fileSaveRequest = .init(opener: opener, content: content, fromPreview: fromPreview,
                                threadRevision: model.threadSelectionRevision)
    }

    private var fileSavePanelRequest: ChatFileSavePanel.Request? {
        guard let request = fileSaveRequest else { return nil }
        func isCurrent() -> Bool {
            fileSaveRequest?.id == request.id && request.threadRevision == model.threadSelectionRevision &&
                filePreviewContent(for: request.opener) == request.content &&
                (!request.fromPreview || filePreview == request.opener)
        }
        guard isCurrent() else { return nil }
        return ChatFileSavePanel.Request(id: request.id, name: request.content.name, load: {
            if case .sent(let threadID, let messageID) = request.opener.owner {
                return await model.readSentFile(threadID: threadID, messageID: messageID,
                                                attachmentID: request.opener.attachmentID)
            }
            return request.content.payload
        }, isCurrent: isCurrent, finish: { error in
            fileSaveRequest = nil
            if !request.fromPreview { focusedFileDownload = request.opener }
            if let error {
                notice = Notice(id: UUID(), message: error, accessibilityID: "attachment-save-error")
            }
        })
    }

    private func messageRow(_ text: String, role: ChatMessage.Role, attachments: [SentAttachment] = [],
                            attachmentOwner: ChatAttachment.Owner? = nil,
                            selection: ThreadFindSession.Selection? = nil) -> some View {
        let rendered = TranscriptText.rendered(text, role: role)
        return HStack {
            if role == .user { Spacer(minLength: 35) }
            VStack(alignment: .leading, spacing: 6) {
                if !text.isEmpty {
                    if let selection {
                        FoundTranscriptText(rendered: rendered, selection: selection)
                    } else {
                        Text(rendered)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                }
                ForEach(attachments) { attachment in
                    let label = Label(attachment.name, systemImage: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc.text")
                    if let attachmentOwner, case .sent(let threadID, let messageID) = attachmentOwner, attachment.hasImage == true {
                        ChatAttachmentPreviewButton(opener: .init(owner: attachmentOwner, attachmentID: attachment.id),
                                               name: attachment.name, identifier: "sent-attachment-\(attachment.id)",
                                               focus: $focusedAttachmentOpener, open: openImagePreview) {
                            SentImageThumbnail(name: attachment.name) {
                                await model.readSentImage(threadID: threadID, messageID: messageID, attachmentID: attachment.id)
                            }
                        }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    } else if let attachmentOwner, attachment.mimeType == "text/plain" {
                        sentFileCard(attachment, owner: attachmentOwner)
                    } else {
                        label
                            .font(.callout)
                            .accessibilityIdentifier("sent-attachment-\(attachment.id)")
                    }
                }
            }
            .padding(role == .user ? 11 : 0)
            .background(role == .user ? surface : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            if role == .assistant { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private func composerError(for threadID: UUID) -> some View {
        if let notice = model.errorNotice, notice.threadID == threadID {
            let canReconnect = model.phase == .closed && !model.canRetryWorktree
            if !notice.isDismissed || canReconnect {
                HStack {
                    if !notice.isDismissed {
                        Text(notice.message).foregroundStyle(.red)
                            .accessibilityIdentifier("composer-error")
                    }
                    Spacer()
                    if canReconnect {
                        Button("Reconnect", action: model.connect)
                            .accessibilityIdentifier("reconnect-thread")
                    }
                    if !notice.isDismissed {
                        Button("Dismiss error", systemImage: "xmark") { model.dismissError(notice) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Dismiss error")
                            .accessibilityLabel("Dismiss error")
                            .accessibilityIdentifier("dismiss-composer-error")
                    }
                }
                .font(.callout)
            }
        }
    }

    private func composer(_ project: Project, _ thread: Conversation, width: CGFloat) -> some View {
        let canCompose = !thread.archived && (thread.worktreeLaunch == nil || model.phase.isRunning)
        let question = model.pendingAgentQuestion
        return VStack(alignment: .leading, spacing: 8) {
            if let saveError = model.composerSaveError {
                HStack {
                    Text("Draft not saved. \(saveError)").foregroundStyle(.red)
                    Spacer()
                    Button("Retry Saving") { model.savePendingComposer() }
                        .accessibilityIdentifier("retry-saving-draft")
                }
                .font(.callout)
            }
            composerError(for: thread.id)
            if let launch = thread.worktreeLaunch, !model.phase.isRunning {
                WorktreeLaunchView(thread: thread, projectPath: project.path, checkedOutBranch: branchDisplay?.branch,
                                   launch: launch, model: model)
                    .id(launch.id ?? thread.id)
            }
            snoozeConversationStatus(thread, project: project)
            if thread.archived {
                Button("Restore Thread") {
                    restoreThread(thread.id, in: project.id)
                }
                .accessibilityIdentifier("restore-open-thread")
            } else if canCompose {
                if let approval = model.pendingToolApproval, let directory = model.workingDirectory {
                    ToolApprovalCard(approval: approval, directory: directory) {
                        model.respond(to: approval.requestID, with: $0)
                    }
                }
                QueuedMessagesView(model: model, threadID: thread.id, focusComposer: { focusedComposer = thread.id },
                                   previewFocus: $focusedAttachmentOpener, openPreview: openImagePreview,
                                   openFilePreview: openFilePreview)
                    .id(thread.id)
                if let scope = model.draftProjectScope {
                    composerStash(in: scope)
                }
                if let question {
                    AgentQuestionCard(request: question.request, submitting: question.submitting, error: question.error,
                                      respond: { model.respond(to: question.request.scope, with: $0) }, stop: model.cancel)
                        .id(question.request.scope.requestID)
                } else {
                    inputCard(threadID: thread.id)
                }
            }
            composerContextStrip(project, thread, width: width, showsPermissions: canCompose && question == nil)
        }
        .frame(maxWidth: .infinity)
        .anchorPreference(key: BrowserMiniPlayerObstacles.self, value: .bounds) { [.composer: $0] }
        .anchorPreference(key: ComposerModelAnchor.self, value: .bounds) { $0 }
    }

    private func composerContextStrip(_ project: Project, _ thread: Conversation, width: CGFloat,
                                      showsPermissions: Bool) -> some View {
        let branch = branchDisplay
        let isCheckout = thread.workingLocation == .project && branch != nil
        let location = isCheckout ? "Current checkout" : thread.workingLocation.label
        let compact = width < 576
        let branchButton = branch.map {
            ThreadBranchButton(branch: $0.branch, label: $0.label,
                               identifier: "composer-branch", open: { openBranchPicker() }, copy: copyBranch)
                .padding(.horizontal, 7)
        }
        return HStack(spacing: 4) {
            Group {
                if model.canChangeWorkspace {
                    Button(action: chooseWorkspace) {
                        Label(location, systemImage: "folder")
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Thread workspace, \(thread.workingLocation.label)")
                    .accessibilityIdentifier("choose-workspace")
                } else {
                    Label(location, systemImage: isCheckout ? "folder" : "desktopcomputer")
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                }
            }
            if compact { branchButton }
            Spacer(minLength: 0)
            Group {
                if model.phase == .connecting && thread.worktreeLaunch == nil {
                    Text("Opening thread…")
                }
                if model.pendingToolApproval != nil {
                    Text("Waiting for approval…")
                } else if model.pendingAgentQuestion != nil {
                    Text("Waiting for answers…")
                } else if model.canSkipCompaction {
                    Text("Compacting conversation…")
                } else if model.phase == .running {
                    Text(model.activity.isEmpty ? "Pi is responding…" : "Running \(model.activity)…")
                }
                if model.phase == .stopping { Text("Stopping…") }
                if model.phase == .stopTimedOut { Text("Pi hasn’t confirmed. Try Stop again.") }
            }
            if !compact { branchButton }
            if showsPermissions && model.effectiveModel.supportsTools {
                Menu {
                    ForEach(ToolPermission.allCases, id: \.self) { permission in
                        Button(permission.title) { model.setToolPermission(permission) }
                            .accessibilityIdentifier("tool-mode-\(permission.rawValue)")
                    }
                } label: {
                    Label(project.toolPermission.title, systemImage: project.toolPermission.icon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.secondary)
                .fixedSize()
                .disabled(model.operationsInProgress)
                .accessibilityIdentifier("tool-permissions")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
    }

    @ViewBuilder
    private func snoozeConversationStatus(_ thread: Conversation, project: Project) -> some View {
        let target = ThreadSnoozeTarget(projectID: project.id, threadID: thread.id)
        switch thread.snoozeStatus(at: model.snoozeClock) {
        case let .snoozed(until: deadline):
            HStack {
                Label("Snoozed until \(ThreadSnoozeSchedule.deadlineLabel(deadline, after: model.snoozeClock))",
                      systemImage: "clock")
                    .accessibilityIdentifier("open-thread-snooze-status")
                Spacer()
                Button("Wake now") { model.wakeThread(target, until: deadline) }
                    .accessibilityIdentifier("wake-open-thread")
            }
            .font(.callout)
        case let .woke(at: deadline):
            HStack {
                Label("Woke from snooze", systemImage: "clock")
                    .accessibilityIdentifier("open-thread-woke-status")
                Spacer()
                Button("Dismiss") { model.dismissWoke(target, at: deadline) }
                    .accessibilityIdentifier("dismiss-open-thread-woke")
            }
            .font(.callout)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func composerStash(in scope: DraftProjectScope) -> some View {
        let entries = model.stashedPrompts
        if !entries.isEmpty {
            Button { showingComposerStash = true } label: {
                Label("Stash \(entries.count)", systemImage: "bookmark")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("Stashed prompts: \(entries.count). Open stash.")
            .accessibilityIdentifier("open-composer-stash")
        }
        if showingComposerStash {
            ComposerStashView(entries: entries, canRestore: model.canMoveStashedPrompt, restore: { id in
                restoreStashedPrompt(id, to: scope)
            }, delete: { id in
                if model.deleteStashedPrompt(id), model.stashedPrompts.isEmpty { showingComposerStash = false }
            }, close: { showingComposerStash = false })
        }
    }

    private func handleComposerStashShortcut() -> Bool {
        guard let scope = model.draftProjectScope, model.conversation?.worktreeLaunch == nil else { return false }
        if model.canMoveStashedPrompt {
            if model.hasStashablePrompt || model.isImportingComposerAttachments {
                if model.stashCurrentPrompt() { showingComposerStash = false }
                return true
            }
            let entries = model.stashedPrompts
            if entries.count == 1, let entry = entries.first {
                restoreStashedPrompt(entry.id, to: scope)
                return true
            }
        }
        showingComposerStash.toggle()
        return true
    }

    private func restoreStashedPrompt(_ id: UUID, to scope: DraftProjectScope) {
        if model.restoreStashedPrompt(id, to: scope) { showingComposerStash = false }
    }

    private func focusComposerAfterFileMention(in threadID: UUID) {
        showingComposerStash = false
        composerFileMentionRevision = model.composerRevision
        focusedComposer = threadID
    }

    private func inputCard(threadID: UUID) -> some View {
        let target = model.attachmentTarget(for: threadID)
        func ownsComposer() -> Bool {
            model.conversation?.id == threadID && model.attachmentTarget(for: threadID) == target
        }
        let drop = AttachmentDropDestination(canDrop: model.canEditAttachments, perform: { items in
            let attachments = ComposerAttachmentInput.readAttachments(from: items)
            return !attachments.isEmpty && ownsComposer() && model.canEditAttachments && model.attach(attachments, to: target)
        }, isTargeted: { targetingComposerDrop = $0 && model.canEditAttachments },
            fileMentionDrop: .init(accepts: { id in
                rightPanels[threadID]?.visibleTab == .files && model.canDropFileMention(id, in: target)
            }, receive: { id in
                guard model.dropFileMention(id, in: target) else { return false }
                focusComposerAfterFileMention(in: threadID)
                return true
            }))
        return ComposerAttachmentsView(model: model, threadID: threadID, previewFocus: $focusedAttachmentOpener,
                                       openPreview: openImagePreview, openFilePreview: openFilePreview) {
            ComposerTextField(target: target, placeholder: model.editingQueuedMessageID == nil ? "Ask Pi anything" : "Edit queued message", text: Binding(
                get: { ownsComposer() ? model.draft : "" },
                set: {
                    guard ownsComposer() else { return }
                    showingComposerStash = false
                    model.editDraft($0, in: threadID)
                }
            ), pasteboard: workspacePasteboard, drop: drop,
               fileMentionRevision: composerFileMentionRevision == model.composerRevision
                   ? composerFileMentionRevision : nil,
               sendShortcut: sendShortcut, isFollowingUp: { isFollowingUp }, submit: { submission in
                guard ownsComposer(), !model.showingSettings, !model.showingCommandPalette,
                      !model.showingWelcome, model.activeThreadFind == nil, model.pendingAgentQuestion == nil else { return }
                if model.editingQueuedMessageID != nil {
                    model.updateQueuedMessage()
                } else if isFollowingUp {
                    let action = submission == .alternate ? followUpBehavior.alternate : followUpBehavior
                    model.queueDraft(steering: action == .steer && model.canSteer)
                } else {
                    model.send()
                }
            }) { text, inlineLength in
                model.foldPastedText(text, inlineLength: inlineLength, in: target) { attachment in
                    let size = ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .binary)
                    notice = Notice(id: attachment.id,
                                    message: "Large paste attached as \(attachment.name) (\(size)). Use ⌘⇧V to keep a paste inline.",
                                    accessibilityID: "large-paste-attached")
                }
            }
                .id(target)
                .focused($focusedComposer, equals: threadID)
                .focusedValue(\.editingComposer, true)
                .task(id: target) {
                    await Task.yield()
                    if !Task.isCancelled && model.conversation?.id == threadID &&
                        focusedDraftProject != threadID && focusScratchHeadline?.threadID != threadID &&
                        !model.showingWelcome && model.projectPicker == nil && draftProjectPicker == nil &&
                        !terminalIsVisible && rightPanels[threadID]?.visibleTerminal == nil &&
                        !model.showingSettings && !model.showingCommandPalette && model.activeThreadFind == nil {
                        focusedComposer = threadID
                    }
                }
                .accessibilityIdentifier("composer")
                .disabled(model.conversation?.worktreeLaunch != nil || model.conversation?.composerSubmission != nil)
        } controls: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    composerModelButton
                    composerActions.fixedSize()
                }
                VStack(alignment: .trailing, spacing: 4) {
                    composerModelButton
                    composerActions.fixedSize()
                }
            }
        }
        .id(target)
        .background(colorScheme == .dark ? Color(.sRGB, white: 15.0 / 255, opacity: 1) : surface,
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(targetingComposerDrop ? accent : .primary.opacity(colorScheme == .dark ? 0.05 : 0.11))
                .allowsHitTesting(false)
        }
        .background { drop.accessibilityHidden(true) }
        .onPasteCommand(of: ComposerAttachmentInput.contentTypes) { providers in
            model.pasteAttachments(providers, to: target)
        }
    }

    private var composerModelButton: some View {
        let settings = model.effectiveModel
        let title = settings.thinkingLevel.map { "\(settings.model) \($0.label)" } ?? settings.model
        return Button {
            guard model.canChooseComposerModel, let scope = model.draftProjectScope else { return }
            composerModelPicker = ComposerModelPresentation(scope: scope, options: model.composerModelOptions())
        } label: {
            HStack(spacing: 4) {
                Label(title, systemImage: "cpu").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Choose model, \(title)")
        .accessibilityIdentifier("active-model")
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!model.canChooseComposerModel)
    }

    private func composerModelOverlay(_ picker: ComposerModelPresentation, anchoredAt anchor: Anchor<CGRect>) -> some View {
        GeometryReader { geometry in
            let box = geometry[anchor]
            let width = min(350, max(0, geometry.size.width - 16))
            let above = box.minY - 10
            let below = geometry.size.height - box.maxY - 10
            let opensAbove = above >= 240 || above >= below
            let height = min(300, max(120, opensAbove ? above : below))
            let x = min(max(width / 2 + 8, box.maxX - width / 2), geometry.size.width - width / 2 - 8)
            let y = opensAbove ? box.minY - height / 2 - 4 : box.maxY + height / 2 + 4
            Color.clear.contentShape(Rectangle())
                .onTapGesture { closeComposerModelPicker() }
                .accessibilityHidden(true)
            ComposerModelPicker(options: picker.options,
                                current: ((try? model.effectiveModel.validated()) ?? model.effectiveModel).identity,
                                canUseDefault: model.canUseInheritedComposerModel, choose: { option in
                if model.chooseComposerModel(option, in: picker.scope) { closeComposerModelPicker() }
            }, useDefault: {
                if model.chooseComposerModel(nil, in: picker.scope) { closeComposerModelPicker() }
            }, openSettings: {
                composerModelPicker = nil
                model.openSettings(.model)
            }, close: closeComposerModelPicker)
            .frame(width: width, height: height)
            .position(x: x, y: min(max(y, height / 2 + 4), geometry.size.height - height / 2 - 4))
        }
    }

    private func closeComposerModelPicker() {
        guard let picker = composerModelPicker else { return }
        composerModelPicker = nil
        if model.draftProjectScope == picker.scope { focusedComposer = picker.scope.threadID }
    }

    private var isFollowingUp: Bool {
        model.phase == .running && model.sideChatCommand == nil && model.editingQueuedMessageID == nil
    }

    private func followUpButton(_ action: ComposerFollowUp) -> some View {
        Button(action.title) { model.queueDraft(steering: action == .steer) }
            .help(action == .steer ? "Send into the current turn" : "Send after the current turn")
            .accessibilityIdentifier(action == .steer ? "steer-message" : "queue-message")
            .disabled(!model.canQueueDraft)
    }

    private var composerActions: some View {
        HStack(spacing: 6) {
            if model.editingQueuedMessageID != nil {
                Button("Cancel", action: model.cancelQueuedMessageEdit)
                    .accessibilityLabel("Cancel editing queued message")
                    .accessibilityIdentifier("queue-cancel-edit")
                Button("Update", action: model.updateQueuedMessage)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Update queued message")
                    .accessibilityIdentifier("queue-update")
                    .disabled(!model.canUpdateQueuedMessage)
            } else {
                if isFollowingUp {
                    let primary = model.canSteer ? followUpBehavior : .queue
                    if model.canSteer { followUpButton(primary.alternate) }
                    followUpButton(primary).buttonStyle(.borderedProminent)
                } else if !model.phase.isRunning || model.sideChatCommand != nil {
                    if model.canSteer { followUpButton(.steer) }
                    if model.canStartQueuedMessage && !model.queuedMessages.isEmpty {
                        Button("Queue") { model.queueDraft() }
                            .accessibilityIdentifier("queue-message")
                            .disabled(!model.canQueueDraft)
                    }
                    Button(action: model.send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color(red: 0.14, green: 0.24, blue: 0.51), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(model.canSend ? 1 : 0.45)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("send-message")
                    .disabled(!model.canSend)
                }
            }
            if model.phase.isRunning {
                Button(action: model.cancel) { Image(systemName: "stop.fill") }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Stop")
                    .accessibilityIdentifier("stop-message")
                    .disabled(!model.phase.canStop)
            }
        }
        .font(.system(size: 12))
    }

    private func newThread() {
        let projects = filteredProjects
        if projects.count > 1 {
            choosingThreadProject = true
        } else if let project = projects.first {
            startThread(in: project.id)
        } else {
            model.openFolder(startThread: true)
        }
    }

    private var paletteContents: CommandPaletteContents {
        CommandPaletteContents(
            projects: filteredProjects, availableProjects: orderedProjects.filter(\.folderIsAvailable),
            preferredProject: model.project?.id, threads: threads, activeThread: model.conversation?.id,
            canStartScratchThread: model.canStartScratchThread, findThread: model.threadFindScope,
            settingsProject: model.project.flatMap { $0.isScratch ? nil : $0 },
            defaultProject: model.workspace.lastUsedProject
        )
    }

    private func handleNewThreadKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard acceptsWorkspaceKeys(in: window), !model.operationsInProgress,
              (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("n", .command), ("o", [.command, .shift]):
            return openNewThread(in: window)
        case ("n", [.command, .shift]):
            return openNewThread(in: window, local: true)
        case ("n", [.command, .option]) where model.canStartScratchThread:
            startScratchThread()
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func openNewThread(in window: NSWindow, local: Bool = false) -> Bool {
        let contents = paletteContents
        if (local || contents.availableProjects.count == 1), let project = contents.localThreadProject {
            startThread(in: project.id)
            return true
        }
        return openCommandPalette(in: window, choosingProject: true)
    }

    private func acceptsWorkspaceCommands(in window: NSWindow) -> Bool {
        window === NSApp.mainWindow && acceptsWorkspaceKeys(in: window)
    }

    private func acceptsWorkspaceKeys(in window: NSWindow) -> Bool {
        !model.showingWelcome && !model.showingSettings && !model.showingCommandPalette &&
            !model.showingQuitSaveFailure && model.projectPicker == nil && draftProjectPicker == nil &&
            composerModelPicker == nil &&
            window.attachedSheet == nil && NSApp.modalWindow == nil && !ThreadTerminal.hasFocus(in: window) &&
            !choosingWorkspace && !choosingThreadProject && choosingBranch == nil && terminalWorkspaceChange == nil &&
            rename == nil && removingProject == nil && archiveConfirmation == nil
    }

    private func navigate(_ direction: WorkspaceModel.NavigationDirection, in window: NSWindow) -> Bool {
        guard acceptsWorkspaceKeys(in: window), !(window.firstResponder is NSTextView),
              (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
              !documentHasFocus(in: window) else { return false }
        model.navigate(direction)
        return true
    }

    private func documentHasFocus(in window: NSWindow) -> Bool {
        var focusedView = window.firstResponder as? NSView
        while let view = focusedView {
            if view is WKWebView || view is PDFView { return true }
            focusedView = view.superview
        }
        return false
    }

    private func handleFindKey(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard acceptsWorkspaceKeys(in: window) else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let editor = window.firstResponder as? NSTextView
        guard (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        if event.charactersIgnoringModifiers?.lowercased() == "f", modifiers == [.command, .shift] {
            searchFocused = true
            return true
        }

        let editingOtherField = editor?.isFieldEditor == true && !(editor is ComposerTextField.Editor)
        if editingOtherField, !findFocused { return false }
        guard !documentHasFocus(in: window) else { return false }

        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            guard let scope = model.threadFindScope else { return false }
            if editingOtherField, let editor {
                editor.selectAll(nil)
            } else {
                openFind(in: scope, window: window)
            }
            return true
        }
        guard model.activeThreadFind != nil else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            closeFind()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard editingOtherField, modifiers.isEmpty || modifiers == .shift else { return false }
            model.threadFind?.step(backward: modifiers == .shift)
            return true
        default:
            return false
        }
    }

    private func loadFindMatches(_ request: ThreadFindSession.Request) async {
        do {
            try await Task.sleep(for: .milliseconds(120))
            let matches = try await SidebarMessageSearch.occurrences(in: model.root, thread: request.thread,
                                                                     term: request.term)
            guard !Task.isCancelled, model.activeThreadFind?.request == request else { return }
            model.threadFind?.receive(matches, for: request)
        } catch {
            guard !Task.isCancelled, model.activeThreadFind?.request == request else { return }
            model.threadFind?.fail(request)
        }
    }

    private func openFind(in scope: SidebarMessageSearch.Thread, term: TranscriptSearchTerm? = nil,
                          occurrence: TranscriptOccurrence? = nil, window: NSWindow? = nil) {
        guard model.threadFindScope == scope else { return }
        let selection = ComposerTextField.FindSelection(window: window ?? NSApp.keyWindow, model: model)
        if model.activeThreadFind == nil || selection != nil { findSelection = selection }
        if model.threadFind?.thread == scope, term == nil {
            model.threadFind?.refocus()
        } else {
            model.threadFind = ThreadFindSession(thread: scope, term: term, occurrence: occurrence)
        }
    }

    private func closeFind() {
        findFocused = false
        model.threadFind = nil
        if model.conversation?.archived == false {
            findSelection?.restoreOnFocus(in: model)
            focusCurrentComposer()
        }
        findSelection = nil
    }

    @discardableResult
    private func openCommandPalette(in eventWindow: NSWindow? = nil, choosingProject: Bool = false) -> Bool {
        guard model.canOpenCommandPalette, let window = eventWindow ?? NSApp.keyWindow,
              eventWindow != nil || window === NSApp.mainWindow,
              acceptsWorkspaceKeys(in: window) else { return false }
        if findFocused {
            paletteReturnFocus = .threadFind
        } else {
            paletteReturnFocus = searchFocused ? .search : focusedComposer.map(PaletteReturnFocus.composer)
        }
        paletteChoosingProject = choosingProject
        model.showingCommandPalette = true
        return true
    }

    private func finishCommandPalette() {
        let action = paletteAction
        let previousFocus = paletteReturnFocus
        paletteAction = nil
        paletteReturnFocus = nil
        guard let action else {
            switch previousFocus {
            case .search: searchFocused = true
            case .composer(let id) where model.conversation?.id == id: focusedComposer = id
            case .threadFind: model.threadFind?.refocus()
            default: break
            }
            return
        }
        guard model.canOpenCommandPalette else { return }
        switch action {
        case .chooseProject, .searchWorkspace:
            break
        case .openWorkspaceFile(let destination):
            let target = destination.target
            guard paletteFilesLocation == target.location else { return }
            do {
                _ = try WorkspaceFiles(directory: target.location.directory).fileURL(target.path, checkout: destination.checkout)
                selectedFiles[target.location] = target.path
                fileLineReveal = destination.line.map { WorkspaceFileLineReveal(target: target, line: $0) }
                rightPanels[target.location.threadID, default: .init()].show(.files)
            } catch {
                model.error = error.localizedDescription
            }
        case .newThread(let id):
            guard let project = model.projects.first(where: { $0.id == id }) else { return }
            guard project.folderIsAvailable else {
                model.error = "The project folder is no longer available."
                return
            }
            startThread(in: id)
            if model.project?.id == id { focusCurrentComposer() }
        case .newScratchThread:
            startScratchThread()
            focusCurrentComposer()
        case .addProject:
            model.openFolder()
        case .home:
            model.showHome()
        case .searchThreads:
            searchFocused = true
        case .findInCurrentThread(let scope):
            openFind(in: scope)
        case .settings:
            model.openSettings()
        case .projectSettings(let id):
            openProjectSettings(id)
        case .openProject(let id):
            guard filteredProjects.contains(where: { $0.id == id }) else { return }
            model.selectProjectFromPalette(id)
            if model.project?.id == id {
                model.threadFind = nil
                clearSearch()
                model.setSidebarFolderCollapsed(false, for: id)
                focusCurrentComposer()
            }
        case .openThread(let id, let project):
            guard let target = threads.first(where: { $0.id == id && $0.project.id == project }) else { return }
            openThread(target)
            if model.conversation?.id == id { focusCurrentComposer() }
        case .openMessage(let id, let project, let occurrence, let term):
            guard let target = threads.first(where: { $0.id == id && $0.project.id == project }) else { return }
            openThread(target, occurrence: occurrence, term: term)
        }
    }

    private func focusCurrentComposer() {
        searchFocused = false
        focusedComposer = model.conversation?.id
    }

    private func chooseWorkspace() {
        if let thread = model.conversation, openTerminals.contains(where: { $0.id.thread == thread.id }) ||
            rightPanels[thread.id]?.terminals.isEmpty == false {
            terminalWorkspaceChange = thread.id
        } else {
            choosingWorkspace = true
        }
    }

    private var branchDisplay: (branch: String?, label: String?)? {
        guard let scope = model.branchPickerScope else { return nil }
        if case let .newWorktree(_, base) = scope.location {
            let branch = GitBranchRef.displayName(base)
            let useRemote = model.conversation?.worktreeStartsFromRemote == true
            let label = useRemote && base.hasPrefix("refs/heads/") ? "From \(branch) (remote)" : "From \(branch)"
            return (branch, label)
        }
        guard let loadedBranch, loadedBranch.scope == scope else { return nil }
        return (loadedBranch.branch, nil)
    }

    @discardableResult
    private func openBranchPicker() -> Bool {
        guard let scope = model.branchPickerScope, !model.showingWelcome, !model.showingSettings,
              !model.showingCommandPalette, model.projectPicker == nil, choosingBranch == nil,
              !choosingWorkspace, !choosingThreadProject, terminalWorkspaceChange == nil,
              rename == nil, removingProject == nil, !model.showingQuitSaveFailure else { return false }
        restoreBranchComposerFocus = focusedComposer == scope.threadID
        choosingBranch = scope
        return true
    }

    private func copyBranch(_ branch: String) {
        if !BranchPickerView.copyBranch(branch, to: workspacePasteboard) {
            model.error = "Could not copy the branch name."
        }
    }

    @discardableResult
    private func startThread(in projectID: UUID) -> DraftProjectScope? {
        guard !model.operationsInProgress, model.projects.contains(where: { $0.id == projectID }) else { return nil }
        model.addConversation(in: projectID)
        guard model.project?.id == projectID, model.editingQueuedMessageID == nil else { return nil }
        revealOpenedProject()
        searchFocused = false
        clearSearch()
        return model.conversation?.isDraft == true ? model.draftProjectScope : nil
    }

    private func clearSearch() {
        query = ""
        highlightedSearchThread = nil
        messageSearchResult = nil
    }

    private func searchResult(in results: [SidebarThread]) -> SidebarThread? {
        results.first { $0.id == highlightedSearchThread } ?? results.first
    }

    private func moveSearchHighlight(in results: [SidebarThread], by step: Int) -> KeyPress.Result {
        guard !searchTerm.isEmpty, !results.isEmpty else { return .ignored }
        let index = results.firstIndex { $0.id == highlightedSearchThread } ?? 0
        highlightedSearchThread = results[(index + step + results.count) % results.count].id
        return .handled
    }

    private func openThread(_ item: SidebarThread, messageMatch: SidebarMessageSearch.Match? = nil) {
        openThread(item, occurrence: messageMatch?.occurrence, term: messageMatch.map { _ in .literal(searchTerm) })
    }

    private func openThread(_ item: SidebarThread, occurrence: TranscriptOccurrence?, term: TranscriptSearchTerm?) {
        model.selectConversation(item.id, in: item.project.id)
        guard model.project?.id == item.project.id, model.conversation?.id == item.id else { return }
        if let term { openFind(in: .init(projectID: item.project.id, threadID: item.id), term: term, occurrence: occurrence) }
        model.setSidebarFolderCollapsed(false, for: item.project.id)
        if !item.thread.archived, item.thread.threadShelf == .settled { settledExpanded = true }
        guard !searchTerm.isEmpty else { return }
        searchFocused = false
        clearSearch()
    }

    private func startScratchThread() {
        let before = model.conversation?.id
        model.startScratchThread()
        guard model.project?.isScratch == true, model.conversation?.id != before else { return }
        model.updateSidebarScope { $0.clear() }
        clearSearch()
    }

    private func canChooseDraftProject(_ threadID: UUID) -> Bool {
        model.canSwitchDraftProject && !openTerminals.contains { $0.id.thread == threadID } &&
            rightPanels[threadID]?.terminals.isEmpty != false
    }

    private func openDraftProjectPicker(for threadID: UUID) {
        guard canChooseDraftProject(threadID), let scope = model.draftProjectScope, scope.threadID == threadID,
              draftProjectPicker == nil, model.projectPicker == nil else { return }
        draftProjectPicker = DraftProjectPickerPresentation(scope: scope, restoreComposerFocus: focusedComposer == threadID)
    }

    private func finishDraftProjectPicker(_ session: DraftProjectPickerPresentation,
                                          with destination: DraftProjectPicker.Destination?) {
        guard draftProjectPicker?.id == session.id else { return }
        draftProjectPicker = nil
        guard model.draftProjectScope == session.scope else { return }
        if let destination, canChooseDraftProject(session.scope.threadID) {
            switch destination {
            case .addProject:
                model.openFolder(draftOrigin: session.scope)
                if model.projectPicker?.draftOrigin == session.scope {
                    focusAfterPicker = session.restoreComposerFocus ? session.scope : nil
                    return
                }
            case .project(let id):
                model.switchDraftProject(to: id, from: session.scope)
            case .noProject:
                model.switchDraftProject(to: nil, from: session.scope)
            }
            if model.project?.id != session.scope.projectID { revealOpenedProject() }
        }
        if session.restoreComposerFocus { focusedComposer = model.conversation?.id }
    }

    private func beginRename(_ target: RenameTarget, title: String) {
        self.title = title
        rename = target
    }

    private func saveTitle() {
        defer { rename = nil }
        let updated = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.isEmpty else { return }
        switch rename {
        case let .project(id): model.renameProject(id, title: updated)
        case let .conversation(id, project): model.renameConversation(id, in: project, title: updated)
        case nil: break
        }
    }
}

private struct DraftComposerLayout: Layout {
    static let bottomInset: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lane = ProposedViewSize(width: bounds.width, height: nil)
        let headline = subviews[0]
        let composer = subviews[1]
        let composerHeight = composer.sizeThatFits(lane).height
        let freeHeight = max(0, bounds.height - composerHeight - Self.bottomInset)
        let headlineSize = headline.sizeThatFits(ProposedViewSize(width: bounds.width, height: freeHeight))
        let spacing = min(48, max(0, freeHeight - headlineSize.height))
        let composerTop = bounds.minY + max(freeHeight / 2, headlineSize.height + spacing)
        headline.place(at: CGPoint(x: bounds.midX, y: composerTop - spacing), anchor: .bottom,
                       proposal: ProposedViewSize(headlineSize))
        composer.place(at: CGPoint(x: bounds.midX, y: composerTop), anchor: .top, proposal: lane)
    }
}

private struct TerminalDrawerReservedHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private extension View {
    func reservesRoomAboveTerminal(_ terminalVisible: Bool, inset: CGFloat = 0) -> some View {
        fixedSize(horizontal: false, vertical: terminalVisible)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: TerminalDrawerReservedHeight.self, value: geometry.size.height + inset)
                }
            }
    }
}

private struct WorkspaceDivider: View {
    let label: String
    let width: CGFloat
    let drag: GestureState<CGFloat>
    var expandsToRight = true
    var color: Color?
    let onResize: (CGFloat) -> Void

    var body: some View {
        Group {
            if let color {
                color
            } else {
                Divider()
            }
        }
            .frame(width: WorkspaceLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .updating(drag) { value, translation, _ in translation = value.translation.width }
                            .onEnded { onResize($0.translation.width) }
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityValue("\(Int(width)) points")
                    .accessibilityAdjustableAction { direction in
                        let step: CGFloat = expandsToRight ? 16 : -16
                        switch direction {
                        case .increment: onResize(step)
                        case .decrement: onResize(-step)
                        @unknown default: break
                        }
                    }
            }
    }
}
