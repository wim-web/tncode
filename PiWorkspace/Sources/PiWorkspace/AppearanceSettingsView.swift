import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @Environment(\.dismiss) private var dismiss

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
            }
            .pickerStyle(.menu)
            HStack {
                Button("Restore Defaults", action: settings.restoreDefaults)
                    .settingsTarget(.restoreAppearance, focus: settingsFocus)
                    .disabled(settings.colorScheme == .system && settings.chatWidth == .comfortable)
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
