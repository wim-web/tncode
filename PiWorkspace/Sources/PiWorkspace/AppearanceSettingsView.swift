import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance").font(.title2.weight(.semibold))
            Form {
                Picker("Color scheme", selection: $settings.colorScheme) {
                    ForEach(AppColorScheme.allCases, id: \.self) { scheme in
                        Text(scheme.rawValue.capitalized).tag(scheme)
                    }
                }
                .accessibilityIdentifier("appearance-color-scheme")
                Picker("Chat width", selection: $settings.chatWidth) {
                    ForEach(ChatWidth.allCases, id: \.self) { width in
                        Text(width.rawValue.capitalized).tag(width)
                    }
                }
                .accessibilityIdentifier("appearance-chat-width")
            }
            .pickerStyle(.menu)
            HStack {
                Button("Restore Defaults", action: settings.restoreDefaults)
                    .accessibilityIdentifier("appearance-restore-defaults")
                    .disabled(settings.colorScheme == .system && settings.chatWidth == .comfortable)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("appearance-done")
            }
        }
        .padding(24)
        .frame(width: 400)
        .onExitCommand { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance-settings")
    }
}
