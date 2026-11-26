import SwiftUI

struct ModelSettingsDraft {
    let projectID: UUID?
    var scope: ModelSettingsScope
    var settings: ModelSettings
    var key = ""
    var removeKey = false

    init(workspace: ModelSettings, project: Project?) {
        projectID = project?.id
        scope = project.map { .project($0.id) } ?? .workspace
        settings = project?.modelOverride ?? workspace
    }
}

struct ModelSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var draft: ModelSettingsDraft
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    private var scopedProject: Project? {
        guard case .project(let id) = draft.scope else { return nil }
        return model.projects.first { $0.id == id }
    }

    var body: some View {
        let hasKey = model.hasKey(for: draft.settings)
        VStack(alignment: .leading, spacing: 18) {
            Form {
                if let project = model.projects.first(where: { $0.id == draft.projectID }) {
                    Picker("Scope", selection: Binding(get: { draft.scope }, set: selectScope)) {
                        Text("Workspace default").tag(ModelSettingsScope.workspace)
                        Text("Project: \(project.title)").tag(ModelSettingsScope.project(project.id))
                    }
                    .settingsTarget(.scope, focus: settingsFocus)
                }
                if let project = scopedProject {
                    Text(project.modelOverride == nil ? "Inherits Workspace default" : "Project override")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("model-settings-source")
                }
                Picker("Provider", selection: Binding(get: { draft.settings.provider }, set: selectProvider)) {
                    ForEach(Provider.allCases) { provider in Text(provider.label).tag(provider) }
                }
                .settingsTarget(.provider, focus: settingsFocus)
                TextField("Model ID", text: $draft.settings.model)
                    .settingsTarget(.modelID, focus: settingsFocus)
                if draft.settings.provider == .local {
                    TextField("Base URL", text: Binding(get: { draft.settings.endpoint }, set: setEndpoint))
                        .settingsTarget(.endpoint, focus: settingsFocus)
                    TextField("Context window", value: $draft.settings.contextWindow, format: .number)
                        .settingsTarget(.contextWindow, focus: settingsFocus)
                    Toggle("Model supports coding tools", isOn: Binding(
                        get: { draft.settings.localTools == true }, set: { draft.settings.localTools = $0 }
                    ))
                    .settingsTarget(.localTools, focus: settingsFocus)
                    Toggle("Model supports image input", isOn: Binding(
                        get: { draft.settings.localImages == true }, set: { draft.settings.localImages = $0 }
                    ))
                    .settingsTarget(.localImages, focus: settingsFocus)
                } else {
                    Picker("Thinking level", selection: Binding(
                        get: { draft.settings.thinkingLevel ?? .off }, set: { draft.settings.thinkingLevel = $0 }
                    )) {
                        ForEach(ModelSettings.ThinkingLevel.allCases) { level in Text(level.label).tag(level) }
                    }
                    .settingsTarget(.thinkingLevel, focus: settingsFocus)
                    .help("Pi adjusts the requested level to the model’s supported levels.")
                }
                SecureField(hasKey ? "Replace saved API key" : "API key", text: $draft.key)
                    .settingsTarget(.apiKey, focus: settingsFocus)
                    .help("Projects using this provider share its saved API key.")
                if hasKey {
                    Toggle("Remove saved key", isOn: $draft.removeKey)
                        .settingsTarget(.removeKey, focus: settingsFocus)
                        .help("Remove the key for every project using this provider account.")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if let project = scopedProject, project.modelOverride != nil {
                    Button("Reset to Workspace default") { reset(project.id) }
                        .settingsTarget(.resetModelOverride, focus: settingsFocus)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("save-settings")
            }
        }
    }

    private func selectScope(_ selection: ModelSettingsScope) {
        guard draft.scope != selection else { return }
        draft.scope = selection
        draft.settings = scopedProject?.modelOverride ?? model.workspace.model
        clearCredentialEdit()
        error = nil
    }

    private func selectProvider(_ provider: Provider) {
        guard draft.settings.provider != provider else { return }
        draft.settings.provider = provider
        draft.settings.model = provider.defaultModel
        clearCredentialEdit()
    }

    private func setEndpoint(_ endpoint: String) {
        guard draft.settings.endpoint != endpoint else { return }
        draft.settings.endpoint = endpoint
        clearCredentialEdit()
    }

    private func clearCredentialEdit() {
        draft.key = ""
        draft.removeKey = false
    }

    private func save() {
        do {
            try model.applySettings(draft.settings, in: draft.scope, newKey: draft.key, removeKey: draft.removeKey)
            clearCredentialEdit()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset(_ project: UUID) {
        do {
            try model.resetProjectModel(project)
            draft.settings = model.workspace.model
            clearCredentialEdit()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
