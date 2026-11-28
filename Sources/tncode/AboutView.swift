import AppKit
import SwiftUI

struct AboutView: View {
    static let windowID = "about"

    @Binding var showingLicenses: Bool
    var settingsFocus: FocusState<SettingsFocus?>.Binding? = nil
    var openWelcome: (() -> Void)? = nil
    var welcomeEnabled = false
    @State private var notices = DependencyNotice.load()
    private let info = AboutInfo()

    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        Group {
            if showingLicenses {
                // The Open source licenses detail page; the header breadcrumb names it.
                ScrollView {
                    Group {
                        if let notices {
                            LicensesView(notices: notices, settingsFocus: settingsFocus)
                        } else {
                            SettingsSection("Third-party notices") {
                                VStack(alignment: .leading, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Open-source notices are unavailable")
                                            .font(.system(size: 14, weight: .medium))
                                        Text("The license manifest could not load.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(T3Palette(colorScheme, t3Themes).mutedForeground.opacity(0.8))
                                    }
                                    .accessibilityIdentifier("licenses-unavailable")
                                    Button("Try again") { notices = DependencyNotice.load() }
                                        .buttonStyle(T3SmallButtonStyle(height: 24))
                                        .accessibilityIdentifier("licenses-retry")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 20)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .settingsPageContainer()
                }
            } else {
                ScrollView {
                    appInformation.settingsPageContainer()
                }
            }
        }
        .background(T3Palette(colorScheme, t3Themes).canvas)
    }

    private var appInformation: some View {
        VStack(alignment: .leading, spacing: 32) {
            SettingsSection("App") {
                versionRow
                if let openWelcome, let settingsFocus {
                    SettingsDivider()
                    SettingsRow("Welcome page", description: "Set up a model and add projects.") {
                        Button("Open", action: openWelcome)
                            .buttonStyle(T3SmallButtonStyle())
                            .settingsTarget(.welcomePage, focus: settingsFocus)
                            .disabled(!welcomeEnabled)
                    }
                }
            }
            SettingsSection("Legal") {
                SettingsRow("Open source licenses", description: "Notices for dependencies, assets, and optional tools used by tncode.") {
                    Button("View licenses") {
                        notices = DependencyNotice.load()
                        showingLicenses = true
                    }
                    .buttonStyle(T3SmallButtonStyle())
                    .accessibilityIdentifier("about-licenses")
                }
            }
        }
    }

    /// "Version" with the version as a muted code label that copies it, as in T3 Code's AboutVersionTitle.
    @ViewBuilder
    private var versionRow: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let row = VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Version")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.foreground)
                AboutVersionLabel(version: info.version ?? String(localized: "Unavailable"))
            }
            .frame(minHeight: 20)
            Text("Current version of the application.")
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        if let settingsFocus {
            row
                .accessibilityElement(children: .contain)
                .focusable()
                .focusEffectDisabled()
                .settingsTarget(.appVersion, focus: settingsFocus)
        } else {
            row
        }
    }
}

/// The version in 11pt medium monospace; muted, underlined on hover, and copied when clicked.
private struct AboutVersionLabel: View {
    let version: String
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        // Selectable text keeps the version readable by VoiceOver as its value; a click copies it.
        Text(verbatim: version)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(hovering ? palette.foreground : palette.mutedForeground)
            .underline(hovering)
            .textSelection(.enabled)
            .onTapGesture(perform: copy)
            .onHover { hovering = $0 }
            .help("Copy version")
            .accessibilityAction(named: Text("Copy version \(version)"), copy)
            .accessibilityIdentifier("about-version")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(version, forType: .string)
    }
}

/// "Third-party notices": a count and search in the header, and one row per dependency that unfolds its
/// notice text (only one open at a time), after T3 Code's OpenSourceLicenses.
private struct LicensesView: View {
    let notices: [DependencyNotice]
    var settingsFocus: FocusState<SettingsFocus?>.Binding?
    @State private var query = ""
    @State private var searching = false
    @State private var expanded: DependencyNotice.ID?
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private var filteredNotices: [DependencyNotice] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return notices.filter { notice in
            let metadata = [notice.name, notice.version, notice.license].compactMap { $0 }
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { metadata.contains($0) }
        }
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let filtered = filteredNotices
        SettingsSection("Third-party notices") {
            VStack(alignment: .leading, spacing: 0) {
                if filtered.isEmpty {
                    Text("No licenses match that search.")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .accessibilityIdentifier("licenses-empty")
                } else {
                    ForEach(filtered) { notice in
                        LicenseRow(notice: notice, open: expanded == notice.id) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                expanded = expanded == notice.id ? nil : notice.id
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("licenses-list")
        } trailing: {
            HStack(spacing: 8) {
                Text(query.isEmpty ? String(localized: "\(notices.count) notices")
                                   : String(localized: "\(filtered.count) of \(notices.count)"))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(palette.mutedForeground)
                if searching || !query.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(palette.mutedForeground)
                        TextField("Search licenses", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .focused($searchFocused)
                            .onSubmit { if query.isEmpty { searching = false } }
                            .onChange(of: searchFocused) { _, focused in if !focused && query.isEmpty { searching = false } }
                            .modifier(LicenseSearchTarget(focus: settingsFocus))
                    }
                    .frame(width: 176 - 18)
                    .modifier(T3FieldChrome())
                } else {
                    Button {
                        searching = true
                        searchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 11))
                    }
                    .buttonStyle(T3IconButtonStyle(size: 20))
                    .help("Search licenses")
                    .accessibilityLabel("Search open-source licenses")
                    .accessibilityIdentifier("licenses-search-open")
                }
            }
        }
        .onAppear { if settingsFocus != nil { searching = true } }
    }
}

private struct LicenseSearchTarget: ViewModifier {
    let focus: FocusState<SettingsFocus?>.Binding?

    func body(content: Content) -> some View {
        if let focus { content.settingsTarget(.licenses, focus: focus) } else { content.accessibilityIdentifier("licenses-search") }
    }
}

private struct LicenseRow: View {
    let notice: DependencyNotice
    let open: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.mutedForeground)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: notice.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        if let version = notice.version {
                            Text(verbatim: version)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(palette.mutedForeground)
                        }
                    }
                    Spacer(minLength: 8)
                    if let license = notice.license {
                        Text(verbatim: license)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(open ? .isSelected : [])
            .accessibilityIdentifier("license-entry-\(notice.id)")
            if open {
                VStack(alignment: .leading, spacing: 12) {
                    if notice.texts.isEmpty {
                        Text("No notice text is included for this dependency.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.mutedForeground)
                            .accessibilityIdentifier("license-text-unavailable")
                    }
                    ForEach(notice.texts) { entry in
                        Text(entry.text)
                            .font(.system(size: 12, design: .monospaced))
                            .lineSpacing(5)
                            .foregroundStyle(palette.foreground.opacity(0.8))
                            .textSelection(.enabled)
                            .frame(maxWidth: 560, alignment: .leading)
                            .accessibilityIdentifier("license-notice-text-\(entry.file)")
                    }
                }
                .padding(.leading, 40)
                .padding(.trailing, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .background(hovering ? palette.muted.opacity(0.35) : .clear)
        .onHover { hovering = $0 }
    }
}

struct AboutWindow: View {
    @State private var showingLicenses = false

    var body: some View {
        AboutView(showingLicenses: $showingLicenses)
            .frame(minWidth: 660, minHeight: 420)
            .onDisappear { showingLicenses = false }
    }
}
