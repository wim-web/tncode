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
                .sheet(item: $model.settingsRequest) { request in
                    SettingsView(model: model, appearance: appearance, browserDefaults: browserDefaults,
                                 request: request)
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
        .defaultSize(width: 1080, height: 720)
        .commands {
            WorkspaceSidebarCommands(model: model)
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
                Button("Browser Settings…") { model.openSettings(.browser) }
                    .accessibilityIdentifier("browser-settings-menu")
                    .disabled(model.showingSettings || model.showingCommandPalette)
            }
            CommandGroup(after: .help) {
                Button("Show Welcome") { model.showingWelcome = true }
                    .disabled(model.startupFailure != nil || model.operationsInProgress
                              || model.showingSettings || model.showingCommandPalette || model.projectPicker != nil)
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

    private var workspaceOpen: Bool {
        model.startupFailure == nil && !model.showingWelcome && !model.showingCommandPalette && !model.showingSettings
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") { model.openFolder() }
                .keyboardShortcut("o")
                .disabled(model.startupFailure != nil || model.operationsInProgress || model.showingCommandPalette)
            Button("New Thread") { model.sidebarCommand.send(.newThread) }
                .keyboardShortcut("n")
                .disabled(!workspaceOpen || model.operationsInProgress)
            if model.canStartScratchThread {
                Button("New Thread Without a Project", action: model.startScratchThread)
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(!workspaceOpen || model.operationsInProgress)
            }
        }
        CommandGroup(after: .pasteboard) {
            Button("Command Palette…", action: model.requestCommandPalette)
                .keyboardShortcut("k")
                .accessibilityIdentifier("open-command-palette")
                .disabled(!model.canOpenCommandPalette || model.showingCommandPalette)
            Button("Search Threads") { model.sidebarCommand.send(.search) }
                .keyboardShortcut("f")
                .disabled(!workspaceOpen)
        }
    }
}
