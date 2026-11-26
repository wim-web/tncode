import AppKit
import SwiftUI

struct WorkspaceFilesView: View {
    let location: WorkspaceFilesLocation
    let saves: WorkspaceFileSaves
    let pasteboard: NSPasteboard
    let activeLocation: () -> WorkspaceFilesLocation?
    let close: () -> Void
    @Binding var selection: String?

    @State private var tree: Result<WorkspaceFileTree, Error>?
    @State private var expanded: Set<String> = []
    @State private var folder = ""
    @State private var query = ""
    @State private var refreshing = 0
    @State private var showingExplorer = true

    private var target: WorkspaceFileTarget? {
        selection.map { WorkspaceFileTarget(location: location, path: $0) }
    }

    private var entries: [WorkspaceFileEntry] {
        guard case let .success(tree) = tree else { return [] }
        return tree.entries
    }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Files").font(.system(size: 13, weight: .semibold))
                Spacer()
                fileButton("Refresh Files", "arrow.clockwise", id: "files-refresh") { refreshing += 1 }
                fileButton("Hide Files", "xmark", id: "files-close", action: close)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()
            GeometryReader { geometry in
                if let target {
                    let twoColumns = geometry.size.width >= 416
                    let explorerWidth = min(256, geometry.size.width - 256)
                    let layout = twoColumns ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        if showingExplorer {
                            explorer
                                .frame(width: twoColumns ? explorerWidth : nil,
                                       height: twoColumns ? nil : min(190, geometry.size.height * 0.38))
                            Divider()
                        }
                        WorkspaceFilePreviewView(
                            target: target, saves: saves, pasteboard: pasteboard, refreshing: refreshing,
                            activeTarget: { activeLocation() == location ? self.target : nil },
                            showingExplorer: $showingExplorer, goToFolder: goToFolder,
                            folderEntries: { parent in entries.filter { $0.parent == parent && $0.kind != .link } },
                            openFile: openFile,
                            close: { selection = nil }
                        )
                        .id(target)
                    }
                } else {
                    explorer
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-panel")
        .task(id: refreshing) {
            let directory = location.directory
            do {
                let result = try await loadWorkspaceFiles { try WorkspaceFiles(directory: directory).tree() }
                try Task.checkCancellation()
                tree = .success(result)
            } catch {
                if !Task.isCancelled { tree = .failure(error) }
            }
        }
    }

    private var explorer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                TextField("Search files", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("files-search")
                    .onSubmit {
                        if let match = rows.first(where: { $0.kind == .file }) { openFile(match.path) }
                    }
                Menu {
                    Button("Expand All Folders") {
                        expanded = Set(entries.filter { $0.kind == .folder }.map(\.path))
                    }
                    .accessibilityIdentifier("files-expand-all")
                    Button("Collapse All Folders") { expanded.removeAll() }
                        .accessibilityIdentifier("files-collapse-all")
                    let unsaved = saves.paths(in: location)
                    if !unsaved.isEmpty {
                        Menu("Unsaved Files") {
                            ForEach(unsaved, id: \.self) { path in
                                Button(path) { openFile(path) }
                                    .accessibilityIdentifier("files-unsaved-row-" + path)
                            }
                        }
                        .accessibilityIdentifier("files-unsaved-files")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Folder Actions")
                .accessibilityIdentifier("files-folder-actions")
            }
            .padding(8)

            if !folder.isEmpty {
                Button {
                    goToFolder(String(folder.split(separator: "/").dropLast().joined(separator: "/")))
                } label: {
                    Label(folder, systemImage: "arrow.up")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
                .accessibilityIdentifier("files-parent-folder")
            }

            switch tree {
            case .none:
                ProgressView().controlSize(.small).padding(12)
            case .failure(let error):
                Text(error.localizedDescription)
                    .padding(12)
                    .accessibilityIdentifier("files-tree-error")
            case .success(let tree):
                if tree.truncated {
                    Text("Only part of this file tree is shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .accessibilityIdentifier("files-tree-limit")
                }
                let rows = rows
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if rows.isEmpty {
                            Text(searching ? "No matching files." : "No files in this folder.")
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                        ForEach(rows) { entry in
                            fileRow(entry)
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.bottom, 5)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var rows: [WorkspaceFileEntry] {
        guard case let .success(tree) = tree else { return [] }
        if searching { return tree.matching(query) }
        return tree.entries.filter { entry in
            if !folder.isEmpty && !entry.path.hasPrefix(folder + "/") { return false }
            var parent = entry.parent
            while parent != folder && !parent.isEmpty {
                guard expanded.contains(parent) else { return false }
                parent = String(parent.split(separator: "/").dropLast().joined(separator: "/"))
            }
            return parent == folder
        }
    }

    private func fileRow(_ entry: WorkspaceFileEntry) -> some View {
        let isFolder = entry.kind == .folder
        let name = searching ? entry.path : entry.name
        let symbol = switch entry.kind {
        case .folder: expanded.contains(entry.path) ? "chevron.down" : "chevron.right"
        case .file: "doc"
        case .link: "link"
        }
        let indent = searching ? 0 : min(12, entry.path.split(separator: "/").count -
                                        folder.split(separator: "/").count - 1)
        return Button {
            if isFolder {
                if searching {
                    goToFolder(entry.path)
                } else if expanded.remove(entry.path) == nil {
                    expanded.insert(entry.path)
                }
            } else {
                openFile(entry.path)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).frame(width: 12)
                Text(name).lineLimit(1).truncationMode(.middle)
                if saves.hasDraft(for: WorkspaceFileTarget(location: location, path: entry.path)) {
                    Circle().fill(.orange).frame(width: 5, height: 5)
                        .accessibilityLabel("Unsaved")
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.leading, CGFloat(indent * 11 + 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry.kind == .link)
        .background(selection == entry.path ? Color.accentColor.opacity(0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .help(entry.kind == .link ? "Symbolic link" : entry.path)
        .accessibilityAddTraits(selection == entry.path ? .isSelected : [])
        .accessibilityIdentifier("files-row-" + entry.path)
    }

    private func goToFolder(_ path: String) {
        folder = path
        query = ""
        showingExplorer = true
    }

    private func openFile(_ path: String) {
        selection = path
    }
}

private struct WorkspaceFilePreviewView: View {
    let target: WorkspaceFileTarget
    let saves: WorkspaceFileSaves
    let pasteboard: NSPasteboard
    let refreshing: Int
    let activeTarget: () -> WorkspaceFileTarget?
    @Binding var showingExplorer: Bool
    let goToFolder: (String) -> Void
    let folderEntries: (String) -> [WorkspaceFileEntry]
    let openFile: (String) -> Void
    let close: () -> Void

    @State private var session: WorkspaceFileSaveSession?
    @State private var actionError: String?
    @State private var confirmDiscard = false
    @State private var wraps = true
    @State private var reload = 0

    private struct ReadRequest: Equatable {
        let session: ObjectIdentifier?
        let refresh: Int
        let reload: Int
    }

    private var draft: WorkspaceFileDraft? { session?.draft }

    private var pathComponents: [String] { target.path.components(separatedBy: "/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumbs
            HStack(spacing: 9) {
                fileButton(showingExplorer ? "Hide File Explorer" : "Show File Explorer",
                           "sidebar.left", id: "files-toggle-explorer") { showingExplorer.toggle() }
                fileButton("Close File", "xmark", id: "files-close-preview", action: close)
                Spacer(minLength: 0)
                if draft != nil {
                    Text("Unsaved").foregroundStyle(.secondary)
                        .accessibilityIdentifier("files-unsaved")
                }
                previewMenu
                Button("Save") { session?.flush() }
                    .disabled(draft == nil || session?.isEditable != true)
                    .accessibilityIdentifier("files-save")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            Divider()
            if session?.isReadOnly == true {
                let message = draft == nil ? "Read-only" : "Read-only. Unsaved edits are kept until write access returns."
                status(message, id: "files-read-only")
            } else if let message = actionError ?? session?.saveError?.localizedDescription ??
                        (session?.changedOnDisk == true ? WorkspaceFileError.changed.localizedDescription : nil) {
                status(message, id: "files-save-error")
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-preview")
        .onAppear {
            if session == nil { session = saves.acquire(target) }
        }
        .onDisappear {
            guard let session else { return }
            self.session = nil
            saves.release(session)
        }
        .onChange(of: refreshing) { _, _ in actionError = nil }
        .task(id: ReadRequest(session: session.map(ObjectIdentifier.init), refresh: refreshing, reload: reload)) {
            await session?.refresh()
        }
        .alert("Discard unsaved edits?", isPresented: $confirmDiscard) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Edits", role: .destructive) {
                session?.discard()
                actionError = nil
                reload += 1
            }
            .accessibilityIdentifier("files-confirm-discard")
        } message: {
            Text("Reload \(pathComponents.last ?? target.path) from disk.")
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Button {
                    goToFolder("")
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Workspace Root")
                .accessibilityIdentifier("files-breadcrumb-root")
                ForEach(pathComponents.indices, id: \.self) { index in
                    let path = pathComponents.prefix(index + 1).joined(separator: "/")
                    let parent = pathComponents.prefix(index).joined(separator: "/")
                    Image(systemName: "chevron.right").font(.system(size: 8)).accessibilityHidden(true)
                    if index < pathComponents.count - 1 {
                        Button(pathComponents[index]) { goToFolder(path) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("files-breadcrumb-" + path)
                    } else {
                        Menu {
                            ForEach(folderEntries(parent)) { entry in
                                Button(entry.name) {
                                    if entry.kind == .folder { goToFolder(entry.path) }
                                    else { openFile(entry.path) }
                                }
                            }
                        } label: {
                            Text(pathComponents[index]).fontWeight(.semibold)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityIdentifier("files-breadcrumb-file")
                    }
                }
            }
            .font(.caption)
            .fixedSize(horizontal: true, vertical: false)
            .padding(8)
        }
    }

    private var previewMenu: some View {
        Menu {
            Button("Copy Path") { copy(target.path) }
                .accessibilityIdentifier("files-copy-path")
            if let text = draft?.text ?? session?.diskText?.text {
                Button("Copy Contents") { copy(text) }
                    .accessibilityIdentifier("files-copy-contents")
            }
            Button(wraps ? "Disable Word Wrap" : "Enable Word Wrap") { wraps.toggle() }
                .accessibilityIdentifier("files-word-wrap")
            Divider()
            Button("Open in Default App") { openExternally(reveal: false) }
                .accessibilityIdentifier("files-open-default-app")
            Button("Show in Finder") { openExternally(reveal: true) }
                .accessibilityIdentifier("files-show-in-finder")
            if draft != nil {
                Divider()
                Button("Discard Edits…", role: .destructive) { confirmDiscard = true }
                    .accessibilityIdentifier("files-discard")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("File Actions")
        .accessibilityIdentifier("files-file-actions")
    }

    @ViewBuilder
    private var content: some View {
        if let session, let source = session.editorSource {
            FileTextView(text: draft?.text ?? source.text, editable: session.isEditable, wraps: wraps,
                         identifier: "files-editor") { text in
                guard self.session === session else { return }
                session.edit(text, from: source)
            }
        } else {
            switch session?.preview {
            case .none:
                ProgressView().controlSize(.small).padding(12)
            case .failure(let error):
                status(error.localizedDescription, id: "files-preview-error")
            case .success(.text):
                EmptyView()
            case .success(.largeText(let prefix, let size)):
                status("Large file (\(formattedSize(size))). Showing the first 1 MiB.", id: "files-large-preview")
                FileTextView(text: prefix, editable: false, wraps: wraps, identifier: "files-contents")
            case .success(.binary(let prefix, let size)):
                status("Binary file (\(formattedSize(size))). Showing \(prefix.count) bytes.", id: "files-binary-preview")
                FileTextView(text: hexadecimal(prefix), editable: false, wraps: false, identifier: "files-contents")
            }
        }
    }

    private func status(_ message: String, id: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(8)
            .accessibilityIdentifier(id)
    }

    private func openExternally(reveal: Bool) {
        guard activeTarget() == target else { return }
        do {
            let url = try WorkspaceFiles(directory: target.location.directory).fileURL(target.path)
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if !NSWorkspace.shared.open(url) {
                throw WorkspaceError("The default app could not open this file.")
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func formattedSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func hexadecimal(_ bytes: Data) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes.dropFirst(offset).prefix(16)
            return String(format: "%08X  ", offset) +
                row.map { String(format: "%02X", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

private func fileButton(_ label: String, _ symbol: String, id: String,
                        action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 18) }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
}

private struct FileTextView: NSViewRepresentable {
    let text: String
    let editable: Bool
    let wraps: Bool
    let identifier: String
    var edit: ((String) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel("File Contents")
        textView.setAccessibilityIdentifier(identifier)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.edit = nil
        textView.isEditable = editable
        textView.setAccessibilityIdentifier(identifier)
        if !textView.string.utf8.elementsEqual(text.utf8) {
            textView.string = text
            textView.undoManager?.removeAllActions(withTarget: textView)
        }
        context.coordinator.edit = edit
        if let container = textView.textContainer, container.widthTracksTextView != wraps {
            scroll.hasHorizontalScroller = !wraps
            textView.isHorizontallyResizable = !wraps
            textView.autoresizingMask = wraps ? [.width] : []
            container.containerSize = NSSize(width: wraps ? max(1, scroll.contentSize.width) : .greatestFiniteMagnitude,
                                             height: .greatestFiniteMagnitude)
            container.widthTracksTextView = wraps
            if wraps { textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: textView.frame.height)) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.edit = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var edit: ((String) -> Void)?

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            edit?(textView.string)
        }
    }
}
