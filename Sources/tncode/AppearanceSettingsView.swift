import SwiftUI

/// Settings → Appearance (T3 Code's AppearanceSettingsPanel): the theme library under one untitled section,
/// then Interface and Typography.
struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings
    var settingsFocus: FocusState<SettingsFocus?>.Binding
    @AppStorage(DiffPreferences.wordWrap) private var wordWrap = DiffPreferences.defaultWordWrap
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        VStack(alignment: .leading, spacing: 32) {
            // "Colors & themes": its title is for screen readers only.
            VStack(alignment: .leading, spacing: 12) {
                heading("Color scheme")
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    ForEach(AppColorScheme.allCases, id: \.self) { scheme in
                        AppearanceModeTile(scheme: scheme, active: settings.colorScheme == scheme,
                                           themes: settings.themes) {
                            settings.colorScheme = scheme
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Appearance mode")
                .settingsTarget(.colorScheme, focus: settingsFocus)
                heading("Themes")
                    .padding(.top, 20)
                    .frame(minHeight: 32)
                    .settingsTarget(.theme, focus: settingsFocus)
                ThemeGrid(settings: settings)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Colors & themes")
            SettingsSection("Interface") {
                SettingsRow("Chat width", description: "Set how wide messages and the composer can grow on large screens.",
                            reset: settings.chatWidth == .comfortable ? nil :
                                SettingsResetButton("Reset chat width to default", id: "reset-chat-width") {
                                    settings.chatWidth = .comfortable
                                }) {
                    T3Select("Chat width", selection: $settings.chatWidth,
                             options: ChatWidth.allCases.map { ($0, $0.title) }, defaultValue: .comfortable)
                        .settingsTarget(.chatWidth, focus: settingsFocus)
                }
            }
            SettingsSection("Typography") {
                SettingsRow("Word wrap", description: "Wrap long lines in code blocks, diffs, and file previews by default.",
                            reset: wordWrap == DiffPreferences.defaultWordWrap ? nil :
                                SettingsResetButton("Reset word wrapping to default", id: "reset-word-wrap") {
                                    wordWrap = DiffPreferences.defaultWordWrap
                                }) {
                    SettingsSwitch("Wrap code, diffs, and file previews by default", isOn: $wordWrap)
                        .settingsTarget(.wordWrap, focus: settingsFocus)
                }
            }
        }
        .foregroundStyle(palette.foreground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance-settings")
    }

    private func heading(_ title: String) -> some View {
        Text(localized: title)
            .font(.system(size: 16, weight: .semibold))
            .frame(minHeight: 28)
            .padding(.horizontal, 16)
    }
}

extension ChatWidth {
    var title: String {
        switch self {
        case .comfortable: String(localized: "Comfortable")
        case .wide: String(localized: "Wide")
        case .full: String(localized: "Full")
        }
    }
}

/// The seven preview roles a theme card and wireframe draw with (packages/shared/src/themePreview.ts).
struct ThemePreviewColors {
    let sidebar: Color
    let canvas: Color
    let surface: Color
    let accentSurface: Color
    let accent: Color
    let messageSurface: Color
    let messageAction: Color

    init(theme: T3ThemeID, dark: Bool) {
        if let c = theme.colors(dark: dark) {
            self.init(sidebar: c.sidebar, canvas: c.canvas, surface: c.surface, accentSurface: c.accentSurface,
                      accent: c.accent, messageSurface: c.messageSurface, messageAction: c.messageAction)
        } else if dark {
            self.init(sidebar: Color(hex: 0x0F0F10), canvas: Color(hex: 0x0A0A0A), surface: Color(hex: 0x121212),
                      accentSurface: Color(hex: 0x27272A), accent: Color(hex: 0x1C1C1F),
                      messageSurface: Color(hex: 0x27272A), messageAction: Color(hex: 0x8B9CFF))
        } else {
            self.init(sidebar: Color(hex: 0xFAFAFA), canvas: Color(hex: 0xFCFCFC), surface: Color(hex: 0xFFFFFF),
                      accentSurface: Color(hex: 0xF4F4F5), accent: Color(hex: 0xF4F4F5),
                      messageSurface: Color(hex: 0xE4E4E7), messageAction: Color(hex: 0x4F46E5))
        }
    }

    private init(sidebar: Color, canvas: Color, surface: Color, accentSurface: Color, accent: Color,
                 messageSurface: Color, messageAction: Color) {
        self.sidebar = sidebar
        self.canvas = canvas
        self.surface = surface
        self.accentSurface = accentSurface
        self.accent = accent
        self.messageSurface = messageSurface
        self.messageAction = messageAction
    }
}

/// System / Light / Dark tile: a 140pt wireframe of the theme for that mode and a centered label.
private struct AppearanceModeTile: View {
    let scheme: AppColorScheme
    let active: Bool
    let themes: T3ThemeChoice
    let select: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @State private var hovering = false

    private var label: String {
        switch scheme {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    private var accessibility: String {
        switch scheme {
        case .system: String(localized: "Follow the system appearance")
        case .light: String(localized: "Use light mode")
        case .dark: String(localized: "Use dark mode")
        }
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        Button(action: select) {
            VStack(spacing: 6) {
                ZStack {
                    switch scheme {
                    case .system:
                        // One wireframe split down the middle with a 2pt gap.
                        GeometryReader { geometry in
                            let half = geometry.size.width / 2
                            ThemeWireframe(colors: ThemePreviewColors(theme: themes.light, dark: false))
                                .mask(alignment: .leading) { Rectangle().frame(width: max(0, half - 1)) }
                            ThemeWireframe(colors: ThemePreviewColors(theme: themes.dark, dark: true))
                                .mask(alignment: .trailing) { Rectangle().frame(width: max(0, half - 1)) }
                        }
                    case .light: ThemeWireframe(colors: ThemePreviewColors(theme: themes.light, dark: false))
                    case .dark: ThemeWireframe(colors: ThemePreviewColors(theme: themes.dark, dark: true))
                    }
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border.opacity(0.6)) }
                Text(verbatim: label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? palette.foreground : palette.mutedForeground)
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
            .background(active ? palette.accentFill.opacity(0.3)
                               : hovering ? palette.accentFill.opacity(0.1) : palette.card.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(palette.ring, lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border.opacity(0.7))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(verbatim: accessibility))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("appearance-color-scheme-\(scheme.rawValue)")
    }
}

/// T3 Code's ThemeWireframe: sidebar with four items, a message bubble, two text lines, the composer and a
/// floating panel, all placed by percentage of the box.
private struct ThemeWireframe: View {
    let colors: ThemePreviewColors
    private let line = Color(red: 127 / 255, green: 127 / 255, blue: 127 / 255).opacity(0.25)

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack(alignment: .topLeading) {
                colors.canvas
                colors.sidebar
                    .frame(width: w * 0.22, height: h)
                    .overlay(alignment: .trailing) { line.frame(width: 1) }
                box(x: 0.03, y: 0.08, width: 0.16, height: 0.08, radius: 6, fill: colors.surface, stroke: true, in: geometry.size)
                box(x: 0.03, y: 0.22, width: 0.16, height: 0.07, radius: 6, fill: colors.accentSurface, in: geometry.size)
                box(x: 0.03, y: 0.32, width: 0.16, height: 0.07, radius: 6, fill: colors.messageSurface.opacity(0.7), in: geometry.size)
                box(x: 0.03, y: 0.42, width: 0.16, height: 0.07, radius: 6, fill: colors.messageSurface.opacity(0.5), in: geometry.size)
                box(x: 1 - 0.28 - 0.24, y: 0.11, width: 0.24, height: 0.09, radius: 8, fill: colors.messageSurface, in: geometry.size)
                box(x: 0.27, y: 0.28, width: 0.34, height: 0.05, radius: 4, fill: line, in: geometry.size)
                box(x: 0.27, y: 0.38, width: 0.26, height: 0.05, radius: 4, fill: line, in: geometry.size)
                // Composer: bottom 8%, left 26%, right 6%, 15% tall.
                let composer = CGSize(width: w * (1 - 0.26 - 0.06), height: h * 0.15)
                HStack {
                    Capsule().fill(line.opacity(0.7)).frame(width: composer.width * 0.34, height: composer.height * 0.26)
                    Spacer(minLength: 0)
                    Circle().fill(colors.messageAction).frame(width: composer.height * 0.58, height: composer.height * 0.58)
                }
                .padding(.horizontal, 4)
                .frame(width: composer.width, height: composer.height)
                .background(colors.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(line) }
                .offset(x: w * 0.26, y: h * (1 - 0.08 - 0.15))
                // Floating panel: right 5%, top 8%, 20% wide, 46% tall, three rows.
                let panel = CGSize(width: w * 0.20, height: h * 0.46)
                ZStack(alignment: .topLeading) {
                    ForEach(Array([Color(hex: 0x34D399), colors.messageAction, Color(hex: 0xFBBF24)].enumerated()),
                            id: \.offset) { index, dot in
                        HStack(spacing: 4) {
                            Circle().fill(dot.opacity(0.55)).frame(width: panel.height * 0.2 * 0.26,
                                                                   height: panel.height * 0.2 * 0.26)
                            RoundedRectangle(cornerRadius: 4).fill(line)
                                .frame(width: panel.width * 0.78 * 0.52, height: panel.height * 0.2 * 0.30)
                        }
                        .frame(width: panel.width * 0.78, height: panel.height * 0.2, alignment: .leading)
                        .offset(x: panel.width * 0.11, y: panel.height * [0.10, 0.40, 0.70][index])
                    }
                }
                .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                .background(colors.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(line) }
                .shadow(color: .black.opacity(0.14), radius: 2.5, y: 2)
                .offset(x: w * (1 - 0.05 - 0.20), y: h * 0.08)
            }
        }
        .accessibilityHidden(true)
    }

    private func box(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat, fill: Color,
                     stroke: Bool = false, in size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(fill)
            .overlay { if stroke { RoundedRectangle(cornerRadius: radius).strokeBorder(line) } }
            .frame(width: size.width * width, height: size.height * height)
            .offset(x: size.width * x, y: size.height * y)
    }
}

/// Theme cards in columns at least 256pt wide, 8pt apart.
private struct ThemeGrid: View {
    @ObservedObject var settings: AppearanceSettings
    @State private var width: CGFloat = 0

    var body: some View {
        let columns = max(1, Int((width + 8) / (256 + 8)))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance-theme-library")
    }
}

/// Theme card: light and dark preview circles (each picks the theme for that mode) above the name.
/// Clicking anywhere else uses the theme for both modes. Cards never show a selected state of their own.
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                circle(.light, picked: lightActive)
                circle(.dark, picked: darkActive)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(minHeight: 80)
            HStack(spacing: 8) {
                Text(verbatim: theme.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(hovering ? palette.accentFill.opacity(0.1) : palette.card.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border.opacity(0.7)) }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { use(nil) }
        .onHover { hovering = $0 }
        .help("Use for both light and dark")
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Use \(theme.label) theme")) { use(nil) }
        .accessibilityLabel(Text(verbatim: theme.label))
        .accessibilityIdentifier("appearance-theme-\(theme.rawValue)")
    }

    private func circle(_ mode: ColorScheme, picked: Bool) -> some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let preview = ThemePreviewColors(theme: theme, dark: mode == .dark)
        return ThemePreviewCircle(colors: preview, dark: mode == .dark, picked: picked, palette: palette) { use(mode) }
            .help(mode == .light ? "Use for light mode only" : "Use for dark mode only")
            .accessibilityLabel(mode == .light ? Text("Use \(theme.label) light mode") : Text("Use \(theme.label) dark mode"))
            .accessibilityAddTraits(picked ? .isSelected : [])
            .accessibilityIdentifier("appearance-theme-\(theme.rawValue)-\(mode == .light ? "light" : "dark")")
    }
}

/// 68pt button holding a 56pt blurred-gradient circle; picked adds a 2pt ring and a sun or moon badge.
private struct ThemePreviewCircle: View {
    let colors: ThemePreviewColors
    let dark: Bool
    let picked: Bool
    let palette: T3Palette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                ZStack {
                    colors.canvas
                    (dark ? Color(hex: 0x09090B) : Color.white).opacity(0.2)
                    RadialGradient(stops: [.init(color: colors.accent, location: 0),
                                           .init(color: colors.accent.opacity(dark ? 0.62 : 0.72), location: 0.28),
                                           .init(color: .clear, location: 0.58)],
                                   center: dark ? UnitPoint(x: 0.28, y: 0.78) : UnitPoint(x: 0.72, y: 0.22),
                                   startRadius: 0, endRadius: 40)
                    RadialGradient(stops: [.init(color: colors.messageAction.opacity(0.45), location: 0),
                                           .init(color: .clear, location: 0.55)],
                                   center: dark ? UnitPoint(x: 0.82, y: 0.18) : UnitPoint(x: 0.18, y: 0.82),
                                   startRadius: 0, endRadius: 40)
                }
                .blur(radius: 3)
                .scaleEffect(1.1)
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(palette.canvas, lineWidth: 2) }
                .overlay {
                    Circle().strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.1), lineWidth: 1)
                        .padding(2)
                }
                .shadow(color: .black.opacity(dark ? 0.18 : 0.08), radius: 1, y: 1)
                if picked {
                    Circle().strokeBorder(palette.ring, lineWidth: 2)
                }
            }
            .frame(width: 68, height: 68)
            .overlay(alignment: .bottomTrailing) {
                if picked {
                    Image(systemName: dark ? "moon" : "sun.max")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 20, height: 20)
                        .background(palette.canvas, in: Circle())
                        .overlay { Circle().strokeBorder(palette.border.opacity(0.7)) }
                        .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                        .padding(2)
                }
            }
            .scaleEffect(hovering && !picked ? 1.05 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
