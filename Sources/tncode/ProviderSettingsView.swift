import AppKit
import SwiftUI

/// Settings → Providers, after T3 Code's ProviderSettingsPanel: the instance list beside the selected instance's
/// editor. At 768pt and wider the two sit side by side (list 272pt); narrower, the editor follows the list.
struct ProviderSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var selected: Provider
    @State private var width: CGFloat = 0
    @State private var refreshing = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.settingsViewportHeight) private var viewportHeight

    init(model: WorkspaceModel, settingsFocus: FocusState<SettingsFocus?>.Binding, initial: Provider? = nil) {
        self.model = model
        self.settingsFocus = settingsFocus
        let current = initial ?? model.effectiveModel.provider
        _selected = State(initialValue: Provider.instanceOrder.contains(current) ? current : .codexAgent)
    }

    private var palette: T3Palette { T3Palette(colorScheme, t3Themes) }
    private var sideBySide: Bool { width >= 768 }

    var body: some View {
        SettingsSection("Providers", plain: true) {
            card
        } trailing: {
            refreshButton.padding(.trailing, -8)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { if model.providersCheckedAt == nil { model.refreshProviders() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-settings")
    }

    private var refreshButton: some View {
        Button {
            refreshing = true
            model.refreshProviders()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                refreshing = false
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(refreshing ? 360 : 0))
                    .animation(refreshing ? .linear(duration: 0.6) : nil, value: refreshing)
                if refreshing {
                    Text("Refreshing providers")
                } else if let checked = model.providersCheckedAt {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("Checked \(ProviderCheckedTime.text(since: checked, now: context.date))")
                    }
                }
            }
        }
        .buttonStyle(T3SmallButtonStyle(kind: .ghost, height: 24))
        .disabled(refreshing)
        .help("Refresh provider status")
        .accessibilityLabel("Refresh provider status")
        .accessibilityIdentifier("refresh-providers")
    }

    private var cardHeight: CGFloat? {
        guard sideBySide else { return nil }
        return max(512, min(704, viewportHeight - 176))
    }

    private var card: some View {
        let layout = sideBySide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            instanceList
                .frame(width: sideBySide ? 272 : nil)
                .frame(maxHeight: sideBySide ? .infinity : nil, alignment: .top)
                .background(palette.muted.opacity(0.1))
                .overlay(alignment: sideBySide ? .trailing : .bottom) {
                    Rectangle().fill(palette.border.opacity(0.6))
                        .frame(width: sideBySide ? 1 : nil, height: sideBySide ? nil : 1)
                }
            Group {
                if sideBySide {
                    ScrollView { editor }.scrollIndicators(.automatic)
                } else {
                    editor
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .background(palette.card.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border.opacity(0.6)) }
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }

    @ViewBuilder
    private var instanceList: some View {
        let rows = VStack(spacing: 0) {
            ForEach(Array(Provider.instanceOrder.enumerated()), id: \.element) { index, provider in
                if index > 0 { Rectangle().fill(palette.border.opacity(0.5)).frame(height: 1) }
                ProviderInstanceListRow(model: model, provider: provider, selected: provider == selected) {
                    selected = provider
                }
            }
        }
        if sideBySide {
            ScrollView { rows }.scrollIndicators(.never)
        } else {
            rows
        }
    }

    private var editor: some View {
        ProviderInstanceEditor(model: model, provider: selected, settingsFocus: settingsFocus)
            .id(selected)
            .padding(.vertical, 16)
            .environment(\.settingsFlatGroups, true)
    }
}

/// "5m" style elapsed time for the provider refresh button, after T3 Code's relative time state.
enum ProviderCheckedTime {
    static func text(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(localized: "just now") }
        let minutes = seconds / 60
        if minutes < 60 { return String(localized: "\(minutes)m ago") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours)h ago") }
        return String(localized: "\(hours / 24)d ago")
    }
}

private struct ViewportHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 720
}

extension EnvironmentValues {
    /// Height of the window Settings is shown in; T3 Code sizes the provider card from the viewport.
    var settingsViewportHeight: CGFloat {
        get { self[ViewportHeightKey.self] }
        set { self[ViewportHeightKey.self] = newValue }
    }
}

// MARK: - List

/// Instance row: logo, name, version and status, with the enable switch. Selecting fills the editor.
private struct ProviderInstanceListRow: View {
    @ObservedObject var model: WorkspaceModel
    let provider: Provider
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let preferences = model.workspace.preferences(for: provider)
        let status = model.providerStatus(provider)
        let name = preferences.displayName ?? provider.instanceLabel
        HStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProviderInstanceIcon(provider: provider, accent: preferences.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(verbatim: name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        if let version = provider.bundledVersion {
                            Text(verbatim: version)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(palette.mutedForeground)
                                .lineLimit(1)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if status.needsAttention { ProviderStatusDot(key: status.key) }
                        Text(verbatim: status.needsAttention && status.detail != nil
                             ? "\(status.headline) · \(status.detail!)" : status.headline)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.mutedForeground.opacity(0.8))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .opacity(!preferences.isEnabled && !selected && !hovering ? 0.6 : 1)
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(Text("Select \(name)"))
            .accessibilityAction(.default, select)
            SettingsSwitch(String(localized: "Enable \(name)"), isOn: Binding(
                get: { preferences.isEnabled },
                set: { enabled in try? model.updateProviderPreferences(provider) { $0.enabled = enabled } }
            ))
            .accessibilityIdentifier("provider-enabled-\(provider.rawValue)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 72)
        .background(selected ? palette.foreground.opacity(0.06) : hovering ? palette.muted.opacity(0.25) : .clear)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-instance-\(provider.rawValue)")
    }
}

/// 6pt status dot: success, warning or destructive.
struct ProviderStatusDot: View {
    let key: ProviderInstanceStatus.Key
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let color: Color = switch key {
        case .ready: palette.success
        case .warning: palette.warning
        case .error: palette.destructive
        case .neutral: palette.mutedForeground
        case .disabled: palette.mutedForeground.opacity(0.5)
        }
        Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
    }
}

/// 20pt logo; with an accent color, a small colored badge with the name's initial sits on its corner.
struct ProviderInstanceIcon: View {
    let provider: Provider
    var accent: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        ProviderLogoShape(logo: provider.logo)
            .fill(palette.foreground.opacity(0.8), style: FillStyle(eoFill: true))
            .frame(width: 16, height: 16)
            .frame(width: 20, height: 20)
            .overlay(alignment: .bottomTrailing) {
                if let color = accent.flatMap(Color.init(hexString:)) {
                    Circle().fill(color)
                        .frame(width: 9, height: 9)
                        .overlay { Circle().strokeBorder(palette.canvas, lineWidth: 1.5) }
                        .offset(x: 2, y: 2)
                }
            }
            .accessibilityHidden(true)
    }
}

extension Provider {
    /// Version shown beside the name. Pi runs the bundled coding agent; Codex reports none to tncode.
    var bundledVersion: String? { driver == .pi ? "v1.6.1" : nil }
}

// MARK: - Editor

private struct ProviderInstanceEditor: View {
    @ObservedObject var model: WorkspaceModel
    let provider: Provider
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var error: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private var preferences: ProviderPreferences { model.workspace.preferences(for: provider) }
    private var name: String { preferences.displayName ?? provider.instanceLabel }

    private func update(_ change: (inout ProviderPreferences) -> Void) {
        do {
            try model.updateProviderPreferences(provider, change)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let status = model.providerStatus(provider)
        VStack(alignment: .leading, spacing: 24) {
            SettingsSection(name) {
                SettingsStatusRow(status: status)
                SettingsDivider()
                SettingsRow("Display name") {
                    ProviderAccentColorButton(name: name, value: preferences.accentColor) { color in
                        update { $0.accentColor = color }
                    }
                    SettingsDraftField("Display name", value: preferences.displayName ?? "",
                                       placeholder: provider.instanceLabel, width: 224) { value in
                        update { $0.displayName = value }
                    }
                    .accessibilityIdentifier("provider-display-name")
                }
            } trailing: {
                HStack(spacing: 6) {
                    if let version = provider.bundledVersion {
                        Text(verbatim: version)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.mutedForeground)
                    }
                    if preferences.isCustomized {
                        SettingsResetButton(String(localized: "Reset \(provider.instanceLabel) provider settings to default"),
                                            id: "reset-provider-\(provider.rawValue)") {
                            update { $0 = $0.withoutCustomizations }
                        }
                    }
                }
            } icon: {
                ProviderInstanceIcon(provider: provider, accent: preferences.accentColor)
            }
            if let error { SettingsMessage(error).padding(.horizontal, 16) }
            setup
            runtime
            ProviderModelsSection(model: model, provider: provider, update: update)
        }
    }

    @ViewBuilder
    private var setup: some View {
        switch provider.authKind {
        case .codexAccount, .piSignIn:
            SettingsSection("Setup") {
                ProviderAccountRow(model: model, provider: provider, settingsFocus: settingsFocus)
            }
        case .apiKey:
            SettingsSection("Setup") {
                ProviderAPIKeyRow(model: model, provider: provider, settingsFocus: settingsFocus)
            }
        case .customEndpoint:
            EmptyView()
        }
    }

    @ViewBuilder
    private var runtime: some View {
        switch provider.authKind {
        case .codexAccount:
            SettingsSection("Runtime") {
                SettingsRow("Binary path", description: "Path to the Codex binary used by this instance.") {
                    SettingsDraftField("Binary path", value: preferences.binaryPath ?? "", placeholder: "codex", width: 224) {
                        value in update { $0.binaryPath = value }
                    }
                    .accessibilityIdentifier("codex-binary-path")
                }
                SettingsDivider()
                SettingsRow("CODEX_HOME path", description: "Custom Codex home and config directory.") {
                    SettingsDraftField("CODEX_HOME path", value: preferences.homePath ?? "", placeholder: "~/.codex",
                                       width: 224) { value in update { $0.homePath = value } }
                        .accessibilityIdentifier("codex-home-path")
                }
                SettingsDivider()
                SettingsRow("Launch arguments",
                            description: "Additional CLI arguments passed to codex app-server on session start.") {
                    SettingsDraftField("Launch arguments", value: preferences.launchArgs ?? "", placeholder: "",
                                       width: 224) { value in update { $0.launchArgs = value } }
                        .accessibilityIdentifier("codex-launch-arguments")
                }
            }
        case .customEndpoint:
            let local = model.instanceModel(.local, id: "model") ?? ModelSettings(provider: .local)
            SettingsSection("Runtime") {
                SettingsRow("Base URL", description: "A loopback OpenAI-compatible endpoint.") {
                    SettingsDraftField("Base URL", value: local.endpoint, placeholder: "http://127.0.0.1:11434/v1",
                                       width: 224, target: (.endpoint, settingsFocus)) { value in update { $0.endpoint = value } }
                }
                SettingsDivider()
                SettingsRow("Context window", description: "Tokens the model accepts, from 8,192 to 2,000,000.") {
                    SettingsDraftField("Context window", value: String(local.contextWindow), placeholder: "8192",
                                       width: 224, target: (.contextWindow, settingsFocus)) { value in
                        if let tokens = Int(value.filter(\.isNumber)), (8192...2_000_000).contains(tokens) {
                            update { $0.contextWindow = tokens }
                        } else {
                            error = String(localized: "Enter a context window between 8,192 and 2,000,000 tokens.")
                        }
                    }
                }
                SettingsDivider()
                SettingsRow("Coding tools", description: "The model supports tool calls.") {
                    SettingsSwitch("Model supports coding tools", isOn: Binding(
                        get: { local.localTools == true }, set: { value in update { $0.localTools = value } }
                    ))
                    .settingsTarget(.localTools, focus: settingsFocus)
                }
                SettingsDivider()
                SettingsRow("Image input", description: "The model accepts images.") {
                    SettingsSwitch("Model supports image input", isOn: Binding(
                        get: { local.localImages == true }, set: { value in update { $0.localImages = value } }
                    ))
                    .settingsTarget(.localImages, focus: settingsFocus)
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Status row of the editor: the headline with its detail, and a status dot when it needs attention.
struct SettingsStatusRow: View {
    let status: ProviderInstanceStatus
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        VStack(alignment: .leading, spacing: 4) {
            Text("Status")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.foreground)
                .frame(minHeight: 20)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if status.needsAttention { ProviderStatusDot(key: status.key) }
                Text(verbatim: status.detail.map { "\(status.headline) · \($0)" } ?? status.headline)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("provider-status")
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Setup

/// "Account" row, after T3 Code's ProviderAuthenticationSection: sign in, follow the browser or device code,
/// and change account.
private struct ProviderAccountRow: View {
    @ObservedObject var model: WorkspaceModel
    let provider: Provider
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @StateObject private var signIn = ProviderSignIn()
    @State private var method = ""
    @State private var answer = ""
    @Environment(\.openURL) private var openURL

    private var supportsCode: Bool { [.codexAgent, .piCodex, .piAnthropic].contains(provider) }
    private var signedIn: Bool {
        provider == .codexAgent ? model.codexAccountStatus == .ready
            : model.piLogins.profiles().contains { $0.provider == provider }
    }
    private var notInstalled: Bool { provider == .codexAgent && model.codexAccountStatus == .notInstalled }
    private var enabled: Bool { model.workspace.preferences(for: provider).isEnabled }

    private var description: String {
        if let instructions = signIn.instructions {
            if instructions.prompt?.kind == .manual_code || instructions.url != nil {
                return String(localized: "Finish signing in in your browser.")
            }
            return String(localized: "Starting sign-in…")
        }
        if signedIn { return String(localized: "Signed in.") }
        if notInstalled { return CodexAccountStatus.notInstalled.label }
        return String(localized: "Sign in on \(ProviderEnvironment.label).")
    }

    var body: some View {
        SettingsRow("Account", description: description) {
            if signIn.instructions == nil && supportsCode && !notInstalled {
                T3Select("Sign-in method", selection: $method,
                         options: [("", "Provider default"), ("code", "Device code")], width: 176)
                    .disabled(!enabled)
            }
            if let instructions = signIn.instructions {
                if instructions.url != nil {
                    Button("Open browser") { signIn.reopenBrowser() }
                        .accessibilityIdentifier("provider-login-browser")
                    Button {
                        if let url = instructions.url {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 13))
                    }
                    .buttonStyle(T3IconButtonStyle(size: 28))
                    .help("Copy sign-in link")
                    .accessibilityLabel("Copy sign-in link")
                }
                Button("Cancel") { signIn.cancel() }
                    .buttonStyle(T3SmallButtonStyle(kind: .ghost))
                    .accessibilityLabel("Cancel sign-in")
                    .accessibilityIdentifier("provider-login-cancel")
            } else if notInstalled {
                Button("Open docs") { openURL(URL(string: "https://developers.openai.com/codex/cli/")!) }
            } else {
                Button(signedIn ? "Change account" : signIn.error != nil ? "Retry sign-in" : "Sign in") { begin() }
                    .disabled(!enabled)
                    .settingsTarget(.accountSignIn, focus: settingsFocus)
            }
        } detail: {
            if let code = signIn.instructions?.deviceCode {
                (Text("Enter code ") + Text(verbatim: code).font(.system(size: 14, design: .monospaced)) +
                 Text(" in your browser."))
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("provider-login-device-code")
            }
            if let prompt = signIn.instructions?.prompt { promptView(prompt) }
            if let message = signIn.error {
                SettingsMessage(message).accessibilityIdentifier("provider-login-error")
            }
        }
        .onDisappear { signIn.cancel() }
        .onChange(of: signIn.instructions?.prompt?.id) { _, _ in answer = "" }
    }

    @ViewBuilder
    private func promptView(_ prompt: ProviderLoginPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt.kind == .manual_code
                 ? String(localized: "If the final localhost page does not load, paste its full URL here.")
                 : prompt.message)
                .font(.system(size: 14))
            if prompt.kind == .select {
                HStack(spacing: 6) {
                    ForEach(prompt.options ?? []) { option in
                        Button(option.label) { signIn.answer(prompt, with: option.id) }
                    }
                }
            } else {
                if prompt.kind == .text {
                    TextField(prompt.placeholder ?? "", text: $answer)
                        .accessibilityIdentifier("provider-login-input")
                } else {
                    SecureField("", text: $answer)
                        .accessibilityIdentifier("provider-login-input")
                }
                Button("Continue") {
                    let value = answer
                    answer = ""
                    signIn.answer(prompt, with: value)
                }
                .disabled(prompt.kind != .text && answer.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("provider-login-answer")
            }
        }
        .padding(.vertical, 8)
    }

    private func begin() {
        answer = ""
        signIn.start(provider, logins: model.piLogins, codexWorkspace: model.root, useCode: method == "code") { _ in
            if provider == .codexAgent { model.setCodexAccountStatus(.ready) }
            model.refreshProviders()
        }
    }
}

/// API key instances keep their key in Keychain; the row saves, replaces or removes it.
private struct ProviderAPIKeyRow: View {
    @ObservedObject var model: WorkspaceModel
    let provider: Provider
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        let saved = model.hasProviderKey(provider)
        SettingsRow("API key", description: saved ? "Saved in Keychain. Projects using this provider share it."
                                                  : "Projects using this provider share its saved API key.") {
            SecureField(saved ? String(localized: "Replace saved API key") : String(localized: "API key"), text: $key)
                .frame(width: 224)
                .onSubmit(save)
                .settingsTarget(.apiKey, focus: settingsFocus)
            Button("Save", action: save)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("save-api-key")
            if saved {
                Button("Remove") {
                    do {
                        try model.removeProviderKey(provider)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(T3SmallButtonStyle(kind: .ghost))
                .accessibilityIdentifier("remove-api-key")
            }
        } detail: {
            if let error { SettingsMessage(error).accessibilityIdentifier("api-key-error") }
        }
    }

    private func save() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try model.saveProviderKey(provider, key: value)
            key = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The machine providers run on. tncode runs everything on this Mac.
enum ProviderEnvironment {
    static var label: String { Host.current().localizedName ?? String(localized: "this Mac") }
}

// MARK: - Models

/// "Models" section: favorites, ordering and picker visibility for the reported and custom models.
private struct ProviderModelsSection: View {
    @ObservedObject var model: WorkspaceModel
    let provider: Provider
    let update: ((inout ProviderPreferences) -> Void) -> Void
    @State private var filter = ""
    @State private var adding = false
    @State private var input = ""
    @State private var addError: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private struct Entry: Identifiable {
        let id: String
        let name: String
        let custom: Bool
    }

    private enum Group { case favorite, visible, hidden }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let preferences = model.workspace.preferences(for: provider)
        let entries = orderedEntries(preferences)
        let builtIn = entries.filter { !$0.custom }
        let hiddenCount = builtIn.filter { preferences.hidden.contains($0.id) }.count
        let favoriteCount = entries.filter { favorites.contains($0.id) }.count
        let filtering = !filter.trimmingCharacters(in: .whitespaces).isEmpty
        let visible = filtering ? entries.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.id.localizedCaseInsensitiveContains(filter)
        } : entries
        SettingsSection("Models") {
            VStack(alignment: .leading, spacing: 0) {
                Text("Model preferences and custom models are saved in this workspace.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.bottom, 12)
                HStack(spacing: 8) {
                    if entries.count > 8 {
                        TextField("Filter models", text: $filter)
                            .frame(width: 224)
                            .accessibilityIdentifier("filter-models")
                    }
                    if !builtIn.isEmpty {
                        Button(hiddenCount == builtIn.count ? "Enable all" : "Disable all") {
                            let all = builtIn.map(\.id)
                            update { $0.hiddenModels = hiddenCount == builtIn.count ? [] : all }
                        }
                        .buttonStyle(T3SmallButtonStyle(kind: .ghost, height: 24))
                    }
                    Text(countText(total: entries.count, favorites: favoriteCount, hidden: hiddenCount))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                    Spacer(minLength: 0)
                    if !adding {
                        Button {
                            adding = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                                Text("Add custom model")
                            }
                        }
                        .buttonStyle(T3SmallButtonStyle(kind: .ghost, height: 24))
                        .padding(.trailing, -8)
                        .accessibilityIdentifier("add-custom-model")
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    if visible.isEmpty {
                        Text(filtering ? "No models match." : "No models reported for this provider yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.mutedForeground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                    }
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        let group = group(of: entry, preferences)
                        let previous = index > 0 ? visible[index - 1] : nil
                        let next = index + 1 < visible.count ? visible[index + 1] : nil
                        if previous.map({ self.group(of: $0, preferences) }) != group {
                            if group == .favorite && favoriteCount > 0 { groupLabel("Favorites", first: index == 0) }
                            if group == .visible && favoriteCount > 0 { groupLabel("All", first: index == 0) }
                            if group == .hidden { groupLabel("Hidden from picker", first: index == 0) }
                        }
                        ProviderModelRow(
                            name: entry.name, slug: entry.id, custom: entry.custom,
                            hidden: group == .hidden, favorite: group == .favorite, filtering: filtering,
                            canMoveUp: previous.map { self.group(of: $0, preferences) == group } ?? false,
                            canMoveDown: next.map { self.group(of: $0, preferences) == group } ?? false,
                            toggleFavorite: { toggleFavorite(entry.id) },
                            move: { direction in move(entry.id, by: direction, in: visible, preferences) },
                            setHidden: { hidden in
                                update { preferences in
                                    var set = preferences.hidden
                                    if hidden { set.insert(entry.id) } else { set.remove(entry.id) }
                                    preferences.hiddenModels = builtIn.map(\.id).filter(set.contains)
                                }
                            },
                            remove: {
                                update { preferences in preferences.customModels?.removeAll { $0 == entry.id } }
                                model.unfavoriteModel(identity(entry.id))
                            }
                        )
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, -8)
                if adding {
                    HStack(spacing: 8) {
                        TextField(provider.customModelPlaceholder, text: $input)
                            .onSubmit(addCustom)
                            .accessibilityIdentifier("custom-model-input")
                        Button("Add", action: addCustom)
                            .accessibilityIdentifier("custom-model-add")
                        Button("Cancel") {
                            adding = false
                            input = ""
                            addError = nil
                        }
                        .buttonStyle(T3SmallButtonStyle(kind: .ghost))
                    }
                    .padding(.top, 12)
                }
                if let addError {
                    SettingsMessage(addError).padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func groupLabel(_ title: String, first: Bool) -> some View {
        Text(localized: title)
            .font(.system(size: 11))
            .foregroundStyle(T3Palette(colorScheme, t3Themes).mutedForeground)
            .padding(.horizontal, 8)
            .padding(.top, first ? 4 : 20)
            .padding(.bottom, 6)
    }

    private func countText(total: Int, favorites: Int, hidden: Int) -> String {
        var parts = [total == 1 ? String(localized: "1 model") : String(localized: "\(total) models")]
        if favorites > 0 { parts.append(favorites == 1 ? String(localized: "1 favorite") : String(localized: "\(favorites) favorites")) }
        if hidden > 0 { parts.append(String(localized: "\(hidden) hidden")) }
        return parts.joined(separator: " · ")
    }

    private func group(of entry: Entry, _ preferences: ProviderPreferences) -> Group {
        if !entry.custom && preferences.hidden.contains(entry.id) { return .hidden }
        return favorites.contains(entry.id) ? .favorite : .visible
    }

    /// Favorites in starred order, then shown models, then hidden ones; each in the saved order, else by ID.
    private func orderedEntries(_ preferences: ProviderPreferences) -> [Entry] {
        let reported = model.reportedModels(for: provider).map { Entry(id: $0.id, name: $0.name, custom: false) }
        let known = Set(reported.map(\.id))
        let custom = (preferences.customModels ?? []).filter { !known.contains($0) }
            .map { Entry(id: $0, name: $0, custom: true) }
        let order = preferences.modelOrder ?? []
        func rank(_ entry: Entry) -> (Int, Int) {
            let group: Int = switch group(of: entry, preferences) { case .favorite: 0; case .visible: 1; case .hidden: 2 }
            let position = group == 0 ? favorites.firstIndex(of: entry.id) ?? Int.max
                : order.firstIndex(of: entry.id) ?? Int.max
            return (group, position)
        }
        return (reported + custom).enumerated().sorted { left, right in
            let l = rank(left.element), r = rank(right.element)
            return l != r ? l < r : left.offset < right.offset
        }.map(\.element)
    }

    /// Stars live in the workspace's favorites, shared with the composer's model picker.
    private var favorites: [String] { model.favoriteModelIDs(account: model.favoriteAccount(for: provider)) }

    private func identity(_ id: String) -> ModelSettings.Identity {
        ModelSettings.Identity(account: model.favoriteAccount(for: provider), model: id)
    }

    private func toggleFavorite(_ id: String) {
        model.toggleFavoriteModel(identity(id))
    }

    private func move(_ id: String, by direction: Int, in entries: [Entry], _ preferences: ProviderPreferences) {
        let group = entries.first { $0.id == id }.map { self.group(of: $0, preferences) }
        if group == .favorite {
            model.moveFavoriteModel(identity(id), by: direction)
            return
        }
        var ids = entries.filter { self.group(of: $0, preferences) == group }.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + direction) else { return }
        ids.swapAt(index, index + direction)
        update { preferences in
            let others = (preferences.modelOrder ?? []).filter { !ids.contains($0) }
            preferences.modelOrder = ids + others
        }
    }

    private func addCustom() {
        let slug = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return }
        let preferences = model.workspace.preferences(for: provider)
        if model.reportedModels(for: provider).contains(where: { $0.id == slug }) ||
            preferences.customModels?.contains(slug) == true {
            addError = String(localized: "That model is already in the list.")
            return
        }
        update { $0.customModels = ($0.customModels ?? []) + [slug] }
        input = ""
        adding = false
        addError = nil
    }
}

/// One model: favorite star, name and slug, move buttons, remove for custom models, and the picker switch.
private struct ProviderModelRow: View {
    let name: String
    let slug: String
    let custom: Bool
    let hidden: Bool
    let favorite: Bool
    let filtering: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let toggleFavorite: () -> Void
    let move: (Int) -> Void
    let setHidden: (Bool) -> Void
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        HStack(spacing: 8) {
            Button(action: toggleFavorite) {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(favorite ? palette.warning : palette.mutedForeground)
            }
            .buttonStyle(T3IconButtonStyle(size: 20))
            .help(favorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityLabel(favorite ? Text("Remove \(name) from favorites") : Text("Add \(name) to favorites"))
            .frame(width: 24)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: name)
                    .font(.system(size: 12))
                    .foregroundStyle(hidden ? palette.mutedForeground : palette.foreground.opacity(0.9))
                    .lineLimit(1)
                    .layoutPriority(1)
                if name != slug {
                    Text(verbatim: slug)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.mutedForeground.opacity(0.7))
                        .lineLimit(1)
                }
                if custom {
                    Text("custom")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.mutedForeground.opacity(0.7))
                }
            }
            .help(name == slug ? name : "\(name)\n\(slug)")
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                if !hidden && !filtering {
                    iconButton("arrow.up", help: "Move up", label: Text("Move \(name) up")) { move(-1) }
                        .disabled(!canMoveUp)
                    iconButton("arrow.down", help: "Move down", label: Text("Move \(name) down")) { move(1) }
                        .disabled(!canMoveDown)
                }
                if custom {
                    iconButton("xmark", help: "Remove custom model", label: Text("Remove \(slug)"), action: remove)
                }
            }
            Toggle("", isOn: Binding(get: { !hidden }, set: { setHidden(!$0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(palette.primary)
                .disabled(custom)
                .help(custom ? "Custom models are always shown in the picker" : hidden ? "Hidden from picker" : "Shown in picker")
                .accessibilityLabel(Text("Show \(name) in the model picker"))
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(hovering ? palette.muted.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .opacity(hidden ? 0.5 : 1)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-model-\(slug)")
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, label: Text,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(T3IconButtonStyle(size: 20))
        .help(help)
        .accessibilityLabel(label)
    }
}

// MARK: - Accent color

/// 28pt button beside the display name: "+" without a color, filled with it otherwise. Opens the color picker.
private struct ProviderAccentColorButton: View {
    let name: String
    let value: String?
    let commit: (String?) -> Void
    @State private var open = false

    var body: some View {
        let color = value.flatMap(Color.init(hexString:))
        Button { open = true } label: {
            ZStack {
                if let color {
                    RoundedRectangle(cornerRadius: 8).fill(color)
                } else {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(T3IconButtonStyle(size: 28))
        .accessibilityLabel(color == nil ? Text("Add accent color for \(name)") : Text("Change accent color for \(name)"))
        .accessibilityIdentifier("provider-accent-color")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProviderAccentColorPanel(value: value ?? "#2563eb", hasColor: value != nil) { next in
                commit(next)
            } clear: {
                commit(nil)
                open = false
            } close: {
                open = false
            }
        }
    }
}

/// Saturation and value plane, hue slider and hex field (T3 Code's ProviderCustomColorPanel), 224pt wide.
private struct ProviderAccentColorPanel: View {
    let value: String
    let hasColor: Bool
    let commit: (String) -> Void
    let clear: () -> Void
    let close: () -> Void
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0
    @State private var hex = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private var current: String { HSV(h: hue, s: saturation, v: brightness).hex }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Color(hue: hue, saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 1)
                        .position(x: saturation * geometry.size.width, y: (1 - brightness) * geometry.size.height)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    saturation = min(max(drag.location.x / geometry.size.width, 0), 1)
                    brightness = 1 - min(max(drag.location.y / geometry.size.height, 0), 1)
                    hex = current
                }.onEnded { _ in commit(current) })
            }
            .frame(height: 128)
            .accessibilityLabel("Accent color")
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map {
                            Color(hue: $0, saturation: 1, brightness: 1)
                        }, startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule())
                        Circle()
                            .fill(Color(hue: hue, saturation: 1, brightness: 1))
                            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.4), radius: 1)
                            .offset(x: hue * (geometry.size.width - 14))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        hue = min(max(drag.location.x / geometry.size.width, 0), 1)
                        hex = current
                    }.onEnded { _ in commit(current) })
                }
                .frame(height: 14)
                .accessibilityLabel("Accent color hue")
                TextField("Custom hex accent color", text: $hex)
                    .textFieldStyle(T3TextFieldStyle(height: 24))
                    .font(.system(size: 12, design: .monospaced))
                    .labelsHidden()
                    .onSubmit(applyHex)
                    .onChange(of: hex) { _, text in if HSV(hex: text) != nil, text.lowercased() != current { applyHex() } }
                if !hasColor {
                    Button("Add color") {
                        commit(current)
                        close()
                    }
                    .buttonStyle(T3SmallButtonStyle(kind: .primary, height: 24))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(12)
            if hasColor {
                Rectangle().fill(palette.border.opacity(0.6)).frame(height: 1)
                Button(action: clear) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark").font(.system(size: 11))
                        Text("Clear color")
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(T3SmallButtonStyle(kind: .ghost, height: 24))
                .padding(4)
            }
        }
        .frame(width: 224)
        .onAppear {
            let hsv = HSV(hex: value) ?? HSV(h: 0.61, s: 0.84, v: 0.92)
            hue = hsv.h
            saturation = hsv.s
            brightness = hsv.v
            hex = current
        }
    }

    private func applyHex() {
        guard let hsv = HSV(hex: hex) else { return }
        hue = hsv.h
        saturation = hsv.s
        brightness = hsv.v
        commit(current)
    }
}

/// Hue, saturation and value in 0...1, with #rrggbb conversion.
struct HSV: Equatable {
    var h: Double
    var s: Double
    var v: Double

    init(h: Double, s: Double, v: Double) {
        self.h = h
        self.s = s
        self.v = v
    }

    init?(hex: String) {
        let text = hex.trimmingCharacters(in: .whitespaces)
        guard text.count == 7, text.first == "#", let value = Int(text.dropFirst(), radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let maximum = max(r, g, b), minimum = min(r, g, b), delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        self.init(h: hue, s: maximum == 0 ? 0 : delta / maximum, v: maximum)
    }

    var hex: String {
        let c = v * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Double, Double, Double) = switch Int(h * 6) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        func byte(_ value: Double) -> Int { Int(((value + m) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}

extension Color {
    init?(hexString: String) {
        let text = hexString.trimmingCharacters(in: .whitespaces)
        guard text.count == 7, text.first == "#", let value = Int(text.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
