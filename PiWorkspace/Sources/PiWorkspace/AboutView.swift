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

    var body: some View {
        Group {
            if showingLicenses {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("About", systemImage: "chevron.left") { showingLicenses = false }
                            .accessibilityIdentifier("licenses-back")
                        Text("Open source licenses").font(.headline)
                    }
                    if let notices {
                        LicensesView(notices: notices, settingsFocus: settingsFocus)
                    } else {
                        VStack(spacing: 12) {
                            Text("Open-source notices are unavailable in this app bundle.")
                                .accessibilityIdentifier("licenses-unavailable")
                            Button("Try Again") { notices = DependencyNotice.load() }
                                .accessibilityIdentifier("licenses-retry")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(16)
            } else {
                appInformation
            }
        }
    }

    private var appInformation: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text(info.name)
                    .font(.title.weight(.semibold))
                    .accessibilityIdentifier("about-app-name")
            }
            VStack(spacing: 6) {
                versionRow
                informationRow("Build", value: info.build, id: "about-build")
                Divider()
                informationRow("Pi coding agent", value: componentVersion(DependencyNotice.piPackage),
                               id: "about-pi-version")
                informationRow("Node.js", value: componentVersion("node"), id: "about-node-version")
                informationRow("SwiftTerm", value: componentVersion("swiftterm"), id: "about-swiftterm-version")
                informationRow("Model providers", value: Provider.allCases.map(\.label).joined(separator: ", "),
                               id: "about-providers")
            }
            .frame(width: 450)
            if let openWelcome, let settingsFocus {
                LabeledContent("Welcome page") {
                    Button("Open", action: openWelcome)
                        .accessibilityLabel("Open Welcome page")
                        .settingsTarget(.welcomePage, focus: settingsFocus)
                        .disabled(!welcomeEnabled)
                }
                .frame(width: 450)
            }
            Button("Open source licenses…") {
                notices = DependencyNotice.load()
                showingLicenses = true
            }
            .accessibilityIdentifier("about-licenses")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var versionRow: some View {
        let row = informationRow("Version", value: info.version, id: "about-version")
        if let settingsFocus {
            row
                .accessibilityElement(children: .contain)
                .focusable()
                .settingsTarget(.appVersion, focus: settingsFocus)
        } else {
            row
        }
    }

    private func componentVersion(_ id: String) -> String? {
        notices?.first { $0.id == id }?.version
    }

    private func informationRow(_ label: String, value: String?, id: String) -> some View {
        LabeledContent(label) {
            Text(value ?? "Unavailable")
                .textSelection(.enabled)
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
