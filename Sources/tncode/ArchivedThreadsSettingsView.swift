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

struct ArchivedThreadsSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var scope: ArchiveScope
    let settingsFocus: FocusState<SettingsFocus?>.Binding
    @State private var failure: (projectID: UUID, threadID: UUID, message: String)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private var palette: T3Palette { T3Palette(colorScheme, t3Themes) }

    var body: some View {
        let projects = model.threadProjects
        let projectID = scope.projectID
        let project = projects.first { $0.id == projectID }
        let checkout = scope.checkoutPath
        let paths = project.map { project in
            Set([project.path] + project.conversations.map { $0.workingLocation.directory(in: project) }).sorted()
        } ?? []

        LazyVStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Archived threads")
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .focusable()
                    .focusEffectDisabled()
                    .settingsTarget(.archive, focus: settingsFocus)
                if model.startupFailure == nil, !projects.isEmpty || projectID != nil {
                    HStack(spacing: 8) {
                        Text("Showing")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.mutedForeground)
                        projectPicker(projects, selected: project)
                        if let project, paths.count > 1 || checkout != nil { checkoutPicker(project, paths: paths) }
                    }
                }
            }
            .padding(.horizontal, 16)

            if let error = model.startupFailure {
                SettingsMessage(String(localized: "Could not load archived threads. \(error.localizedDescription)"), isError: false)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("archive-load-error")
            } else if projectID != nil && project == nil {
                unavailable("This project is no longer open. Choose another project.")
            } else if let checkout, !paths.contains(checkout) {
                unavailable("This checkout is no longer available. Choose another checkout.")
            } else {
                archivedRows(in: project.map { [$0] } ?? projects, checkout: checkout)
            }
        }
    }

    private func projectPicker(_ projects: [Project], selected: Project?) -> some View {
        var options: [(UUID?, String)] = [(nil, "All projects")]
        if let id = scope.projectID, selected == nil { options.append((id, "Unavailable project")) }
        for project in projects {
            let matchedTitle = projects.contains { $0.id != project.id && $0.title == project.title }
            options.append((project.id, matchedTitle ? "\(project.title) (\(project.path))" : project.title))
        }
        return T3Select("Project", selection: Binding(get: { scope.projectID }, set: {
            scope = $0.map(ArchiveScope.project) ?? .all
        }), options: options, width: 176)
        .accessibilityIdentifier("archive-project")
    }

    private func checkoutPicker(_ project: Project, paths: [String]) -> some View {
        var options: [(String?, String)] = [(nil, "All checkouts")]
        if let path = scope.checkoutPath, !paths.contains(path) { options.append((path, "Unavailable checkout")) }
        options += paths.map { (Optional($0), $0) }
        return T3Select("Checkout", selection: Binding(get: { scope.checkoutPath }, set: {
            scope = $0.map { .checkout(projectID: project.id, path: $0) } ?? .project(project.id)
        }), options: options, width: 224)
        .accessibilityIdentifier("archive-checkout")
    }

    private func unavailable(_ message: String) -> some View {
        SettingsSection {
            SettingsRow(message) { EmptyView() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("archive-scope-unavailable")
    }

    @ViewBuilder
    private func archivedRows(in projects: [Project], checkout: String?) -> some View {
        let rows = SidebarThread.matching(in: projects, search: "", archived: true).filter { row in
            checkout == nil || row.thread.workingLocation.directory(in: row.project) == checkout
        }
        let byProject = Dictionary(grouping: rows, by: \.project.id)
        if rows.isEmpty {
            SettingsSection {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: 13)).foregroundStyle(palette.mutedForeground)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No archived threads").font(.system(size: 14, weight: .medium))
                        Text("Archived threads will appear here.")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.mutedForeground)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("archive-empty")
        } else {
            ForEach(projects) { project in
                if let projectRows = byProject[project.id] {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ProjectIconView(icon: project.icon, projectName: project.title)
                            Text(project.displayTitle)
                                .font(.system(size: 16, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 28)
                        SettingsSection {
                            ForEach(Array(projectRows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { SettingsDivider() }
                                archivedRow(row)
                            }
                        }
                    }
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
                if message == nil {
                    Image(systemName: "tray.and.arrow.up").font(.system(size: 12))
                } else {
                    Text("Retry Unarchive")
                }
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
