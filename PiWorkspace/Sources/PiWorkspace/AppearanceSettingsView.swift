import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @AppStorage(DiffPreferences.wordWrap) private var wordWrap = DiffPreferences.defaultWordWrap

    private var isDefault: Bool {
        settings.colorScheme == .system && settings.chatWidth == .comfortable && wordWrap == DiffPreferences.defaultWordWrap
            && settings.themes == T3ThemeChoice()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            SettingsSection("Color scheme", plain: true) {
                HStack(spacing: 12) {
                    ForEach(AppColorScheme.allCases, id: \.self) { scheme in
                        AppearanceModeTile(scheme: scheme, active: settings.colorScheme == scheme) {
                            settings.colorScheme = scheme
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .settingsTarget(.colorScheme, focus: settingsFocus)
            } trailing: {
                Button {
                    settings.restoreDefaults()
                    wordWrap = DiffPreferences.defaultWordWrap
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 11))
                        Text("Restore defaults")
                    }
                }
                .buttonStyle(T3SmallButtonStyle(kind: .ghost, height: 24))
                .settingsTarget(.restoreAppearance, focus: settingsFocus)
                .disabled(isDefault)
            }
            SettingsSection("Theme", plain: true) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(T3ThemeID.allCases) { theme in
                        ThemeLibraryCard(theme: theme, lightActive: settings.lightTheme == theme,
                                         darkActive: settings.darkTheme == theme) { mode in
                            switch mode {
                            case .light: settings.lightTheme = theme
                            case .dark: settings.darkTheme = theme
                            default:
                                settings.lightTheme = theme
                                settings.darkTheme = theme
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("appearance-theme-library")
            }
            SettingsSection("Interface") {
                SettingsRow("Chat width", description: "How wide conversations and the composer can grow.") {
                    T3Select("Chat width", selection: $settings.chatWidth,
                             options: ChatWidth.allCases.map { ($0, $0.rawValue.capitalized) })
                        .settingsTarget(.chatWidth, focus: settingsFocus)
                }
            }
            SettingsSection("Typography") {
                SettingsRow("Word wrap", description: "Wrap long lines in diffs and file previews by default.",
                            reset: wordWrap == DiffPreferences.defaultWordWrap ? nil :
                                SettingsResetButton("Reset word wrapping to default", id: "reset-word-wrap") {
                                    wordWrap = DiffPreferences.defaultWordWrap
                                }) {
                    SettingsSwitch("Word wrap", isOn: $wordWrap)
                        .settingsTarget(.wordWrap, focus: settingsFocus)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance-settings")
    }
}

/// System / Light / Dark tile with a small wireframe of the workspace in that mode.
private struct AppearanceModeTile: View {
    let scheme: AppColorScheme
    let active: Bool
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @State private var hovering = false

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    switch scheme {
                    case .system:
                        HStack(spacing: 0) {
                            Wireframe(palette: T3Palette(.light, t3Themes))
                            Wireframe(palette: T3Palette(.dark, t3Themes))
                        }
                    case .light: Wireframe(palette: T3Palette(.light, t3Themes))
                    case .dark: Wireframe(palette: T3Palette(.dark, t3Themes))
                    }
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border) }
                Text(localized: scheme.rawValue.capitalized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? palette.foreground : palette.mutedForeground)
                    .padding(.horizontal, 2)
            }
            .padding(8)
            .background(active ? palette.accentFill.opacity(0.3) : palette.card.opacity(hovering ? 0.9 : 0.6),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(palette.primary, lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border.opacity(0.7))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(localized: scheme.rawValue.capitalized))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("appearance-color-scheme-\(scheme.rawValue)")
    }

    private struct Wireframe: View {
        let palette: T3Palette

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index == 0 ? palette.rowActive : palette.foreground.opacity(0.08))
                            .frame(height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: 52)
                .frame(maxHeight: .infinity)
                .background(palette.sidebar)
                .overlay(alignment: .trailing) { Rectangle().fill(palette.border).frame(width: 1) }
                VStack(alignment: .trailing, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).fill(palette.userBubble).frame(width: 46, height: 12)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach([0.9, 0.7, 0.8], id: \.self) { fraction in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(palette.foreground.opacity(0.12))
                                .frame(height: 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .scaleEffect(x: fraction, anchor: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(palette.card)
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(palette.composerBorder) }
                        .frame(height: 22)
                        .overlay(alignment: .trailing) {
                            Circle().fill(palette.primary).frame(width: 10, height: 10).padding(.trailing, 5)
                        }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.canvas)
            }
        }
    }
}

/// Theme library card: light and dark swatches on top (each applies the theme to that mode), name below.
private struct ThemeLibraryCard: View {
    let theme: T3ThemeID
    let lightActive: Bool
    let darkActive: Bool
    /// nil applies the theme to both modes.
    let use: (ColorScheme?) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @State private var hovering = false

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let active = lightActive || darkActive
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 40) {
                swatch(.light, active: lightActive)
                swatch(.dark, active: darkActive)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            Button { use(nil) } label: {
                HStack(spacing: 6) {
                    Text(theme.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if active {
                        Text(lightActive && darkActive ? "Light & Dark" : lightActive ? "Light" : "Dark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(palette.muted, in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(active ? "Use \(theme.label) theme, currently active" : "Use \(theme.label) theme")
            .accessibilityIdentifier("appearance-theme-\(theme.rawValue)")
        }
        .background(active ? palette.accentFill.opacity(0.3) : palette.card.opacity(hovering ? 0.9 : 0.6),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(active ? palette.ring : palette.border.opacity(0.7), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
    }

    private func swatch(_ mode: ColorScheme, active: Bool) -> some View {
        let preview = T3Palette(mode, T3ThemeChoice(light: theme, dark: theme))
        let palette = T3Palette(colorScheme, t3Themes)
        return Button { use(mode) } label: {
            ZStack {
                Circle().fill(preview.canvas)
                HStack(spacing: 0) {
                    Rectangle().fill(preview.sidebar).frame(width: 18)
                    VStack(alignment: .trailing, spacing: 5) {
                        Capsule().fill(preview.userBubble).frame(width: 16, height: 6)
                        Capsule().fill(preview.foreground.opacity(0.35)).frame(width: 20, height: 3)
                        Circle().fill(preview.primary).frame(width: 9, height: 9)
                    }
                    .frame(maxWidth: .infinity)
                }
                .clipShape(Circle())
                Circle().strokeBorder(preview.border)
                if active {
                    Circle().strokeBorder(palette.ring, lineWidth: 2)
                }
            }
            .frame(width: 56, height: 56)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: mode == .light ? "sun.max.fill" : "moon.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(palette.foreground)
                    .frame(width: 16, height: 16)
                    .background(palette.canvas, in: Circle())
                    .overlay { Circle().strokeBorder(palette.border.opacity(0.7)) }
                    .offset(x: 2, y: 2)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(mode == .light ? "Light: \(theme.label)" : "Dark: \(theme.label)")
        .accessibilityLabel(mode == .light ? "Use \(theme.label) in light mode" : "Use \(theme.label) in dark mode")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("appearance-theme-\(theme.rawValue)-\(mode == .light ? "light" : "dark")")
    }
}
