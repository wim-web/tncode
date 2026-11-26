import SwiftUI
import UniformTypeIdentifiers

struct ProjectFolderView: View {
    let request: ProjectPickerRequest
    let open: (URL, ProjectPickerRequest) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var browsing = false
    @State private var error: String?
    @FocusState private var pathFocused: Bool

    init(request: ProjectPickerRequest, open: @escaping (URL, ProjectPickerRequest) throws -> Void) {
        self.request = request
        self.open = open
        _path = State(initialValue: request.initialPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.relinking == nil ? "Add project" : "Relink project")
                .font(.title3.weight(.semibold))
            Text("Project folder")
                .font(.callout.weight(.medium))
            HStack(spacing: 8) {
                TextField("Enter a folder path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .focused($pathFocused)
                    .accessibilityIdentifier("project-path")
                Button("Browse…") { browsing = true }
                    .accessibilityIdentifier("browse-project")
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("project-path-error")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(request.relinking == nil ? "Add Project" : "Relink", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("confirm-project")
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 485)
        .onAppear { pathFocused = true }
        .onChange(of: path) { _, _ in error = nil }
        .fileImporter(isPresented: $browsing, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): path = url.path
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    private func submit() {
        let value = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        do {
            guard value.hasPrefix("/") else { throw WorkspaceError("Enter an absolute folder path or choose Browse.") }
            try open(URL(fileURLWithPath: value, isDirectory: true), request)
            dismiss()
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}
