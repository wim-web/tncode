import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var request: SettingsRequest
    let appearance: AppearanceSettings
    let browserDefaults: UserDefaults
    let pasteboard: NSPasteboard
    let openWelcome: () -> Void
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarPreference.groupByProject) private var groupByProject = false
    @AppStorage(ComposerSendShortcut.key) private var sendShortcut = ComposerSendShortcut.initial
    @AppStorage(ComposerFollowUp.key) private var followUpBehavior = ComposerFollowUp.initial
    @FocusState private var focus: SettingsFocus?
    @State private var page: SettingsPage
    @State private var jump: SettingsJump?
    @State private var search = SettingsSearch()
    @State private var modelDrafts: [UUID?: ModelSettingsDraft]
    @State private var projectTitles: [UUID: String] = [:]
    @State private var browserDraft: BrowserSearchSettings
    @State private var projectBaseDirectory: String
    @State private var projectBaseDirectoryError: String?
    @State private var worktreeDirectory: String
    @State private var worktreeDirectoryError: String?
    @State private var startFromRemoteError: String?
    @State private var showingLicenses: Bool

    init(model: WorkspaceModel, appearance: AppearanceSettings, browserDefaults: UserDefaults,
         request: SettingsRequest, pasteboard: NSPasteboard = .general, openWelcome: @escaping () -> Void) {
        self.model = model
        self.request = request
        self.appearance = appearance
        self.browserDefaults = browserDefaults
        self.pasteboard = pasteboard
        self.openWelcome = openWelcome
        _page = State(initialValue: request.page)
        _jump = State(initialValue: request.destination.anchor.map { SettingsJump(anchor: $0) })
        _showingLicenses = State(initialValue: request.destination.anchor == .licenses)
        let projectID = request.projectID
        let project = model.projects.first { $0.id == projectID }
        _modelDrafts = State(initialValue: [projectID: ModelSettingsDraft(workspace: model.workspace.model, project: project)])
        _browserDraft = State(initialValue: BrowserSearchSettings.load(from: browserDefaults))
        _projectBaseDirectory = State(initialValue: model.workspace.addProjectBaseDirectory ?? "")
        _worktreeDirectory = State(initialValue: model.workspace.worktreesDirectory ?? "")
    }

    private var scopedProject: Project? { model.projects.first { $0.id == request.projectID } }
    private var projectScopeUnavailable: Bool { request.projectID != nil && scopedProject == nil }

    private var modelDraft: Binding<ModelSettingsDraft> {
        let project = scopedProject
        let projectID = request.projectID
        return Binding(get: {
            modelDrafts[projectID] ?? ModelSettingsDraft(workspace: model.workspace.model, project: project)
        }, set: { modelDrafts[projectID] = $0 })
    }

    private func projectTitle(_ project: Project) -> Binding<String> {
        Binding(get: { projectTitles[project.id] ?? project.title },
                set: { projectTitles[project.id] = $0 })
    }

    private var results: [SettingsSearchResult] {
        guard search.isSearching else { return [] }
        let modelDraft = modelDraft.wrappedValue
        let scopedOverride: Bool
        if case .project(let id) = modelDraft.scope {
            scopedOverride = model.projects.contains { $0.id == id && $0.modelOverride != nil }
        } else {
            scopedOverride = false
        }
        return search.results(available: SettingsSearchAvailability(
            canEditModels: model.canOpenModelSettings,
            hasProjectScope: scopedProject != nil,
            usesLocalProvider: modelDraft.settings.provider == .local,
            hasSavedKey: model.canOpenModelSettings && model.hasKey(for: modelDraft.settings),
            canResetModelOverride: scopedOverride,
            usesCustomSearch: browserDraft.engine == .custom
        ))
    }

    var body: some View {
        HStack(spacing: 0) {
            navigation
                .frame(width: 214)
                .background(.quaternary.opacity(0.25))
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(page.title)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .focusable()
                        .focused($focus, equals: .heading)
                        .accessibilityIdentifier("settings-heading-\(page.rawValue)")
                    Spacer()
                    if page == .model {
                        Button("About") { openWindow(id: AboutView.windowID) }
                            .accessibilityIdentifier("settings-about")
                    }
                    if [.general, .threads, .chat, .project, .worktrees, .usage, .about].contains(page) ||
                        (page == .model && projectScopeUnavailable) {
                        Button("Done", action: closeSettings)
                            .accessibilityIdentifier("settings-close")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                Divider()
                ScrollViewReader { reader in
                    Group {
                        if page == .about {
                            AboutView(showingLicenses: $showingLicenses, settingsFocus: $focus,
                                      openWelcome: openWelcome, welcomeEnabled: model.canOpenWelcome)
                        } else if page == .usage {
                            UsageSettingsView(root: model.root, projects: model.workspace.projects)
                                .padding(24)
                        } else {
                            ScrollView {
                                detail
                                    .padding(24)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(page)
                        }
                    }
                    .task(id: jump) {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        if let anchor = jump?.anchor {
                            reader.scrollTo(anchor)
                        } else {
                            focus = jump == nil && page != .usage ? .search : .heading
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: 784, height: 474)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings")
        .environment(\.settingsJump, jump)
        .background { WindowKeyMonitor(handle: handleKey) }
        .onChange(of: request.destination) { _, destination in
            navigate(to: destination.page, anchor: destination.anchor)
        }
        .onChange(of: focus) { previous, _ in
            if previous == .anchor(.addProjectStartsIn) { commitProjectBaseDirectory() }
            if previous == .anchor(.worktreeLocation) { commitWorktreeDirectory(worktreeDirectory) }
        }
    }

    private var navigation: some View {
        let rows = results
        let selected = search.selected(in: rows)?.id
        return VStack(spacing: 10) {
            HStack(spacing: 6) {
                TextField("Search settings", text: $search.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                    .accessibilityIdentifier("settings-search")
                if !search.query.isEmpty {
                    Button {
                        clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear settings search")
                    .accessibilityIdentifier("settings-search-clear")
                }
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 3) {
                        if !search.isSearching {
                            ForEach(SettingsPage.allCases.filter { $0 != .project || scopedProject != nil }) { item in
                                navigationRow(title: item.title, page: item, selected: item == page) {
                                    navigate(to: item)
                                }
                                .accessibilityIdentifier("settings-nav-\(item.rawValue)")
                                .disabled(item == .model && !model.canOpenModelSettings)
                            }
                        } else if rows.isEmpty {
                            Text("No settings found")
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 16)
                                .accessibilityIdentifier("settings-search-empty")
                        } else {
                            ForEach(rows) { result in
                                navigationRow(title: result.title, page: result.page, selected: result.id == selected,
                                              subtitle: result.anchor == nil ? nil : result.page.title) {
                                    navigate(to: result.page, anchor: result.anchor)
                                }
                                .accessibilityIdentifier("settings-result-\(result.id)")
                                .id(result.id)
                            }
                        }
                    }
                }
                .onChange(of: selected) { _, id in
                    if let id { reader.scrollTo(id) }
                }
            }
        }
        .padding(12)
    }

    private func navigationRow(title: String, page: SettingsPage, selected: Bool,
                               subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: page.icon)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(7)
            .background(selected ? Color.accentColor.opacity(0.17) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .general:
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Group by Project", isOn: $groupByProject)
                    .settingsTarget(.groupByProject, focus: $focus)
                Divider()
                projectBaseDirectorySetting
            }
        case .threads:
            SnoozeOptionsSettingsView(model: model, settingsFocus: $focus)
        case .appearance:
            AppearanceSettingsView(settings: appearance, settingsFocus: $focus)
        case .chat:
            chatSettings
        case .project:
            if let scopedProject {
                ProjectOverviewSettingsView(model: model, project: scopedProject, title: projectTitle(scopedProject),
                                            pasteboard: pasteboard) { navigate(to: .model) }
                    .id(scopedProject.id)
            } else {
                projectUnavailable
            }
        case .model:
            if projectScopeUnavailable {
                projectUnavailable
            } else {
                ModelSettingsView(model: model, draft: modelDraft, settingsFocus: $focus)
                    .id(request.projectID)
            }
        case .worktrees:
            worktreeDirectorySetting
            Divider()
            startFromRemoteSetting
        case .browser:
            BrowserSettingsView(defaults: browserDefaults, draft: $browserDraft, settingsFocus: $focus)
        case .about, .usage:
            EmptyView()
        }
    }

    private var projectUnavailable: some View {
        Text("This project is no longer open.")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings-project-unavailable")
    }

    private var chatSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Send shortcut", selection: $sendShortcut) {
                        ForEach(ComposerSendShortcut.allCases, id: \.self) { option in
                            Text(option.title)
                                .accessibilityIdentifier("send-shortcut-\(option.rawValue)")
                                .tag(option)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .settingsTarget(.sendShortcut, focus: $focus)
                    if sendShortcut != .initial {
                        Button("Reset") { sendShortcut = .initial }
                            .accessibilityLabel("Reset send shortcut to default")
                            .accessibilityIdentifier("reset-send-shortcut")
                    }
                }
                Text("Choose when Enter sends a prompt or inserts a new line. Shift + Enter inserts a new line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("Follow-up behavior", selection: $followUpBehavior) {
                        ForEach(ComposerFollowUp.allCases, id: \.self) { option in
                            Text(option.title)
                                .accessibilityIdentifier("follow-up-behavior-\(option.rawValue)")
                                .tag(option)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .settingsTarget(.followUpBehavior, focus: $focus)
                    if followUpBehavior != .initial {
                        Button("Reset") { followUpBehavior = .initial }
                            .accessibilityLabel("Reset follow-up behavior to default")
                            .accessibilityIdentifier("reset-follow-up-behavior")
                    }
                }
                Text("Queue follow-ups or steer the current turn. Press \(sendShortcut.alternateShortcutDescription) to use the other action for one message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var projectBaseDirectorySetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add project starts in")
                .font(.callout.weight(.medium))
            Text("Leave empty to start in your home folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Add project starts in", text: $projectBaseDirectory, prompt: Text("~/"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Add project starts in")
                    .settingsTarget(.addProjectStartsIn, focus: $focus)
                if model.workspace.addProjectBaseDirectory != nil {
                    Button("Reset") {
                        projectBaseDirectory = ""
                        commitProjectBaseDirectory()
                    }
                    .accessibilityIdentifier("reset-add-project-starts-in")
                }
            }
            if let projectBaseDirectoryError {
                Text(projectBaseDirectoryError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("add-project-starts-in-error")
            }
        }
    }

    @discardableResult
    private func commitProjectBaseDirectory() -> Bool {
        do {
            try model.updateAddProjectBaseDirectory(projectBaseDirectory)
            projectBaseDirectory = model.workspace.addProjectBaseDirectory ?? ""
            projectBaseDirectoryError = nil
            return true
        } catch {
            projectBaseDirectoryError = error.localizedDescription
            return false
        }
    }

    private var worktreeDirectorySetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Worktree location")
                .font(.callout.weight(.medium))
            Text("Folder where new worktrees are created on this Mac. Leave empty to use the workspace’s worktrees folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Worktree location", text: Binding(get: { worktreeDirectory }, set: { value in
                    worktreeDirectory = WorktreeDirectory.replacingPastedPath(previous: worktreeDirectory, next: value)
                }), prompt: Text("Default"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Worktree location")
                    .settingsTarget(.worktreeLocation, focus: $focus)
                if model.workspace.worktreesDirectory?.isEmpty == false {
                    Button("Reset") { commitWorktreeDirectory("") }
                        .accessibilityLabel("Reset worktree location to default")
                        .accessibilityIdentifier("reset-worktree-location")
                }
            }
            if let worktreeDirectoryError {
                Text(worktreeDirectoryError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("worktree-location-error")
            }
        }
    }

    @discardableResult
    private func commitWorktreeDirectory(_ input: String) -> Bool {
        do {
            try model.updateWorktreesDirectory(input)
            worktreeDirectory = model.workspace.worktreesDirectory ?? ""
            worktreeDirectoryError = nil
            return true
        } catch {
            worktreeDirectoryError = error.localizedDescription
            return false
        }
    }

    private var startFromRemoteSetting: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Start from remote", isOn: Binding(
                    get: { model.workspace.startNewWorktreesFromRemote },
                    set: updateStartFromRemote
                ))
                .toggleStyle(.switch)
                .accessibilityLabel("Start new worktrees from remote by default")
                .settingsTarget(.startFromRemote, focus: $focus)
                if !model.workspace.startNewWorktreesFromRemote {
                    Spacer()
                    Button("Reset") { updateStartFromRemote(true) }
                        .accessibilityLabel("Reset new worktrees start from remote to default")
                        .accessibilityIdentifier("reset-start-from-origin")
                }
            }
            Text("Uses the latest commit of the base branch’s tracked remote branch, even if its name differs. Otherwise uses the same-named branch on origin. Uses your local branch if that remote branch is missing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let startFromRemoteError {
                Text(startFromRemoteError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("start-from-origin-error")
            }
        }
    }

    private func updateStartFromRemote(_ enabled: Bool) {
        do {
            try model.updateNewWorktreesStartFromRemote(enabled)
            startFromRemoteError = nil
        } catch {
            startFromRemoteError = error.localizedDescription
        }
    }

    private func closeSettings() {
        if page == .general, !commitProjectBaseDirectory() { return }
        if page == .worktrees, !commitWorktreeDirectory(worktreeDirectory) { return }
        if model.settingsRequest === request { model.settingsRequest = nil }
    }

    private func navigate(to page: SettingsPage, anchor: SettingsAnchor? = nil) {
        focus = nil
        search.query = ""
        self.page = page
        showingLicenses = anchor == .licenses
        jump = SettingsJump(anchor: anchor)
    }

    private func clearSearch() {
        search.query = ""
        focus = .search
    }

    private func handleKey(_ event: NSEvent, window: NSWindow) -> Bool {
        let editor = window.firstResponder as? NSTextView
        guard editor?.hasMarkedText() != true else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.charactersIgnoringModifiers == "f", modifiers == .command || modifiers == .control {
            if focus == .search { editor?.selectAll(nil) }
            focus = .search
            return true
        }
        if event.characters == "/", editor?.isEditable != true,
           modifiers.isEmpty || modifiers == .shift {
            focus = .search
            return true
        }
        guard modifiers.isEmpty else { return false }
        let key = Int(event.keyCode)
        if key == kVK_Escape {
            if !event.isARepeat {
                if search.query.isEmpty { closeSettings() } else { clearSearch() }
            }
            return true
        }
        if focus == .anchor(.addProjectStartsIn), editor?.isFieldEditor == true,
           key == kVK_Return || key == kVK_ANSI_KeypadEnter {
            if !event.isARepeat, commitProjectBaseDirectory() { focus = .heading }
            return true
        }
        if focus == .anchor(.worktreeLocation), editor?.isFieldEditor == true,
           key == kVK_Return || key == kVK_ANSI_KeypadEnter {
            if !event.isARepeat, commitWorktreeDirectory(worktreeDirectory) { focus = .heading }
            return true
        }
        guard focus == .search, editor?.isFieldEditor == true else { return false }
        let rows = results
        switch key {
        case kVK_UpArrow, kVK_DownArrow:
            guard search.isSearching else { return false }
            search.move(by: key == kVK_UpArrow ? -1 : 1, in: rows)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if !event.isARepeat, let result = search.selected(in: rows) {
                navigate(to: result.page, anchor: result.anchor)
            }
        default:
            return false
        }
        return true
    }
}

private struct SettingsJump: Equatable {
    let id = UUID()
    let anchor: SettingsAnchor?
}

private struct SettingsJumpKey: EnvironmentKey {
    static let defaultValue: SettingsJump? = nil
}

private extension EnvironmentValues {
    var settingsJump: SettingsJump? {
        get { self[SettingsJumpKey.self] }
        set { self[SettingsJumpKey.self] = newValue }
    }
}

private struct SettingsTarget: ViewModifier {
    @Environment(\.settingsJump) private var jump
    let anchor: SettingsAnchor
    let focus: FocusState<SettingsFocus?>.Binding

    func body(content: Content) -> some View {
        content
            .focused(focus, equals: .anchor(anchor))
            .background {
                if jump?.anchor == anchor {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.12))
                        .padding(-4)
                }
            }
            .accessibilityIdentifier(anchor.rawValue)
            .id(anchor)
            .task(id: jump?.anchor == anchor ? jump : nil) {
                guard jump?.anchor == anchor else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                focus.wrappedValue = .anchor(anchor)
            }
    }
}

extension View {
    func settingsTarget(_ anchor: SettingsAnchor, focus: FocusState<SettingsFocus?>.Binding) -> some View {
        modifier(SettingsTarget(anchor: anchor, focus: focus))
    }
}
