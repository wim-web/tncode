import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DiffPreferences.wordWrap) private var wordWrap = DiffPreferences.defaultWordWrap

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Picker("Color scheme", selection: $settings.colorScheme) {
                    ForEach(AppColorScheme.allCases, id: \.self) { scheme in
                        Text(scheme.rawValue.capitalized).tag(scheme)
                    }
                }
                .settingsTarget(.colorScheme, focus: settingsFocus)
                Picker("Chat width", selection: $settings.chatWidth) {
                    ForEach(ChatWidth.allCases, id: \.self) { width in
                        Text(width.rawValue.capitalized).tag(width)
                    }
                }
                .settingsTarget(.chatWidth, focus: settingsFocus)
                HStack {
                    Toggle("Word wrap", isOn: $wordWrap)
                        .help("Wrap long lines in diffs and file previews by default.")
                        .settingsTarget(.wordWrap, focus: settingsFocus)
                    if wordWrap != DiffPreferences.defaultWordWrap {
                        Button("Reset") { wordWrap = DiffPreferences.defaultWordWrap }
                            .accessibilityLabel("Reset word wrapping to default")
                            .accessibilityIdentifier("reset-word-wrap")
                    }
                }
            }
            .pickerStyle(.menu)
            HStack {
                Button("Restore Defaults") {
                    settings.restoreDefaults()
                    wordWrap = DiffPreferences.defaultWordWrap
                }
                .settingsTarget(.restoreAppearance, focus: settingsFocus)
                .disabled(settings.colorScheme == .system && settings.chatWidth == .comfortable
                          && wordWrap == DiffPreferences.defaultWordWrap)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("appearance-done")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance-settings")
    }
}
