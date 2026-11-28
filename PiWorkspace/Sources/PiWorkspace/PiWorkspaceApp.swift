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
    @State private var openingURL: UUID?
    @State private var showWelcomeAfterSettings = false
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
                guard settings.provider != .codexAgent, settings.provider.piProviderID == nil else {
                    throw WorkspaceError("Pi manages this login.")
                }
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
                    WorkspaceStartupRecoveryView(model: model, failure: failure, pasteboard: workspacePasteboard)
                } else {
                    WorkspaceView(model: model, chatWidthMode: appearance.chatWidth, browserDefaults: browserDefaults, workspacePasteboard: workspacePasteboard)
                        .onReceive(appDelegate.$finishedLaunching.first(where: { $0 })) { _ in
                            launchWorkspace()
                        }
                }
            }
                .handlesExternalEvents(preferring: [ThreadLink.scheme], allowing: [])
                .onOpenURL { url in
                    if model.openSettingsLink(url) || model.openPromptLink(url) {
                        launchWorkspace()
                        return
                    }
                    let request = UUID()
                    openingURL = request
                    Task {
                        let opened = await model.openThreadLink(url.absoluteString)
                        guard request == openingURL else { return }
                        openingURL = nil
                        if opened { launched = true } else { launchWorkspace() }
                    }
                }
                .safeAreaInset(edge: .top) {
                    if let error = model.threadLinkError {
                        HStack {
                            Text(error)
                                .accessibilityIdentifier("thread-link-error")
                            Spacer()
                            Button("Dismiss") { model.threadLinkError = nil }
                        }
                        .padding(8)
                        .background(.bar)
                    }
                }
                .sheet(item: $model.settingsRequest, onDismiss: {
                    guard showWelcomeAfterSettings else { return }
                    showWelcomeAfterSettings = false
                    model.openWelcome()
                }) { request in
                    SettingsView(model: model, appearance: appearance, browserDefaults: browserDefaults,
                                 request: request, pasteboard: workspacePasteboard) {
                        showWelcomeAfterSettings = true
                        model.settingsRequest = nil
                    }
                    .defaultAppStorage(browserDefaults)
                }
                .defaultAppStorage(browserDefaults)
                .alert(model.quitFileSaveError == nil ? "Your draft couldn’t be saved" : "A file couldn’t be saved",
                       isPresented: $model.showingQuitSaveFailure) {
                    Button("Keep Editing", role: .cancel) {}
                        .accessibilityIdentifier("keep-editing-draft")
                    Button("Retry and Quit") { NSApp.terminate(nil) }
                        .accessibilityIdentifier("retry-save-and-quit")
                } message: {
                    Text(model.quitFileSaveError ?? model.composerSaveError ?? "Restore write access to the workspace and try again.")
                }
                .onChange(of: appearance.colorScheme, initial: true) { _, scheme in
                    scheme.apply(to: NSApplication.shared)
                }
                .frame(minWidth: 800, minHeight: 540)
        }
        .handlesExternalEvents(matching: [ThreadLink.scheme])
        .defaultSize(width: 1080, height: 720)
        .commands {
            WorkspaceSidebarCommands(model: model, workspacePasteboard: workspacePasteboard)
            CommandGroup(replacing: .appInfo) {
                Button("About \(AboutInfo().name)") { openWindow(id: AboutView.windowID) }
                    .accessibilityIdentifier("about-menu")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.openSettings() }
                    .keyboardShortcut(",")
                    .accessibilityIdentifier("settings-menu")
                    .disabled(model.showingSettings || model.showingCommandPalette)
                Button("Model Settings…") { model.openSettings(.model) }
                    .accessibilityIdentifier("model-settings-menu")
                    .disabled(!model.canOpenModelSettings || model.showingSettings || model.showingCommandPalette)
                Button("Appearance Settings…") { model.openSettings(.appearance) }
                    .accessibilityIdentifier("appearance-settings-menu")
                    .disabled(model.showingSettings || model.showingCommandPalette)
                Button("Usage…") { model.openSettings(.usage) }
                    .accessibilityIdentifier("usage-menu")
                    .disabled(model.startupFailure != nil || model.showingSettings || model.showingCommandPalette)
                Button("Browser Settings…") { model.openSettings(.browser) }
                    .accessibilityIdentifier("browser-settings-menu")
                    .disabled(model.showingSettings || model.showingCommandPalette)
            }
            CommandGroup(after: .help) {
                Button("Show Welcome", action: model.openWelcome)
                    .accessibilityIdentifier("show-welcome-menu")
                    .disabled(!model.canOpenWelcome || model.showingSettings || model.showingWelcome)
            }
        }

        Window("About \(AboutInfo().name)", id: AboutView.windowID) {
            AboutWindow()
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }

    private func launchWorkspace() {
        guard !launched, openingURL == nil else { return }
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
    @Published private(set) var finishedLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI can present the window before routing the URL that launched it.
        finishedLaunching = true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.savePendingEditsForQuit() else {
            model.showingQuitSaveFailure = true
            return .terminateCancel
        }
        guard let clone = model.cancelProjectCloneForQuit() else { return .terminateNow }
        Task {
            _ = await clone.result
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.terminate()
    }
}

private struct WorkspaceSidebarCommands: Commands {
    @ObservedObject var model: WorkspaceModel
    let workspacePasteboard: NSPasteboard
    @FocusedValue(\.editingComposer) private var editingComposer

    private var workspaceOpen: Bool {
        model.startupFailure == nil && !model.showingWelcome && !model.showingCommandPalette && !model.showingSettings
            && model.projectPicker == nil && !model.showingQuitSaveFailure
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { model.openFolder() }
                .keyboardShortcut("o")
                .accessibilityIdentifier("add-project-menu")
                .disabled(model.startupFailure != nil || model.operationsInProgress || model.showingCommandPalette
                          || model.showingSettings || model.projectPicker != nil)
            Button("New Thread") { model.sidebarCommand.send(.newThread) }
                .accessibilityIdentifier("new-thread-menu")
                .disabled(!workspaceOpen || model.operationsInProgress)
            if model.canStartScratchThread {
                Button("New Thread Without a Project") { model.sidebarCommand.send(.newScratchThread) }
                    .accessibilityIdentifier("new-thread-without-project-menu")
                    .disabled(!workspaceOpen || model.operationsInProgress)
            }
        }
        CommandGroup(after: .pasteboard) {
            Button("Paste and Match Style") {
                NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(editingComposer != true)
            Button("Open Thread Link from Clipboard") {
                Task { await model.openThreadLink(from: workspacePasteboard) }
            }
                .help("Open a thread or draft link from the clipboard")
                .accessibilityIdentifier("open-thread-link-from-clipboard")
                .disabled(!workspaceOpen || model.projectPicker != nil)
            Button("Command Palette…", action: model.requestCommandPalette)
                .keyboardShortcut("k")
                .accessibilityIdentifier("open-command-palette")
                .disabled(!model.canOpenCommandPalette || model.showingCommandPalette)
            Button("Search Threads") { model.sidebarCommand.send(.search) }
                .disabled(!workspaceOpen)
        }
    }
}
