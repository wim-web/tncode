import SwiftUI

struct BrowserSettingsView: View {
    @Environment(\.closeSettings) private var dismiss
    let defaults: UserDefaults
    @Binding var draft: BrowserSearchSettings
    var settingsFocus: FocusState<SettingsFocus?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection("Browsing") {
                SettingsRow("Search engine", description: "Used when you type words instead of an address.",
                            reset: draft == BrowserSearchSettings() ? nil :
                                SettingsResetButton("Reset search engine to default", id: "reset-browser-search-engine") {
                                    draft = BrowserSearchSettings()
                                    draft.save(to: defaults)
                                }) {
                    T3Select("Search engine", selection: $draft.engine,
                             options: BrowserSearchSettings.Engine.allCases.map { ($0, $0.rawValue) })
                        .settingsTarget(.searchEngine, focus: settingsFocus)
                }
                if draft.engine == .custom {
                    SettingsDivider()
                    SettingsRow("Custom search URL", description: "Use %s where the search terms go.",
                                status: draft.templateIssue?.rawValue) {
                        TextField("Custom search URL", text: $draft.customURL,
                                  prompt: Text("https://example.com/search?q=%s"))
                            .labelsHidden()
                            .frame(width: 256)
                            .settingsTarget(.customSearchURL, focus: settingsFocus)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("browser-settings-cancel")
                Button("Save") {
                    if draft.save(to: defaults) { dismiss() }
                }
                .buttonStyle(T3SmallButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("browser-settings-save")
                .disabled(!draft.canSave)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-settings")
    }
}
