import SwiftUI

/// Settings → Source control & issues → Commits & pull requests (T3 Code's SourceControlWritingSettings).
/// Changes save as they are made; the custom instructions save when the editor loses focus.
struct CommitWritingSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    let settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var instructions: String
    @State private var error: String?
    @FocusState private var editingInstructions: Bool

    init(model: WorkspaceModel, settingsFocus: FocusState<SettingsFocus?>.Binding) {
        self.model = model
        self.settingsFocus = settingsFocus
        _instructions = State(initialValue: model.commitWritingSettings.customInstructions)
    }

    private var settings: CommitWritingSettings { model.commitWritingSettings }

    var body: some View {
        SettingsSection("Commits & pull requests") {
            SettingsRow("Commit and pull request writing", description: settings.style.summary,
                        reset: settings.style == .repository && settings.customInstructions.isEmpty ? nil :
                            SettingsResetButton("Reset commit and pull request writing to default",
                                                id: "reset-commit-writing-style") {
                                instructions = ""
                                save { $0.style = .repository; $0.customInstructions = "" }
                            }) {
                T3Select("Commit and pull request writing", selection: Binding(get: { settings.style }, set: { style in
                    save { $0.style = style }
                }), options: CommitWritingSettings.Style.allCases.map { ($0, $0.title) }, width: 224)
                    .settingsTarget(.commitWritingStyle, focus: settingsFocus)
            } detail: {
                if settings.style == .custom {
                    ZStack(alignment: .topLeading) {
                        if instructions.isEmpty {
                            Text("Keep commit subjects under 60 characters. Keep pull request descriptions short and plain.")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $instructions)
                            .font(.system(size: 14))
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .focused($editingInstructions)
                    }
                    .frame(minHeight: 92, maxHeight: 256)
                    .modifier(T3FieldChrome(height: 92))
                    .frame(maxWidth: 672, alignment: .leading)
                    .padding(.bottom, 2)
                    .onChange(of: editingInstructions) { _, editing in
                        if !editing { save { $0.customInstructions = instructions } }
                    }
                    .onDisappear { save { $0.customInstructions = instructions } }
                    .accessibilityLabel("Custom commit and pull request instructions")
                    .accessibilityIdentifier("commit-writing-instructions")
                }
                if let error { SettingsMessage(error) }
            }
            SettingsDivider()
            SettingsAdvancedGroup(targets: [.commitWriterModel]) {
                writerModelRow
            }
        }
    }

    private var writerModelRow: some View {
        // Commit messages are written through Pi, so Codex models are not offered.
        let current = settings.writerModel ?? model.workspace.model
        let options = model.defaultModelOptions(current: current).filter { $0.settings.provider != .codexAgent }
        return SettingsRow("Source control writer model",
                           description: "Model for commit messages. When disabled, use the model of the thread you commit from.") {
            if let writer = settings.writerModel {
                SettingsModelPickerButton(model: model, title: "Source control writer model", current: writer,
                                          excluded: [.codexAgent], choose: { option in
                    var next = option.settings
                    next.thinkingLevel = writer.thinkingLevel
                    save { $0.writerModel = next }
                }, chooseLevel: { level in
                    var next = writer
                    next.thinkingLevel = level == .off ? nil : level
                    save { $0.writerModel = next }
                })
                .accessibilityIdentifier("commit-writer-model")
                if writer.provider != .local {
                    ThinkingLevelPicker(level: writer.thinkingLevel ?? .off) { level in
                        var next = writer
                        next.thinkingLevel = level
                        save { $0.writerModel = next }
                    }
                }
            }
            SettingsSwitch("Use a separate source control writer model", isOn: Binding(
                get: { settings.writerModel != nil },
                set: { separate in
                    save { $0.writerModel = separate ? (options.first { $0.unavailableReason == nil }?.settings ?? current) : nil }
                }
            ))
            .settingsTarget(.commitWriterModel, focus: settingsFocus)
        }
    }

    private func save(_ change: (inout CommitWritingSettings) -> Void) {
        var next = settings
        change(&next)
        do {
            try model.saveCommitWritingSettings(next)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension CommitWritingSettings.Style {
    /// Row description for the chosen style. tncode writes commit messages only.
    var summary: String {
        switch self {
        case .repository: String(localized: "Commit messages match each project's history.")
        case .conventional: String(localized: "Conventional Commit prefixes, with short subjects and bodies.")
        case .custom: String(localized: "Your instructions shape commit messages.")
        }
    }
}
