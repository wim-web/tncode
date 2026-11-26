import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("groupThreadsByProject") private var grouped = false
    @State private var collapsed: Set<UUID> = []
    @State private var query = ""
    @State private var projectFilter = SidebarProjectFilter()
    @State private var showingSidebarFilters = false
    @State private var highlightedSearchThread: UUID?
    @FocusState private var searchFocused: Bool
    @State private var showingDetails = false
    @State private var showingChanges = false
    @State private var browserPanels: [UUID: BrowserPanel] = [:]
    @State private var showingTerminal = false
    @State private var choosingWorkspace = false
    @State private var confirmingTerminalClose = false
    @State private var choosingThreadProject = false
    @State private var openTerminals: [TerminalLocation] = []
    @State private var settledExpanded = false
    @State private var rename: RenameTarget?
    @State private var title = ""
    @State private var removingProject: Project?
    @State private var createdProject: UUID?
    @FocusState private var focusedComposer: UUID?
    @State private var focusAfterPicker = false
    @State private var targetingProjectDrop = false

    private enum RenameTarget {
        case project(UUID)
        case conversation(UUID, project: UUID)
    }

    private struct TerminalLocation: Identifiable, Hashable {
        let thread: UUID
        let path: String
        var id: Self { self }
    }

    @MainActor
    private struct BrowserPanel {
        let preview = ThreadBrowserPreview()
        var isVisible = true
    }

    private var orderedProjects: [Project] { SidebarProjectFilter.orderedProjects(model.projects) }
    private var filteredProjects: [Project] { projectFilter.projects(in: orderedProjects) }
    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var threads: [SidebarThread] {
        let scope = projectFilter.selection.isEmpty ? model.threadProjects : filteredProjects
        return SidebarThread.matching(in: scope, search: searchTerm, archived: model.showArchive)
            .filter { $0.project.isScratch || model.showsInSidebar($0.thread) }
    }

    private var rail: Color { colorScheme == .dark ? Color(white: 0.082) : Color(white: 0.955) }
    private var canvas: Color { colorScheme == .dark ? Color(white: 0.065) : Color(nsColor: .textBackgroundColor) }
    private var surface: Color { colorScheme == .dark ? Color.white.opacity(0.065) : Color.black.opacity(0.042) }
    private let accent = Color(red: 0.24, green: 0.48, blue: 0.70)

    var body: some View {
        ZStack {
            HSplitView {
                sidebar
                    .frame(minWidth: 177, idealWidth: 212, maxWidth: 238)
                detail
                    .frame(minWidth: 475, maxWidth: .infinity, maxHeight: .infinity)
            }
            .opacity(model.showingWelcome ? 0 : 1)
            .accessibilityHidden(model.showingWelcome)
            .disabled(model.showingWelcome)
            if model.showingWelcome { welcome }
        }
        .tint(accent)
        .focusedSceneValue(\.sidebarActions, model.showingWelcome ? nil : WorkspaceSidebarActions(
            newThread: model.operationsInProgress ? nil : newThread,
            searchThreads: { searchFocused = true }
        ))
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
        .sheet(isPresented: $model.showingSettings) { ModelSettingsView(model: model) }
        .sheet(isPresented: $choosingWorkspace) {
            if let project = model.project { ThreadLocationView(project: project, model: model) }
        }
        .confirmationDialog("Close this thread’s terminal?", isPresented: $confirmingTerminalClose) {
            Button("Close Terminal and Choose Workspace", role: .destructive) {
                if let thread = model.conversation {
                    openTerminals.removeAll { $0.thread == thread.id }
                    showingTerminal = false
                }
                choosingWorkspace = true
            }
        } message: {
            Text("Workspace changes require a new terminal in the selected folder.")
        }
        .confirmationDialog("Start a thread in", isPresented: $choosingThreadProject, titleVisibility: .visible) {
            ForEach(filteredProjects) { project in
                Button(project.title) { startThread(in: project.id) }
                    .accessibilityIdentifier("new-thread-project-\(project.id)")
            }
            if model.canStartScratchThread {
                Button("No project", action: startScratchThread)
                    .accessibilityIdentifier("new-thread-no-project")
            }
        }
        .sheet(item: $model.projectPicker, onDismiss: {
            if focusAfterPicker { focusedComposer = model.conversation?.id }
            focusAfterPicker = false
        }) { request in
            ProjectFolderView(request: request) { source in
                try await model.openProject(source, request: request)
                focusAfterPicker = true
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
        return VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Pi Workspace")
                .font(.title.weight(.semibold))
            Text("Connect a model to send messages with Pi. You can open projects before setting up a model.")
                .foregroundStyle(.secondary)
            LabeledContent("Model", value: model.workspace.model.model)
            Button("Model Settings…") { model.showingSettings = true }
                .accessibilityIdentifier("model-settings")
            if let error = model.error { Text(error).foregroundStyle(.red) }
            Button(ready ? "Start" : "Start without an agent", action: model.finishWelcome)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("start-workspace")
        }
        .padding(32)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvas)
    }

    private var sidebar: some View {
        let visibleThreads = threads
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
            .frame(height: 42)

            sidebarSearch(visibleThreads)

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
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if searchTerm.isEmpty {
                            threadShelves(visibleThreads)
                        } else if visibleThreads.isEmpty {
                            Text("No matching threads")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(7)
                        } else {
                            ForEach(visibleThreads) { link in
                                threadRow(link, showProject: true,
                                          highlighted: link.id == highlightedID)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: highlightedSearchThread) { _, id in
                    if let id { reader.scrollTo(id) }
                }
                .onChange(of: searchTerm) { _, term in
                    if !term.isEmpty, let id = visibleThreads.first?.id { reader.scrollTo(id, anchor: .top) }
                }
            }

            Divider()
            Button { model.showingSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Model Settings")
            .accessibilityIdentifier("model-settings")
            .disabled(model.phase.isRunning)
            .padding(13)
        }
        .background(rail)
        .contentShape(Rectangle())
        .overlay {
            if targetingProjectDrop && !model.operationsInProgress {
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

    private func sidebarSearch(_ results: [SidebarThread]) -> some View {
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
                    if !searchTerm.isEmpty, let result = searchResult(in: results) { openThread(result) }
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
            .background(emphasized ? accent.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("thread-row-\(link.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(model.operationsInProgress && !selected)
        .contextMenu { threadActions(link.thread, project: link.project) }
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
        if projectFilter.selection == [project.id] {
            Button("Show All Projects") { projectFilter.clear() }
        } else {
            Button("Filter by \(project.title)") { projectFilter.selectOnly(project.id) }
        }
        Button("Rename Thread…") { beginRename(.conversation(thread.id, project: project.id), title: thread.title) }
        if project.isScratch {
            Button("Turn into project") {
                if model.convertScratchThread(thread.id, in: project.id) { createdProject = project.id }
            }
            .accessibilityIdentifier("turn-into-project")
            .disabled(model.operationsInProgress)
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

    private var detail: some View {
        VStack(spacing: 0) {
            if let project = model.project, let thread = model.conversation {
                let browser = browserPanels[thread.id]
                header(project, thread, browser: browser)
                Divider()
                HSplitView {
                    conversation(project, thread).frame(minWidth: 260)
                    if let browser, browser.isVisible {
                        BrowserPreviewView(preview: browser.preview)
                            .frame(minWidth: 290, idealWidth: 380, maxWidth: 495)
                    } else if showingChanges, !thread.workingLocation.needsWorktree,
                              let directory = model.workingDirectory {
                        SourceControlView(directory: directory, model: model)
                            .id(directory)
                            .frame(minWidth: 290, idealWidth: 355, maxWidth: 495)
                    }
                }
            } else {
                readyScreen
            }
            terminalDrawer
        }
        .background(canvas)
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

    private func header(_ project: Project, _ thread: Conversation, browser: BrowserPanel?) -> some View {
        let browserIsVisible = browser?.isVisible == true
        return HStack(spacing: 8) {
            let canSwitchProject = model.canSwitchDraftProject &&
                !openTerminals.contains { $0.thread == thread.id } &&
                (!project.isScratch || !model.projects.isEmpty)
            if canSwitchProject || !project.isScratch {
                Menu {
                    if canSwitchProject {
                        Menu("Draft project") {
                            ForEach(model.projects.filter { $0.id != project.id }) { target in
                                Button(target.title) { switchDraftProject(to: target.id) }
                                    .accessibilityIdentifier("draft-project-\(target.id)")
                            }
                            if !project.isScratch {
                                Button("No project") { switchDraftProject(to: nil) }
                                    .accessibilityIdentifier("draft-no-project")
                            }
                        }
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
            if !thread.workingLocation.needsWorktree, let directory = model.workingDirectory {
                PullRequestsButton(directory: directory)
                    .id(directory)
            }
            Button {
                if browserIsVisible {
                    browserPanels[thread.id]?.isVisible = false
                    showingChanges = true
                } else {
                    showingChanges.toggle()
                }
            } label: {
                Image(systemName: showingChanges && !browserIsVisible ? "doc.text.fill" : "doc.text")
            }
            .buttonStyle(.plain)
            .help("Changes")
            .accessibilityLabel("Changes")
            .accessibilityIdentifier("toggle-changes")
            .disabled(thread.workingLocation.needsWorktree)

            Button {
                if browser != nil {
                    browserPanels[thread.id]?.isVisible.toggle()
                } else {
                    browserPanels[thread.id] = BrowserPanel()
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
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                inspector(project, thread)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .frame(height: 42)
    }

    private func conversation(_ project: Project, _ thread: Conversation) -> some View {
        let legacyDraft = model.phase == .ready && model.messages.isEmpty && thread.worktreeLaunch == nil
        let drafting = !thread.archived && (thread.isDraft ?? legacyDraft)
        return VStack(spacing: 0) {
            if drafting {
                Spacer()
                Text(project.isScratch ? "What should we work on?" : "What should we build in \(project.title)?")
                    .font(.system(size: 27, weight: .semibold))
                    .padding(.bottom, 12)
                composer(project, thread)
                Spacer(minLength: 45)
            } else {
                transcript
                composer(project, thread)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inspector(_ project: Project, _ thread: Conversation) -> some View {
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
        .frame(width: 260)
        .accessibilityIdentifier("workspace-details")
    }

    private var activeTerminal: TerminalLocation? {
        guard let thread = model.conversation?.id, let path = model.workingDirectory else { return nil }
        return TerminalLocation(thread: thread, path: path)
    }

    private var terminalIsVisible: Bool {
        showingTerminal && activeTerminal.map(openTerminals.contains) == true
    }

    private func toggleTerminal() {
        guard let activeTerminal else { return }
        if terminalIsVisible {
            showingTerminal = false
        } else {
            if !openTerminals.contains(activeTerminal) { openTerminals.append(activeTerminal) }
            showingTerminal = true
        }
    }

    private var terminalDrawer: some View {
        VStack(spacing: 0) {
            if terminalIsVisible {
                Divider()
                HStack {
                    Label("Terminal", systemImage: "terminal").font(.caption.weight(.medium))
                    Spacer()
                    Button("Hide") { showingTerminal = false }
                        .buttonStyle(.plain)
                    Button("Close") {
                        openTerminals.removeAll { $0 == activeTerminal }
                        showingTerminal = false
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("close-terminal")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            ZStack {
                ForEach(openTerminals) { terminal in
                    let visible = terminalIsVisible && terminal == activeTerminal
                    ThreadTerminal(directory: terminal.path, visible: visible)
                        .frame(height: 174)
                        .opacity(visible ? 1 : 0)
                        .accessibilityHidden(!visible)
                        .allowsHitTesting(visible)
                }
            }
            .frame(height: terminalIsVisible ? 174 : 0)
            .clipped()
        }
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 23) {
                    ForEach(model.messages) { message in
                        messageRow(message.text, role: message.role)
                    }
                    if !model.partial.isEmpty {
                        messageRow(model.partial, role: .assistant)
                            .accessibilityIdentifier("streaming-reply")
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .frame(maxWidth: 710)
                .padding(.vertical, 22)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("transcript")
            .onChange(of: model.messages.count) { _, _ in reader.scrollTo("latest", anchor: .bottom) }
            .onChange(of: model.partial) { _, _ in reader.scrollTo("latest", anchor: .bottom) }
        }
    }

    private func messageRow(_ text: String, role: ChatMessage.Role) -> some View {
        let rendered = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return HStack {
            if role == .user { Spacer(minLength: 35) }
            Text(role == .assistant ? rendered : AttributedString(text))
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(role == .user ? 11 : 0)
                .background(role == .user ? surface : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            if role == .assistant { Spacer(minLength: 0) }
        }
    }

    private func composer(_ project: Project, _ thread: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.error {
                HStack {
                    Text(error).foregroundStyle(.red)
                    Spacer()
                    if model.phase == .closed && !model.canRetryWorktree {
                        Button("Reconnect", action: model.connect)
                    }
                }
                .font(.callout)
            }
            if let launch = thread.worktreeLaunch, !model.phase.isRunning {
                WorktreeLaunchView(launch: launch, model: model)
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
                inputCard(project, threadID: thread.id)
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
                Spacer()
                if model.preparingWorktree { Text("Preparing worktree…") }
                if model.phase == .connecting && !model.preparingWorktree { Text("Opening thread…") }
                if model.pendingToolApproval != nil {
                    Text("Waiting for approval…")
                } else if model.phase == .running {
                    Text(model.activity.isEmpty ? "Pi is responding…" : "Running \(model.activity)…")
                }
                if model.phase == .stopping { Text("Stopping…") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: 710)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func inputCard(_ project: Project, threadID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Ask Pi anything", text: $model.draft, axis: .vertical)
                .lineLimit(2...7)
                .textFieldStyle(.plain)
                .focused($focusedComposer, equals: threadID)
                .task(id: threadID) {
                    await Task.yield()
                    if !Task.isCancelled && model.projectPicker == nil && !model.showingSettings {
                        focusedComposer = threadID
                    }
                }
                .font(.system(size: 14))
                .accessibilityIdentifier("composer")
                .disabled(model.preparingWorktree)
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
                    model.showingSettings = true
                } label: {
                    Label(model.effectiveModel.model, systemImage: "cpu")
                        .lineLimit(1)
                }
                .accessibilityIdentifier("active-model")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.phase.isRunning)
                if model.phase.isRunning {
                    Button(action: model.cancel) { Image(systemName: "stop.fill") }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("stop-message")
                        .disabled(model.phase == .stopping)
                } else {
                    Button(action: model.send) { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityLabel("Send")
                        .accessibilityIdentifier("send-message")
                        .disabled(!model.canSend)
                }
            }
            .font(.system(size: 12))
        }
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.11)).allowsHitTesting(false) }
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

    private func chooseWorkspace() {
        if let thread = model.conversation, openTerminals.contains(where: { $0.thread == thread.id }) {
            confirmingTerminalClose = true
        } else {
            choosingWorkspace = true
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

    private func openThread(_ item: SidebarThread) {
        model.selectConversation(item.id, in: item.project.id)
        guard model.conversation?.id == item.id, !searchTerm.isEmpty else { return }
        collapsed.remove(item.project.id)
        if !item.thread.archived, item.thread.threadShelf == .settled { settledExpanded = true }
        searchFocused = false
        clearSearch()
    }

    private func startScratchThread() {
        model.startScratchThread()
        projectFilter.clear()
        query = ""
    }

    private func switchDraftProject(to projectID: UUID?) {
        let previousProject = model.project?.id
        model.switchDraftProject(to: projectID)
        guard let project = model.project, project.id != previousProject else { return }
        projectFilter.clear()
        collapsed.remove(project.id)
        focusedComposer = model.conversation?.id
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
