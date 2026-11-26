import SwiftUI
import UniformTypeIdentifiers

struct ProjectFolderView: View {
    let request: ProjectPickerRequest
    let open: (ProjectSource) async throws -> Void

    private enum Page {
        case sources, localFolder, newProject
    }

    private enum Field: Hashable {
        case path, name
    }

    @Environment(\.dismiss) private var dismiss
    @State private var page: Page
    @State private var path: String
    @State private var name = ""
    @State private var browsing = false
    @State private var browsedFolder: URL?
    @State private var submitting = false
    @State private var error: String?
    @FocusState private var focusedField: Field?

    init(request: ProjectPickerRequest, open: @escaping (ProjectSource) async throws -> Void) {
        self.request = request
        self.open = open
        _page = State(initialValue: request.relinking == nil ? .sources : .localFolder)
        _path = State(initialValue: request.initialPath)
    }

    private var title: String {
        switch page {
        case .sources: "Add project"
        case .localFolder: request.relinking == nil ? "Local folder" : "Relink project"
        case .newProject: "New project"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            if page == .sources {
                sourceButtons
            } else {
                if page == .newProject {
                    Text("Project name").font(.callout.weight(.medium))
                    TextField("Enter a project name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                        .accessibilityIdentifier("project-name")
                }
                pathInput
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("project-path-error")
                }
            }
            HStack {
                if page != .sources && request.relinking == nil {
                    Button("Back") { show(.sources) }
                        .accessibilityIdentifier("back-project-source")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .accessibilityIdentifier("cancel-project")
                if page != .sources {
                    Button(confirmTitle, action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  (page == .newProject && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("confirm-project")
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 485)
        .disabled(submitting)
        .interactiveDismissDisabled(submitting)
        .onChange(of: page, initial: true) { _, page in
            switch page {
            case .sources: focusedField = nil
            case .localFolder: focusedField = .path
            case .newProject: focusedField = .name
            }
        }
        .onChange(of: path) { _, _ in error = nil }
        .onChange(of: name) { _, _ in error = nil }
        .fileImporter(isPresented: $browsing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                browsedFolder = url
                path = url.path
                error = nil
            case .failure(let failure):
                if (failure as? CocoaError)?.code != .userCancelled { error = failure.localizedDescription }
            }
        }
        .fileDialogDefaultDirectory(browseDirectory)
    }

    private var sourceButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { show(.localFolder) } label: {
                Label("Local folder", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("project-source-local")
            Button { show(.newProject) } label: {
                Label("New project", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("project-source-new")
        }
        .buttonStyle(.bordered)
    }

    private var pathInput: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(page == .newProject ? "Parent folder" : "Project folder")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                TextField("Enter a folder path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .path)
                    .accessibilityIdentifier(page == .newProject ? "project-parent-path" : "project-path")
                Button("Browse…") { browsing = true }
                    .accessibilityIdentifier("browse-project")
            }
        }
    }

    private var confirmTitle: String {
        if page == .newProject { return "Create Project" }
        return request.relinking == nil ? "Add Project" : "Relink"
    }

    private var browseDirectory: URL? {
        if let folder = try? enteredFolder() {
            if (try? ProjectFolder.existing(at: folder)) != nil { return folder }
            return folder.deletingLastPathComponent()
        }
        return request.basePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func show(_ page: Page) {
        self.page = page
        path = page == .newProject
            ? request.basePath ?? FileManager.default.homeDirectoryForCurrentUser.path
            : request.initialPath
        name = ""
        browsedFolder = nil
        error = nil
    }

    private func enteredFolder() throws -> URL {
        if let browsedFolder, path == browsedFolder.path { return browsedFolder }
        return try ProjectFolder.resolve(path, relativeTo: request.basePath)
    }

    private func submit() {
        do {
            let folder = try enteredFolder()
            let source: ProjectSource = page == .newProject ? .newProject(name: name, parent: folder) : .localFolder(folder)
            submitting = true
            error = nil
            Task {
                defer { submitting = false }
                do {
                    try await open(source)
                    dismiss()
                } catch let failure {
                    error = failure.localizedDescription
                }
            }
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}
