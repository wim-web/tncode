import SwiftUI

struct CommitWritingSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    let settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var draft: CommitWritingSettings
    @State private var error: String?

    init(model: WorkspaceModel, settingsFocus: FocusState<SettingsFocus?>.Binding) {
        self.model = model
        self.settingsFocus = settingsFocus
        _draft = State(initialValue: model.commitWritingSettings)
    }

    private var profiles: [ModelSettings] {
        var accounts = Set<String>()
        let settings = [model.effectiveModel, model.project?.modelOverride, model.workspace.model,
                        model.commitWritingSettings.writerModel, draft.writerModel]
        return settings.compactMap { $0 }.compactMap { try? $0.validated() }
            .filter { accounts.insert($0.account).inserted }
    }

    private var writerAccount: Binding<String?> {
        Binding(get: { draft.writerModel?.account }, set: { account in
            draft.writerModel = profiles.first { $0.account == account }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection("Commits & pull requests") {
                SettingsRow("Commit and pull request writing",
                            description: "How Pi writes generated commit subjects and bodies.",
                            reset: draft.style == .repository && draft.customInstructions.isEmpty ? nil :
                                SettingsResetButton("Reset Writing Style", id: "reset-commit-writing-style") {
                                    draft.style = .repository
                                    draft.customInstructions = ""
                                }) {
                    T3Select("Commit writing style", selection: $draft.style,
                             options: CommitWritingSettings.Style.allCases.map { ($0, $0.title) }, width: 224)
                        .settingsTarget(.commitWritingStyle, focus: settingsFocus)
                } detail: {
                    if draft.style == .custom {
                        TextEditor(text: $draft.customInstructions)
                            .font(.system(size: 14))
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .frame(minHeight: 92, maxHeight: 256)
                            .modifier(T3FieldChrome(height: 92))
                            .frame(maxWidth: 672, alignment: .leading)
                            .accessibilityLabel("Custom commit writing instructions")
                            .accessibilityIdentifier("commit-writing-instructions")
                    }
                }
                SettingsDivider()
                SettingsRow("Source control writer model",
                            description: draft.writerModel == nil ? "Inherits the active thread’s model." : nil) {
                    T3Select("Source control writer model", selection: writerAccount,
                             options: [(nil as String?, "Use active model")] + profiles.map {
                                 (Optional($0.account), $0.provider == .local ? $0.endpoint : $0.provider.label)
                             }, width: 224)
                        .settingsTarget(.commitWriterModel, focus: settingsFocus)
                } detail: {
                    if let writer = Binding($draft.writerModel) {
                        TextField("Writer model ID", text: writer.model)
                            .frame(width: 256)
                            .accessibilityIdentifier("commit-writer-model-id")
                    }
                }
            }
            HStack(spacing: 8) {
                if let error { SettingsMessage(error) }
                Spacer()
                Button("Save Changes") {
                    do {
                        try model.saveCommitWritingSettings(draft)
                        draft = model.commitWritingSettings
                        error = nil
                    } catch let failure {
                        error = failure.localizedDescription
                    }
                }
                .buttonStyle(T3SmallButtonStyle(kind: .primary))
                .disabled(draft == model.commitWritingSettings)
                .accessibilityIdentifier("save-commit-writing")
            }
        }
    }
}
