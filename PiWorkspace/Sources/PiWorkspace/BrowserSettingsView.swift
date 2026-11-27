import SwiftUI

struct BrowserSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let defaults: UserDefaults
    @Binding var draft: BrowserSearchSettings
    var settingsFocus: FocusState<SettingsFocus?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Search engine", selection: $draft.engine) {
                    ForEach(BrowserSearchSettings.Engine.allCases, id: \.self) { engine in
                        Text(engine.rawValue).tag(engine).accessibilityIdentifier("browser-engine-\(engine.rawValue)")
                    }
                }
                .pickerStyle(.menu)
                .settingsTarget(.searchEngine, focus: settingsFocus)
                if draft != BrowserSearchSettings() {
                    Button("Reset") {
                        draft = BrowserSearchSettings()
                        draft.save(to: defaults)
                    }
                    .accessibilityLabel("Reset search engine to default")
                    .accessibilityIdentifier("reset-browser-search-engine")
                }
            }
            if draft.engine == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom search URL").accessibilityHidden(true)
                    TextField("Custom search URL", text: $draft.customURL,
                              prompt: Text("https://example.com/search?q=%s"))
                        .settingsTarget(.customSearchURL, focus: settingsFocus)
                    if let issue = draft.templateIssue {
                        Text(issue.rawValue)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("browser-search-url-validation")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("browser-settings-cancel")
                Button("Save") {
                    if draft.save(to: defaults) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("browser-settings-save")
                .disabled(!draft.canSave)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-settings")
    }
}
