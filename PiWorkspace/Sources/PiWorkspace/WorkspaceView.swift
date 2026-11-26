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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SidebarPreference.groupByProject) private var grouped = false
    @State private var sidebarWidth = WorkspaceLayout.defaultSidebarWidth
    @GestureState private var sidebarDrag: CGFloat = 0
    @State private var rightPanelWidths: [UUID: CGFloat] = [:]
    @GestureState private var rightPanelDrag: CGFloat = 0
    @State private var collapsed: Set<UUID> = []
    @State private var query = ""
    @State private var projectFilter = SidebarProjectFilter()
    @State private var showingSidebarFilters = false
    @State private var highlightedSearchThread: UUID?
    @State private var messageSearchResult: (key: MessageSearchKey, matches: [UUID: SidebarMessageSearch.Match])?
    @FocusState private var searchFocused: Bool
    @FocusState private var findFocused: Bool
    @State private var showingDetails = false
    @State private var showingChanges = false
    @State private var browserPanels: [UUID: ThreadBrowserPreview] = [:]
    @State private var showingFiles: Set<UUID> = []
    @State private var selectedFiles: [WorkspaceFilesLocation: String] = [:]
    @State private var choosingWorkspace = false
    @State private var choosingBranch: WorkspaceModel.BranchPickerScope?
    @State private var loadedBranch: (scope: WorkspaceModel.BranchPickerScope, branch: String?)?
    @State private var restoreBranchComposerFocus = false
    @State private var terminalWorkspaceChange: UUID?
    @State private var choosingThreadProject = false
    @State private var draftProjectPicker: DraftProjectPickerPresentation?
    @State private var paletteAction: CommandPaletteAction?
    @State private var paletteReturnFocus: PaletteReturnFocus?
    @State private var openTerminals: [ThreadTerminalDrawerState] = []
    @State private var terminalDrawerReservedHeight: CGFloat = 0
    @State private var settledExpanded = false
    @State private var rename: RenameTarget?
    @State private var title = ""
    @State private var removingProject: Project?
    @State private var createdProject: UUID?
    @State private var draftCheckoutBranches: [String: String] = [:]
    @FocusState private var focusedComposer: UUID?
    @FocusState private var welcomeFocus: WelcomeFocus?
    @State private var focusAfterPicker: DraftProjectScope?
    @State private var targetingProjectDrop = false
    @State private var targetingAttachmentRow: UUID?
    @State private var targetingComposerDrop = false

    private enum RenameTarget {
        case project(UUID)
        case conversation(UUID, project: UUID)
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

    private struct SearchRow: Identifiable {
        let thread: SidebarThread
        let match: SidebarMessageSearch.Match?
        var id: String { thread.id.uuidString + "/" + (match?.messageID ?? "") }
    }

    private enum TranscriptAnchor: Hashable {
        case message(String)
        case latest
    }

    private var orderedProjects: [Project] { SidebarProjectFilter.orderedProjects(model.projects) }
    private var filteredProjects: [Project] { projectFilter.projects(in: orderedProjects) }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var threads: [SidebarThread] {
        let scope = projectFilter.selection.isEmpty ? model.threadProjects : filteredProjects
        return SidebarThread.matching(in: scope, search: "", archived: model.showArchive)
            .filter { $0.project.isScratch || model.showsInSidebar($0.thread) }
    }

    private var rail: Color { colorScheme == .dark ? Color(white: 0.082) : Color(white: 0.955) }
    private var canvas: Color { colorScheme == .dark ? Color(white: 0.065) : Color(nsColor: .textBackgroundColor) }
    private var surface: Color { colorScheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.042) }
    private let accent = Color(red: 0.24, green: 0.48, blue: 0.70)

    var body: some View {
        let findRequest = model.activeThreadFind?.request
        ZStack {
            GeometryReader { window in
                let viewportWidth = window.size.width
                let width = WorkspaceLayout.sidebarWidth(in: viewportWidth, preferred: sidebarWidth, drag: sidebarDrag)
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: width)
                    WorkspaceDivider(label: "Resize sidebar", width: width, drag: $sidebarDrag) { translation in
                        sidebarWidth = WorkspaceLayout.sidebarWidth(
                            in: viewportWidth, preferred: sidebarWidth, drag: translation)
                    }
                    .zIndex(1)
                    detail(viewport: window.size)
                }
            }
            .opacity(model.showingWelcome ? 0 : 1)
            .accessibilityHidden(model.showingWelcome)
            .disabled(model.showingWelcome)
            if model.showingWelcome { welcome }
        }
        .tint(accent)
        .background {
            WindowKeyMonitor { event, window in
                if handleFindKey(event, in: window) { return true }
                guard !event.isARepeat else { return false }
                if case .toggle? = CommandPaletteSession.Key(event) {
                    return openCommandPalette(in: window)
                }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
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
        .onReceive(model.sidebarCommand) { command in
            switch command {
            case .commandPalette: openCommandPalette()
            case .newThread, .search:
                guard !model.showingWelcome, !model.showingCommandPalette,
                      NSApp.mainWindow?.attachedSheet == nil else { return }
                if command == .newThread { newThread() } else { searchFocused = true }
            }
        }
        .onChange(of: model.projects.map(\.id)) { _, ids in projectFilter.retainProjects(ids) }
        .overlay(alignment: .topTrailing) {
            if let createdProject {
                Text("Project created")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("project-created")
                    .task(id: createdProject) {
                        try? await Task.sleep(for: .seconds(3))
                        if !Task.isCancelled { self.createdProject = nil }
                    }
            }
        }
        .onChange(of: model.threadFindScope) { _, scope in
            if model.threadFind?.thread != scope { model.threadFind = nil }
        }
        .onChange(of: model.draftProjectScope) { _, scope in
            if let draftProjectPicker, draftProjectPicker.scope != scope { self.draftProjectPicker = nil }
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
        .sheet(isPresented: $model.showingCommandPalette, onDismiss: finishCommandPalette) {
            CommandPaletteView(contents: paletteContents, latestMessageID: model.messages.last?.id,
                               searchMessages: model.searchMessages) { action in
                guard model.showingCommandPalette else { return }
                paletteAction = action
                model.showingCommandPalette = false
            }
        }
        .task(id: model.repositoryRevision) {
            var branches: [String: String] = [:]
            let paths = Set(model.threadProjects.flatMap(\.conversations).compactMap { thread -> String? in
                guard thread.isDraft == true, case let .worktree(path, _) = thread.workingLocation else { return nil }
                return path
            })
            for path in paths {
                if Task.isCancelled { return }
                branches[path] = try? await GitWorkspace(path: path).currentBranch()
            }
            if !Task.isCancelled { draftCheckoutBranches = branches }
        }
        .sheet(isPresented: $choosingWorkspace) {
            if let project = model.project { ThreadLocationView(project: project, model: model) }
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
                choosingWorkspace = true
            }
        } message: { _ in
            Text("Workspace changes require a new terminal in the selected folder.")
        }
        .sheet(isPresented: $choosingThreadProject) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start a thread in").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(filteredProjects) { project in
                            Button(project.title) {
                                choosingThreadProject = false
                                startThread(in: project.id)
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
            TextField("Name", text: $title)
            Button("Cancel", role: .cancel) { rename = nil }
            Button("Save") { saveTitle() }
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
            HStack(spacing: 11) {
                Text("Pi Workspace")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
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
                    if searchTerm.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 3) { threadShelves(visibleThreads) }
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
        projectFilter.clear()
        if let id = model.project?.id { collapsed.remove(id) }
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
        let active = model.showArchive ? threads : threads.filter { $0.thread.threadShelf == .active }
        let pinned = model.showArchive ? [] : threads.filter { $0.thread.threadShelf == .pinned }
        let settled = model.showArchive ? [] : threads.filter { $0.thread.threadShelf == .settled }
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
                    (project.pinned == true || projectFilter.selection.contains(project.id))) {
                    projectGroup(project, items: items)
                }
            }
        } else {
            ForEach(active) { link in threadRow(link, showProject: true) }
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
            VStack(alignment: .leading, spacing: 8) {
                Button("All Projects") { projectFilter.clear() }
                    .accessibilityIdentifier("project-filter-all")
                    .disabled(projectFilter.selection.isEmpty)
                if !orderedProjects.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(orderedProjects) { project in
                                Toggle(isOn: Binding(
                                    get: { projectFilter.selection.contains(project.id) },
                                    set: { projectFilter.setSelected(project.id, $0) }
                                )) {
                                    Label(project.title, systemImage: project.pinned == true ? "pin.fill" : "folder")
                                        .lineLimit(1)
                                }
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("project-filter-\(project.id)")
                                .contextMenu { projectPinAction(project) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(idealHeight: CGFloat(min(orderedProjects.count, 9)) * 26, maxHeight: 234)
                }
                Divider()
                Toggle("Group by Project", isOn: $grouped)
                    .accessibilityIdentifier("group-threads-by-project")
                Toggle("Show Archive", isOn: $model.showArchive)
                    .accessibilityIdentifier("show-thread-archive")
                Button("Done") { showingSidebarFilters = false }
                    .accessibilityIdentifier("close-thread-filters")
            }
            .padding(12)
            .frame(width: 230)
        }
    }

    private func projectGroup(_ project: Project, items: [SidebarThread]) -> some View {
        let expanded = !collapsed.contains(project.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                Button {
                    if expanded { collapsed.insert(project.id) }
                    else { collapsed.remove(project.id) }
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

    private func threadRow(_ link: SidebarThread, showProject: Bool, highlighted: Bool = false) -> some View {
        let selected = model.conversation?.id == link.id
        let emphasized = searchTerm.isEmpty ? selected : highlighted
        let acceptsAttachments = !link.thread.archived && link.thread.worktreeLaunch == nil &&
            link.thread.composerSubmission == nil && (!model.operationsInProgress || selected)
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
        .contextMenu { threadActions(link.thread, project: link.project) }
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
    private func projectActions(_ project: Project) -> some View {
        Button("New Thread") { startThread(in: project.id) }
            .disabled(model.operationsInProgress)
        projectPinAction(project)
        Button("Rename Project…") { beginRename(.project(project.id), title: project.title) }
        Button("Relink Folder…") { model.openFolder(relinking: project.id) }
            .disabled(model.phase.isRunning)
        Button("Remove Project…") { removingProject = project }
            .disabled(model.phase.isRunning)
    }

    private func projectPinAction(_ project: Project) -> some View {
        Button(project.pinned == true ? "Unpin Project" : "Pin Project") {
            model.setProjectPinned(project.id, pinned: project.pinned != true)
        }
        .accessibilityIdentifier("toggle-project-pin-\(project.id)")
    }

    @ViewBuilder
    private func threadActions(_ thread: Conversation, project: Project) -> some View {
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
            submittedThreadActions(thread, project: project)
        }
    }

    @ViewBuilder
    private func draftActions(_ thread: Conversation, project: Project) -> some View {
        let path = thread.workingLocation.directory(in: project)
        let branch = draftBranch(in: thread.workingLocation)
        Menu("Copy") {
            if !path.isEmpty {
                Button("Path") { copyToPasteboard(path) }
                    .accessibilityIdentifier("draft-copy-path")
            }
            if let branch, !branch.isEmpty {
                Button("Branch") { copyToPasteboard(branch) }
                    .accessibilityIdentifier("draft-copy-branch")
            }
        }
        .accessibilityIdentifier("draft-copy")
        .disabled(path.isEmpty && (branch ?? "").isEmpty)
        if project.isScratch {
            turnIntoProject(thread, project: project)
        } else {
            Button("Project settings") { model.openSettings(.model, projectID: project.id) }
                .accessibilityIdentifier("draft-project-settings")
                .disabled(model.operationsInProgress)
        }
        Divider()
        Button("Discard draft", role: .destructive) { model.discardDraft(thread.id, in: project.id) }
            .accessibilityIdentifier("discard-draft")
            .disabled(model.operationsInProgress || !thread.canDiscardDraft)
    }

    private func draftBranch(in location: ThreadLocation) -> String? {
        switch location {
        case .project: nil
        case let .newWorktree(_, base): GitBranchRef.displayName(base)
        case let .worktree(path, _): draftCheckoutBranches[path]
        }
    }

    private func copyToPasteboard(_ text: String) {
        workspacePasteboard.clearContents()
        workspacePasteboard.setString(text, forType: .string)
    }

    private func turnIntoProject(_ thread: Conversation, project: Project) -> some View {
        Button("Turn into project") {
            if model.convertScratchThread(thread.id, in: project.id) { createdProject = project.id }
        }
        .accessibilityIdentifier("turn-into-project")
        .disabled(model.operationsInProgress)
    }

    @ViewBuilder
    private func submittedThreadActions(_ thread: Conversation, project: Project) -> some View {
        if projectFilter.selection == [project.id] {
            Button("Show All Projects") { projectFilter.clear() }
        } else {
            Button("Filter by \(project.title)") { projectFilter.selectOnly(project.id) }
        }
        Button("Rename Thread…") { beginRename(.conversation(thread.id, project: project.id), title: thread.title) }
        if project.isScratch {
            turnIntoProject(thread, project: project)
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
        }
        Button(thread.archived ? "Restore Thread" : "Archive Thread") {
            model.archiveConversation(thread.id, in: project.id, archived: !thread.archived)
        }
        .disabled(model.operationsInProgress)
    }

    private func detail(viewport: CGSize) -> some View {
        let limits = TerminalDrawerHeight(viewport: viewport.height,
                                          reserved: WorkspaceLayout.headerHeight + terminalDrawerReservedHeight)
        return VStack(spacing: 0) {
            GeometryReader { workspace in
                if let project = model.project, let thread = model.conversation {
                    threadWorkspace(project, thread, viewportWidth: viewport.width, size: workspace.size)
                } else {
                    readyScreen
                }
            }
            terminalDrawer(limits: limits)
        }
        .background(canvas)
        .onPreferenceChange(TerminalDrawerReservedHeight.self) { terminalDrawerReservedHeight = $0 }
    }

    private func threadWorkspace(_ project: Project, _ thread: Conversation, viewportWidth: CGFloat, size: CGSize) -> some View {
        let browser = Binding(
            get: { browserPanels[thread.id] ?? ThreadBrowserPreview(searchDefaults: browserDefaults) },
            set: { browserPanels[thread.id] = $0 }
        )
        let filesAreVisible = showingFiles.contains(thread.id)
        let browserIsVisible = !filesAreVisible && browser.wrappedValue.isVisible
        let changesDirectory = showingChanges && !thread.workingLocation.needsWorktree ? model.workingDirectory : nil
        let hasRightPanel = filesAreVisible || browserIsVisible || changesDirectory != nil
        let preferredWidth = rightPanelWidths[thread.id] ?? WorkspaceLayout.defaultRightPanelWidth
        let layout = WorkspaceLayout(
            viewportWidth: viewportWidth,
            workspaceSize: size,
            preferredRightPanelWidth: hasRightPanel ? preferredWidth : nil,
            rightPanelDrag: rightPanelDrag,
            showingDetails: showingDetails,
            miniPlayer: browser.wrappedValue.miniPlayer?.placement,
            chatWidthMode: chatWidthMode
        )
        return VStack(spacing: 0) {
            header(project, thread, browserIsVisible: browserIsVisible, filesAreVisible: filesAreVisible,
                   detailsFitInline: layout.detailsFitInline)
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
                    if hasRightPanel {
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
                            Group {
                                if filesAreVisible {
                                    filesPanel(project, thread)
                                } else if browserIsVisible {
                                    BrowserPreviewView(preview: browser)
                                } else if let changesDirectory {
                                    SourceControlView(directory: changesDirectory, model: model, openBranch: {
                                        openBranchPicker()
                                    }, copyBranch: copyBranch) { path in
                                        guard let location = selectedFilesLocation,
                                              location.threadID == thread.id, location.directory == changesDirectory
                                        else { return }
                                        selectedFiles[location] = path
                                        showingFiles.insert(thread.id)
                                    }
                                        .id(changesDirectory)
                                }
                            }
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

    private var selectedFilesLocation: WorkspaceFilesLocation? {
        guard let project = model.project, let thread = model.conversation else { return nil }
        return WorkspaceFilesLocation(thread: thread, project: project)
    }

    @ViewBuilder
    private func filesPanel(_ project: Project, _ thread: Conversation) -> some View {
        if let location = WorkspaceFilesLocation(thread: thread, project: project) {
            WorkspaceFilesView(location: location, saves: model.fileSaves, pasteboard: workspacePasteboard,
                               activeLocation: { showingFiles.contains(thread.id) ? selectedFilesLocation : nil },
                               close: { showingFiles.remove(thread.id) },
                               selection: Binding(get: { selectedFiles[location] },
                                                  set: { selectedFiles[location] = $0 }))
                .id(location)
        } else {
            Text("Files will be available when the worktree is ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
                .accessibilityIdentifier("files-pending-worktree")
        }
    }

    private var readyScreen: some View {
        VStack(spacing: 12) {
            if let error = model.error {
                Text(error).foregroundStyle(.red)
            }
            if let project = model.project {
                Text(project.title).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                Button("New Thread") { newThread() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.operationsInProgress)
                Menu("Project Actions") { projectActions(project) }
                    .fixedSize()
                    .accessibilityIdentifier("project-actions")
            } else {
                Text("What should we work on?").font(.system(size: 26, weight: .semibold))
                Button("Add Project") { model.openFolder() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("empty-open-project")
                if model.canStartScratchThread {
                    Button("Start without a project", action: startScratchThread)
                        .accessibilityIdentifier("start-without-project")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ project: Project, _ thread: Conversation, browserIsVisible: Bool,
                        filesAreVisible: Bool, detailsFitInline: Bool) -> some View {
        return HStack(spacing: 8) {
            let canSwitchProject = canChooseDraftProject(thread.id)
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
                    Label(project.title, systemImage: project.isScratch ? "doc" : "folder")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.primary)
                .fixedSize(horizontal: true, vertical: false)
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
            if let scope = model.pullRequestScope, scope.canReadRepository || !thread.pullRequestLinks.isEmpty {
                PullRequestsButton(workspace: model, scope: scope, pasteboard: workspacePasteboard)
                    .id(scope)
            }
            Button {
                if showingFiles.remove(thread.id) != nil || browserIsVisible {
                    browserPanels[thread.id]?.isVisible = false
                    showingChanges = true
                } else {
                    showingChanges.toggle()
                }
            } label: {
                Image(systemName: showingChanges && !browserIsVisible && !filesAreVisible ? "doc.text.fill" : "doc.text")
            }
            .buttonStyle(.plain)
            .help("Changes")
            .accessibilityLabel("Changes")
            .accessibilityIdentifier("toggle-changes")
            .disabled(thread.workingLocation.needsWorktree)

            Button {
                if showingFiles.remove(thread.id) == nil { showingFiles.insert(thread.id) }
            } label: {
                Image(systemName: filesAreVisible ? "folder.fill" : "folder")
            }
            .buttonStyle(.plain)
            .help(filesAreVisible ? "Hide Files" : "Show Files")
            .accessibilityLabel("Files")
            .accessibilityAddTraits(filesAreVisible ? .isSelected : [])
            .accessibilityIdentifier("toggle-files")

            Button {
                let wasShowingFiles = showingFiles.remove(thread.id) != nil
                if !wasShowingFiles || browserPanels[thread.id]?.isVisible != true {
                    browserPanels[thread.id, default: ThreadBrowserPreview(searchDefaults: browserDefaults)].togglePanel()
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
                    composer(project, thread)
                        .reservesRoomAboveTerminal(terminalIsVisible)
                }
            } else {
                transcript(find?.selection, project: project, thread: thread)
                composer(project, thread).padding(.vertical, 12)
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
                    .accessibilityIdentifier("draft-project-trigger")
                    if !project.isScratch { Text("?").padding(.leading, -4) }
                }
            } else {
                Text(project.isScratch ? "What should we work on?" : "What should we build in \(project.title)?")
            }
        }
        .popover(item: Binding(
            get: { draftProjectPicker },
            set: { if $0 == nil, let session = draftProjectPicker { finishDraftProjectPicker(session, with: nil) } }
        ), arrowEdge: .bottom) { session in
            let projects = model.projects.sorted { lhs, rhs in
                if (lhs.pinned == true) != (rhs.pinned == true) { return lhs.pinned == true }
                return lhs.lastActivity > rhs.lastActivity
            }
            DraftProjectPicker(projects: projects, currentProject: project.id, isScratch: project.isScratch) {
                finishDraftProjectPicker(session, with: $0)
            }
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
        }
        .padding(15)
        .frame(width: width, alignment: .leading)
        .accessibilityIdentifier("workspace-details")
    }

    private var activeTerminal: ThreadTerminalLocation? {
        guard let thread = model.conversation?.id, let path = model.workingDirectory else { return nil }
        return ThreadTerminalLocation(thread: thread, path: path)
    }

    private var terminalIsVisible: Bool {
        openTerminals.contains { $0.id == activeTerminal && $0.isOpen }
    }

    private func toggleTerminal() {
        guard let activeTerminal else { return }
        if let index = openTerminals.firstIndex(where: { $0.id == activeTerminal }) {
            openTerminals[index].isOpen.toggle()
        } else {
            openTerminals.append(ThreadTerminalDrawerState(id: activeTerminal))
        }
    }

    private func terminalDrawer(limits: TerminalDrawerHeight) -> some View {
        VStack(spacing: 0) {
            ForEach($openTerminals) { $drawer in
                let location = drawer.id
                ThreadTerminalDrawer(drawer: $drawer, selected: location == activeTerminal, limits: limits) {
                    openTerminals.removeAll { $0.id == location }
                }
            }
        }
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
                            messageRow(message.text, role: message.role, attachments: message.attachments ?? [])
                                .background(isMatch ? accent.opacity(0.18) : .clear,
                                            in: RoundedRectangle(cornerRadius: 11))
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
            .onChange(of: target, initial: true) { _, target in
                if let id = target?.messageID { reader.scrollTo(TranscriptAnchor.message(id), anchor: .center) }
            }
            .onChange(of: model.messages.count) { _, _ in
                if target == nil { reader.scrollTo(TranscriptAnchor.latest, anchor: .bottom) }
            }
            .onChange(of: model.partial) { _, _ in
                if target == nil { reader.scrollTo(TranscriptAnchor.latest, anchor: .bottom) }
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

    private func messageRow(_ text: String, role: ChatMessage.Role, attachments: [SentAttachment] = []) -> some View {
        let rendered = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return HStack {
            if role == .user { Spacer(minLength: 35) }
            VStack(alignment: .leading, spacing: 6) {
                if !text.isEmpty {
                    Text(role == .assistant ? rendered : AttributedString(text))
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                ForEach(attachments) { attachment in
                    Label(attachment.name, systemImage: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc.text")
                        .font(.callout)
                        .accessibilityIdentifier("sent-attachment-\(attachment.id)")
                }
            }
            .padding(role == .user ? 11 : 0)
            .background(role == .user ? surface : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            if role == .assistant { Spacer(minLength: 0) }
        }
    }

    private func composer(_ project: Project, _ thread: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let saveError = model.composerSaveError {
                HStack {
                    Text("Draft not saved. \(saveError)").foregroundStyle(.red)
                    Spacer()
                    Button("Retry Saving") { model.savePendingComposer() }
                        .accessibilityIdentifier("retry-saving-draft")
                }
                .font(.callout)
            }
            if let error = model.error {
                HStack {
                    Text(error).foregroundStyle(.red)
                        .accessibilityIdentifier("composer-error")
                    Spacer()
                    if model.phase == .closed && !model.canRetryWorktree {
                        Button("Reconnect", action: model.connect)
                    }
                }
                .font(.callout)
            }
            if let launch = thread.worktreeLaunch, !model.phase.isRunning {
                WorktreeLaunchView(threadID: thread.id, launch: launch, model: model)
            }
            if thread.archived {
                Button("Restore Thread") {
                    model.archiveConversation(thread.id, in: project.id, archived: false)
                }
            } else if thread.worktreeLaunch == nil || model.phase.isRunning {
                if let approval = model.pendingToolApproval, let directory = model.workingDirectory {
                    ToolApprovalCard(approval: approval, directory: directory) {
                        model.respond(to: approval.requestID, with: $0)
                    }
                }
                QueuedMessagesView(model: model) { focusedComposer = thread.id }
                    .id(thread.id)
                if let question = model.pendingAgentQuestion {
                    AgentQuestionCard(request: question.request, submitting: question.submitting, error: question.error,
                                      respond: { model.respond(to: question.request.scope, with: $0) }, stop: model.cancel)
                        .id(question.request.scope.requestID)
                } else {
                    inputCard(project, threadID: thread.id)
                }
            }
            HStack {
                if model.canChangeWorkspace {
                    Button(action: chooseWorkspace) {
                        Label(thread.workingLocation.label, systemImage: "chevron.up.chevron.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Thread workspace, \(thread.workingLocation.label)")
                    .accessibilityIdentifier("choose-workspace")
                } else {
                    Label(thread.workingLocation.label, systemImage: "desktopcomputer")
                }
                if let display = branchDisplay {
                    ThreadBranchButton(branch: display.branch, fallback: display.fallback,
                                       identifier: "composer-branch", open: { openBranchPicker() }, copy: copyBranch)
                }
                Spacer()
                if model.preparingWorktree && thread.worktreeLaunch?.interruption != nil {
                    Text("Cancelling setup…")
                } else if model.preparingWorktree && thread.workingLocation != .project {
                    Text("Preparing worktree…")
                } else if model.phase == .connecting {
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
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
            .frame(minHeight: 24)
        }
        .frame(maxWidth: .infinity)
        .anchorPreference(key: BrowserMiniPlayerObstacles.self, value: .bounds) { [.composer: $0] }
    }

    private func inputCard(_ project: Project, threadID: UUID) -> some View {
        let target = model.attachmentTarget(for: threadID)
        func ownsComposer() -> Bool {
            model.conversation?.id == threadID && model.attachmentTarget(for: threadID) == target
        }
        let drop = AttachmentDropDestination(canDrop: model.canEditAttachments, perform: { items in
            let attachments = ComposerAttachmentInput.readAttachments(from: items)
            return !attachments.isEmpty && ownsComposer() && model.canEditAttachments && model.attach(attachments, to: target)
        }, isTargeted: { targetingComposerDrop = $0 && model.canEditAttachments })
        return VStack(alignment: .leading, spacing: 0) {
            ComposerAttachmentsView(model: model, threadID: threadID)
                .id(threadID)
                .padding(.bottom, 6)
            ComposerTextField(placeholder: model.editingQueuedMessageID == nil ? "Ask Pi anything" : "Edit queued message", text: Binding(
                get: { ownsComposer() ? model.draft : "" },
                set: { if ownsComposer() { model.editDraft($0, in: threadID) } }
            ), drop: drop) { text in
                if ownsComposer(), model.canEditAttachments { model.attach([.pastedText(text)], to: target) }
            }
                .id(threadID)
                .focused($focusedComposer, equals: threadID)
                .task(id: threadID) {
                    await Task.yield()
                    if !Task.isCancelled && model.conversation?.id == threadID &&
                        !model.showingWelcome && model.projectPicker == nil && draftProjectPicker == nil &&
                        !model.showingSettings && !model.showingCommandPalette && model.activeThreadFind == nil {
                        focusedComposer = threadID
                    }
                }
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, minHeight: 53.5, alignment: .topLeading)
                .accessibilityIdentifier("composer")
                .disabled(model.conversation?.worktreeLaunch != nil || model.conversation?.composerSubmission != nil)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 13) {
                    composerConfiguration(project)
                    composerActions.fixedSize()
                }
                VStack(alignment: .trailing, spacing: 4) {
                    composerConfiguration(project)
                    composerActions
                }
            }
            .font(.system(size: 12))
            .frame(minHeight: 32)
        }
        .padding(WorkspaceLayout.editorInset)
        .background(surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(targetingComposerDrop ? accent : .primary.opacity(0.11))
                .allowsHitTesting(false)
        }
        .background { drop.accessibilityHidden(true) }
        .onPasteCommand(of: ComposerAttachmentInput.contentTypes) { providers in
            guard model.canEditAttachments else { return }
            Task {
                var items: [ComposerAttachmentInput] = []
                for provider in providers.prefix(ComposerAttachment.maxCount + 1) {
                    let loaded = await withCheckedContinuation { continuation in
                        _ = provider.loadTransferable(type: ComposerAttachmentInput.self) { result in
                            continuation.resume(returning: result)
                        }
                    }
                    if case .success(let item) = loaded { items.append(item) }
                }
                let attached = !items.isEmpty && model.attach(items, to: target)
                if model.error == nil && items.count < min(providers.count, ComposerAttachment.maxCount + 1) {
                    model.error = "Some pasted files or images could not be read."
                } else if !attached && !items.isEmpty && model.error == nil {
                    model.error = "The attachment target is no longer editable."
                }
            }
        }
    }

    private func composerConfiguration(_ project: Project) -> some View {
        HStack(spacing: 13) {
            if model.effectiveModel.supportsTools {
                Menu {
                    ForEach(ToolPermission.allCases, id: \.self) { permission in
                        Button(permission.title) { model.setToolPermission(permission) }
                            .accessibilityIdentifier("tool-mode-\(permission.rawValue)")
                    }
                } label: {
                    Label(project.toolPermission.title, systemImage: project.toolPermission.icon)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.operationsInProgress)
                .accessibilityIdentifier("tool-permissions")
            }
            Spacer()
            Button {
                model.openSettings(.model)
            } label: {
                Label(model.effectiveModel.model, systemImage: "cpu")
                    .lineLimit(1)
            }
            .accessibilityIdentifier("active-model")
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.phase.isRunning)
        }
    }

    private var composerActions: some View {
        HStack(spacing: 6) {
            if model.editingQueuedMessageID != nil {
                Button("Cancel", action: model.cancelQueuedMessageEdit)
                    .accessibilityLabel("Cancel editing queued message")
                    .accessibilityIdentifier("queue-cancel-edit")
                Button("Update", action: model.updateQueuedMessage)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Update queued message")
                    .accessibilityIdentifier("queue-update")
                    .disabled(!model.canUpdateQueuedMessage)
            } else {
                if model.canSteer {
                    Button("Steer") { model.queueDraft(steering: true) }
                        .help("Send into the current turn")
                        .accessibilityIdentifier("steer-message")
                        .disabled(!model.canQueueDraft)
                }
                if model.phase == .running {
                    Button("Queue") { model.queueDraft() }
                        .help("Send after the current turn")
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("queue-message")
                        .disabled(!model.canQueueDraft)
                } else if model.phase != .stopping {
                    if model.canStartQueuedMessage && !model.queuedMessages.isEmpty {
                        Button("Queue") { model.queueDraft() }
                            .accessibilityIdentifier("queue-message")
                            .disabled(!model.canQueueDraft)
                    }
                    Button(action: model.send) { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .keyboardShortcut(.return, modifiers: .command)
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
                    .disabled(model.phase == .stopping)
            }
        }
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
        let projects = filteredProjects
        return CommandPaletteContents(
            projects: projects, availableProjects: projects.filter(availableForNewThread),
            preferredProject: model.project?.id, threads: threads, activeThread: model.conversation?.id,
            canStartScratchThread: model.canStartScratchThread, findThread: model.threadFindScope
        )
    }

    private func availableForNewThread(_ project: Project) -> Bool {
        (try? ProjectFolder.existing(at: URL(fileURLWithPath: project.path, isDirectory: true))) != nil
    }

    private func acceptsWorkspaceCommands(in window: NSWindow) -> Bool {
        window === NSApp.mainWindow && acceptsWorkspaceKeys(in: window)
    }

    private func acceptsWorkspaceKeys(in window: NSWindow) -> Bool {
        !model.showingWelcome && !model.showingSettings && !model.showingCommandPalette &&
            !model.showingQuitSaveFailure && model.projectPicker == nil && draftProjectPicker == nil &&
            window.attachedSheet == nil && NSApp.modalWindow == nil && !ThreadTerminal.hasFocus(in: window) &&
            !choosingWorkspace && !choosingThreadProject && choosingBranch == nil && terminalWorkspaceChange == nil &&
            rename == nil && removingProject == nil
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
        var focusedView = window.firstResponder as? NSView
        while let view = focusedView {
            if view is WKWebView || view is PDFView { return false }
            focusedView = view.superview
        }

        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            guard let scope = model.threadFindScope else { return false }
            if editingOtherField, let editor {
                editor.selectAll(nil)
            } else {
                openFind(in: scope)
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
            let ids = try await SidebarMessageSearch.matchingMessageIDs(in: model.root, thread: request.thread,
                                                                        term: request.term)
            guard !Task.isCancelled, model.activeThreadFind?.request == request else { return }
            model.threadFind?.receive(ids, for: request)
        } catch {
            guard !Task.isCancelled, model.activeThreadFind?.request == request else { return }
            model.threadFind?.fail(request)
        }
    }

    private func openFind(in scope: SidebarMessageSearch.Thread, term: TranscriptSearchTerm? = nil,
                          messageID: String? = nil) {
        guard model.threadFindScope == scope else { return }
        if model.threadFind?.thread == scope, term == nil {
            model.threadFind?.refocus()
        } else {
            model.threadFind = ThreadFindSession(thread: scope, term: term, messageID: messageID)
        }
    }

    private func closeFind() {
        findFocused = false
        model.threadFind = nil
        if model.conversation?.archived == false { focusCurrentComposer() }
    }

    @discardableResult
    private func openCommandPalette(in eventWindow: NSWindow? = nil) -> Bool {
        guard model.canOpenCommandPalette, let window = eventWindow ?? NSApp.keyWindow,
              acceptsWorkspaceCommands(in: window) else { return false }
        if findFocused {
            paletteReturnFocus = .threadFind
        } else {
            paletteReturnFocus = searchFocused ? .search : focusedComposer.map(PaletteReturnFocus.composer)
        }
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
        case .chooseProject:
            break
        case .newThread(let id):
            guard let project = filteredProjects.first(where: { $0.id == id }) else { return }
            guard availableForNewThread(project) else {
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
        case .openProject(let id):
            guard filteredProjects.contains(where: { $0.id == id }) else { return }
            model.selectProjectFromPalette(id)
            if model.project?.id == id {
                model.threadFind = nil
                clearSearch()
                collapsed.remove(id)
                focusCurrentComposer()
            }
        case .openThread(let id, let project):
            guard let target = threads.first(where: { $0.id == id && $0.project.id == project }) else { return }
            openThread(target)
            if model.conversation?.id == id { focusCurrentComposer() }
        case .openMessage(let id, let project, let messageID, let term):
            guard let target = threads.first(where: { $0.id == id && $0.project.id == project }) else { return }
            openThread(target, messageID: messageID, term: term)
        }
    }

    private func focusCurrentComposer() {
        searchFocused = false
        focusedComposer = model.conversation?.id
    }

    private func chooseWorkspace() {
        if let thread = model.conversation, openTerminals.contains(where: { $0.id.thread == thread.id }) {
            terminalWorkspaceChange = thread.id
        } else {
            choosingWorkspace = true
        }
    }

    private var branchDisplay: (branch: String?, fallback: String)? {
        guard let scope = model.branchPickerScope else { return nil }
        if case let .newWorktree(_, base) = scope.location {
            return (GitBranchRef.displayName(base), "Choose base branch")
        }
        guard let loadedBranch, loadedBranch.scope == scope else { return nil }
        return (loadedBranch.branch, "Detached HEAD")
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

    private func startThread(in projectID: UUID) {
        guard !model.operationsInProgress, model.projects.contains(where: { $0.id == projectID }) else { return }
        model.addConversation(in: projectID)
        guard model.project?.id == projectID else { return }
        if !projectFilter.selection.isEmpty, !projectFilter.selection.contains(projectID) {
            projectFilter.clear()
        }
        collapsed.remove(projectID)
        searchFocused = false
        clearSearch()
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
        openThread(item, messageID: messageMatch?.messageID, term: messageMatch.map { _ in .literal(searchTerm) })
    }

    private func openThread(_ item: SidebarThread, messageID: String?, term: TranscriptSearchTerm?) {
        model.selectConversation(item.id, in: item.project.id)
        guard model.project?.id == item.project.id, model.conversation?.id == item.id else { return }
        if let term { openFind(in: .init(projectID: item.project.id, threadID: item.id), term: term, messageID: messageID) }
        collapsed.remove(item.project.id)
        if !item.thread.archived, item.thread.threadShelf == .settled { settledExpanded = true }
        guard !searchTerm.isEmpty else { return }
        searchFocused = false
        clearSearch()
    }

    private func startScratchThread() {
        model.startScratchThread()
        projectFilter.clear()
        query = ""
    }

    private func canChooseDraftProject(_ threadID: UUID) -> Bool {
        model.canSwitchDraftProject && !openTerminals.contains { $0.id.thread == threadID }
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
    let onResize: (CGFloat) -> Void

    var body: some View {
        Divider()
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
