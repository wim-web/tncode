import SwiftUI

/// Settings → Browser (T3 Code's BrowserSettingsPanel, Browsing section). The engine saves when chosen; the
/// custom URL saves on Return or when the field loses focus.
struct BrowserSettingsView: View {
    let defaults: UserDefaults
    @Binding var draft: BrowserSearchSettings
    var settingsFocus: FocusState<SettingsFocus?>.Binding

    var body: some View {
        SettingsSection("Browsing") {
            SettingsRow("Search engine", description: "What the address bar searches when you type something that isn't a URL.",
                        reset: draft == BrowserSearchSettings() ? nil :
                            SettingsResetButton("Reset search engine to default", id: "reset-browser-search-engine") {
                                draft = BrowserSearchSettings()
                                draft.save(to: defaults)
                            }) {
                T3Select("Search engine", selection: Binding(get: { draft.engine }, set: { engine in
                    draft.engine = engine
                    draft.save(to: defaults)
                }), options: BrowserSearchSettings.Engine.allCases.map { ($0, $0.rawValue) })
                    .settingsTarget(.searchEngine, focus: settingsFocus)
            }
            if draft.engine == .custom {
                SettingsDivider()
                SettingsRow("Custom search URL", description: "Use %s where the search terms go.",
                            status: draft.templateIssue?.rawValue) {
                    SettingsDraftField("Custom search URL", value: draft.customURL,
                                       placeholder: "https://example.com/search?q=%s", width: 256,
                                       target: (.customSearchURL, settingsFocus)) { value in
                        draft.customURL = String(value.trimmingCharacters(in: .whitespacesAndNewlines)
                            .prefix(BrowserSearchSettings.maximumTemplateLength))
                        draft.save(to: defaults)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-settings")
    }
}
