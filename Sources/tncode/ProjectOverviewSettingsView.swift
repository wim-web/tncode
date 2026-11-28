import SwiftUI

struct ProjectOverviewSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    let project: Project
    @Binding var title: String
    let pasteboard: NSPasteboard
    let openModelSettings: () -> Void
    @State private var checkouts: [GitCheckout] = []
    @State private var error: String?
    @State private var choosingIcon = false
    @State private var choosingIconFile = false
    @State private var iconError: String?

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let folderIsAvailable = project.folderIsAvailable
        VStack(alignment: .leading, spacing: 32) {
            SettingsSection("Project") {
                SettingsRow("Name") {
                    TextField("Project name", text: $title)
                        .frame(width: 256)
                        .accessibilityIdentifier("project-settings-name")
                        .onSubmit(rename)
                    Button("Save", action: rename)
                        .disabled(trimmedTitle.isEmpty || trimmedTitle == project.title)
                        .accessibilityIdentifier("project-settings-save-name")
                }
                SettingsDivider()
                projectIconSetting
                SettingsDivider()
                SettingsRow("Project folder", description: project.path, descriptionID: "project-settings-path",
                            status: folderIsAvailable ? nil : "The project folder is no longer available.",
                            statusID: "project-settings-folder-unavailable") {
                    Button("Copy path") {
                        do {
                            try model.copyProjectPath(project.id, to: pasteboard)
                            error = nil
                        } catch let failure {
                            error = failure.localizedDescription
                        }
                    }
                    .disabled(!folderIsAvailable)
                    .accessibilityIdentifier("project-settings-copy-path")
                }
                SettingsDivider()
                SettingsRow("Pin", description: "Keep this project at the top of the sidebar.") {
                    SettingsSwitch("Pin project", isOn: Binding(get: { project.pinned == true }, set: {
                        model.setProjectPinned(project.id, pinned: $0)
                    }))
                    .accessibilityIdentifier("project-settings-pin")
                }
                SettingsDivider()
                SettingsRow("Model", description: "Choose a model for this project or inherit the workspace default.") {
                    Button("Model settings", action: openModelSettings)
                        .disabled(!model.canOpenModelSettings)
                        .accessibilityIdentifier("project-settings-model")
                }
            }
            if folderIsAvailable && !checkouts.isEmpty {
                SettingsSection("Checkouts") {
                    ForEach(Array(checkouts.enumerated()), id: \.element.path) { index, checkout in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(checkout.branch ?? "Detached", description: checkout.path,
                                    descriptionID: "project-settings-checkout-\(checkout.path)") {
                            EmptyView()
                        }
                    }
                }
            }
            if let error {
                SettingsMessage(error).accessibilityIdentifier("project-settings-error")
            }
        }
        .task(id: project.path) {
            checkouts = []
            guard folderIsAvailable else { return }
            let listed = try? await GitWorkspace(path: project.path).worktrees()
            if !Task.isCancelled { checkouts = listed ?? [] }
        }
    }

    private var projectIconSetting: some View {
        SettingsRow("Project icon", description: "Shown in the sidebar and breadcrumbs.",
                    reset: project.icon == nil ? nil :
                        SettingsResetButton("Reset project icon to default", id: "project-settings-reset-icon") {
                            updateIcon { nil }
                        }) {
            ProjectIconView(icon: project.icon, size: 24, projectName: project.title)
                .accessibilityIdentifier("project-settings-icon-preview")
            Button("Choose icon") { choosingIcon = true }
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

    private func rename() {
        let name = trimmedTitle
        guard !name.isEmpty, name != project.title else { return }
        if model.renameProject(project.id, title: name) {
            title = name
            error = nil
        } else {
            error = model.error ?? "Couldn’t save the project name."
        }
    }
}
