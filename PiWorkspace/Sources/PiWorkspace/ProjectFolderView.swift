import Carbon
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
    @State private var listing: ProjectPathSuggestions.Listing?
    @State private var highlightedFolder: ProjectPathSuggestions.Row?
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
        let suggestions = pathSuggestions
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
                if let suggestions {
                    let rows = suggestions.rows(in: listing)
                    if !rows.isEmpty { folderSuggestions(rows, for: suggestions) }
                }
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
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancel-project")
                if page != .sources {
                    Button(confirmTitle, action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("confirm-project")
                }
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 485)
        .disabled(submitting)
        .interactiveDismissDisabled(submitting)
        .task(id: page) {
            switch page {
            case .sources: focusedField = nil
            case .localFolder: focusedField = .path
            case .newProject: focusedField = .name
            }
        }
        .onChange(of: path) { _, _ in
            error = nil
            highlightedFolder = nil
        }
        .onChange(of: name) { _, _ in error = nil }
        .onChange(of: browsing) { _, browsing in
            if !browsing, page == .localFolder { focusedField = .path }
        }
        .task(id: suggestions?.directory) {
            listing = nil
            guard let directory = suggestions?.directory,
                  let result = try? await ProjectPathSuggestions.Listing.load(directory),
                  !Task.isCancelled else { return }
            listing = result
        }
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
                pathField
                Button("Browse…") { browsing = true }
                    .accessibilityIdentifier("browse-project")
            }
        }
    }

    private var pathField: some View {
        TextField("Enter a folder path", text: $path)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .path)
            .accessibilityIdentifier(page == .newProject ? "project-parent-path" : "project-path")
            .background {
                if page == .localFolder {
                    ProjectPathKeyboard(isPathFocused: { focusedField == .path }, handle: handlePathKey)
                        .accessibilityHidden(true)
                }
            }
    }

    private var pathSuggestions: ProjectPathSuggestions? {
        guard page == .localFolder else { return nil }
        return ProjectPathSuggestions(path: path, basePath: request.basePath)
    }

    private func folderSuggestions(_ rows: [ProjectPathSuggestions.Row], for suggestions: ProjectPathSuggestions) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.self) { row in
                            folderRow(row, for: suggestions)
                                .id(row)
                        }
                    }
                    .padding(3)
                }
                .frame(height: min(168, CGFloat(rows.count) * 27 + 6))
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Folders")
                .accessibilityIdentifier("project-path-suggestions")
                .onChange(of: highlightedFolder) { _, row in
                    if let row { proxy.scrollTo(row) }
                }
            }
            Text("↑ ↓ Highlight, Tab Complete")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func folderRow(_ row: ProjectPathSuggestions.Row, for suggestions: ProjectPathSuggestions) -> some View {
        let title: String
        let icon: String
        let identifier: String
        switch row {
        case .parent:
            title = "Parent folder"
            icon = "arrow.turn.left.up"
            identifier = "project-path-up"
        case .folder(let name):
            title = name
            icon = "folder"
            identifier = "project-path-suggestion-\(name)"
        }
        return Button {
            guard let nextPath = suggestions.path(for: row) else { return }
            path = nextPath
            focusedField = .path
        } label: {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(highlightedFolder == row ? Color.accentColor.opacity(0.22) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .accessibilityAddTraits(highlightedFolder == row ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func handlePathKey(_ event: NSEvent) -> ProjectPathKeyboard.Response {
        guard !browsing, !submitting else { return .ignored }
        let key = Int(event.keyCode)
        switch key {
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Delete, kVK_UpArrow, kVK_DownArrow, kVK_Tab:
            break
        default:
            return .ignored
        }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if modifiers == .command && (key == kVK_Return || key == kVK_ANSI_KeypadEnter) {
            if !event.isARepeat { submit() }
            return .handled
        }
        guard modifiers.isEmpty else { return .ignored }
        if key == kVK_Delete {
            guard !event.isARepeat, path.isEmpty, request.relinking == nil else { return .ignored }
            show(.sources)
            return .handled
        }
        guard let suggestions = pathSuggestions else { return .ignored }
        let rows = suggestions.rows(in: listing)
        let selection = highlightedFolder.flatMap { rows.firstIndex(of: $0) }
        switch key {
        case kVK_UpArrow, kVK_DownArrow:
            guard !rows.isEmpty else { return .ignored }
            let index = key == kVK_DownArrow
                ? min((selection ?? -1) + 1, rows.count - 1)
                : max((selection ?? rows.count) - 1, 0)
            highlightedFolder = rows[index]
            return .handled
        case kVK_Tab:
            if let completion = suggestions.tabCompletion(in: rows, highlighted: highlightedFolder) {
                return .replacePath(completion)
            }
            return .handled
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if event.isARepeat { return .handled }
            guard let selection, let nextPath = suggestions.path(for: rows[selection]) else { return .ignored }
            return .replacePath(nextPath)
        default:
            return .ignored
        }
    }

    private var confirmTitle: String {
        if page == .newProject { return "Create Project" }
        return request.relinking == nil ? "Add Project" : "Relink"
    }

    private var canSubmit: Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (page != .newProject || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        highlightedFolder = nil
        error = nil
    }

    private func enteredFolder() throws -> URL {
        if let browsedFolder, path == browsedFolder.path { return browsedFolder }
        return try ProjectFolder.resolve(path, relativeTo: request.basePath)
    }

    private func submit() {
        guard canSubmit, !submitting else { return }
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
