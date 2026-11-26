import AppKit
import CryptoKit
import Darwin
import SwiftUI

@main
@MainActor
struct PiWorkspaceApp: App {
    @NSApplicationDelegateAdaptor(WorkspaceApplicationDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model: WorkspaceModel
    @StateObject private var appearance: AppearanceSettings
    @State private var launched = false
    @State private var showingBrowserSettings = false
    @State private var showingAppearanceSettings = false
    private let browserDefaults: UserDefaults
    private let workspacePasteboard: NSPasteboard
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
        browserDefaults = override.flatMap { _ in UserDefaults(suiteName: "dev.piworkspace.browser.\(scope)") } ?? .standard
        if override != nil, let name = ProcessInfo.processInfo.environment["PI_WORKSPACE_TEST_PASTEBOARD"],
           name.hasPrefix("dev.piworkspace.verification.") {
            workspacePasteboard = NSPasteboard(name: .init(name))
        } else {
            workspacePasteboard = .general
        }
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
        let model = WorkspaceModel(root: root, keychainService: keychainService)
        _model = StateObject(wrappedValue: model)
        let appearanceDefaults = override == nil ? .standard : UserDefaults(suiteName: "dev.piworkspace.appearance.\(scope)")
        _appearance = StateObject(wrappedValue: AppearanceSettings(defaults: appearanceDefaults))
        appDelegate.model = model
    }

    var body: some Scene {
        Window("Pi Workspace", id: "workspace") {
            Group {
                if let failure = model.startupFailure {
                    WorkspaceStartupRecoveryView(model: model, failure: failure)
                } else {
                    WorkspaceView(model: model, chatWidthMode: appearance.chatWidth, browserDefaults: browserDefaults, workspacePasteboard: workspacePasteboard)
                        .onAppear(perform: launchWorkspace)
                }
            }
                .sheet(isPresented: $showingBrowserSettings) { BrowserSettingsView(defaults: browserDefaults) }
                .sheet(isPresented: $showingAppearanceSettings) { AppearanceSettingsView(settings: appearance) }
                .alert("Your draft couldn’t be saved", isPresented: $model.showingQuitSaveFailure) {
                    Button("Keep Editing", role: .cancel) {}
                        .accessibilityIdentifier("keep-editing-draft")
                    Button("Retry and Quit") { NSApp.terminate(nil) }
                        .accessibilityIdentifier("retry-save-and-quit")
                } message: {
                    Text(model.composerSaveError ?? "Restore write access to the workspace and try again.")
                }
                .onChange(of: appearance.colorScheme, initial: true) { _, scheme in
                    scheme.apply(to: NSApplication.shared)
                }
                .frame(minWidth: 800, minHeight: 540)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            WorkspaceSidebarCommands(model: model)
            CommandGroup(replacing: .appInfo) {
                Button("About \(AboutInfo().name)") { openWindow(id: AboutView.windowID) }
                    .accessibilityIdentifier("about-menu")
            }
            CommandGroup(after: .appSettings) {
                Button("Model Settings…") { model.showingSettings = true }
                    .keyboardShortcut(",")
                    .disabled(model.startupFailure != nil || model.phase.isRunning
                              || showingBrowserSettings || showingAppearanceSettings)
                Button("Appearance Settings…") { showingAppearanceSettings = true }
                    .accessibilityIdentifier("appearance-settings-menu")
                    .disabled(model.showingSettings || showingBrowserSettings || showingAppearanceSettings)
                Button("Browser Settings…") { showingBrowserSettings = true }
                    .accessibilityIdentifier("browser-settings-menu")
                    .disabled(model.showingSettings || showingBrowserSettings || showingAppearanceSettings)
            }
            CommandGroup(after: .help) {
                Button("Show Welcome") { model.showingWelcome = true }
                    .disabled(model.startupFailure != nil || model.operationsInProgress
                              || model.showingSettings || model.projectPicker != nil)
            }
        }

        Window("About \(AboutInfo().name)", id: AboutView.windowID) {
            AboutView()
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }

    private func launchWorkspace() {
        guard !launched else { return }
        launched = true
        if let launchProject {
            do { try model.openProject(launchProject) }
            catch { model.error = error.localizedDescription }
        } else { model.start() }
    }
}

@MainActor
final class WorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, !model.savePendingComposer() else { return .terminateNow }
        model.showingQuitSaveFailure = true
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.terminate()
    }
}

private struct WorkspaceSidebarCommands: Commands {
    @ObservedObject var model: WorkspaceModel

    private var workspaceOpen: Bool { model.startupFailure == nil && !model.showingWelcome }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { model.openFolder() }
                .keyboardShortcut("o")
                .disabled(model.startupFailure != nil || model.operationsInProgress)
            Button("New Thread") { model.sidebarCommand.send(.newThread) }
                .keyboardShortcut("n")
                .disabled(!workspaceOpen || model.operationsInProgress)
            if model.canStartScratchThread {
                Button("New Thread Without a Project", action: model.startScratchThread)
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(model.showingWelcome || model.operationsInProgress)
            }
        }
        CommandGroup(after: .pasteboard) {
            Button("Search Threads") { model.sidebarCommand.send(.search) }
                .keyboardShortcut("f")
                .disabled(!workspaceOpen)
        }
    }
}

struct ModelSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var scope: ModelSettingsScope
    @State private var settings: ModelSettings
    @State private var key = ""
    @State private var removeKey = false
    @State private var error: String?
    private let projectID: UUID?

    init(model: WorkspaceModel, projectID: UUID? = nil) {
        self.model = model
        let project = projectID.flatMap { id in model.projects.first { $0.id == id } } ?? model.project
        self.projectID = project?.isScratch == false ? project?.id : nil
        _scope = State(initialValue: self.projectID.map { .project($0) } ?? .workspace)
        _settings = State(initialValue: project?.modelOverride ?? model.workspace.model)
    }

    private var scopedProject: Project? {
        guard case .project(let id) = scope else { return nil }
        return model.projects.first { $0.id == id }
    }

    var body: some View {
        let hasKey = model.hasKey(for: settings)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Model Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("About") { openWindow(id: AboutView.windowID) }
                    .accessibilityIdentifier("settings-about")
            }
            Form {
                if let project = model.projects.first(where: { $0.id == projectID }) {
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
