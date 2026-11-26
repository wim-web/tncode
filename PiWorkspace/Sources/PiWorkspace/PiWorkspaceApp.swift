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
                let settings = try store.load().model.validated()
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
                    }
                    model.start()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.shutdown()
                }
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Project…") { model.openFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.phase.isRunning)
                Button("New Thread") { model.addConversation() }
                    .keyboardShortcut("n")
                    .disabled(model.phase.isRunning)
            }
            CommandGroup(after: .appSettings) {
                Button("Model Settings…") { model.showingSettings = true }
                    .keyboardShortcut(",")
                    .disabled(model.phase.isRunning)
            }
        }
    }
}

struct ModelSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ModelSettings
    @State private var key = ""
    @State private var removeKey = false
    @State private var error: String?

    init(model: WorkspaceModel) {
        self.model = model
        _settings = State(initialValue: model.workspace.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Model Settings").font(.title2.weight(.semibold))
            Form {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(Provider.allCases) { provider in Text(provider.label).tag(provider) }
                }
                .accessibilityIdentifier("provider")
                .onChange(of: settings.provider) { _, provider in
                    settings.model = provider.defaultModel
                    key = ""
                    removeKey = false
                }
                TextField("Model ID", text: $settings.model)
                    .accessibilityIdentifier("model-id")
                if settings.provider == .local {
                    TextField("Base URL", text: $settings.endpoint)
                        .accessibilityIdentifier("endpoint")
                    TextField("Context window", value: $settings.contextWindow, format: .number)
                    Toggle("Model supports coding tools", isOn: Binding(
                        get: { settings.localTools == true }, set: { settings.localTools = $0 }
                    ))
                }
                SecureField(model.hasKey(for: settings) ? "Replace saved API key" : "API key", text: $key)
                    .accessibilityIdentifier("key-input")
                if model.hasKey(for: settings) {
                    Toggle("Remove saved key", isOn: $removeKey)
                        .accessibilityIdentifier("remove-api-key")
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
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

    private func save() {
        do {
            try model.applySettings(settings, newKey: key, removeKey: removeKey)
            key = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
