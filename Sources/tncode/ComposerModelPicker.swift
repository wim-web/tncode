import AppKit
import Carbon
import SwiftUI

/// The composer's model picker, laid out as T3 Code's docked picker (ProviderModelPicker with an effort
/// column): a provider rail, the searchable model list, the current model's effort levels and a footer.
struct ComposerModelPicker: View {
    static let width: CGFloat = 552
    static let height: CGFloat = 346 + footerHeight
    private static let listWidth: CGFloat = 360
    private static let effortWidth: CGFloat = 192
    private static let footerHeight: CGFloat = 45

    let providers: [ComposerModelProvider]
    let favorites: Set<ModelSettings.Identity>
    let current: ModelSettings
    let currentName: String
    let disabled: Bool
    let permission: ToolPermission?
    let permissionDisabled: Bool
    let choose: (ComposerModelOption) -> Void
    let chooseLevel: (ModelSettings.ThinkingLevel) -> Void
    let toggleFavorite: (ModelSettings.Identity) -> Void
    let setPermission: (ToolPermission) -> Void
    let openSetup: () -> Void
    let close: () -> Void

    private enum Tab: Hashable {
        case favorites
        case provider(String)
    }

    @State private var query = ""
    @State private var tab: Tab
    @State private var highlight: ModelSettings.Identity?
    @FocusState private var searchFocused: Bool
    @Namespace private var rail
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private var palette: T3Palette { T3Palette(colorScheme, t3Themes) }

    init(providers: [ComposerModelProvider], favorites: Set<ModelSettings.Identity>, current: ModelSettings,
         currentName: String, disabled: Bool, permission: ToolPermission?, permissionDisabled: Bool,
         choose: @escaping (ComposerModelOption) -> Void,
         chooseLevel: @escaping (ModelSettings.ThinkingLevel) -> Void,
         toggleFavorite: @escaping (ModelSettings.Identity) -> Void,
         setPermission: @escaping (ToolPermission) -> Void,
         openSetup: @escaping () -> Void, close: @escaping () -> Void) {
        self.providers = providers
        self.favorites = favorites
        self.current = current
        self.currentName = currentName
        self.disabled = disabled
        self.permission = permission
        self.permissionDisabled = permissionDisabled
        self.choose = choose
        self.chooseLevel = chooseLevel
        self.toggleFavorite = toggleFavorite
        self.setPermission = setPermission
        self.openSetup = openSetup
        self.close = close
        // A started thread, or an account that still needs setup, opens on its own provider.
        let active = providers.first { $0.account == current.account }
        let pickableFavorite = providers.contains { provider in
            !provider.locked && provider.setupReason == nil && provider.options.contains { favorites.contains($0.id) }
        }
        let opensOnActive = providers.contains(where: \.locked) || active?.setupReason != nil || !pickableFavorite
        _tab = State(initialValue: opensOnActive ? .provider(current.account) : .favorites)
    }

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let rows = rows(searching: searching)
        let selectable = rows.filter { $0.unavailableReason == nil && !disabled }
        let highlighted = selectable.first { $0.id == highlight } ?? selectable.first
        let jumps = Dictionary(uniqueKeysWithValues: selectable.prefix(9).enumerated().map { ($1.id, "⌘\($0 + 1)") })
        let setup = searching ? nil : selectedProvider?.setupReason
        let showsRail = !searching && !providers.isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsRail { providerRail }
                VStack(spacing: 0) {
                    searchField
                    if !rows.isEmpty {
                        modelList(rows, highlighted: highlighted?.id, jumps: jumps, searching: searching)
                    } else if setup == nil {
                        Text(localized: emptyLabel(searching: searching))
                            .font(.system(size: 14))
                            .foregroundStyle(palette.mutedForeground)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .accessibilityIdentifier("composer-model-no-results")
                    }
                    if let setup { setupNotice(setup) }
                    if rows.isEmpty { Spacer(minLength: 0) }
                }
                .frame(width: Self.listWidth - (showsRail ? 44 : 0))
                .frame(maxHeight: .infinity)
                .background(palette.muted.opacity(0.4))
                .overlay(alignment: .leading) { if showsRail { divider(vertical: true) } }
                effortColumn
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .frame(width: Self.width)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .background(palette.dropdownGlass, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.dropdownBorder).allowsHitTesting(false) }
        .shadow(color: .black.opacity(palette.isDark ? 0.8 : 0.55), radius: 22, y: 17)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose model")
        .accessibilityIdentifier("composer-model-picker")
        .defaultFocus($searchFocused, true)
        .onAppear { searchFocused = true }
        .onChange(of: query) { highlight = nil }
        .onChange(of: tab) { highlight = nil }
        .background {
            WindowKeyMonitor { event, window in
                handleKey(event, in: window, selectable: selectable, highlighted: highlighted)
            }
        }
    }

    // MARK: Rows

    private var selectedProvider: ComposerModelProvider? {
        guard case let .provider(account) = tab else { return nil }
        return providers.first { $0.account == account }
    }

    /// An account that still needs setup lists only the model the thread already uses.
    private func listed(_ provider: ComposerModelProvider) -> [ComposerModelOption] {
        provider.setupReason == nil ? provider.options : provider.options.filter { $0.id == current.identity }
    }

    private func rows(searching: Bool) -> [ComposerModelOption] {
        let reachable = providers.filter { !$0.locked }
        if searching {
            return reachable.flatMap(listed).filter { $0.matches(query) }
        }
        switch tab {
        case .favorites:
            return reachable.flatMap(listed).filter { favorites.contains($0.id) }
        case .provider:
            guard let provider = selectedProvider else { return [] }
            let options = listed(provider)
            return options.filter { favorites.contains($0.id) } + options.filter { !favorites.contains($0.id) }
        }
    }

    private func emptyLabel(searching: Bool) -> String {
        tab == .favorites && !searching ? "No favorites yet" : "No models found"
    }

    // MARK: Provider rail

    /// Providers this thread can use come first; the rest stay visible but disabled.
    private var railProviders: [ComposerModelProvider] {
        providers.filter { !$0.locked } + providers.filter(\.locked)
    }

    private var providerRail: some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                railButton(.favorites, help: "Favorites", identifier: "composer-model-favorites") {
                    Image(systemName: "star.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.foreground)
                }
                Rectangle().fill(palette.border.opacity(0.7)).frame(height: 1).accessibilityHidden(true)
                ForEach(railProviders) { provider in
                    railButton(.provider(provider.account), help: railHelp(provider),
                               identifier: "composer-model-provider-\(provider.account)", disabled: provider.locked) {
                        ProviderGlyph(provider: provider.provider, size: 20)
                            .foregroundStyle(palette.foreground)
                    }
                }
            }
            .padding(4)
            .animation(.easeOut(duration: 0.2), value: tab)
        }
        .scrollIndicators(.never)
        .frame(width: 44)
        .frame(maxHeight: .infinity)
        .background(palette.muted.opacity(0.3))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Providers")
    }

    private func railHelp(_ provider: ComposerModelProvider) -> String {
        if provider.locked {
            return String(localized: "\(provider.title) is unavailable in this thread. Start a new thread to switch providers.")
        }
        if let reason = provider.setupReason {
            return String(localized: "\(provider.title): Not ready. \(reason)")
        }
        return provider.title
    }

    private func railButton(_ target: Tab, help: String, identifier: String, disabled: Bool = false,
                            @ViewBuilder icon: () -> some View) -> some View {
        let selected = tab == target
        return Button {
            tab = target
            searchFocused = true
        } label: {
            icon()
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(palette: palette))
        .overlay(alignment: .trailing) {
            if selected {
                Capsule().fill(palette.primary)
                    .frame(width: 3, height: 20)
                    .matchedGeometryEffect(id: "selected-provider", in: rail)
                    .allowsHitTesting(false)
            }
        }
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
        .help(Text(localized: help))
        .accessibilityLabel(Text(localized: help))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    // MARK: Search and list

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(palette.mutedForeground.opacity(0.55))
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            TextField("Search models…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .accessibilityIdentifier("composer-model-search")
                .submitScope()
        }
        .frame(height: 26)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(searchFocused ? palette.ring : palette.border.opacity(0.7)).frame(height: 1)
        }
        .offset(y: -1)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func modelList(_ rows: [ComposerModelOption], highlighted: ModelSettings.Identity?,
                           jumps: [ModelSettings.Identity: String], searching: Bool) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { option in
                        row(option, highlighted: highlighted == option.id, jump: jumps[option.id],
                            starOnHover: tab == .favorites && !searching)
                            .id(option.id)
                    }
                }
                .padding(.vertical, 6)
                .padding(.leading, 8)
                .padding(.trailing, 1)
            }
            .scrollIndicators(.automatic)
            .onChange(of: highlight) { _, id in
                if let id { reader.scrollTo(id) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ option: ComposerModelOption, highlighted: Bool, jump: String?, starOnHover: Bool) -> some View {
        let favorite = favorites.contains(option.id)
        let selected = option.id == current.identity
        let reason = disabled ? String(localized: "Model picker is disabled") : option.unavailableReason
        return ZStack(alignment: .trailing) {
            Button { choose(option) } label: {
                HStack(spacing: 8) {
                    ProviderGlyph(provider: option.settings.provider, size: 16)
                        .foregroundStyle(palette.foreground)
                    HStack(spacing: 8) {
                        Text(option.name)
                            .font(.system(size: 14))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.mutedForeground)
                                .frame(width: 14, height: 14)
                                .accessibilityHidden(true)
                        }
                        if option.unavailableReason != nil { UnavailableBadge(palette: palette) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Room for the star and shortcut that sit over the row.
                    Color.clear.frame(width: jump == nil ? 24 : 54, height: 1)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .background(highlighted ? palette.itemHighlight : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(reason != nil)
            .opacity(reason != nil ? 0.64 : 1)
            .help(reason.map { Text(localized: $0) } ?? Text(verbatim: ""))
            .accessibilityLabel(Text(verbatim: "\(option.name), \(option.settings.provider.label)"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(option.accessibilityID)
            HStack(spacing: 6) {
                let label = favorite ? "Remove from favorites" : "Add to favorites"
                Button { toggleFavorite(option.id) } label: {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(favorite ? palette.warning : palette.mutedForeground)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(favorite && !starOnHover || highlighted ? 1 : 0)
                .disabled(reason != nil)
                .help(Text(localized: label))
                .accessibilityLabel(Text(localized: label))
                .accessibilityIdentifier("composer-model-favorite-\(option.settings.provider.rawValue)-\(option.settings.model)")
                if let jump { T3Kbd(jump).accessibilityHidden(true) }
            }
            .padding(.trailing, 8)
        }
        .onHover { if $0, reason == nil { highlight = option.id } }
    }

    private func setupNotice(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized: reason)
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open provider setup", action: openSetup)
                .buttonStyle(InlineLinkButtonStyle(palette: palette))
                .accessibilityIdentifier("composer-model-provider-setup")
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .padding(8)
        .overlay(alignment: .top) { divider(vertical: false) }
    }

    // MARK: Effort column

    private var effortColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Effort").foregroundStyle(palette.mutedForeground)
                Spacer(minLength: 0)
                Text(currentName)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 14))
            .frame(height: 26)
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { divider(vertical: false) }
            .offset(y: -1)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            ScrollView {
                VStack(spacing: 2) {
                    if current.provider == .local {
                        Text("No effort levels")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.mutedForeground)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .padding(.horizontal, 8)
                    } else {
                        ForEach(ModelSettings.ThinkingLevel.allCases) { level in
                            effortRow(level, selected: (current.thinkingLevel ?? .off) == level)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Effort")
        }
        .frame(width: Self.effortWidth)
        .frame(maxHeight: .infinity)
        .background(palette.muted.opacity(0.4))
        .overlay(alignment: .leading) { divider(vertical: true) }
    }

    private func effortRow(_ level: ModelSettings.ThinkingLevel, selected: Bool) -> some View {
        Button { chooseLevel(level) } label: {
            HStack(spacing: 8) {
                Text(level.label)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(ColumnRowStyle(palette: palette))
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("composer-model-effort-\(level.rawValue)")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if let permission {
                Menu {
                    Picker(selection: Binding(get: { permission }, set: setPermission)) {
                        ForEach(ToolPermission.allCases, id: \.self) { option in
                            Text(localized: option.title).tag(option)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: permission.icon).font(.system(size: 12))
                        Text(localized: permission.title)
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(palette.mutedForeground)
                .foregroundStyle(palette.mutedForeground)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .fixedSize()
                .disabled(permissionDisabled)
                .accessibilityLabel(Text("Permissions: \(permission.title)"))
                .accessibilityIdentifier("composer-model-permissions")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.footerHeight)
        .background(palette.muted.opacity(0.4))
        .overlay(alignment: .top) { divider(vertical: false) }
    }

    private func divider(vertical: Bool) -> some View {
        Rectangle()
            .fill(palette.border.opacity(0.7))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .allowsHitTesting(false)
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent, in window: NSWindow, selectable: [ComposerModelOption],
                           highlighted: ComposerModelOption?) -> Bool {
        guard (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            if !event.isARepeat { close() }
            return true
        case kVK_UpArrow, kVK_DownArrow:
            let step = Int(event.keyCode) == kVK_UpArrow ? -1 : 1
            if modifiers == [.command, .shift] {
                switchProvider(by: step)
                return true
            }
            guard modifiers.isEmpty, searchFocused, let highlighted,
                  let index = selectable.firstIndex(where: { $0.id == highlighted.id }) else { return false }
            highlight = selectable[(index + step + selectable.count) % selectable.count].id
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard modifiers.isEmpty, searchFocused else { return false }
            if let highlighted, !event.isARepeat { choose(highlighted) }
            return true
        default:
            guard modifiers == .command, let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
                  (1...9).contains(digit) else { return false }
            if digit <= selectable.count, !event.isARepeat { choose(selectable[digit - 1]) }
            return true
        }
    }

    private func switchProvider(by step: Int) {
        let tabs = [Tab.favorites] + railProviders.filter { !$0.locked }.map { .provider($0.account) }
        let index = tabs.firstIndex(of: tab).map { ($0 + step + tabs.count) % tabs.count } ?? (step > 0 ? 0 : tabs.count - 1)
        query = ""
        tab = tabs[index]
        searchFocused = true
    }
}

/// Stand-in for the provider logo.
private struct ProviderGlyph: View {
    let provider: Provider
    let size: CGFloat

    var body: some View {
        Image(systemName: provider.symbolName)
            .font(.system(size: size * 0.8))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct UnavailableBadge: View {
    let palette: T3Palette

    var body: some View {
        Text("Unavailable")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 3)
            .frame(minHeight: 16)
            .background(palette.isDark ? palette.input.opacity(0.32) : palette.canvas, in: RoundedRectangle(cornerRadius: 4))
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(palette.input) }
            .fixedSize()
    }
}

private struct RailButtonStyle: ButtonStyle {
    let palette: T3Palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering && isEnabled ? palette.foreground.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

private struct ColumnRowStyle: ButtonStyle {
    let palette: T3Palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering && isEnabled ? palette.itemHighlight : .clear, in: RoundedRectangle(cornerRadius: 4))
            .opacity(isEnabled ? 1 : 0.64)
            .onHover { hovering = $0 }
    }
}

/// T3 Code's InlineButton: medium text that underlines on hover.
private struct InlineLinkButtonStyle: ButtonStyle {
    let palette: T3Palette
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.foreground)
            .underline(hovering)
            .onHover { hovering = $0 }
    }
}
