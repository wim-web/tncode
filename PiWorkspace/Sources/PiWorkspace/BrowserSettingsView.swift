import SwiftUI

struct BrowserSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BrowserSearchSettings
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        _draft = State(initialValue: BrowserSearchSettings.load(from: defaults))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Browser Settings").font(.title2.weight(.semibold))
            Picker("Search engine", selection: $draft.engine) {
                ForEach(BrowserSearchSettings.Engine.allCases, id: \.self) { engine in
                    Text(engine.rawValue).tag(engine).accessibilityIdentifier("browser-engine-\(engine.rawValue)")
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("browser-search-engine")
            if draft.engine == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom search URL").accessibilityHidden(true)
                    TextField("Custom search URL", text: $draft.customURL,
                              prompt: Text("https://example.com/search?q=%s"))
                        .accessibilityIdentifier("browser-custom-search-url")
                    if !draft.canSave {
                        Text("Use %s for the search terms in an HTTP or HTTPS URL.")
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
        .padding(24)
        .frame(width: 460)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-settings")
    }
}
