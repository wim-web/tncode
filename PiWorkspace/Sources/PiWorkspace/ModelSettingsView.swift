import SwiftUI

struct ModelSettingsDraft {
    let projectID: UUID?
    var scope: ModelSettingsScope
    var settings: ModelSettings
    var key = ""
    var removeKey = false

    init(workspace: ModelSettings, project: Project?, signingIn: Bool = false) {
        projectID = project?.id
        scope = project.map { .project($0.id) } ?? .workspace
        settings = project?.modelOverride ?? workspace
        if signingIn && settings.provider != .codexAgent && settings.provider.piProviderID == nil {
            let provider = settings.provider.signInProvider ?? .piCodex
            settings = ModelSettings(provider: provider, model: provider.defaultModel)
        }
    }

    mutating func useAccount(_ profile: ModelSettings) {
        if settings.provider == profile.provider {
            settings.piLoginProfile = profile.piLoginProfile
        } else {
            settings = profile
        }
        key = ""
        removeKey = false
    }
}

struct ModelSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var draft: ModelSettingsDraft
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var error: String?
    @StateObject private var signIn = ProviderSignIn()
    @State private var signInAnswer = ""

    private var scopedProject: Project? {
        guard case .project(let id) = draft.scope else { return nil }
        return model.projects.first { $0.id == id }
    }

    var body: some View {
        let hasCredential = model.hasCredential(for: draft.settings)
        let profiles = model.piLogins.profiles()
        let savedProviders = profiles.map(\.provider)
        let accounts: [Provider] = [.piCodex, .piAnthropic, .piCopilot, .piOpenAI]
        let providers = savedProviders + accounts.filter { !savedProviders.contains($0) } + [.openai, .anthropic, .local]
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
                Picker("Agent", selection: Binding(get: { draft.settings.provider == .codexAgent }, set: { useCodex in
                    selectProvider(useCodex ? .codexAgent : (profiles.first?.provider ?? .piOpenAI))
                })) {
                    Text("Codex").tag(true)
                    Text("Pi").tag(false)
                }
                .accessibilityIdentifier("model-agent")
                if draft.settings.provider != .codexAgent {
                    Picker("Provider", selection: Binding(get: { draft.settings.provider }, set: selectProvider)) {
                        ForEach(providers) { provider in Text(provider.label).tag(provider) }
                    }
                    .settingsTarget(.provider, focus: settingsFocus)
                }
                if let provider = draft.settings.provider.signInProvider {
                    accountRow(provider, saved: provider == .codexAgent
                               ? (model.codexAccountStatus == .ready ? .codex : nil)
                               : profiles.first { $0.provider == provider })
                }
                if draft.settings.provider == .codexAgent {
                    if let tools = model.codexCapabilities {
                        LabeledContent("Web search", value: tools.webSearch.label)
                            .accessibilityIdentifier("codex-web-search")
                        LabeledContent("Computer Use", value: tools.computerUseLabel)
                            .accessibilityIdentifier("codex-computer-use")
                    } else {
                        Text("Open a Codex conversation to check its Web search and Computer Use tools.")
                    }
                }
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
                    .help(draft.settings.provider == .codexAgent ? "" : "Pi adjusts the requested level to the model’s supported levels.")
                }
                if draft.settings.provider != .codexAgent && draft.settings.provider.piProviderID == nil {
                    SecureField(hasCredential ? "Replace saved API key" : "API key", text: $draft.key)
                        .settingsTarget(.apiKey, focus: settingsFocus)
                        .help("Projects using this provider share its saved API key.")
                    if hasCredential {
                        Toggle("Remove saved key", isOn: $draft.removeKey)
                            .settingsTarget(.removeKey, focus: settingsFocus)
                            .help("Remove the key for every project using this provider account.")
                    }
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
                    .disabled(signIn.instructions != nil)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("save-settings")
            }
        }
        .onDisappear { signIn.cancel() }
        .task(id: draft.settings.provider) {
            if draft.settings.provider == .codexAgent { model.refreshCodexAccount() }
        }
        .onChange(of: signIn.instructions?.prompt?.id) { _, _ in signInAnswer = "" }
    }

    private func accountRow(_ provider: Provider, saved: ModelSettings?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if provider == .codexAgent {
                Text(model.codexAccountStatus?.label ?? String(localized: "Checking Codex…"))
                    .accessibilityIdentifier("pi-login-status")
            } else if saved != nil {
                Text("Signed in").accessibilityIdentifier("pi-login-status")
            }
            if signIn.instructions != nil {
                Button("Cancel sign-in") { signIn.cancel() }
                    .accessibilityIdentifier("provider-login-cancel")
            } else if provider == .codexAgent && model.codexAccountStatus == .notInstalled {
                Button("Get Codex") { openURL(URL(string: "https://developers.openai.com/codex/cli/")!) }
                Button("Check again") { model.refreshCodexAccount() }
            } else if provider == .codexAgent, let saved {
                Button("Use Codex") { activate(saved) }
                    .accessibilityIdentifier("use-codex-agent")
            } else if let saved {
                if saved.account != draft.settings.account {
                    Button("Use this account") { activate(saved) }
                        .accessibilityIdentifier("provider-login-use")
                }
                Button("Sign in again") { beginSignIn(provider) }
                    .accessibilityIdentifier("provider-login-start")
            } else {
                Button(provider.signInLabel) { beginSignIn(provider) }
                    .accessibilityIdentifier("provider-login-start")
            }
            if let instructions = signIn.instructions {
                if let code = instructions.deviceCode {
                    Text("Enter this code on the sign-in page")
                    Text(verbatim: code).font(.body.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("provider-login-device-code")
                }
                if instructions.url != nil {
                    Text("Finish signing in in your browser. This window will update automatically.")
                        .accessibilityIdentifier("provider-login-waiting")
                    Button("Reopen sign-in page") { signIn.reopenBrowser() }
                        .accessibilityIdentifier("provider-login-browser")
                } else if instructions.prompt == nil {
                    ProgressView().controlSize(.small)
                }
                if let prompt = instructions.prompt { loginPrompt(prompt) }
            }
            if let message = signIn.error {
                Text(message).foregroundStyle(.red).accessibilityIdentifier("provider-login-error")
                if signIn.instructions == nil && (provider == .codexAgent || provider == .piCodex || provider == .piAnthropic) {
                    Button("Sign in using a code") { beginSignIn(provider, useCode: true) }
                        .accessibilityIdentifier("provider-login-code-method")
                }
            }
        }
    }

    @ViewBuilder
    private func loginPrompt(_ prompt: ProviderLoginPrompt) -> some View {
        Text(prompt.kind == .manual_code
             ? String(localized: "If the browser doesn’t return automatically, paste the code or final redirect URL here.")
             : prompt.message)
        if prompt.kind == .select {
            ForEach(prompt.options ?? []) { option in
                Button(option.label) { signIn.answer(prompt, with: option.id) }
            }
        } else {
            HStack {
                if prompt.kind == .text {
                    TextField(prompt.placeholder ?? "", text: $signInAnswer)
                        .accessibilityIdentifier("provider-login-input")
                } else {
                    SecureField("Code or redirect URL", text: $signInAnswer)
                        .accessibilityIdentifier("provider-login-input")
                }
                Button("Continue") {
                    let answer = signInAnswer
                    signInAnswer = ""
                    signIn.answer(prompt, with: answer)
                }
                .disabled(prompt.kind != .text && signInAnswer.isEmpty)
                .accessibilityIdentifier("provider-login-answer")
            }
        }
    }

    private func beginSignIn(_ provider: Provider, useCode: Bool = false) {
        let scope = draft.scope
        let original = draft.settings.provider
        let request = model.settingsRequest
        error = nil
        signInAnswer = ""
        signIn.start(provider, logins: model.piLogins, codexWorkspace: model.root, useCode: useCode) { profile in
            guard model.settingsRequest === request, request?.page == .model,
                  request?.projectID == draft.projectID, draft.scope == scope,
                  draft.settings.provider == original else { return }
            activate(profile)
        }
    }

    private func activate(_ profile: ModelSettings) {
        if profile.provider == .codexAgent { model.setCodexAccountStatus(.ready) }
        draft.useAccount(profile)
        save()
    }

    private func selectScope(_ selection: ModelSettingsScope) {
        guard draft.scope != selection else { return }
        signIn.cancel()
        draft.scope = selection
        draft.settings = scopedProject?.modelOverride ?? model.workspace.model
        clearCredentialEdit()
        error = nil
    }

    private func selectProvider(_ provider: Provider) {
        if provider == draft.settings.provider,
           provider.piProviderID == nil || model.hasCredential(for: draft.settings) { return }
        signIn.cancel()
        if provider == .codexAgent {
            draft.settings = .codex
        } else if let profile = model.piLogins.profiles().first(where: { $0.provider == provider }) {
            draft.settings = profile
        } else {
            draft.settings.provider = provider
            draft.settings.model = provider.defaultModel
            draft.settings.piLoginProfile = nil
        }
        clearCredentialEdit()
        error = nil
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
