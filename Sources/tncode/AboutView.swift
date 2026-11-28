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
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Button { showingLicenses = false } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left").font(.system(size: 11))
                                Text("About")
                            }
                        }
                        .buttonStyle(T3SmallButtonStyle(kind: .ghost, height: 24))
                        .accessibilityIdentifier("licenses-back")
                        Text("Open source licenses").font(.system(size: 16, weight: .semibold))
                    }
                    if let notices {
                        LicensesView(notices: notices, settingsFocus: settingsFocus)
                    } else {
                        VStack(spacing: 12) {
                            Text("Open-source notices are unavailable in this app bundle.")
                                .font(.system(size: 14))
                                .foregroundStyle(T3Palette(colorScheme, t3Themes).mutedForeground)
                                .accessibilityIdentifier("licenses-unavailable")
                            Button("Try Again") { notices = DependencyNotice.load() }
                                .buttonStyle(T3SmallButtonStyle())
                                .accessibilityIdentifier("licenses-retry")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
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
                SettingsDivider()
                informationRow("Build", value: info.build, id: "about-build")
                SettingsDivider()
                informationRow("Pi coding agent", value: componentVersion(DependencyNotice.piPackage),
                               id: "about-pi-version")
                SettingsDivider()
                informationRow("Node.js", value: componentVersion("node"), id: "about-node-version")
                SettingsDivider()
                informationRow("SwiftTerm", value: componentVersion("swiftterm"), id: "about-swiftterm-version")
                SettingsDivider()
                informationRow("Model providers", value: Provider.allCases.map(\.label).joined(separator: ", "),
                               id: "about-providers")
                if let openWelcome, let settingsFocus {
                    SettingsDivider()
                    SettingsRow("Welcome page", description: "Set up a model and add projects.") {
                        Button("Open", action: openWelcome)
                            .buttonStyle(T3SmallButtonStyle())
                            .accessibilityLabel("Open Welcome page")
                            .settingsTarget(.welcomePage, focus: settingsFocus)
                            .disabled(!welcomeEnabled)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                Text(info.name)
                    .font(.system(size: 12))
                    .foregroundStyle(T3Palette(colorScheme, t3Themes).mutedForeground)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 28)
                    .accessibilityIdentifier("about-app-name")
            }
            SettingsSection("Legal") {
                SettingsRow("Open-source licenses", description: "Notices for the software bundled with this app.") {
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

    @ViewBuilder
    private var versionRow: some View {
        let row = informationRow("Version", value: info.version, id: "about-version", chip: true)
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

    private func componentVersion(_ id: String) -> String? {
        notices?.first { $0.id == id }?.version
    }

    private func informationRow(_ label: String, value: String?, id: String, chip: Bool = false) -> some View {
        let palette = T3Palette(colorScheme, t3Themes)
        return SettingsRow(label) {
            Text(value ?? String(localized: "Unavailable"))
                .font(chip ? .system(size: 11, design: .monospaced) : .system(size: 14))
                .foregroundStyle(chip ? palette.foreground : palette.mutedForeground)
                .padding(.horizontal, chip ? 6 : 0)
                .padding(.vertical, chip ? 2 : 0)
                .background(chip ? palette.kbdFill : .clear, in: RoundedRectangle(cornerRadius: 4))
                .textSelection(.enabled)
                .lineLimit(1)
                .accessibilityIdentifier(id)
        }
    }
}

private struct LicensesView: View {
    let notices: [DependencyNotice]
    var settingsFocus: FocusState<SettingsFocus?>.Binding?
    @State private var query = ""
    @State private var selection: DependencyNotice.ID?

    private var filteredNotices: [DependencyNotice] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return notices.filter { notice in
            let metadata = [notice.name, notice.version, notice.license].compactMap { $0 }
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { metadata.contains($0) }
        }
    }

    private var searchField: some View {
        TextField("Search licenses", text: $query)
            .textFieldStyle(T3TextFieldStyle())
            .frame(maxWidth: 288)
    }

    var body: some View {
        let filtered = filteredNotices
        VStack(alignment: .leading, spacing: 8) {
            if let settingsFocus {
                searchField.settingsTarget(.licenses, focus: settingsFocus)
            } else {
                searchField.accessibilityIdentifier("licenses-search")
            }
            if filtered.isEmpty {
                Text("No licenses match that search.")
                    .accessibilityIdentifier("licenses-empty")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(filtered, selection: $selection) { notice in
                        Button {
                            selection = notice.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notice.name)
                                Text([notice.version, notice.license].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("license-entry-\(notice.id)")
                        .tag(notice.id)
                    }
                    .accessibilityIdentifier("licenses-list")
                    .frame(minWidth: settingsFocus == nil ? 220 : 170, idealWidth: settingsFocus == nil ? 270 : 226)
                    if let notice = filtered.first(where: { $0.id == selection }) {
                        noticeDetail(notice)
                            .id(notice.id)
                            .frame(minWidth: settingsFocus == nil ? 340 : 285, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Select a dependency to read its notices.")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: settingsFocus == nil ? 340 : 285, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private func noticeDetail(_ notice: DependencyNotice) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(notice.name).font(.title3.weight(.semibold))
                    .accessibilityIdentifier("license-notice-name")
                if let license = notice.license {
                    LabeledContent("Declared license", value: license)
                }
                if notice.texts.isEmpty {
                    Text("No notice text is included for this dependency.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("license-text-unavailable")
                }
                ForEach(notice.texts) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.file).font(.headline)
                        Text(entry.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("license-notice-text-\(entry.file)")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
