import AppKit
import CryptoKit
import Darwin
import SwiftUI

@main
@MainActor
struct PiWorkspaceApp: App {
    @StateObject private var model: WorkspaceModel
    @State private var launched = false
    private let launchProject: URL?

    init() {
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        let override = args.firstIndex(of: "--workspace").flatMap { index in
            args.indices.contains(index + 1) ? args[index + 1] : nil
        }
        let root = override.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? URL.applicationSupportDirectory.appendingPathComponent("Pi Workspace", isDirectory: true)
        launchProject = args.firstIndex(of: "--project").flatMap { index in
            args.indices.contains(index + 1) ? URL(fileURLWithPath: args[index + 1], isDirectory: true) : nil
        }
        let service = "dev.piworkspace.model-key"
        let scope = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let keychainService = override == nil ? service : "\(service).\(scope)"
        if args.contains("--set-api-key-from-stdin") || args.contains("--remove-api-key") {
            do {
                let store = try WorkspaceStore(root: root)
                let settings = try store.load().effectiveModel.validated()
                let vault = KeyVault(service: keychainService)
                if args.contains("--remove-api-key") {
                    try vault.remove(settings.account)
                } else {
                    let input = FileHandle.standardInput.readDataToEndOfFile()
                    let key = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    try vault.save(KeyVault.validatedKey(key), account: settings.account)
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Could not update the API key.\n".utf8))
                exit(1)
            }
        }
        _model = StateObject(wrappedValue: WorkspaceModel(
            root: root, keychainService: keychainService
        ))
    }

    var body: some Scene {
        Window("Pi Workspace", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: 800, minHeight: 540)
                .onAppear {
                    guard !launched else { return }
                    launched = true
                    if let launchProject {
                        do { try model.openProject(launchProject) }
                        catch { model.error = error.localizedDescription }
                    } else { model.start() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.shutdown()
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            WorkspaceSidebarCommands(model: model)
            CommandGroup(after: .appSettings) {
                Button("Model Settings…") { model.showingSettings = true }
                    .keyboardShortcut(",")
                    .disabled(model.phase.isRunning)
            }
            CommandGroup(after: .help) {
                Button("Show Welcome") { model.showingWelcome = true }
                    .disabled(model.operationsInProgress || model.showingSettings || model.projectPicker != nil)
            }
        }
    }
}

struct WorkspaceSidebarActions {
    let newThread: (() -> Void)?
    let searchThreads: () -> Void
}

private struct WorkspaceSidebarActionsKey: FocusedValueKey {
    typealias Value = WorkspaceSidebarActions
}

extension FocusedValues {
    var sidebarActions: WorkspaceSidebarActions? {
        get { self[WorkspaceSidebarActionsKey.self] }
        set { self[WorkspaceSidebarActionsKey.self] = newValue }
    }
}

private struct WorkspaceSidebarCommands: Commands {
    @ObservedObject var model: WorkspaceModel
    @FocusedValue(\.sidebarActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { model.openFolder() }
                .keyboardShortcut("o")
                .disabled(model.operationsInProgress)
            Button("New Thread") { actions?.newThread?() }
                .keyboardShortcut("n")
                .disabled(actions?.newThread == nil)
            if model.canStartScratchThread {
                Button("New Thread Without a Project", action: model.startScratchThread)
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(model.showingWelcome || model.operationsInProgress)
            }
        }
        CommandGroup(after: .pasteboard) {
            Button("Search Threads") { actions?.searchThreads() }
                .keyboardShortcut("f")
                .disabled(actions == nil)
        }
    }
}

struct ModelSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var scope: ModelSettingsScope
    @State private var settings: ModelSettings
    @State private var key = ""
    @State private var removeKey = false
    @State private var error: String?

    init(model: WorkspaceModel) {
        self.model = model
        _scope = State(initialValue: model.project.map { .project($0.id) } ?? .workspace)
        _settings = State(initialValue: model.effectiveModel)
    }

    private var scopedProject: Project? {
        guard case .project(let id) = scope else { return nil }
        return model.projects.first { $0.id == id }
    }

    var body: some View {
        let hasKey = model.hasKey(for: settings)
        VStack(alignment: .leading, spacing: 18) {
            Text("Model Settings").font(.title2.weight(.semibold))
            Form {
                if let project = model.project {
                    Picker("Scope", selection: Binding(get: { scope }, set: selectScope)) {
                        Text("Workspace default").tag(ModelSettingsScope.workspace)
                        Text("Project: \(project.title)").tag(ModelSettingsScope.project(project.id))
                    }
                    .accessibilityIdentifier("model-settings-scope")
                }
                if let project = scopedProject {
                    Text(project.modelOverride == nil ? "Inherits Workspace default" : "Project override")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("model-settings-source")
                }
                Picker("Provider", selection: Binding(get: { settings.provider }, set: selectProvider)) {
                    ForEach(Provider.allCases) { provider in Text(provider.label).tag(provider) }
                }
                .accessibilityIdentifier("provider")
                TextField("Model ID", text: $settings.model)
                    .accessibilityIdentifier("model-id")
                if settings.provider == .local {
                    TextField("Base URL", text: Binding(get: { settings.endpoint }, set: setEndpoint))
                        .accessibilityIdentifier("endpoint")
                    TextField("Context window", value: $settings.contextWindow, format: .number)
                        .accessibilityIdentifier("context-window")
                    Toggle("Model supports coding tools", isOn: Binding(
                        get: { settings.localTools == true }, set: { settings.localTools = $0 }
                    ))
                    .accessibilityIdentifier("local-tools")
                } else {
                    Picker("Thinking level", selection: Binding(
                        get: { settings.thinkingLevel ?? .off }, set: { settings.thinkingLevel = $0 }
                    )) {
                        ForEach(ModelSettings.ThinkingLevel.allCases) { level in Text(level.label).tag(level) }
                    }
                    .accessibilityIdentifier("thinking-level")
                    .help("Pi adjusts the requested level to the model’s supported levels.")
                }
                SecureField(hasKey ? "Replace saved API key" : "API key", text: $key)
                    .accessibilityIdentifier("key-input")
                    .help("Projects using this provider share its saved API key.")
                if hasKey {
                    Toggle("Remove saved key", isOn: $removeKey)
                        .accessibilityIdentifier("remove-api-key")
                        .help("Remove the key for every project using this provider account.")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                if let project = scopedProject, project.modelOverride != nil {
                    Button("Reset to Workspace default") { reset(project.id) }
                        .accessibilityIdentifier("reset-model-override")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("save-settings")
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    private func selectScope(_ selection: ModelSettingsScope) {
        guard scope != selection else { return }
        scope = selection
        settings = scopedProject?.modelOverride ?? model.workspace.model
        clearCredentialEdit()
        error = nil
    }

    private func selectProvider(_ provider: Provider) {
        guard settings.provider != provider else { return }
        settings.provider = provider
        settings.model = provider.defaultModel
        clearCredentialEdit()
    }

    private func setEndpoint(_ endpoint: String) {
        guard settings.endpoint != endpoint else { return }
        settings.endpoint = endpoint
        clearCredentialEdit()
    }

    private func clearCredentialEdit() {
        key = ""
        removeKey = false
    }

    private func save() {
        do {
            try model.applySettings(settings, in: scope, newKey: key, removeKey: removeKey)
            clearCredentialEdit()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset(_ project: UUID) {
        do {
            try model.resetProjectModel(project)
            settings = model.workspace.model
            clearCredentialEdit()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
