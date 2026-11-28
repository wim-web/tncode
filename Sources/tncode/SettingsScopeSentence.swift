import SwiftUI

/// "Applying settings for [project ▾] on [machine ▾]" at the top of scoped settings pages (T3 Code's
/// SettingsScopeSentence). tncode has one machine, so its menu holds only this Mac.
struct SettingsScopeSentence: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var request: SettingsRequest
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        let projects = model.projects
        let selected = projects.first { $0.id == request.projectID }
        // Word order differs by language (Japanese reads "[project]の設定を [machine]に適用中").
        let parts = (beforeProject: String(localized: "settings.scope.beforeProject", defaultValue: "Applying settings for"),
                     afterProject: String(localized: "settings.scope.afterProject", defaultValue: ""),
                     beforeEnvironment: String(localized: "settings.scope.beforeEnvironment", defaultValue: "on"),
                     afterEnvironment: String(localized: "settings.scope.afterEnvironment", defaultValue: ""))
        HStack(spacing: 6) {
            if !parts.beforeProject.isEmpty { Text(verbatim: parts.beforeProject) }
            SettingsScopeMenu(
                label: selected?.title ?? (request.projectID == nil ? String(localized: "All projects")
                                                                   : String(localized: "Unavailable project")),
                accessibility: "Project scope",
                icon: { if let selected { ProjectIconView(icon: selected.icon, size: 14, projectName: selected.title) } },
                options: [(nil, String(localized: "All projects"))] + projects.map { ($0.id, $0.title) },
                selection: request.projectID,
                separatorAfterFirst: true
            ) { request.selectProject($0) }
            .accessibilityIdentifier("settings-scope-project")
            if !parts.afterProject.isEmpty { Text(verbatim: parts.afterProject) }
            if !parts.beforeEnvironment.isEmpty { Text(verbatim: parts.beforeEnvironment) }
            SettingsScopeMenu(
                label: ProviderEnvironment.label, accessibility: "Environment scope",
                icon: { Image(systemName: "laptopcomputer").font(.system(size: 12)) },
                options: [(Optional<UUID>.none, ProviderEnvironment.label)], selection: nil, separatorAfterFirst: false
            ) { _ in }
            .accessibilityIdentifier("settings-scope-environment")
            if !parts.afterEnvironment.isEmpty { Text(verbatim: parts.afterEnvironment) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .foregroundStyle(palette.mutedForeground)
        .padding(.horizontal, 16)
    }
}

/// Outline sm trigger (28pt, max 288pt) with a chevron that opens a radio menu.
private struct SettingsScopeMenu<Icon: View>: View {
    let label: String
    let accessibility: String
    @ViewBuilder let icon: Icon
    let options: [(UUID?, String)]
    let selection: UUID?
    let separatorAfterFirst: Bool
    let choose: (UUID?) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    init(label: String, accessibility: String, @ViewBuilder icon: () -> Icon, options: [(UUID?, String)],
         selection: UUID?, separatorAfterFirst: Bool, choose: @escaping (UUID?) -> Void) {
        self.label = label
        self.accessibility = accessibility
        self.icon = icon()
        self.options = options
        self.selection = selection
        self.separatorAfterFirst = separatorAfterFirst
        self.choose = choose
    }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    choose(option.0)
                } label: {
                    if option.0 == selection { Label(option.1, systemImage: "checkmark") } else { Text(verbatim: option.1) }
                }
                if index == 0 && separatorAfterFirst && options.count > 1 { Divider() }
            }
        } label: {
            HStack(spacing: 6) {
                icon
                Text(verbatim: label).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.mutedForeground.opacity(0.7))
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .frame(maxWidth: 288)
            .background(palette.outlineFill, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.outlineBorder) }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("\(NSLocalizedString(accessibility, comment: "")): \(label)"))
    }
}
