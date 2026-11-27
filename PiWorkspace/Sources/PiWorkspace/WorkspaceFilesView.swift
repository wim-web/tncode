import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceFileLineReveal: Equatable {
    let target: WorkspaceFileTarget
    let line: Int
    let id = UUID()

    func range(in text: NSString) -> NSRange? {
        guard line > 0 else { return nil }
        var start = 0
        for number in 1...line {
            let end = text.range(of: "\n", options: .literal, range: NSRange(location: start, length: text.length - start))
            if number == line {
                let limit = end.location == NSNotFound ? text.length : end.location
                let cr = limit > start && text.character(at: limit - 1) == 13
                return NSRange(location: start, length: limit - start - (cr ? 1 : 0))
            }
            guard end.location != NSNotFound else { return nil }
            start = NSMaxRange(end)
        }
        return nil
    }
}

struct WorkspaceFilesView: View {
    let location: WorkspaceFilesLocation
    let saves: WorkspaceFileSaves
    let pasteboard: NSPasteboard
    let activeLocation: () -> WorkspaceFilesLocation?
    let close: () -> Void
    let canAddToComposer: Bool
    let addToComposer: (WorkspaceFileTarget) throws -> Void
    let beginMentionDrag: (WorkspaceFileTarget) -> NSItemProvider?
    @Binding var selection: String?
    var lineReveal: WorkspaceFileLineReveal? = nil

    @State private var tree: Result<WorkspaceFileTree, Error>?
    @State private var expanded: Set<String> = []
    @State private var folder = ""
    @State private var query = ""
    @State private var refreshing = 0
    @State private var showingExplorer = true
    @State private var recovery: WorkspaceFileSaveSession?
    @State private var mentionError: String?

    static func saveFocusedFile(in window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView,
              let coordinator = editor.delegate as? FileTextView.Coordinator,
              let session = coordinator.saveSession, editor.isEditable, session.isEditable else { return false }
        session.flush()
        return true
    }

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
            if let mentionError {
                Text(mentionError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .accessibilityIdentifier("files-mention-error")
            }
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
                            lineReveal: lineReveal?.target == target ? lineReveal : nil,
                            activeTarget: { activeLocation() == location ? self.target : nil },
                            showingExplorer: $showingExplorer, goToFolder: goToFolder,
                            folderEntries: { parent in entries.filter { $0.parent == parent && $0.kind != .link } },
                            openFile: openFile,
                            mentionActions: mentionActions(for: target, fromPreview: true),
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
        .alert("Recover unsaved edits?", isPresented: Binding(
            get: { recovery != nil }, set: { if !$0 { recovery = nil } }
        ), presenting: recovery) { session in
            Button("Copy Contents") {
                guard let text = session.draft?.text else { return }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            .accessibilityIdentifier("files-recovery-copy")
            Button("Discard Edits", role: .destructive) { session.discard() }
                .accessibilityIdentifier("files-recovery-discard")
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("The unsaved edits belong to \(session.target.fullPath). Discarding them removes the draft.")
        }
        .task(id: refreshing) {
            mentionError = nil
            saves.recoverMovedDrafts(in: location)
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
                    let unsaved = saves.pendingFiles(for: location.threadID)
                    if !unsaved.isEmpty {
                        Menu("Unsaved Files") {
                            ForEach(unsaved, id: \.target) { session in
                                if session.target.location == location {
                                    Button(session.target.path) { openFile(session.target.path) }
                                        .accessibilityIdentifier("files-unsaved-row-" + session.target.path)
                                } else {
                                    Button(session.target.fullPath) { recovery = session }
                                        .accessibilityIdentifier("files-unsaved-row-" + session.target.fullPath)
                                }
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
        let file = WorkspaceFileTarget(location: location, path: entry.path)
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
        .contextMenu {
            if entry.kind != .link {
                mentionActions(for: file, fromPreview: false)
            }
        }
        .onDrag {
            guard entry.kind != .link, activeLocation() == file.location else { return NSItemProvider() }
            return beginMentionDrag(file) ?? NSItemProvider()
        }
    }

    private func mentionActions(for file: WorkspaceFileTarget, fromPreview: Bool) -> FileMentionMenuItems {
        FileMentionMenuItems(idPrefix: fromPreview ? "files-preview" : "files-tree", canAdd: canAddToComposer,
                             copy: {
            performMentionAction(for: file, fromPreview: fromPreview) {
                let mention = try file.composerMention()
                pasteboard.clearContents()
                guard pasteboard.setString(mention, forType: .string) else {
                    throw WorkspaceError("Failed to copy file mention.")
                }
            }
        }, add: {
            performMentionAction(for: file, fromPreview: fromPreview) {
                try addToComposer(file)
            }
        })
    }

    private func performMentionAction(for file: WorkspaceFileTarget, fromPreview: Bool,
                                      _ action: () throws -> Void) {
        guard activeLocation() == file.location, !fromPreview || target == file else { return }
        do {
            try action()
            mentionError = nil
        } catch {
            mentionError = error.localizedDescription
        }
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

private struct FileMentionMenuItems: View {
    let idPrefix: String
    let canAdd: Bool
    let copy: () -> Void
    let add: () -> Void

    var body: some View {
        Button("Copy file mention", action: copy)
            .accessibilityIdentifier(idPrefix + "-copy-mention")
        Button("Add to composer", action: add)
            .disabled(!canAdd)
            .accessibilityIdentifier(idPrefix + "-add-to-composer")
    }
}

private struct WorkspaceFilePreviewView: View {
    let target: WorkspaceFileTarget
    let saves: WorkspaceFileSaves
    let pasteboard: NSPasteboard
    let refreshing: Int
    let lineReveal: WorkspaceFileLineReveal?
    let activeTarget: () -> WorkspaceFileTarget?
    @Binding var showingExplorer: Bool
    let goToFolder: (String) -> Void
    let folderEntries: (String) -> [WorkspaceFileEntry]
    let openFile: (String) -> Void
    let mentionActions: FileMentionMenuItems
    let close: () -> Void

    @State private var session: WorkspaceFileSaveSession?
    @State private var actionError: String?
    @State private var confirmDiscard = false
    @State private var wraps = true
    @State private var reload = 0
    @State private var dismissedReveal: UUID?
    @AppStorage("files-render-markdown") private var rendersMarkdown = false
    @AppStorage("files-render-table") private var rendersTable = true

    private struct ReadRequest: Equatable {
        let session: ObjectIdentifier?
        let refresh: Int
        let reload: Int
    }

    private var draft: WorkspaceFileDraft? { session?.draft }

    private var pathComponents: [String] { target.path.components(separatedBy: "/") }

    private var renderFormat: WorkspaceFileRenderFormat? {
        guard session?.editorSource != nil else { return nil }
        return WorkspaceFileRenderFormat(path: target.path)
    }

    private func renderPreference(for format: WorkspaceFileRenderFormat) -> Binding<Bool> {
        format == .markdown ? $rendersMarkdown : $rendersTable
    }

    private var activeLineReveal: WorkspaceFileLineReveal? {
        lineReveal?.id == dismissedReveal ? nil : lineReveal
    }

    private func isRendering(_ format: WorkspaceFileRenderFormat) -> Bool {
        activeLineReveal == nil && renderPreference(for: format).wrappedValue
    }

    private var canWrap: Bool {
        if case .success(.largeText) = session?.preview { return true }
        if let renderFormat, isRendering(renderFormat) { return false }
        return session?.editorSource != nil
    }

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
                if let renderFormat {
                    let rendered = isRendering(renderFormat)
                    let previewIcon = renderFormat == .markdown ? "doc.richtext" : "tablecells"
                    fileButton(renderFormat.toggleLabel(rendered: rendered),
                               rendered ? "chevron.left.forwardslash.chevron.right" : previewIcon,
                               id: "files-toggle-rendered") {
                        dismissedReveal = lineReveal?.id
                        renderPreference(for: renderFormat).wrappedValue = !rendered
                    }
                }
                previewMenu
                if session?.editorSource != nil {
                    Button("Save") { session?.flush() }
                        .disabled(draft == nil || session?.isEditable != true)
                        .accessibilityIdentifier("files-save")
                }
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
            mentionActions
            if let text = draft?.text ?? session?.diskText?.text {
                Button("Copy Contents") { copy(text) }
                    .accessibilityIdentifier("files-copy-contents")
            }
            if canWrap {
                Button(wraps ? "Disable Word Wrap" : "Enable Word Wrap") { wraps.toggle() }
                    .accessibilityIdentifier("files-word-wrap")
            }
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
            let text = draft?.text ?? source.text
            if let renderFormat, isRendering(renderFormat) {
                WorkspaceRenderedFileView(format: renderFormat, text: text, openLink: openMarkdownLink)
            } else {
                FileTextView(text: text, editable: session.isEditable, wraps: wraps,
                             identifier: "files-editor", lineReveal: activeLineReveal, saveSession: session) { text in
                    guard self.session === session else { return }
                    session.edit(text, from: source)
                }
            }
        } else {
            switch session?.preview {
            case .none:
                ProgressView().controlSize(.small).padding(12)
            case .failure(let error):
                status(error.localizedDescription, id: "files-preview-error")
                Button("Retry") { reload += 1 }
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("files-preview-retry")
            case .success(.text):
                EmptyView()
            case .success(.largeText(let file)):
                WorkspaceLargeTextView(file: file, wraps: wraps, retry: { reload += 1 })
            case .success(.binary(let prefix, let size)):
                status("Binary file (\(formattedSize(size))). Showing \(prefix.count) bytes.", id: "files-binary-preview")
                FileTextView(text: hexadecimal(prefix), editable: false, wraps: false, identifier: "files-contents")
            case .success(.image(let file)):
                WorkspaceImageView(file: file, name: pathComponents.last ?? target.path)
                    .id(file.id)
            case .success(.pdf(let file)):
                WorkspacePDFView(file: file, name: pathComponents.last ?? target.path,
                                 position: { saves.pdfPosition(for: target) },
                                 remember: { saves.rememberPDFPosition($0, for: target) },
                                 retry: { reload += 1 }, save: { savePDF(file) })
            }
        }
    }

    private func openMarkdownLink(_ url: URL) {
        guard activeTarget() == target else { return }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case nil:
            guard url.host == nil, !url.path.isEmpty else { return }
            let root = URL(fileURLWithPath: target.location.directory, isDirectory: true).standardizedFileURL
            let base = root.appendingPathComponent(target.path).deletingLastPathComponent()
            let destination = URL(fileURLWithPath: url.path, relativeTo: base).standardizedFileURL
            let prefix = root.path == "/" ? "/" : root.path + "/"
            guard destination.path.hasPrefix(prefix) else { return }
            let relative = String(destination.path.dropFirst(prefix.count))
            if (try? WorkspaceFiles(directory: target.location.directory).fileURL(relative)) != nil {
                openFile(relative)
            }
        default:
            break
        }
    }

    private func savePDF(_ file: WorkspacePDFFile) {
        guard activeTarget() == target else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = pathComponents.last ?? target.path
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try file.data.write(to: url, options: .atomic)
        } catch {
            actionError = error.localizedDescription
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

private struct WorkspaceLargeTextView: View {
    let file: WorkspaceLargeTextFile
    let wraps: Bool
    let retry: () -> Void

    private struct Request: Equatable {
        let id = UUID()
        let line: Int64
        let select: Bool
    }

    private struct Load: Equatable {
        let fileID: UUID
        let request: Request
    }

    private struct Display {
        let id = UUID()
        let load: Load
        let page: WorkspaceLargeTextPage
    }

    @State private var request = Request(line: 1, select: false)
    @State private var completed: Load?
    @State private var display: Display?
    @State private var lineInput = ""
    @State private var lineError: String?
    @State private var readError: String?

    var body: some View {
        let load = Load(fileID: file.id, request: request)
        let visible = display.flatMap { $0.load.fileID == file.id ? $0 : nil }
        let reading = load != completed
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Large file (\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))")
                    .accessibilityIdentifier("files-large-preview")
                HStack(spacing: 6) {
                    fileButton("Previous Page", "chevron.left", id: "files-large-previous") {
                        if let page = visible?.page {
                            request = Request(line: page.firstLine - Int64(WorkspaceLargeTextPage.lineCount), select: false)
                        }
                    }
                    .disabled(reading || (visible?.page.firstLine ?? 1) == 1)
                    fileButton("Next Page", "chevron.right", id: "files-large-next") {
                        if let page = visible?.page { request = Request(line: page.lastLine + 1, select: false) }
                    }
                    .disabled(reading || visible?.page.hasNext != true)
                    TextField("Go to Line", text: $lineInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("files-large-line")
                        .onSubmit(goToLine)
                    Button("Go", action: goToLine)
                        .accessibilityIdentifier("files-large-go")
                }
                if let page = visible?.page {
                    Text("Lines \(page.firstLine.formatted())–\(page.lastLine.formatted())")
                        .accessibilityIdentifier("files-large-range")
                    if page.hasClippedLines { Text("Long lines show their first 16 KiB.") }
                }
                if let lineError {
                    Text(lineError).accessibilityIdentifier("files-large-line-error")
                }
                if reading {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading lines")
                } else if let readError {
                    Text("Could not read file. \(readError)")
                        .accessibilityIdentifier("files-large-error")
                    Button("Retry", action: retry)
                        .accessibilityIdentifier("files-preview-retry")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
            if let visible {
                FileTextView(text: visible.page.lines.joined(separator: "\n"), editable: false, wraps: wraps,
                             identifier: "files-contents", reveal: (visible.id, selection(in: visible)))
            }
        }
        .task(id: load) { await read(load, after: visible?.page) }
    }

    private func goToLine() {
        guard let line = Int64(lineInput.trimmingCharacters(in: .whitespaces)), line > 0 else {
            lineError = "Enter a positive line number."
            return
        }
        request = Request(line: line, select: true)
    }

    private func read(_ load: Load, after previous: WorkspaceLargeTextPage?) async {
        lineError = nil
        readError = nil
        let file = file
        do {
            let page = try await loadWorkspaceFiles { try file.page(containing: load.request.line, after: previous) }
            try Task.checkCancellation()
            display = Display(load: load, page: page)
        } catch WorkspaceLargeTextError.lineNotFound {
            guard !Task.isCancelled else { return }
            lineError = WorkspaceLargeTextError.lineNotFound.localizedDescription
        } catch {
            guard !Task.isCancelled else { return }
            display = nil
            readError = error.localizedDescription
        }
        completed = load
    }

    private func selection(in display: Display) -> NSRange {
        guard display.load.request.select else { return NSRange(location: 0, length: 0) }
        let page = display.page
        let index = Int(display.load.request.line - page.firstLine)
        let start = page.lines.prefix(index).reduce(0) { $0 + $1.utf16.count + 1 }
        return NSRange(location: start, length: page.lines[index].utf16.count)
    }
}

func fileButton(_ label: String, _ symbol: String, id: String,
                action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 18) }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
}

struct FileTextView: NSViewRepresentable {
    let text: String
    let editable: Bool
    let wraps: Bool
    let identifier: String
    var reveal: (id: UUID, range: NSRange)?
    var lineReveal: WorkspaceFileLineReveal?
    var saveSession: WorkspaceFileSaveSession?
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
        context.coordinator.saveSession = saveSession
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
        if let reveal, context.coordinator.revealed != reveal.id {
            context.coordinator.revealed = reveal.id
            textView.setSelectedRange(reveal.range)
            textView.scrollRangeToVisible(NSRange(location: reveal.range.location, length: 0))
        }
        if let lineReveal, context.coordinator.revealed != lineReveal.id {
            let coordinator = context.coordinator
            coordinator.revealed = lineReveal.id
            if let range = lineReveal.range(in: textView.string as NSString) {
                textView.setSelectedRange(range)
                // A newly opened Files panel gets its size after the representable update.
                Task { @MainActor [weak scroll, weak textView, weak coordinator] in
                    guard let scroll, let textView, coordinator?.revealed == lineReveal.id,
                          textView.selectedRange() == range else { return }
                    scroll.layoutSubtreeIfNeeded()
                    textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.edit = nil
        coordinator.saveSession = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var saveSession: WorkspaceFileSaveSession?
        var edit: ((String) -> Void)?
        var revealed: UUID?

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            edit?(textView.string)
        }
    }
}
