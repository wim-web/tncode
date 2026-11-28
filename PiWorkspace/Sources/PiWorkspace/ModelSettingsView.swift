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
    @Environment(\.closeSettings) private var dismiss
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
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection("Account") {
                if let project = model.projects.first(where: { $0.id == draft.projectID }) {
                    SettingsRow("Scope", description: scopedProject.map {
                        $0.modelOverride == nil ? "Inherits Workspace default" : "Project override"
                    }, descriptionID: "model-settings-source") {
                        T3Select("Scope", selection: Binding(get: { draft.scope }, set: selectScope),
                                 options: [(ModelSettingsScope.workspace, "Workspace default"),
                                           (ModelSettingsScope.project(project.id), String(localized: "Project: \(project.title)"))],
                                 width: 224)
                            .settingsTarget(.scope, focus: settingsFocus)
                    }
                    SettingsDivider()
                }
                SettingsRow("Agent") {
                    T3Select("Agent", selection: Binding(get: { draft.settings.provider == .codexAgent }, set: { useCodex in
                        selectProvider(useCodex ? .codexAgent : (profiles.first?.provider ?? .piOpenAI))
                    }), options: [(true, "Codex"), (false, "Pi")], width: 224)
                    .accessibilityIdentifier("model-agent")
                }
                if draft.settings.provider != .codexAgent {
                    SettingsDivider()
                    SettingsRow("Provider") {
                        T3Select("Provider", selection: Binding(get: { draft.settings.provider }, set: selectProvider),
                                 options: providers.map { ($0, $0.label) }, width: 224)
                            .settingsTarget(.provider, focus: settingsFocus)
                    }
                }
                if let provider = draft.settings.provider.signInProvider {
                    SettingsDivider()
                    accountRow(provider, saved: provider == .codexAgent
                               ? (model.codexAccountStatus == .ready ? .codex : nil)
                               : profiles.first { $0.provider == provider })
                }
            }
            if draft.settings.provider == .codexAgent {
                SettingsSection("Codex tools") {
                    if let tools = model.codexCapabilities {
                        SettingsRow("Web search") { Text(tools.webSearch.label).accessibilityIdentifier("codex-web-search") }
                        SettingsDivider()
                        SettingsRow("Computer Use") { Text(tools.computerUseLabel).accessibilityIdentifier("codex-computer-use") }
                    } else {
                        SettingsRow("Tool availability", description: "Open a Codex conversation to check its Web search and Computer Use tools.") { EmptyView() }
                    }
                }
            }
            SettingsSection("Model") {
                SettingsRow("Model ID", description: draft.settings.provider == .codexAgent ? "Use auto for the model in your Codex configuration." : nil) {
                    TextField("Model ID", text: $draft.settings.model)
                        .frame(width: 256)
                        .settingsTarget(.modelID, focus: settingsFocus)
                }
                if draft.settings.provider == .local {
                    SettingsDivider()
                    SettingsRow("Base URL", description: "A loopback OpenAI-compatible endpoint.") {
                        TextField("Base URL", text: Binding(get: { draft.settings.endpoint }, set: setEndpoint))
                            .frame(width: 256)
                            .settingsTarget(.endpoint, focus: settingsFocus)
                    }
                    SettingsDivider()
                    SettingsRow("Context window") {
                        TextField("Context window", value: $draft.settings.contextWindow, format: .number)
                            .frame(width: 160)
                            .settingsTarget(.contextWindow, focus: settingsFocus)
                    }
                    SettingsDivider()
                    SettingsRow("Coding tools", description: "The model supports tool calls.") {
                        SettingsSwitch("Model supports coding tools", isOn: Binding(
                            get: { draft.settings.localTools == true }, set: { draft.settings.localTools = $0 }
                        ))
                        .settingsTarget(.localTools, focus: settingsFocus)
                    }
                    SettingsDivider()
                    SettingsRow("Image input", description: "The model accepts images.") {
                        SettingsSwitch("Model supports image input", isOn: Binding(
                            get: { draft.settings.localImages == true }, set: { draft.settings.localImages = $0 }
                        ))
                        .settingsTarget(.localImages, focus: settingsFocus)
                    }
                } else {
                    SettingsDivider()
                    SettingsRow("Thinking level",
                                description: draft.settings.provider == .codexAgent ? nil : "Pi adjusts the requested level to the model’s supported levels.") {
                        T3Select("Thinking level", selection: Binding(
                            get: { draft.settings.thinkingLevel ?? .off }, set: { draft.settings.thinkingLevel = $0 }
                        ), options: ModelSettings.ThinkingLevel.allCases.map { ($0, $0.label) })
                        .settingsTarget(.thinkingLevel, focus: settingsFocus)
                    }
                }
            }
            if draft.settings.provider != .codexAgent && draft.settings.provider.piProviderID == nil {
                SettingsSection("Credentials") {
                    SettingsRow("API key", description: "Projects using this provider share its saved API key.",
                                status: hasCredential ? "A key is saved in Keychain." : nil) {
                        SecureField(hasCredential ? "Replace saved API key" : "API key", text: $draft.key)
                            .frame(width: 256)
                            .settingsTarget(.apiKey, focus: settingsFocus)
                    }
                    if hasCredential {
                        SettingsDivider()
                        SettingsRow("Remove saved key",
                                    description: "Remove the key for every project using this provider account.") {
                            SettingsSwitch("Remove saved key", isOn: $draft.removeKey)
                                .settingsTarget(.removeKey, focus: settingsFocus)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if let error { SettingsMessage(error) }
                if let project = scopedProject, project.modelOverride != nil {
                    Button("Reset to Workspace default") { reset(project.id) }
                        .settingsTarget(.resetModelOverride, focus: settingsFocus)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .buttonStyle(T3SmallButtonStyle(kind: .primary))
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
        SettingsRow(provider == .codexAgent ? "Codex account" : provider.label,
                    status: provider == .codexAgent ? (model.codexAccountStatus?.label ?? String(localized: "Checking Codex…"))
                         : (saved == nil ? nil : "Signed in"), statusID: "pi-login-status") {
            if signIn.instructions != nil {
                Button("Cancel sign-in") { signIn.cancel() }
                    .accessibilityIdentifier("provider-login-cancel")
            } else if provider == .codexAgent && model.codexAccountStatus == .notInstalled {
                Button("Get Codex") { openURL(URL(string: "https://developers.openai.com/codex/cli/")!) }
                Button("Check again") { model.refreshCodexAccount() }
            } else if provider == .codexAgent, let saved {
                Button("Use Codex") { activate(saved) }
                    .buttonStyle(T3SmallButtonStyle(kind: .primary))
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
                    .buttonStyle(T3SmallButtonStyle(kind: .primary))
                    .accessibilityIdentifier("provider-login-start")
            }
        } detail: {
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
                SettingsMessage(message).accessibilityIdentifier("provider-login-error")
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
