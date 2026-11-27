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

    var body: some View {
        let projects = model.threadProjects
        let projectID = scope.projectID
        let project = projects.first { $0.id == projectID }
        let checkout = scope.checkoutPath
        let paths = project.map { project in
            Set([project.path] + project.conversations.map { $0.workingLocation.directory(in: project) }).sorted()
        } ?? []

        LazyVStack(alignment: .leading, spacing: 12) {
            Text("Archived threads")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .focusable()
                .settingsTarget(.archive, focus: settingsFocus)

            if let error = model.startupFailure {
                Text("Could not load archived threads. \(error.localizedDescription)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("archive-load-error")
            } else {
                if !projects.isEmpty || projectID != nil { projectPicker(projects, selected: project) }
                if let project, paths.count > 1 || checkout != nil { checkoutPicker(project, paths: paths) }

                if projectID != nil && project == nil {
                    unavailable("This project is no longer open. Choose another project.")
                } else if let checkout, !paths.contains(checkout) {
                    unavailable("This checkout is no longer available. Choose another checkout.")
                } else {
                    archivedRows(in: project.map { [$0] } ?? projects, checkout: checkout)
                }
            }
        }
    }

    private func projectPicker(_ projects: [Project], selected: Project?) -> some View {
        Picker("Project", selection: Binding(get: { scope.projectID }, set: {
            scope = $0.map(ArchiveScope.project) ?? .all
        })) {
            Text("All projects").tag(nil as UUID?)
            if let id = scope.projectID, selected == nil {
                Text("Unavailable project").tag(Optional(id))
            }
            ForEach(projects) { project in
                let matchedTitle = projects.contains { $0.id != project.id && $0.title == project.title }
                Text(matchedTitle ? "\(project.title) (\(project.path))" : project.title).tag(Optional(project.id))
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("archive-project")
    }

    private func checkoutPicker(_ project: Project, paths: [String]) -> some View {
        Picker("Checkout", selection: Binding(get: { scope.checkoutPath }, set: {
            scope = $0.map { .checkout(projectID: project.id, path: $0) } ?? .project(project.id)
        })) {
            Text("All checkouts").tag(nil as String?)
            if let path = scope.checkoutPath, !paths.contains(path) {
                Text("Unavailable checkout").tag(Optional(path))
            }
            ForEach(paths, id: \.self) { path in
                Text(path).tag(Optional(path))
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("archive-checkout")
    }

    private func unavailable(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("archive-scope-unavailable")
    }

    @ViewBuilder
    private func archivedRows(in projects: [Project], checkout: String?) -> some View {
        let rows = SidebarThread.matching(in: projects, search: "", archived: true).filter { row in
            checkout == nil || row.thread.workingLocation.directory(in: row.project) == checkout
        }
        let byProject = Dictionary(grouping: rows, by: \.project.id)
        if rows.isEmpty {
            Text("No archived threads")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("archive-empty")
        } else {
            ForEach(projects) { project in
                if let projectRows = byProject[project.id] {
                    Text(project.title)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(projectRows) { row in
                        archivedRow(row)
                    }
                }
            }
        }
    }

    private func archivedRow(_ row: SidebarThread) -> some View {
        let path = row.thread.workingLocation.directory(in: row.project)
        let message = failure.flatMap { $0.projectID == row.project.id && $0.threadID == row.id ? $0.message : nil }
        let enabled = model.canChangeArchive(for: row.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.thread.title)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(message == nil ? "Unarchive" : "Retry Unarchive") { unarchive(row) }
                    .accessibilityLabel("Unarchive \(row.thread.title)")
                    .accessibilityHint(path)
                    .accessibilityIdentifier("archive-unarchive-\(row.id)")
                    .disabled(!enabled)
            }
            if let message {
                Text("Failed to unarchive thread. \(message)")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("archive-error-\(row.id)")
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
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
