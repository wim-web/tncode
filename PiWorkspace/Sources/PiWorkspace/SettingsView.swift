import Carbon
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: WorkspaceModel
    let appearance: AppearanceSettings
    let browserDefaults: UserDefaults
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarPreference.groupByProject) private var groupByProject = false
    @FocusState private var focus: SettingsFocus?
    @State private var page: SettingsPage
    @State private var jump: SettingsJump?
    @State private var search = SettingsSearch()
    @State private var modelDraft: ModelSettingsDraft
    @State private var browserDraft: BrowserSearchSettings
    @State private var showingLicenses = false

    init(model: WorkspaceModel, appearance: AppearanceSettings, browserDefaults: UserDefaults,
         request: SettingsRequest) {
        self.model = model
        self.appearance = appearance
        self.browserDefaults = browserDefaults
        _page = State(initialValue: request.page)
        _jump = State(initialValue: request.anchor.map { SettingsJump(anchor: $0) })
        let project = model.projects.first { $0.id == request.projectID }
        _modelDraft = State(initialValue: ModelSettingsDraft(workspace: model.workspace.model, project: project))
        _browserDraft = State(initialValue: BrowserSearchSettings.load(from: browserDefaults))
    }

    private var results: [SettingsSearchResult] {
        guard search.isSearching else { return [] }
        let hasProjectScope = model.projects.contains { $0.id == modelDraft.projectID }
        let scopedOverride: Bool
        if case .project(let id) = modelDraft.scope {
            scopedOverride = model.projects.contains { $0.id == id && $0.modelOverride != nil }
        } else {
            scopedOverride = false
        }
        return search.results(available: SettingsSearchAvailability(
            canEditModels: model.canOpenModelSettings,
            hasProjectScope: hasProjectScope,
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
                    if page == .general || page == .about || page == .usage {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("settings-close")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                Divider()
                ScrollViewReader { reader in
                    Group {
                        if page == .about {
                            AboutView(showingLicenses: $showingLicenses, settingsFocus: $focus)
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
                            focus = jump == nil ? .search : .heading
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
                            ForEach(SettingsPage.allCases) { item in
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
            Toggle("Group by Project", isOn: $groupByProject)
                .settingsTarget(.groupByProject, focus: $focus)
        case .appearance:
            AppearanceSettingsView(settings: appearance, settingsFocus: $focus)
        case .model:
            ModelSettingsView(model: model, draft: $modelDraft, settingsFocus: $focus)
        case .browser:
            BrowserSettingsView(defaults: browserDefaults, draft: $browserDraft, settingsFocus: $focus)
        case .about, .usage:
            EmptyView()
        }
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
        if Int(event.keyCode) == kVK_Escape {
            if !event.isARepeat {
                if search.query.isEmpty { dismiss() } else { clearSearch() }
            }
            return true
        }
        guard focus == .search, editor?.isFieldEditor == true else { return false }
        let rows = results
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_DownArrow:
            guard search.isSearching else { return false }
            search.move(by: Int(event.keyCode) == kVK_UpArrow ? -1 : 1, in: rows)
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
