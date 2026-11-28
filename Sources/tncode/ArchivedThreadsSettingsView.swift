import SwiftUI

enum ArchiveScope: Equatable {
    case all
    case project(UUID)
    case checkout(projectID: UUID, path: String)

    var projectID: UUID? {
        switch self {
        case .all: nil
        case let .project(id), let .checkout(id, _): id
        }
    }

    var checkoutPath: String? {
        if case let .checkout(_, path) = self { return path }
        return nil
    }
}

/// Settings → Archive (T3 Code's ArchivedThreadsPanel). The scope sentence above picks the project; a
/// project with several checkouts adds an "in [checkout]" menu.
struct ArchivedThreadsSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    let projectID: UUID?
    @Binding var checkout: String?
    let settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var failure: (projectID: UUID, threadID: UUID, message: String)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private var palette: T3Palette { T3Palette(colorScheme, t3Themes) }

    var body: some View {
        let projects = model.threadProjects
        let project = projects.first { $0.id == projectID }
        let paths = project.map { project in
            Set([project.path] + project.conversations.map { $0.workingLocation.directory(in: project) }).sorted()
        } ?? []

        LazyVStack(alignment: .leading, spacing: 32) {
            if let project, paths.count > 1 || checkout != nil {
                checkoutPicker(project, paths: paths)
            }
            if let error = model.startupFailure {
                SettingsSection("Archived threads") {
                    SettingsRow("Could not load archived threads", description: error.localizedDescription) { EmptyView() }
                }
                .accessibilityIdentifier("archive-load-error")
            } else if projectID != nil && project == nil {
                unavailable("This project is no longer available.")
            } else if let checkout, !paths.contains(checkout) {
                unavailable("This checkout is no longer available in the selected project and environment.")
            } else {
                archivedRows(in: project.map { [$0] } ?? projects, checkout: checkout)
            }
        }
        .onChange(of: projectID) { _, _ in checkout = nil }
    }

    private func checkoutPicker(_ project: Project, paths: [String]) -> some View {
        var options: [(String?, String)] = [(nil, String(localized: "All checkouts"))]
        if let path = checkout, !paths.contains(path) { options.append((path, String(localized: "Unavailable checkout"))) }
        options += paths.map { (Optional($0), $0) }
        return HStack(spacing: 6) {
            Text("in").font(.system(size: 14)).foregroundStyle(palette.mutedForeground)
            T3Select("Checkout scope", selection: $checkout, options: options, width: nil)
                .accessibilityIdentifier("archive-checkout")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, -20)
    }

    private func unavailable(_ message: String) -> some View {
        Text(localized: message)
            .font(.system(size: 14))
            .foregroundStyle(palette.mutedForeground)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("archive-scope-unavailable")
    }

    @ViewBuilder
    private func archivedRows(in projects: [Project], checkout: String?) -> some View {
        let rows = SidebarThread.matching(in: projects, search: "", archived: true).filter { row in
            checkout == nil || row.thread.workingLocation.directory(in: row.project) == checkout
        }
        let byProject = Dictionary(grouping: rows, by: \.project.id)
        if rows.isEmpty {
            SettingsSection("Archived threads") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox").font(.system(size: 13)).foregroundStyle(palette.mutedForeground)
                        Text("No archived threads").font(.system(size: 14, weight: .medium))
                    }
                    .frame(minHeight: 20)
                    Text("Archived threads will appear here.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("archive-empty")
            }
            .accessibilityElement(children: .contain)
            .focusable()
            .focusEffectDisabled()
            .settingsTarget(.archive, focus: settingsFocus)
        } else {
            let shown = projects.filter { byProject[$0.id] != nil }
            ForEach(shown) { project in
                if let projectRows = byProject[project.id] {
                    SettingsSection(project.displayTitle) {
                        ForEach(Array(projectRows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { SettingsDivider() }
                            archivedRow(row)
                        }
                    } icon: {
                        ProjectIconView(icon: project.icon, size: 14, projectName: project.title)
                    }
                    .modifier(ArchiveTarget(first: project.id == shown.first?.id, focus: settingsFocus))
                }
            }
        }
    }

    private func archivedRow(_ row: SidebarThread) -> some View {
        let path = row.thread.workingLocation.directory(in: row.project)
        let message = failure.flatMap { $0.projectID == row.project.id && $0.threadID == row.id ? $0.message : nil }
        let enabled = model.canChangeArchive(for: row.id)
        return SettingsRow(row.thread.title, description: path) {
            Button { unarchive(row) } label: {
                Image(systemName: "tray.and.arrow.up").font(.system(size: 13)).frame(width: 10)
            }
            .buttonStyle(T3SmallButtonStyle(kind: .outline))
            .help("Unarchive")
            .accessibilityLabel("Unarchive \(row.thread.title)")
            .accessibilityHint(path)
            .accessibilityIdentifier("archive-unarchive-\(row.id)")
            .disabled(!enabled)
        } detail: {
            if let message {
                SettingsMessage(String(localized: "Failed to unarchive thread. \(message)"))
                    .accessibilityIdentifier("archive-error-\(row.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archive-row-\(row.id)")
        .contextMenu {
            Button("Unarchive") { unarchive(row) }
                .disabled(!enabled)
        }
    }

    private func unarchive(_ row: SidebarThread) {
        do {
            try model.archiveConversation(row.id, in: row.project.id, archived: false)
            failure = nil
        } catch {
            failure = (row.project.id, row.id, error.localizedDescription)
        }
    }
}

/// Search lands on the first project's section, T3 Code's `id="archive"`.
private struct ArchiveTarget: ViewModifier {
    let first: Bool
    let focus: FocusState<SettingsFocus?>.Binding

    func body(content: Content) -> some View {
        if first {
            content.accessibilityElement(children: .contain).focusable().focusEffectDisabled()
                .settingsTarget(.archive, focus: focus)
        } else {
            content
        }
    }
}
