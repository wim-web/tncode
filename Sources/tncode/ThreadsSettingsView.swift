import SwiftUI

/// Settings → Threads (T3 Code's ThreadsSettingsPanel): New projects, New threads and Snooze.
/// The scope sentence picks All projects or one project; New threads then edits that project's override.
struct ThreadsSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var request: SettingsRequest
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var baseDirectoryError: String?

    private var project: Project? { model.projects.first { $0.id == request.projectID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            if project == nil {
                SettingsSection("New projects") {
                    SettingsRow("Add project starts in", description: "Leave empty to use \"~/\" when the Add Project browser opens.",
                                reset: model.workspace.addProjectBaseDirectory == nil ? nil :
                                    SettingsResetButton("Reset add project base directory to default",
                                                        id: "reset-add-project-starts-in") {
                                        commitBaseDirectory("")
                                    }) {
                        SettingsDraftField("Add project base directory", value: model.workspace.addProjectBaseDirectory ?? "",
                                           placeholder: "~/", width: 288,
                                           target: (.addProjectStartsIn, settingsFocus)) { value in
                            commitBaseDirectory(WorktreeDirectory.replacingPastedPath(previous: "", next: value))
                        }
                    } detail: {
                        if let baseDirectoryError {
                            SettingsMessage(baseDirectoryError).accessibilityIdentifier("add-project-starts-in-error")
                        }
                    }
                }
            }
            SettingsSection("New threads") {
                DefaultModelRow(model: model, project: project, settingsFocus: settingsFocus)
                SettingsDivider()
                DefaultPermissionsRow(model: model, project: project, settingsFocus: settingsFocus)
            }
            if project == nil {
                SnoozeOptionsSettingsView(model: model, settingsFocus: settingsFocus)
            }
        }
    }

    private func commitBaseDirectory(_ value: String) {
        do {
            try model.updateAddProjectBaseDirectory(value)
            baseDirectoryError = nil
        } catch {
            baseDirectoryError = error.localizedDescription
        }
    }
}

/// "Model": the provider and model new threads start with, plus its reasoning effort.
struct DefaultModelRow: View {
    @ObservedObject var model: WorkspaceModel
    let project: Project?
    var settingsFocus: FocusState<SettingsFocus?>.Binding?
    @State private var error: String?

    private var current: ModelSettings { project?.modelOverride ?? model.workspace.model }
    private var scope: ModelSettingsScope { project.map { .project($0.id) } ?? .workspace }

    var body: some View {
        let options = model.defaultModelOptions(current: current)
        let selected = options.first { $0.id == current.identity }
        let status = statusLine(selected)
        SettingsRow("Model",
                    description: project == nil ? "Default model for new threads. Projects can override it."
                                                : "Model for new threads in this project.",
                    status: status,
                    reset: project?.modelOverride == nil ? nil :
                        SettingsResetButton("Reset default model to default", id: "reset-model-override") { reset() }) {
            SettingsModelPickerButton(model: model, title: "Default model", current: current, choose: choose) { level in
                var next = current
                next.thinkingLevel = level == .off ? nil : level
                apply(next)
            }
                .modifier(OptionalSettingsTarget(target: settingsFocus.map { (SettingsAnchor.defaultModel, $0) }))
                .accessibilityIdentifier(SettingsAnchor.defaultModel.rawValue)
            if current.provider != .local && status == nil {
                ThinkingLevelPicker(level: current.thinkingLevel ?? .off) { level in
                    var next = current
                    next.thinkingLevel = level
                    apply(next)
                }
            }
        } detail: {
            if let error { SettingsMessage(error).accessibilityIdentifier("default-model-error") }
        }
    }

    private func statusLine(_ option: ComposerModelOption?) -> String? {
        let preferences = model.workspace.preferences(for: current.provider)
        let name = preferences.displayName ?? current.provider.instanceLabel
        if !preferences.isEnabled { return String(localized: "\(name) is turned off.") }
        return option?.unavailableReason
    }

    private func choose(_ option: ComposerModelOption) {
        var next = option.settings
        if next.provider != .local { next.thinkingLevel = current.thinkingLevel }
        apply(next)
    }

    private func apply(_ settings: ModelSettings) {
        do {
            try model.applySettings(settings, in: scope, newKey: "", removeKey: false)
            error = nil
        } catch {
            self.error = String(localized: "Default model not saved. \(error.localizedDescription)")
        }
    }

    private func reset() {
        guard let project else { return }
        do {
            try model.resetProjectModel(project.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Reasoning effort beside a model picker: gauge icon and level, opening a menu (T3 Code's TraitsPicker).
struct ThinkingLevelPicker: View {
    let level: ModelSettings.ThinkingLevel
    let choose: (ModelSettings.ThinkingLevel) -> Void

    var body: some View {
        Menu {
            ForEach(ModelSettings.ThinkingLevel.allCases) { option in
                Button { choose(option) } label: {
                    if option == level { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent").font(.system(size: 13))
                Text(level.label).lineLimit(1)
            }
            .modifier(SettingsPickerTriggerChrome())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Reasoning effort: \(level.label)"))
        .accessibilityIdentifier("default-thinking-level")
    }
}

/// "Permissions": tool permissions new projects start with, or one project's permissions.
private struct DefaultPermissionsRow: View {
    @ObservedObject var model: WorkspaceModel
    let project: Project?
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var error: String?

    private var value: ToolPermission { project?.toolPermission ?? model.workspace.defaultToolPermission ?? .readFiles }

    var body: some View {
        SettingsRow("Permissions",
                    description: project == nil ? "Default permissions for new projects. Projects can override them."
                                                : "Permissions for new threads in this project.",
                    reset: project != nil || value == .readFiles ? nil :
                        SettingsResetButton("Reset default permissions to default", id: "reset-default-permissions") {
                            set(.readFiles)
                        }) {
            Menu {
                ForEach(ToolPermission.allCases, id: \.self) { permission in
                    Button { set(permission) } label: {
                        Label {
                            Text(permission.title + "\n" + permission.summary)
                        } icon: {
                            Image(systemName: permission == value ? "checkmark" : permission.icon)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: value.icon).font(.system(size: 12))
                    Text(value.title).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).opacity(0.7)
                }
                .frame(width: 142)
                .modifier(T3FieldChrome())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Default permissions: \(value.title)"))
            .settingsTarget(.defaultPermissions, focus: settingsFocus)
        } detail: {
            if let error { SettingsMessage(error) }
        }
    }

    private func set(_ permission: ToolPermission) {
        do {
            if let project {
                try model.updateToolPermission(permission, forProject: project.id)
            } else {
                try model.updateDefaultToolPermission(permission)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension ToolPermission {
    var summary: String {
        switch self {
        case .readFiles: String(localized: "Read files without running commands or editing.")
        case .supervised: String(localized: "Ask before commands and file changes.")
        case .shellAndEdits: String(localized: "Allow commands and edits without prompts.")
        }
    }
}

/// Settings model and traits triggers: 28pt, bordered input chrome, regular 14pt text, no chevron.
struct SettingsPickerTriggerChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    func body(content: Content) -> some View {
        let palette = T3Palette(colorScheme, t3Themes)
        content
            .font(.system(size: 14))
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(palette.fieldFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.input) }
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsPickerTriggerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(SettingsPickerTriggerChrome())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Text input that saves on Return or when focus leaves, like T3 Code's DraftInput.
struct SettingsDraftField: View {
    let title: String
    let value: String
    var placeholder: String = ""
    var width: CGFloat = 224
    /// Settings search lands on this field.
    var target: (anchor: SettingsAnchor, focus: FocusState<SettingsFocus?>.Binding)?
    let commit: (String) -> Void
    @State private var draft: String?
    @FocusState private var focused: Bool

    init(_ title: String, value: String, placeholder: String = "", width: CGFloat = 224,
         target: (anchor: SettingsAnchor, focus: FocusState<SettingsFocus?>.Binding)? = nil,
         commit: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.placeholder = placeholder
        self.width = width
        self.target = target
        self.commit = commit
    }

    var body: some View {
        TextField(text: Binding(get: { draft ?? value }, set: { draft = $0 }),
                  prompt: placeholder.isEmpty ? nil : Text(verbatim: placeholder)) {
            Text(localized: title)
        }
        .labelsHidden()
        .frame(width: width)
        .focused($focused)
        .onSubmit(save)
        .onChange(of: focused) { _, now in if !now { save() } }
        .onDisappear(perform: save)
        .accessibilityLabel(Text(localized: title))
        .modifier(OptionalSettingsTarget(target: target))
    }

    private func save() {
        guard let draft else { return }
        self.draft = nil
        if draft != value { commit(draft) }
    }
}

/// Model picker trigger for settings rows: the provider logo and model name, opening the composer's model
/// picker (T3 Code's ProviderModelPicker) without its permissions control.
struct SettingsModelPickerButton: View {
    @ObservedObject var model: WorkspaceModel
    let title: String
    let current: ModelSettings
    var excluded: Set<Provider> = []
    let choose: (ComposerModelOption) -> Void
    var chooseLevel: ((ModelSettings.ThinkingLevel) -> Void)?
    @State private var picking = false
    @Environment(\.closeSettings) private var closeSettings

    var body: some View {
        let name = model.modelName(current)
        Button { picking = true } label: {
            HStack(spacing: 6) {
                ProviderInstanceIcon(provider: current.provider,
                                     accent: model.workspace.preferences(for: current.provider).accentColor)
                    .frame(width: 16, height: 16)
                Text(verbatim: name).lineLimit(1)
            }
        }
        .buttonStyle(SettingsPickerTriggerStyle())
        .help(name)
        .accessibilityLabel(Text("\(NSLocalizedString(title, comment: "")): \(name)"))
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            ComposerModelPicker(
                providers: model.defaultModelProviders(current: current, excluding: excluded),
                favorites: model.favoriteModels, current: current, currentName: name, disabled: false,
                permission: nil, permissionDisabled: true,
                choose: { option in
                    picking = false
                    choose(option)
                }, chooseLevel: { level in chooseLevel?(level) },
                toggleFavorite: { model.toggleFavoriteModel($0) },
                setPermission: { _ in },
                openSetup: { picking = false }, close: { picking = false })
            .frame(width: ComposerModelPicker.width, height: ComposerModelPicker.height)
        }
    }
}

private struct OptionalSettingsTarget: ViewModifier {
    let target: (anchor: SettingsAnchor, focus: FocusState<SettingsFocus?>.Binding)?

    func body(content: Content) -> some View {
        if let target { content.settingsTarget(target.anchor, focus: target.focus) } else { content }
    }
}
