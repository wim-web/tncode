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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private var palette: T3Palette { T3Palette(colorScheme, t3Themes) }

    var body: some View {
        let matches = options.filter { $0.matches(query) }
        let selectable = matches.filter { $0.unavailableReason == nil }
        let selected = selectable.first { $0.id == highlight } ?? selectable.first
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.mutedForeground.opacity(0.55))
                TextField("Search models…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .accessibilityIdentifier("composer-model-search")
                    .onChange(of: query) { highlight = nil }
                    .onSubmit { if let selected { choose(selected) } }
                    .submitScope()
            }
            .frame(height: 26)
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(searchFocused ? palette.ring : palette.border.opacity(0.7)).frame(height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            if matches.isEmpty {
                Text("No matching models.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("composer-model-no-results")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { option in
                                row(option, highlighted: searchFocused && selected?.id == option.id)
                                    .id(option.id)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .onChange(of: selected?.id) { _, id in
                        if let id { reader.scrollTo(id) }
                    }
                }
                .padding(4)
            }
            HStack(spacing: 4) {
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
            .buttonStyle(T3SmallButtonStyle(kind: .ghost, height: 24))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(alignment: .top) { Rectangle().fill(palette.border.opacity(0.7)).frame(height: 1) }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .background(palette.dropdownGlass, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.dropdownBorder).allowsHitTesting(false) }
        .shadow(color: .black.opacity(palette.isDark ? 0.8 : 0.55), radius: 22, y: 17)
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
                    Text(option.name).lineLimit(1).font(.system(size: 14)).foregroundStyle(palette.foreground)
                    Text(option.unavailableReason ?? option.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if option.unavailableReason != nil {
                    Text("Unavailable").font(.system(size: 12)).foregroundStyle(palette.mutedForeground)
                }
                if current == option.id {
                    Image(systemName: "checkmark").font(.system(size: 12)).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(highlighted ? palette.itemHighlight : current == option.id ? palette.itemSelected : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(option.unavailableReason != nil)
        .accessibilityAddTraits(current == option.id ? .isSelected : [])
        .accessibilityIdentifier(option.accessibilityID)
    }
}
