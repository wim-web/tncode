import SwiftUI

/// Default T3 Code theme tokens (apps/web/src/index.css, v0.1.12), resolved to sRGB.
struct T3Palette {
    let canvas: Color
    let sidebar: Color
    let foreground: Color
    let mutedForeground: Color
    let muted: Color
    let border: Color
    let input: Color
    let card: Color
    let popover: Color
    let primary: Color
    let primaryForeground: Color
    let ring: Color
    /// Hover/pressed fill for ghost controls (`--accent`).
    let accentFill: Color
    let destructive: Color
    let userBubble: Color
    let codeBackground: Color
    let inlineCodeBackground: Color
    let rowHover: Color
    let rowSelected: Color
    let composerFill: Color
    let composerBorder: Color
    let outlineFill: Color
    let outlineBorder: Color
    let disabledSendFill: Color
    let link: Color
    let codeBorder: Color
    let sidebarForeground: Color
    let sidebarMuted: Color
    let secondaryLabel: Color
    let sidebarIcon: Color
    let sidebarAccent: Color
    let rowActive: Color
    let rowActiveRing: Color
    let success: Color
    let warning: Color
    let info: Color
    let isDark: Bool
    /// False when a built-in theme other than T3 Code supplies the colors.
    private(set) var isDefaultTheme = true

    init(_ scheme: ColorScheme, _ themes: T3ThemeChoice = T3ThemeChoice()) {
        let dark = scheme == .dark
        if let colors = themes.theme(dark: dark).colors(dark: dark) {
            self = .themed(colors, dark: dark)
        } else {
            self = dark ? .dark : .light
        }
    }

    /// Maps theme roles onto tokens the way index.css does for html[data-theme-id].
    private static func themed(_ c: T3ThemeColors, dark: Bool) -> T3Palette {
        var palette = T3Palette(
            canvas: c.canvas,
            sidebar: c.sidebar,
            foreground: c.text,
            mutedForeground: c.mutedForeground,
            muted: c.muted,
            border: c.border,
            input: c.input,
            card: c.surface,
            popover: c.surfaceOverlay,
            primary: c.messageAction,
            primaryForeground: c.messageActionForeground,
            ring: c.focus,
            accentFill: c.accentSurface,
            destructive: c.error,
            userBubble: c.messageSurface,
            codeBackground: c.codeBackground,
            inlineCodeBackground: c.text.opacity(0.10),
            rowHover: c.sidebarRowHover,
            rowSelected: c.sidebarRowSelected,
            composerFill: c.surface.opacity(0.8),
            composerBorder: c.border,
            outlineFill: dark ? c.text.opacity(0.035) : c.surfaceOverlay,
            outlineBorder: c.input,
            disabledSendFill: c.text.opacity(0.12),
            link: c.accent,
            codeBorder: dark ? .clear : c.border.opacity(0.7),
            sidebarForeground: c.sidebarForeground,
            sidebarMuted: c.sidebarMutedForeground,
            secondaryLabel: c.secondaryLabel,
            sidebarIcon: c.iconMuted,
            sidebarAccent: c.sidebarControlSurface,
            rowActive: c.sidebarRowActive,
            rowActiveRing: dark ? .clear : c.sidebarBorder.opacity(0.7),
            success: dark ? Color(hex: 0x00D492) : Color(hex: 0x007A55),
            warning: c.warningForeground,
            info: c.accent,
            isDark: dark
        )
        palette.isDefaultTheme = false
        return palette
    }

    private init(canvas: Color, sidebar: Color, foreground: Color, mutedForeground: Color, muted: Color, border: Color,
                 input: Color, card: Color, popover: Color, primary: Color, primaryForeground: Color, ring: Color,
                 accentFill: Color, destructive: Color, userBubble: Color, codeBackground: Color,
                 inlineCodeBackground: Color, rowHover: Color, rowSelected: Color, composerFill: Color,
                 composerBorder: Color, outlineFill: Color, outlineBorder: Color, disabledSendFill: Color, link: Color,
                 codeBorder: Color, sidebarForeground: Color, sidebarMuted: Color, secondaryLabel: Color,
                 sidebarIcon: Color, sidebarAccent: Color, rowActive: Color, rowActiveRing: Color, success: Color,
                 warning: Color, info: Color, isDark: Bool) {
        self.canvas = canvas
        self.sidebar = sidebar
        self.foreground = foreground
        self.mutedForeground = mutedForeground
        self.muted = muted
        self.border = border
        self.input = input
        self.card = card
        self.popover = popover
        self.primary = primary
        self.primaryForeground = primaryForeground
        self.ring = ring
        self.accentFill = accentFill
        self.destructive = destructive
        self.userBubble = userBubble
        self.codeBackground = codeBackground
        self.inlineCodeBackground = inlineCodeBackground
        self.rowHover = rowHover
        self.rowSelected = rowSelected
        self.composerFill = composerFill
        self.composerBorder = composerBorder
        self.outlineFill = outlineFill
        self.outlineBorder = outlineBorder
        self.disabledSendFill = disabledSendFill
        self.link = link
        self.codeBorder = codeBorder
        self.sidebarForeground = sidebarForeground
        self.sidebarMuted = sidebarMuted
        self.secondaryLabel = secondaryLabel
        self.sidebarIcon = sidebarIcon
        self.sidebarAccent = sidebarAccent
        self.rowActive = rowActive
        self.rowActiveRing = rowActiveRing
        self.success = success
        self.warning = warning
        self.info = info
        self.isDark = isDark
    }

    static let dark = T3Palette(
        canvas: .black,
        sidebar: .black,
        foreground: Color(hex: 0xF5F5F5),
        mutedForeground: Color(hex: 0xA1A1A1),
        muted: Color.white.opacity(0.03),
        border: Color.white.opacity(0.08),
        input: Color.white.opacity(0.11),
        card: Color(hex: 0x111111),
        popover: Color(hex: 0x111111),
        primary: Color(hex: 0x346BF1),
        primaryForeground: .white,
        ring: Color(hex: 0x346BF1),
        accentFill: Color.white.opacity(0.04),
        destructive: Color(hex: 0xFB414A),
        userBubble: Color(hex: 0x1E1E1E),
        codeBackground: Color.white.opacity(0.035),
        inlineCodeBackground: Color(hex: 0xF5F5F5).opacity(0.10),
        rowHover: Color(hex: 0xF1F3F7, opacity: 0.08),
        rowSelected: Color(hex: 0xF1F3F7, opacity: 0.07),
        composerFill: Color(hex: 0x111111).opacity(0.8),
        composerBorder: Color.white.opacity(0.05),
        outlineFill: Color.white.opacity(0.035),
        outlineBorder: Color.white.opacity(0.11),
        disabledSendFill: Color(hex: 0xF5F5F5).opacity(0.12),
        link: Color(hex: 0x51A2FF),
        codeBorder: .clear,
        sidebarForeground: Color(hex: 0xF1F3F7),
        sidebarMuted: Color(hex: 0xA3A3A3),
        secondaryLabel: Color(hex: 0x8F8F8F),
        sidebarIcon: Color(hex: 0x8B8B8B),
        sidebarAccent: Color(hex: 0x191A1D),
        rowActive: Color(hex: 0xF1F3F7, opacity: 0.11),
        rowActiveRing: .clear,
        success: Color(hex: 0x00D492),
        warning: Color(hex: 0xFFB900),
        info: Color(hex: 0x51A2FF),
        isDark: true
    )

    static let light = T3Palette(
        canvas: Color(hex: 0xFCFCFC),
        sidebar: Color(hex: 0xFAFAFA),
        foreground: Color(hex: 0x18181B),
        mutedForeground: Color(hex: 0x71717B),
        muted: Color(hex: 0xFAFAFA),
        border: Color(hex: 0xE4E4E7),
        input: Color(hex: 0xD4D4D8),
        card: .white,
        popover: .white,
        primary: Color(hex: 0x1B4ED8),
        primaryForeground: .white,
        ring: Color(hex: 0x1B4ED8),
        accentFill: Color(hex: 0xF4F4F5),
        destructive: Color(hex: 0xFB2C36),
        userBubble: Color(hex: 0xEBEBED),
        codeBackground: Color(hex: 0xFAFAFA),
        inlineCodeBackground: Color(hex: 0x18181B).opacity(0.10),
        rowHover: Color(hex: 0xFCFCFC),
        rowSelected: .white,
        composerFill: Color.white.opacity(0.8),
        composerBorder: Color.black.opacity(0.08),
        outlineFill: .white,
        outlineBorder: Color(hex: 0xD4D4D8),
        disabledSendFill: Color(hex: 0x18181B).opacity(0.12),
        link: Color(hex: 0x1447E6),
        codeBorder: Color(hex: 0xE4E4E7).opacity(0.7),
        sidebarForeground: Color(hex: 0x18181B),
        sidebarMuted: Color(hex: 0x71717B),
        secondaryLabel: Color(hex: 0x71717B),
        sidebarIcon: Color(hex: 0x86858E),
        sidebarAccent: Color(hex: 0xF4F4F5),
        rowActive: .white,
        rowActiveRing: Color(hex: 0xE4E4E7, opacity: 0.7),
        success: Color(hex: 0x007A55),
        warning: Color(hex: 0xBB4D00),
        info: Color(hex: 0x1447E6),
        isDark: false
    )
}

/// Type scale used by T3 Code (CSS px = pt).
enum T3Type {
    static let body: CGFloat = 14
    /// 14px text with a 22.75px line box (leading-relaxed).
    static let bodyLineSpacing: CGFloat = 22.75 - 17
    static let small: CGFloat = 12
    static let code: CGFloat = 13
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Ghost icon button used for header, sidebar and composer controls: 28×28, radius 8, accent fill on hover.
struct T3IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var active = false
    var foreground: Color? = nil
    var hoverFill: Color? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        T3HoverChrome(configuration: configuration, size: size, active: active, foreground: foreground,
                      hoverFill: hoverFill, palette: T3Palette(colorScheme, t3Themes), isEnabled: isEnabled)
    }

    private struct T3HoverChrome: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let active: Bool
        let foreground: Color?
        let hoverFill: Color?
        let palette: T3Palette
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(foreground ?? (hovering || active ? palette.foreground : palette.mutedForeground))
                .frame(width: size, height: size)
                .background(hovering || active || configuration.isPressed ? (hoverFill ?? palette.accentFill) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.64)
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

/// Text+icon chip (model picker, context strip items): accent fill on hover, radius 8.
struct T3ChipButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 8
    var foreground: Color? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, height: height, horizontalPadding: horizontalPadding,
               foreground: foreground, palette: T3Palette(colorScheme, t3Themes), isEnabled: isEnabled)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let horizontalPadding: CGFloat
        let foreground: Color?
        let palette: T3Palette
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? palette.foreground : (foreground ?? palette.mutedForeground))
                .padding(.horizontal, horizontalPadding)
                .frame(height: height)
                .background(hovering || configuration.isPressed ? palette.accentFill : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.64)
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

/// Filled primary or outline button, 28pt tall, radius 8 (ui/button.tsx `size="sm"`).
struct T3ButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, ghost }
    var kind: Kind = .primary
    var height: CGFloat = 28
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, kind: kind, height: height, palette: T3Palette(colorScheme, t3Themes),
               isEnabled: isEnabled)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let height: CGFloat
        let palette: T3Palette
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(kind == .primary ? palette.primaryForeground : palette.foreground)
                .padding(.leading, 9)
                .padding(.trailing, 10)
                .frame(minHeight: height)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    switch kind {
                    case .primary:
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .clear],
                                                         startPoint: .top, endPoint: .init(x: 0.5, y: 0.1)))
                    case .outline:
                        RoundedRectangle(cornerRadius: 8).strokeBorder(palette.outlineBorder)
                    case .ghost:
                        EmptyView()
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.64)
                .onHover { hovering = $0 && isEnabled }
        }

        private var fill: Color {
            switch kind {
            case .primary: palette.primary.opacity(hovering ? 0.9 : 1)
            case .outline: hovering ? (palette.isDark ? Color.white.opacity(0.07) : Color(hex: 0xF4F4F5, opacity: 0.5))
                                    : palette.outlineFill
            case .ghost: hovering ? palette.accentFill : .clear
            }
        }
    }
}

extension Provider {
    /// Stand-in for the provider logo shown before the model name.
    var symbolName: String {
        switch self {
        case .codexAgent, .openai, .piOpenAI, .piCodex: "circle.hexagongrid"
        case .anthropic, .piAnthropic: "asterisk"
        case .piCopilot: "chevron.left.forwardslash.chevron.right"
        case .local: "desktopcomputer"
        }
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<Style: ButtonStyle>(_ style: Style) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Up arrow drawn like the original 14×14 send glyph (stroke 1.8, round caps).
struct T3SendGlyph: View {
    var body: some View {
        Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
    }
}

/// 32pt primary circle used for Send/Steer/Update. Disabled turns grey instead of fading.
struct T3SendButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, palette: T3Palette(colorScheme, t3Themes), isEnabled: isEnabled)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let palette: T3Palette
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? palette.primaryForeground : palette.mutedForeground)
                .frame(width: 32, height: 32)
                .background(isEnabled ? palette.primary.opacity(hovering ? 0.9 : 1) : palette.disabledSendFill,
                            in: Circle())
                .overlay {
                    if isEnabled {
                        Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .clear],
                                                             startPoint: .top, endPoint: .init(x: 0.5, y: 0.12)))
                    }
                }
                .shadow(color: .black.opacity(isEnabled ? 0.24 : 0), radius: 1, y: 1)
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.97 : hovering ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

/// Destructive circle with a white rounded-square glyph.
struct T3StopButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, size: size, palette: T3Palette(colorScheme, t3Themes), isEnabled: isEnabled)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let palette: T3Palette
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(palette.destructive.opacity(hovering ? 1 : 0.9), in: Circle())
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.64)
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

/// Plain text button that brightens to the foreground on hover (breadcrumb crumbs, hero links).
struct T3TextLinkStyle: ButtonStyle {
    var color: Color
    var underline = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, color: color, underline: underline, palette: T3Palette(colorScheme, t3Themes))
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let color: Color
        let underline: Bool
        let palette: T3Palette
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? palette.foreground : color)
                .underline(underline && hovering)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Sidebar icon button (Projects, New thread, footer): sidebar icon colour, row-hover fill.
struct T3SidebarIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var active = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, size: size, active: active, palette: T3Palette(colorScheme, t3Themes), isEnabled: isEnabled)
    }

    private struct Chrome: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let active: Bool
        let palette: T3Palette
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hovering || active ? palette.sidebarForeground : palette.sidebarIcon)
                .frame(width: size, height: size)
                .background(configuration.isPressed || active ? palette.rowActive : hovering ? palette.rowHover : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.64)
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

/// Small outline button used by sidebar empty states.
struct T3SidebarOutlineButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let palette = T3Palette(colorScheme, t3Themes)
        return configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.sidebarMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minHeight: 26)
            .background(configuration.isPressed ? palette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(palette.border) }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.64)
    }
}

/// Sidebar row fill: transparent, row-hover on hover, row-active when open (with a light-mode ring).
struct T3SidebarRowBackground: ViewModifier {
    let selected: Bool
    let targeted: Bool
    let draft: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @State private var hovering = false

    func body(content: Content) -> some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let fill: Color = targeted ? palette.primary.opacity(0.18)
            : selected ? palette.rowActive
            : draft ? palette.warning.opacity(hovering ? 0.08 : 0.04)
            : hovering ? palette.rowHover : .clear
        return content
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if selected || targeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(targeted ? palette.primary : palette.rowActiveRing)
                }
            }
            .onHover { hovering = $0 }
    }
}

/// Search field chrome: no fill at rest, row-hover fill on hover or focus, inset ring on focus.
struct T3SidebarSearchField<Content: View>: View {
    let focused: Bool
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @State private var hovering = false

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        HStack(spacing: 8) { content }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(hovering || focused ? palette.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if focused { RoundedRectangle(cornerRadius: 6).strokeBorder(palette.ring.opacity(0.7)) }
            }
            .onHover { hovering = $0 }
    }
}

enum SidebarTimeLabel {
    /// Compact relative time used in sidebar rows, as T3 Code formats it: now, 5m, 2h, 3d.
    static func compact(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return String(localized: "now") }
        if minutes < 60 { return String(localized: "\(minutes)m") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours)h") }
        return String(localized: "\(hours / 24)d")
    }
}

// Tokens used by Settings, dialogs, menus and the command palette (index.css, ui/*.tsx).
extension T3Palette {
    /// Settings navigation fill (`--sidebar` at the modal root).
    var navFill: Color { isDefaultTheme ? (isDark ? Color(hex: 0x111111) : Color(hex: 0xFAFAFA)) : sidebar }
    var navHover: Color { isDark ? foreground.opacity(0.04) : canvas }
    var navSelected: Color { isDark ? foreground.opacity(0.03) : popover }
    /// Input/select chrome fill.
    var fieldFill: Color { isDark ? foreground.opacity(0.035) : canvas }
    var destructiveForeground: Color {
        isDefaultTheme ? (isDark ? Color(hex: 0xFF6467) : Color(hex: 0xC10007)) : destructive
    }
    var segmentedSelected: Color { isDark ? foreground.opacity(0.08) : canvas }
    var backdrop: Color { canvas.opacity(isDark ? 0.64 : 0.6) }
    var kbdFill: Color { foreground.opacity(0.07) }
    var dropdownGlass: Color { popover.opacity(0.836) }
    var dropdownBorder: Color { foreground.opacity(0.10) }
    var dialogGlass: Color { canvas.opacity(0.8) }
    var dialogBorder: Color { foreground.opacity(isDark ? 0.08 : 0.10) }
    var dialogFooterFill: Color { isDark ? foreground.opacity(0.0216) : muted.opacity(0.72) }
    var itemHighlight: Color { foreground.opacity(0.09) }
    var itemSelected: Color { foreground.opacity(0.06) }
    var commandFooterFill: Color { foreground.opacity(0.025) }
    var commandFooterBorder: Color { foreground.opacity(0.07) }
}

/// Built-in themes (BUILT_IN_THEME_IDS plus the T3 Code default).
enum T3ThemeID: String, CaseIterable, Identifiable, Codable {
    case t3Code = "t3-code"
    case t3Chat = "t3-chat"
    case grove, ocean, ember, iris

    var id: String { rawValue }

    var label: String {
        switch self {
        case .t3Code: "T3 Code"
        case .t3Chat: "T3 Chat"
        case .grove: "Grove"
        case .ocean: "Ocean"
        case .ember: "Ember"
        case .iris: "Iris"
        }
    }
}

/// The theme used in light mode and the one used in dark mode, chosen separately as in T3 Code.
struct T3ThemeChoice: Equatable {
    var light: T3ThemeID = .t3Code
    var dark: T3ThemeID = .t3Code

    func theme(dark isDark: Bool) -> T3ThemeID { isDark ? dark : light }
}

private struct T3ThemeChoiceKey: EnvironmentKey {
    static let defaultValue = T3ThemeChoice()
}

extension EnvironmentValues {
    var t3Themes: T3ThemeChoice {
        get { self[T3ThemeChoiceKey.self] }
        set { self[T3ThemeChoiceKey.self] = newValue }
    }
}

extension Text {
    /// UI copy that reaches a view as a String: looked up in Localizable.strings, shown as-is when missing.
    init(localized string: String) {
        self.init(LocalizedStringKey(string))
    }
}
