import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var request: SettingsRequest
    @ObservedObject private var appearance: AppearanceSettings
    let browserDefaults: UserDefaults
    let pasteboard: NSPasteboard
    let openWelcome: () -> Void
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarPreference.groupByProject) private var groupByProject = false
    @AppStorage(ComposerSendShortcut.key) private var sendShortcut = ComposerSendShortcut.initial
    @AppStorage(ComposerFollowUp.key) private var followUpBehavior = ComposerFollowUp.initial
    @AppStorage(TerminalPreference.confirmClose) private var confirmTerminalClose = TerminalPreference.defaultConfirmClose
    @AppStorage(DiffPreferences.ignoreWhitespace) private var ignoreWhitespace = DiffPreferences.defaultIgnoreWhitespace
    @AppStorage(DiffPreferences.wordWrap) private var wordWrap = DiffPreferences.defaultWordWrap
    @FocusState private var focus: SettingsFocus?
    @State private var search = SettingsSearch()
    @State private var projectTitles: [UUID: String] = [:]
    @State private var browserDraft: BrowserSearchSettings
    @State private var archiveConfirmationError: String?
    @State private var confirmingDeviceRestore = false
    @State private var deviceRestoreError: String?
    @State private var archiveCheckout: String?
    @State private var worktreeDirectory: String
    @State private var worktreeDirectoryError: String?
    @State private var startFromRemoteError: String?
    @State private var language = AppLanguage.selected
    private var page: SettingsPage { request.page }
    private var showingLicenses: Binding<Bool> {
        Binding(get: { request.destination.anchor == .licenses },
                set: { navigate(to: .about, anchor: $0 ? .licenses : nil) })
    }

    init(model: WorkspaceModel, appearance: AppearanceSettings, browserDefaults: UserDefaults,
         request: SettingsRequest, pasteboard: NSPasteboard = .general, openWelcome: @escaping () -> Void) {
        self.model = model
        self.request = request
        self.appearance = appearance
        self.browserDefaults = browserDefaults
        self.pasteboard = pasteboard
        self.openWelcome = openWelcome
        _browserDraft = State(initialValue: BrowserSearchSettings.load(from: browserDefaults))
        _worktreeDirectory = State(initialValue: model.workspace.worktreesDirectory ?? "")
    }

    private var scopedProject: Project? { model.projects.first { $0.id == request.projectID } }
    private var projectScopeUnavailable: Bool { request.projectID != nil && scopedProject == nil }

    private func projectTitle(_ project: Project) -> Binding<String> {
        Binding(get: { projectTitles[project.id] ?? project.title },
                set: { projectTitles[project.id] = $0 })
    }

    private var results: [SettingsSearchResult] {
        guard search.isSearching else { return [] }
        return search.results(available: SettingsSearchAvailability(
            model: model, project: scopedProject, browser: browserDraft
        ))
    }

    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.t3Themes) private var t3Themes
    private var palette: T3Palette { T3Palette(colorScheme, t3Themes) }

    var body: some View {
        HStack(spacing: 0) {
            // Usage is its own route modal in T3 Code, without the settings navigation.
            if page != .usage {
                navigation
                    .frame(width: 240)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(palette.navFill)
                    .overlay(alignment: .trailing) { Rectangle().fill(palette.border).frame(width: 1) }
            }
            VStack(spacing: 0) {
                header
                ScrollViewReader { reader in
                    Group {
                        if page == .about {
                            AboutView(showingLicenses: showingLicenses, settingsFocus: $focus,
                                      openWelcome: openWelcome, welcomeEnabled: model.canOpenWelcome)
                        } else if page == .usage {
                            UsageSettingsView(root: model.root, projects: model.workspace.projects)
                                .padding(.horizontal, 24)
                                .padding(.top, 24)
                                .frame(maxWidth: 1024, maxHeight: .infinity, alignment: .top)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 32) {
                                    if page.showsScopeSentence {
                                        SettingsScopeSentence(model: model, request: request)
                                    }
                                    detail
                                }
                                .settingsPageContainer()
                            }
                            .id(page)
                        }
                    }
                    .task(id: request.destination) {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        if let anchor = request.destination.anchor {
                            reader.scrollTo(anchor)
                        } else {
                            focus = request.destination.navigationID == nil && page != .usage ? .search : .heading
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .foregroundStyle(palette.foreground)
        // T3 Code's 30×18 switch is closest to the native small switch, tinted with the primary blue.
        .tint(palette.primary)
        .textFieldStyle(T3TextFieldStyle())
        .buttonStyle(T3SmallButtonStyle())
        .frame(minWidth: 784, idealWidth: 1000, maxWidth: .infinity, minHeight: 474, idealHeight: 640, maxHeight: .infinity)
        .background(palette.canvas)
        .environment(\.closeSettings, CloseSettingsAction(closeSettings))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings")
        .environment(\.settingsDestination, request.destination)
        .background { WindowKeyMonitor(handle: handleKey) }
        .alert("Restore default settings?", isPresented: $confirmingDeviceRestore,
               presenting: changedDeviceSettings) { _ in
            Button("Confirm", role: .destructive, action: restoreDeviceDefaults)
                .accessibilityIdentifier("confirm-restore-device-defaults")
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("cancel-restore-device-defaults")
        } message: { changes in
            Text("This will reset: \(changes.joined(separator: ", ")).")
        }
        .onChange(of: request.closeRequests) { _, _ in closeSettings() }
        .onChange(of: request.destination) {
            focus = nil
            search.query = ""
        }
        .onChange(of: focus) { previous, _ in
            if previous == .anchor(.worktreeLocation) { commitWorktreeDirectory(worktreeDirectory) }
        }
    }

    /// 48pt bar: "Settings / Page" breadcrumb, page actions and the close button.
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                if page != .usage {
                    Text("Settings").foregroundStyle(palette.mutedForeground)
                    Text("/").foregroundStyle(palette.mutedForeground).accessibilityHidden(true)
                }
                Text(page == .about && request.destination.anchor == .licenses
                     ? String(localized: "Open source licenses") : page.title)
                    .foregroundStyle(palette.foreground)
                    .accessibilityAddTraits(.isHeader)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focus, equals: .heading)
                    .accessibilityIdentifier("settings-heading-\(page.rawValue)")
            }
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            Spacer(minLength: 0)
            if page == .general {
                Button {
                    confirmingDeviceRestore = true
                    focus = .heading
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 12, weight: .medium))
                        Text("Restore device defaults")
                    }
                }
                .buttonStyle(T3SmallButtonStyle(kind: .ghost, height: 24))
                .accessibilityIdentifier("restore-device-defaults")
                .disabled(changedDeviceSettings.isEmpty)
            }
            Button(action: closeSettings) {
                Image(systemName: "xmark")
            }
            .buttonStyle(T3IconButtonStyle())
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("settings-close")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.border).frame(height: 1) }
    }

    private var navigation: some View {
        let rows = results
        let selected = search.selected(in: rows)?.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.mutedForeground.opacity(0.8))
                    .accessibilityHidden(true)
                TextField("Search settings", text: $search.query, prompt: Text("Search"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($focus, equals: .search)
                    .accessibilityIdentifier("settings-search")
                if search.query.isEmpty {
                    T3Kbd("/").accessibilityHidden(true)
                } else {
                    Button {
                        clearSearch()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(T3IconButtonStyle(size: 16))
                    .accessibilityLabel("Clear settings search")
                    .accessibilityIdentifier("settings-search-clear")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .modifier(T3SidebarRowBackground(selected: false, targeted: false, draft: false))
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !search.isSearching {
                            ForEach(Array(SettingsPage.navigationGroups.enumerated()), id: \.offset) { _, group in
                                let pages = group.pages
                                VStack(alignment: .leading, spacing: 4) {
                                    if let title = group.title {
                                        Text(localized: title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(palette.mutedForeground.opacity(0.8))
                                            .padding(.horizontal, 8)
                                            .padding(.bottom, 0)
                                    }
                                    ForEach(pages) { item in
                                        navigationRow(title: item.title, page: item, selected: item == page) {
                                            navigate(to: item)
                                        }
                                        .accessibilityIdentifier("settings-nav-\(item.rawValue)")
                                    }
                                }
                            }
                        } else if rows.isEmpty {
                            Text("No settings found")
                                .font(.system(size: 12))
                                .foregroundStyle(palette.mutedForeground)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                                .accessibilityIdentifier("settings-search-empty")
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
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
                    .padding(.top, 0)
                }
                .scrollIndicators(.never)
                .onChange(of: selected) { _, id in
                    if let id { reader.scrollTo(id) }
                }
            }
        }
        .padding(8)
    }

    private func navigationRow(title: String, page: SettingsPage, selected: Bool,
                               subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsNavigationRow(title: title, icon: page.icon, subtitle: subtitle, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(localized: title))
        .accessibilityHint(subtitle ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .general:
            if let deviceRestoreError { SettingsMessage(deviceRestoreError).accessibilityIdentifier("restore-device-defaults-error") }
            SettingsSection("Confirmations") {
                archiveConfirmationSetting
                SettingsDivider()
                terminalCloseConfirmationSetting
            }
            SettingsSection("Display") {
                languageSetting
            }
        case .threads:
            ThreadsSettingsView(model: model, request: request, settingsFocus: $focus)
                .id(request.projectID)
        case .appearance:
            AppearanceSettingsView(settings: appearance, settingsFocus: $focus)
        case .chat:
            chatSettings
        case .project:
            if let scopedProject {
                ProjectOverviewSettingsView(model: model, project: scopedProject, title: projectTitle(scopedProject))
                    .id(scopedProject.id)
            } else if projectScopeUnavailable {
                projectUnavailable
            } else {
                ProjectChooserView(model: model) { request.selectProject($0) }
            }
        case .model:
            ProviderSettingsView(model: model, settingsFocus: $focus, initial: initialProvider)
        case .sourceControl:
            CommitWritingSettingsView(model: model, settingsFocus: $focus)
        case .diffs:
            SettingsSection("Diffs") {
                SettingsRow("Hide whitespace changes",
                            description: "Set whether the diff panel ignores whitespace-only edits by default.",
                            reset: ignoreWhitespace == DiffPreferences.defaultIgnoreWhitespace ? nil :
                                SettingsResetButton("Reset diff whitespace changes to default",
                                                    id: "reset-hide-whitespace-changes") {
                                    ignoreWhitespace = DiffPreferences.defaultIgnoreWhitespace
                                }) {
                    SettingsSwitch("Hide whitespace changes by default", isOn: $ignoreWhitespace)
                        .settingsTarget(.hideWhitespaceChanges, focus: $focus)
                }
            }
        case .worktrees:
            SettingsSection("Creation") {
                worktreeDirectorySetting
                SettingsDivider()
                startFromRemoteSetting
            }
        case .browser:
            BrowserSettingsView(defaults: browserDefaults, draft: $browserDraft, settingsFocus: $focus)
        case .labs:
            SettingsSection("Beta") {
                SettingsRow("Boring sidebar (group by project)",
                            description: "Group sidebar threads into project folders. Pinned threads stay on top, and Snoozed and Settled stay below the folders.") {
                    SettingsSwitch("Boring sidebar (group by project)", isOn: $groupByProject)
                        .settingsTarget(.groupByProject, focus: $focus)
                }
            }
        case .archived:
            ArchivedThreadsSettingsView(model: model, projectID: request.projectID, checkout: $archiveCheckout,
                                        settingsFocus: $focus)
        case .about, .usage:
            EmptyView()
        }
    }

    /// The instance Providers opens on: the one search or a sign-in prompt points at.
    private var initialProvider: Provider? {
        let current = model.effectiveModel.provider
        switch request.destination.anchor {
        case .apiKey: return current.authKind == .apiKey ? current : .openai
        case .accountSignIn: return [.codexAccount, .piSignIn].contains(current.authKind) ? current : current.signInProvider
        case .endpoint, .contextWindow, .localTools, .localImages: return .local
        default: return nil
        }
    }

    private var projectUnavailable: some View {
        Text("This project is no longer available.")
            .font(.system(size: 14))
            .foregroundStyle(palette.mutedForeground)
            .accessibilityIdentifier("settings-project-unavailable")
    }

    private var changedDeviceSettings: [String] {
        let workspace = model.workspace
        return [
            ("Color scheme", appearance.colorScheme != .system),
            ("Chat width", appearance.chatWidth != .comfortable),
            ("Theme", appearance.themes != T3ThemeChoice()),
            ("Word wrap", wordWrap != DiffPreferences.defaultWordWrap),
            ("Hide whitespace changes", ignoreWhitespace != DiffPreferences.defaultIgnoreWhitespace),
            ("Snooze options", workspace.effectiveSnoozeOptions != ThreadSnoozeSchedule.defaultOptions),
            ("Send shortcut", sendShortcut != .initial),
            ("Follow-up behavior", followUpBehavior != .initial),
            ("Start from remote", !workspace.startNewWorktreesFromRemote),
            ("Add project base directory", workspace.addProjectBaseDirectory?.isEmpty == false),
            ("Archive confirmation", model.confirmsThreadArchive),
            ("Terminal close confirmation", confirmTerminalClose != TerminalPreference.defaultConfirmClose),
            ("Search engine", BrowserSearchSettings.load(from: browserDefaults) != BrowserSearchSettings())
        ].compactMap { label, changed in changed ? NSLocalizedString(label, comment: "Setting name") : nil }
    }

    private func restoreDeviceDefaults() {
        do {
            try model.restoreDeviceWorkspaceDefaults()
        } catch {
            deviceRestoreError = error.localizedDescription
            return
        }
        if appearance.colorScheme != .system || appearance.chatWidth != .comfortable ||
            appearance.themes != T3ThemeChoice() {
            appearance.restoreDefaults()
        }
        if wordWrap != DiffPreferences.defaultWordWrap { wordWrap = DiffPreferences.defaultWordWrap }
        if ignoreWhitespace != DiffPreferences.defaultIgnoreWhitespace { ignoreWhitespace = DiffPreferences.defaultIgnoreWhitespace }
        if sendShortcut != .initial { sendShortcut = .initial }
        if followUpBehavior != .initial { followUpBehavior = .initial }
        if confirmTerminalClose != TerminalPreference.defaultConfirmClose {
            confirmTerminalClose = TerminalPreference.defaultConfirmClose
        }
        let browserDefaultsValue = BrowserSearchSettings()
        if BrowserSearchSettings.load(from: browserDefaults) != browserDefaultsValue {
            browserDefaultsValue.save(to: browserDefaults)
        }
        browserDraft = browserDefaultsValue
        archiveConfirmationError = nil
        startFromRemoteError = nil
        deviceRestoreError = nil
    }

    private var chatSettings: some View {
        VStack(alignment: .leading, spacing: 32) {
            SettingsSection("Composer") {
                SettingsRow("Send shortcut",
                            description: "Choose when Enter sends a prompt or inserts a new line",
                            reset: sendShortcut == .initial ? nil :
                                SettingsResetButton("Reset send shortcut to default", id: "reset-send-shortcut") {
                                    sendShortcut = .initial
                                }) {
                    T3Select("Send shortcut", selection: $sendShortcut,
                             options: ComposerSendShortcut.allCases.map { ($0, $0.title) }, width: nil)
                        .settingsTarget(.sendShortcut, focus: $focus)
                }
            }
            SettingsSection("Follow-ups") {
                SettingsRow("Follow-up behavior",
                            description: sendShortcut.followUpDescription,
                            reset: followUpBehavior == .initial ? nil :
                                SettingsResetButton("Reset follow-up behavior to default", id: "reset-follow-up-behavior") {
                                    followUpBehavior = .initial
                                }) {
                    T3Select("Follow-up behavior", selection: $followUpBehavior,
                             options: ComposerFollowUp.allCases.map { ($0, $0.title) }, width: nil)
                        .settingsTarget(.followUpBehavior, focus: $focus)
                }
            }
        }
    }

    private var archiveConfirmationSetting: some View {
        SettingsRow("Archive confirmation", description: "Ask before archiving a thread.",
                    status: nil,
                    reset: model.confirmsThreadArchive ?
                        SettingsResetButton("Reset archive confirmation to default", id: "reset-archive-confirmation") {
                            setArchiveConfirmation(false)
                        } : nil) {
            SettingsSwitch("Confirm thread archiving", isOn: Binding(get: { model.confirmsThreadArchive },
                                                              set: setArchiveConfirmation))
                .settingsTarget(.archiveConfirmation, focus: $focus)
        } detail: {
            if let archiveConfirmationError {
                SettingsMessage(archiveConfirmationError).accessibilityIdentifier("archive-confirmation-error")
            }
        }
    }

    private func setArchiveConfirmation(_ enabled: Bool) {
        do {
            try model.updateArchiveConfirmation(enabled)
            archiveConfirmationError = nil
        } catch {
            archiveConfirmationError = error.localizedDescription
        }
    }

    private var languageSetting: some View {
        SettingsRow("Language", description: "System default follows your OS language.",
                    status: language.isRunning ? nil : String(localized: "Restart tncode to use this language."),
                    reset: language == .system ? nil :
                        SettingsResetButton("Reset language to default", id: "reset-language") {
                            AppLanguage.system.select()
                            language = .system
                        }) {
            if !language.isRunning {
                Button("Restart now") { AppLanguage.relaunch() }
                    .accessibilityIdentifier("language-restart")
            }
            T3Select("Language", selection: Binding(get: { language }, set: { choice in
                choice.select()
                language = choice
            }), options: AppLanguage.allCases.map { ($0, $0.title) })
            .settingsTarget(.language, focus: $focus)
        }
    }

    private var terminalCloseConfirmationSetting: some View {
        SettingsRow("Terminal close confirmation",
                    description: "Ask before closing terminals and stopping their running processes.",
                    reset: confirmTerminalClose == TerminalPreference.defaultConfirmClose ? nil :
                        SettingsResetButton("Reset terminal close confirmation to default",
                                            id: "reset-terminal-close-confirmation") {
                            confirmTerminalClose = TerminalPreference.defaultConfirmClose
                        }) {
            SettingsSwitch("Terminal close confirmation", isOn: $confirmTerminalClose)
                .accessibilityLabel("Confirm terminal closing")
                .settingsTarget(.terminalCloseConfirmation, focus: $focus)
        }
    }

    private var worktreeDirectorySetting: some View {
        SettingsRow("Worktree location",
                    description: "Folder where new worktrees are created, on any drive, such as ~/worktrees. Existing worktrees stay where they are. Leave empty to use the workspace’s worktrees folder.",
                    reset: model.workspace.worktreesDirectory?.isEmpty == false ?
                        SettingsResetButton("Reset worktree location to default", id: "reset-worktree-location") {
                            commitWorktreeDirectory("")
                        } : nil) {
            TextField("Worktree location", text: Binding(get: { worktreeDirectory }, set: { value in
                worktreeDirectory = WorktreeDirectory.replacingPastedPath(previous: worktreeDirectory, next: value)
            }), prompt: Text("Default"))
                .labelsHidden()
                .frame(width: 256)
                .accessibilityLabel("Worktree location")
                .settingsTarget(.worktreeLocation, focus: $focus)
        } detail: {
            if let worktreeDirectoryError {
                SettingsMessage(worktreeDirectoryError).accessibilityIdentifier("worktree-location-error")
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
        SettingsRow("Start from remote",
                    description: "Uses the latest commit of the base branch’s tracked remote branch, even if its name differs. Otherwise uses the same-named branch on origin. Uses your local branch if that remote branch is missing.",
                    reset: model.workspace.startNewWorktreesFromRemote ? nil :
                        SettingsResetButton("Reset new worktrees start from remote to default", id: "reset-start-from-origin") {
                            updateStartFromRemote(true)
                        }) {
            SettingsSwitch("Start from remote", isOn: Binding(
                get: { model.workspace.startNewWorktreesFromRemote },
                set: updateStartFromRemote
            ))
            .accessibilityLabel("Start new worktrees from remote by default")
            .settingsTarget(.startFromRemote, focus: $focus)
        } detail: {
            if let startFromRemoteError {
                SettingsMessage(startFromRemoteError).accessibilityIdentifier("start-from-origin-error")
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
        if page == .worktrees, !commitWorktreeDirectory(worktreeDirectory) { return }
        if model.settingsRequest === request { model.settingsRequest = nil }
    }

    private func navigate(to page: SettingsPage, anchor: SettingsAnchor? = nil) {
        request.navigate(to: page, anchor: anchor, projectID: nil)
    }

    private func clearSearch() {
        search.query = ""
        focus = .search
    }

    private func handleKey(_ event: NSEvent, window: NSWindow) -> Bool {
        guard !confirmingDeviceRestore else { return false }
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
        if focus == .anchor(.worktreeLocation), editor?.isFieldEditor == true,
           key == kVK_Return || key == kVK_ANSI_KeypadEnter {
            if !event.isARepeat, commitWorktreeDirectory(worktreeDirectory) { focus = .heading }
            return true
        }
        // Fields that save when they lose focus, like T3 Code's draft inputs, save on Return too.
        if case .anchor(let anchor) = focus, [.addProjectStartsIn, .customSearchURL, .endpoint, .contextWindow].contains(anchor),
           editor?.isFieldEditor == true, key == kVK_Return || key == kVK_ANSI_KeypadEnter {
            if !event.isARepeat { focus = .heading }
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

private struct SettingsDestinationKey: EnvironmentKey {
    static let defaultValue: SettingsRequest.Destination? = nil
}

extension EnvironmentValues {
    var settingsDestination: SettingsRequest.Destination? {
        get { self[SettingsDestinationKey.self] }
        set { self[SettingsDestinationKey.self] = newValue }
    }
}

private struct SettingsTarget: ViewModifier {
    @Environment(\.settingsDestination) private var destination
    let anchor: SettingsAnchor
    let focus: FocusState<SettingsFocus?>.Binding

    func body(content: Content) -> some View {
        content
            .focused(focus, equals: .anchor(anchor))
            .background {
                if destination?.anchor == anchor { SettingsHitRing().accessibilityHidden(true) }
            }
            .accessibilityIdentifier(anchor.rawValue)
            .id(anchor)
            .task(id: destination?.anchor == anchor ? destination : nil) {
                guard destination?.anchor == anchor else { return }
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

/// Closes Settings from a page. Settings is an in-window modal, so `\.dismiss` has nothing to dismiss.
struct CloseSettingsAction {
    private let action: () -> Void

    init(_ action: @escaping () -> Void = {}) { self.action = action }

    func callAsFunction() { action() }
}

private struct CloseSettingsKey: EnvironmentKey {
    static let defaultValue = CloseSettingsAction()
}

extension EnvironmentValues {
    var closeSettings: CloseSettingsAction {
        get { self[CloseSettingsKey.self] }
        set { self[CloseSettingsKey.self] = newValue }
    }
}

/// Settings navigation item: h32, radius 8, neutral hover and selected fills.
struct SettingsNavigationRow: View {
    let title: String
    let icon: String
    var subtitle: String?
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @State private var hovering = false

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let emphasized = selected || hovering
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(emphasized ? palette.foreground : palette.sidebarIcon)
                .frame(width: 16)
                .padding(.top, subtitle == nil ? 0 : 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(localized: title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(emphasized || subtitle != nil ? palette.foreground : palette.mutedForeground.opacity(0.8))
                    .lineLimit(1)
                if let subtitle {
                    Text(localized: subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.mutedForeground.opacity(0.75))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, subtitle == nil ? 0 : 6)
        .frame(minHeight: subtitle == nil ? 32 : 40)
        .background(selected ? palette.navSelected : hovering ? palette.navHover : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}

/// 2pt primary ring that pulses twice around a control reached from settings search.
struct SettingsHitRing: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @State private var visible = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(T3Palette(colorScheme, t3Themes).primary.opacity(visible ? 0.7 : 0.2), lineWidth: 2)
            .padding(-6)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.65).repeatCount(4, autoreverses: true)) { visible = true }
            }
    }
}

extension View {
    /// Centered settings page column (WorkspacePageContainer, readable): 896 wide including its 24 side
    /// padding, 24 top, 48 bottom.
    func settingsPageContainer(maxWidth: CGFloat = 896) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}
