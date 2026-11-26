import SwiftUI

struct ProjectOverviewSettingsView: View {
    @ObservedObject var model: WorkspaceModel
    let project: Project
    @Binding var title: String
    let pasteboard: NSPasteboard
    let openModelSettings: () -> Void
    @State private var checkouts: [GitCheckout] = []
    @State private var error: String?

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
