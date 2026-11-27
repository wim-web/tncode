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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Commit writing style")
                Spacer()
                Button("Reset Writing Style") {
                    draft.style = .repository
                    draft.customInstructions = ""
                }
                .disabled(draft.style == .repository && draft.customInstructions.isEmpty)
                .accessibilityIdentifier("reset-commit-writing-style")
            }
            Picker("Commit writing style", selection: $draft.style) {
                ForEach(CommitWritingSettings.Style.allCases, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .settingsTarget(.commitWritingStyle, focus: settingsFocus)
            if draft.style == .custom {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Custom commit writing instructions")
                    TextEditor(text: $draft.customInstructions)
                        .font(.body)
                        .frame(minHeight: 80)
                        .border(.separator)
                        .accessibilityLabel("Custom commit writing instructions")
                        .accessibilityIdentifier("commit-writing-instructions")
                }
            }
            Divider()
            Picker("Source control writer model", selection: writerAccount) {
                Text("Use active model").tag(nil as String?)
                ForEach(profiles, id: \.account) { profile in
                    Text(profile.provider == .local ? profile.endpoint : profile.provider.label)
                        .tag(Optional(profile.account))
                }
            }
            .settingsTarget(.commitWriterModel, focus: settingsFocus)
            if let writer = Binding($draft.writerModel) {
                TextField("Writer model ID", text: writer.model)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("commit-writer-model-id")
            } else {
                Text("Inherits the active thread’s model.")
                    .foregroundStyle(.secondary)
            }
            Button("Save Changes") {
                do {
                    try model.saveCommitWritingSettings(draft)
                    draft = model.commitWritingSettings
                    error = nil
                } catch let failure {
                    error = failure.localizedDescription
                }
            }
            .disabled(draft == model.commitWritingSettings)
            .accessibilityIdentifier("save-commit-writing")
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
    }
}
