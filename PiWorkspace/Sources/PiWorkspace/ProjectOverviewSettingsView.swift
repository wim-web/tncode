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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("Project name", text: $title)
                    .accessibilityIdentifier("project-settings-name")
                    .onSubmit(rename)
                Button("Save Name", action: rename)
                    .disabled(trimmedTitle.isEmpty || trimmedTitle == project.title)
                    .accessibilityIdentifier("project-settings-save-name")
            }
            projectIconSetting
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Project folder", systemImage: "folder")
                        .fontWeight(.medium)
                    Spacer()
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
                Text(project.path)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("project-settings-path")
                if !folderIsAvailable {
                    Text("The project folder is no longer available.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("project-settings-folder-unavailable")
                }
            }
            Toggle("Pin project", isOn: Binding(get: { project.pinned == true }, set: {
                model.setProjectPinned(project.id, pinned: $0)
            }))
            .accessibilityIdentifier("project-settings-pin")
            Button("Model Settings", action: openModelSettings)
                .disabled(!model.canOpenModelSettings)
                .accessibilityIdentifier("project-settings-model")
            if folderIsAvailable && !checkouts.isEmpty {
                Divider()
                Text("Git checkouts").fontWeight(.medium)
                ForEach(checkouts, id: \.path) { checkout in
                    VStack(alignment: .leading, spacing: 3) {
                        if let branch = checkout.branch {
                            Text(branch).foregroundStyle(.secondary)
                        }
                        Text(checkout.path)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("project-settings-checkout-\(checkout.path)")
                    }
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("project-settings-error")
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Project icon").fontWeight(.medium)
                ProjectIconView(icon: project.icon, size: 28)
                    .accessibilityIdentifier("project-settings-icon-preview")
                Spacer()
                Button("Choose icon") { choosingIcon = true }
                    .accessibilityIdentifier("project-settings-choose-icon")
                Button("Choose file") { choosingIconFile = true }
                    .accessibilityLabel("Choose a project icon file")
                    .accessibilityIdentifier("project-settings-choose-icon-file")
                if project.icon != nil {
                    Button("Reset") {
                        updateIcon { nil }
                    }
                    .help("Reset project icon to default")
                    .accessibilityLabel("Reset project icon to default")
                    .accessibilityIdentifier("project-settings-reset-icon")
                }
            }
            if let iconError {
                Text(iconError).foregroundStyle(.red).accessibilityIdentifier("project-settings-icon-error")
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
