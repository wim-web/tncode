import SwiftUI

struct ComposerModelPicker: View {
    let options: [ComposerModelOption]
    let current: ModelSettings.Identity
    let canUseDefault: Bool
    let choose: (ComposerModelOption) -> Void
    let useDefault: () -> Void
    let openSettings: () -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var highlight: ModelSettings.Identity?
    @FocusState private var searchFocused: Bool

    var body: some View {
        let matches = options.filter { $0.matches(query) }
        let selectable = matches.filter { $0.unavailableReason == nil }
        let selected = selectable.first { $0.id == highlight } ?? selectable.first
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search models…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("composer-model-search")
                .onChange(of: query) { highlight = nil }
                .onSubmit { if let selected { choose(selected) } }
                .submitScope()
            if matches.isEmpty {
                Text("No matching models.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("composer-model-no-results")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matches) { option in
                                row(option, highlighted: searchFocused && selected?.id == option.id)
                                    .id(option.id)
                            }
                        }
                    }
                    .onChange(of: selected?.id) { _, id in
                        if let id { reader.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                if canUseDefault {
                    Button("Use Default", action: useDefault)
                        .accessibilityIdentifier("composer-model-default")
                }
                Button("Model Settings", action: openSettings)
                    .accessibilityIdentifier("composer-model-settings")
                Spacer(minLength: 0)
                Button("Close", action: close)
                    .accessibilityIdentifier("composer-model-close")
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose model")
        .accessibilityIdentifier("composer-model-picker")
        .defaultFocus($searchFocused, true)
        .onAppear { searchFocused = true }
        .background {
            WindowKeyMonitor { event, window in
                guard let key = CommandPaletteSession.Key(event),
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
                if key == .escape {
                    if !event.isARepeat { close() }
                    return true
                }
                guard searchFocused else { return false }
                switch key {
                case .up, .down:
                    if let selected, let index = selectable.firstIndex(where: { $0.id == selected.id }) {
                        let offset = key == .up ? -1 : 1
                        highlight = selectable[(index + offset + selectable.count) % selectable.count].id
                    }
                    return true
                case .select:
                    if let selected, !event.isARepeat { choose(selected) }
                    return true
                default:
                    return false
                }
            }
        }
    }

    private func row(_ option: ComposerModelOption, highlighted: Bool) -> some View {
        Button { choose(option) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).lineLimit(1)
                    Text(option.unavailableReason ?? option.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if option.unavailableReason != nil {
                    Text("Unavailable").font(.caption)
                }
                if current == option.id {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(highlighted ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(option.unavailableReason != nil)
        .accessibilityAddTraits(current == option.id ? .isSelected : [])
        .accessibilityIdentifier(option.accessibilityID)
    }
}
