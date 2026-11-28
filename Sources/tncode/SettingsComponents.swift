import AppKit
import SwiftUI

// Building blocks for T3 Code's settings pages (components/settings/*, ui/switch.tsx, ui/select.tsx, ui/input.tsx).

/// Section heading (16/600) above a rounded group card. Put `SettingsDivider()` between rows.
/// `titleAction` sits right after the title; `trailing` is the header action at the far end.
struct SettingsSection<Content: View, Trailing: View, Icon: View, TitleAction: View>: View {
    var title: String?
    var plain = false
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let icon: Icon
    @ViewBuilder let titleAction: TitleAction
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.settingsFlatGroups) private var flat

    init(_ title: String? = nil, plain: Bool = false,
         @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder icon: () -> Icon = { EmptyView() }, @ViewBuilder titleAction: () -> TitleAction = { EmptyView() }) {
        self.title = title
        self.plain = plain
        self.content = content()
        self.trailing = trailing()
        self.icon = icon()
        self.titleAction = titleAction()
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        HStack(spacing: 8) {
                            icon
                            Text(localized: title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(palette.foreground)
                                .lineLimit(1)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .frame(minHeight: 28)
                        titleAction
                    }
                    Spacer(minLength: 0)
                    trailing.frame(minWidth: 28, minHeight: 28, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 28)
            }
            if plain {
                VStack(alignment: .leading, spacing: 4) { content }
            } else {
                VStack(alignment: .leading, spacing: 0) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(1)
                    .background(flat ? Color.clear : palette.card.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        if !flat { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.border.opacity(0.6)) }
                    }
                    .shadow(color: .black.opacity(flat ? 0 : 0.05), radius: 1, y: 1)
            }
        }
    }
}

private struct SettingsFlatGroupsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Sections in the provider detail pane sit flat in its card: no border, fill or shadow, dividers kept.
    var settingsFlatGroups: Bool {
        get { self[SettingsFlatGroupsKey.self] }
        set { self[SettingsFlatGroupsKey.self] = newValue }
    }
}

/// Hairline between rows inside a settings card.
struct SettingsDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        Rectangle().fill(T3Palette(colorScheme, t3Themes).border.opacity(0.5)).frame(height: 1)
    }
}

/// Title and description on the left, control on the right; optional full-width detail below.
struct SettingsRow<Control: View, Detail: View>: View {
    let title: String
    var description: String?
    var descriptionID: String?
    var status: String?
    var statusID: String?
    var reset: SettingsResetButton?
    @ViewBuilder let control: Control
    @ViewBuilder let detail: Detail
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    /// Below 512pt the control drops under the text, like T3 Code's `@min-[32rem]/settings-row` grid.
    @State private var stacked = false

    init(_ title: String, description: String? = nil, descriptionID: String? = nil, status: String? = nil,
         statusID: String? = nil, reset: SettingsResetButton? = nil,
         @ViewBuilder control: () -> Control, @ViewBuilder detail: () -> Detail = { EmptyView() }) {
        self.title = title
        self.description = description
        self.descriptionID = descriptionID
        self.status = status
        self.statusID = statusID
        self.reset = reset
        self.control = control()
        self.detail = detail()
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 32))
        VStack(alignment: .leading, spacing: 12) {
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(localized: title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.foreground)
                        // The reset slot keeps its 20×20 space even when empty, as in T3 Code.
                        ZStack { if let reset { reset } }.frame(width: 20, height: 20)
                    }
                    .frame(minHeight: 20)
                    if let description {
                        Text(localized: description)
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .foregroundStyle(palette.mutedForeground)
                            .frame(maxWidth: 672, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(descriptionID ?? "")
                            .modifier(SelectableWhenIdentified(identified: descriptionID != nil))
                    }
                    if let status {
                        Text(localized: status)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.mutedForeground)
                            .padding(.top, 2)
                            .accessibilityIdentifier(statusID ?? "")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) { control }
                    .fixedSize(horizontal: !stacked, vertical: false)
            }
            detail
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onGeometryChange(for: Bool.self) { $0.size.width < 512 } action: { stacked = $0 }
    }
}

/// 20×20 undo glyph shown next to a row title when the value differs from its default.
struct SettingsResetButton: View {
    let label: String
    let identifier: String
    let action: () -> Void

    init(_ label: String, id identifier: String, action: @escaping () -> Void) {
        self.label = label
        self.identifier = identifier
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(T3IconButtonStyle(size: 20))
        .help("Reset to default")
        .accessibilityLabel(Text(localized: label))
        .accessibilityIdentifier(identifier)
    }
}

/// Inline status or error line under a section, 12pt.
struct SettingsMessage: View {
    let text: String
    var isError = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    init(_ text: String, isError: Bool = true) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        Text(localized: text)
            .font(.system(size: 12))
            .foregroundStyle(isError ? palette.destructiveForeground : palette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Bordered field chrome shared by selects and inputs: 28pt (sm) or 32pt, radius 8.
struct T3FieldChrome: ViewModifier {
    var height: CGFloat = 28
    var focused = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    func body(content: Content) -> some View {
        let palette = T3Palette(colorScheme, t3Themes)
        content
            .padding(.horizontal, height >= 32 ? 11 : 9)
            .frame(height: height)
            .background(palette.fieldFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? palette.ring : palette.input)
                if focused {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(palette.ring.opacity(0.24), lineWidth: 3).padding(1)
                }
            }
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

/// T3 Code text input. Use `T3TextField` when the focus ring matters; this style keeps existing TextFields.
struct T3TextFieldStyle: TextFieldStyle {
    var height: CGFloat = 28

    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .modifier(T3FieldChrome(height: height))
    }
}

/// Select trigger (h28, radius 8, chevron) that opens a native menu below itself.
/// Accessibility exposes a standard pop-up button so the value can be read and picked.
struct T3Select<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
    }

    let title: String
    @Binding var selection: Value
    let options: [Option]
    /// Nil fits the trigger to its value, like T3 Code's `w-auto` selects.
    var width: CGFloat? = 160
    /// The menu marks this option "(default)", as T3 Code's popups do; the trigger keeps the plain label.
    var defaultValue: Value?
    @State private var anchor = T3MenuAnchor()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, selection: Binding<Value>, options: [(Value, String)], width: CGFloat? = 160,
         defaultValue: Value? = nil) {
        self.title = title
        _selection = selection
        self.options = options.map { Option(value: $0.0, label: $0.1) }
        self.width = width
        self.defaultValue = defaultValue
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        Button {
            anchor.popUp(options.map { option in
                let label = NSLocalizedString(option.label, comment: "")
                return option.value == defaultValue ? String(localized: "\(label) (default)") : label
            }, selected: options.firstIndex { $0.value == selection }) { index in
                selection = options[index].value
            }
        } label: {
            HStack(spacing: 6) {
                Text(localized: options.first { $0.value == selection }?.label ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                if width != nil { Spacer(minLength: 0) }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.mutedForeground.opacity(0.7))
            }
            .frame(width: width.map { $0 - 18 })
            .fixedSize(horizontal: width == nil, vertical: false)
            .modifier(T3FieldChrome())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.64)
        .background(T3MenuAnchorView(anchor: anchor))
        .accessibilityRepresentation {
            Picker(LocalizedStringKey(title), selection: $selection) {
                ForEach(options, id: \.value) { option in Text(localized: option.label).tag(option.value) }
            }
            .pickerStyle(.menu)
        }
    }
}

/// Holds the AppKit view a pop-up menu is positioned against.
final class T3MenuAnchor {
    fileprivate weak var view: NSView?

    func popUp(_ titles: [String], selected: Int?, choose: @escaping (Int) -> Void) {
        guard let view else { return }
        let target = Target(choose: choose)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target
            item.tag = index
            item.state = index == selected ? .on : .off
            menu.addItem(item)
        }
        menu.minimumWidth = view.bounds.width
        // T3 Code aligns select popups to the trigger's trailing edge.
        let x = view.bounds.width - max(menu.size.width, view.bounds.width)
        withExtendedLifetime(target) {
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: view.isFlipped ? view.bounds.height + 4 : -4), in: view)
        }
    }

    private final class Target: NSObject {
        let choose: (Int) -> Void
        init(choose: @escaping (Int) -> Void) { self.choose = choose }
        @objc func choose(_ item: NSMenuItem) { choose(item.tag) }
    }
}

struct T3MenuAnchorView: NSViewRepresentable {
    let anchor: T3MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// Segmented control: track at input 40%, 24pt segments with radius 6.
struct T3SegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String, id: String?)]
    /// Expose a native segmented control to accessibility instead of one button per option.
    var nativeAccessibility = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    init(_ title: String, selection: Binding<Value>, options: [(Value, String, String?)], nativeAccessibility: Bool = false) {
        self.title = title
        _selection = selection
        self.options = options.map { (value: $0.0, label: $0.1, id: $0.2) }
        self.nativeAccessibility = nativeAccessibility
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(localized: option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? palette.foreground : palette.mutedForeground)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(selected ? palette.segmentedSelected : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(selected && !palette.isDark ? 0.08 : 0), radius: 1, y: 1)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(localized: option.label))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(option.id ?? "")
            }
        }
        .padding(2)
        .background(palette.input.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        .modifier(SegmentedAccessibility(native: nativeAccessibility, title: title, selection: $selection,
                                         options: options.map { ($0.value, $0.label) }))
    }
}

private struct SegmentedAccessibility<Value: Hashable>: ViewModifier {
    let native: Bool
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    func body(content: Content) -> some View {
        if native {
            content.accessibilityRepresentation {
                Picker(LocalizedStringKey(title), selection: $selection) {
                    ForEach(options, id: \.0) { option in Text(localized: option.1).tag(option.0) }
                }
                .pickerStyle(.segmented)
            }
        } else {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(localized: title))
        }
    }
}

/// Keyboard key chip.
struct T3Kbd: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    init(_ text: String) { self.text = text }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        Text(localized: text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.mutedForeground)
            .padding(.horizontal, 4)
            .frame(minWidth: 20, minHeight: 20)
            .background(palette.kbdFill, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Small text buttons used in settings: xs (24pt, 12pt text) and sm outline/destructive (28pt).
struct T3SmallButtonStyle: ButtonStyle {
    enum Kind { case ghost, outline, destructiveOutline, primary }
    var kind: Kind = .outline
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
                .font(.system(size: height <= 24 ? 12 : 14, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, height <= 24 ? 7 : 9)
                .frame(height: height)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    switch kind {
                    case .outline: RoundedRectangle(cornerRadius: 8).strokeBorder(palette.outlineBorder)
                    case .destructiveOutline:
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(hovering ? palette.destructive.opacity(0.32) : palette.outlineBorder)
                    default: EmptyView()
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.64)
                .onHover { hovering = $0 && isEnabled }
        }

        private var foreground: Color {
            switch kind {
            case .primary: palette.primaryForeground
            case .destructiveOutline: palette.destructiveForeground
            case .ghost: hovering ? palette.foreground : palette.mutedForeground
            case .outline: palette.foreground
            }
        }

        private var fill: Color {
            switch kind {
            case .primary: palette.primary.opacity(hovering ? 0.9 : 1)
            case .ghost: hovering ? palette.accentFill : .clear
            case .outline: hovering ? (palette.isDark ? Color.white.opacity(0.07) : Color(hex: 0xF4F4F5, opacity: 0.5))
                                    : palette.outlineFill
            case .destructiveOutline: hovering ? palette.destructive.opacity(0.04) : palette.outlineFill
            }
        }
    }
}

/// Identified descriptions (paths) stay selectable and expose their text as the accessibility value.
private struct SelectableWhenIdentified: ViewModifier {
    let identified: Bool

    func body(content: Content) -> some View {
        if identified { content.textSelection(.enabled) } else { content }
    }
}

/// Settings switch: the native small switch (32×18, closest to T3 Code's 30×18) in the primary blue, with no
/// visible label so the row title reads as its label. Keeps native press and value accessibility.
struct SettingsSwitch: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(T3Palette(colorScheme, t3Themes).primary)
            .accessibilityLabel(Text(localized: title))
    }
}

/// T3 Code's AdvancedSettings: a 40pt "Advanced" row at the end of a section card that folds its rows away.
/// It opens on its own when settings search lands on one of `targets`. Put a `SettingsDivider()` before it.
struct SettingsAdvancedGroup<Content: View>: View {
    var targets: [SettingsAnchor] = []
    @ViewBuilder let content: Content
    @State private var open = false
    @State private var hovering = false
    @Environment(\.settingsDestination) private var destination
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    init(targets: [SettingsAnchor] = [], @ViewBuilder content: () -> Content) {
        self.targets = targets
        self.content = content()
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("Advanced")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? palette.foreground : palette.mutedForeground)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(open ? .isSelected : [])
            .accessibilityIdentifier("settings-advanced")
            if open {
                SettingsDivider()
                content
            }
        }
        .onAppear { if let anchor = destination?.anchor, targets.contains(anchor) { open = true } }
        .onChange(of: destination) { _, next in
            if let anchor = next?.anchor, targets.contains(anchor) { open = true }
        }
    }
}
