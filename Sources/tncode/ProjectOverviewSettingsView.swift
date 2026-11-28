import SwiftUI

/// Settings → Projects (T3 Code's ProjectsSettings and ProjectSettingsPanel). The scope sentence picks the
/// project; without one, the page lists projects to choose from.
struct ProjectOverviewSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    let project: Project
    @Binding var title: String
    @State private var error: String?
    @State private var choosingIcon = false
    @State private var choosingIconFile = false
    @State private var iconError: String?
    @State private var removing = false
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsInfoAlert("Can't find a setting? Keep this project picked above and hop to any other settings page.")
            // "Project": its title is for screen readers only.
            SettingsSection {
                SettingsRow("Name", description: "The shared name for this project group in the sidebar and thread lists.") {
                    TextField("Project name", text: $title)
                        .frame(width: 256)
                        .focused($editingName)
                        .onSubmit { editingName = false }
                        .onChange(of: editingName) { _, editing in if !editing { rename() } }
                        .onDisappear { rename() }
                        .accessibilityIdentifier("project-settings-name")
                }
                SettingsDivider()
                projectIconSetting
                SettingsDivider()
                SettingsRow("Pin", description: "Pinned projects come first in project pickers.") {
                    SettingsSwitch("Pin project", isOn: Binding(get: { project.pinned == true }, set: {
                        model.setProjectPinned(project.id, pinned: $0)
                    }))
                    .accessibilityIdentifier("project-settings-pin")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Project")
            if let error {
                SettingsMessage(error).accessibilityIdentifier("project-settings-error")
            }
            SettingsSection("New threads") {
                DefaultModelRow(model: model, project: project)
            }
            SettingsSection("Danger") {
                SettingsRow("Remove project", description: "Removes the project from the sidebar. The folder and its threads stay on disk.") {
                    Button {
                        removing = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash").font(.system(size: 13))
                            Text("Remove project")
                        }
                    }
                    .buttonStyle(T3SmallButtonStyle(kind: .destructiveOutline))
                    .accessibilityIdentifier("project-settings-remove")
                }
            }
        }
        .confirmationDialog("Remove project \"\(project.title)\"?", isPresented: $removing) {
            Button("Remove project", role: .destructive) { model.removeProject(project.id) }
        } message: {
            Text("Path: \(project.path)\nThe folder and its threads stay on disk.")
        }
    }

    private var projectIconSetting: some View {
        SettingsRow("Project icon", description: project.icon?.summary ?? String(localized: "Automatic"),
                    reset: project.icon == nil ? nil :
                        SettingsResetButton("Reset project icon to default", id: "project-settings-reset-icon") {
                            updateIcon { nil }
                        }) {
            ProjectIconView(icon: project.icon, size: 24, projectName: project.title)
                .accessibilityIdentifier("project-settings-icon-preview")
            Button("Choose icon") { choosingIcon = true }
                .accessibilityLabel("Choose a project icon")
                .accessibilityIdentifier("project-settings-choose-icon")
            Button("Choose file") { choosingIconFile = true }
                .accessibilityLabel("Choose a project icon file")
                .accessibilityIdentifier("project-settings-choose-icon-file")
        } detail: {
            if let iconError {
                SettingsMessage(iconError).accessibilityIdentifier("project-settings-icon-error")
            }
        }
        .sheet(isPresented: $choosingIcon) {
            ProjectIconPicker(project: project) { icon in
                try model.setProjectIcon(icon, for: project.id)
                iconError = nil
            }
        }
        .fileImporter(isPresented: $choosingIconFile, allowedContentTypes: ProjectIcon.contentTypes) { result in
            updateIcon { try ProjectIcon.importing(result.get()) }
        }
        .fileDialogDefaultDirectory(project.folderIsAvailable ? URL(fileURLWithPath: project.path, isDirectory: true) : nil)
    }

    private func updateIcon(_ icon: () throws -> ProjectIcon?) {
        do {
            try model.setProjectIcon(icon(), for: project.id)
            iconError = nil
        } catch {
            if (error as? CocoaError)?.code != .userCancelled { iconError = error.localizedDescription }
        }
    }

    /// Saves on Return or when the field loses focus; an empty name goes back to the saved one.
    private func rename() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            title = project.title
            error = String(localized: "Project title cannot be empty")
            return
        }
        guard name != project.title else { return }
        if model.renameProject(project.id, title: name) {
            title = name
            error = nil
        } else {
            error = model.error ?? String(localized: "Failed to rename project")
        }
    }
}

/// Projects page before a project is picked: a prompt and the projects to choose from.
struct ProjectChooserView: View {
    @ObservedObject var model: WorkspaceModel
    let choose: (UUID) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        if model.projects.isEmpty {
            Text("Add a project from the sidebar to configure it here.")
                .font(.system(size: 14))
                .foregroundStyle(palette.mutedForeground)
                .frame(maxWidth: .infinity)
                .padding(32)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose a project to manage its name, icon, checkouts and actions.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.horizontal, 16)
                SettingsSection {
                    ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { SettingsDivider() }
                        ProjectChooserRow(project: project) { choose(project.id) }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-project-chooser")
        }
    }
}

private struct ProjectChooserRow: View {
    let project: Project
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        Button(action: action) {
            HStack(spacing: 12) {
                ProjectIconView(icon: project.icon, size: 16, projectName: project.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: project.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Text(verbatim: project.path)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.mutedForeground)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(hovering ? palette.accentFill.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(project.path)
        .accessibilityIdentifier("settings-project-choose-\(project.id.uuidString)")
    }
}

/// Info alert: 12pt-radius box with an info icon, T3 Code's `Alert variant="info"`.
struct SettingsInfoAlert: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    init(_ text: String) { self.text = text }

    var body: some View {
        let palette = T3Palette(colorScheme, t3Themes)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(palette.info)
            Text(localized: text)
                .font(.system(size: 14))
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.info.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.info.opacity(0.32)) }
    }
}
