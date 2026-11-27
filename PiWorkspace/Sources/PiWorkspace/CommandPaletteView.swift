import SwiftUI

struct CommandPaletteView: View {
    private enum SearchField: Hashable {
        case command
        case workspace(WorkspaceFileSearch.Mode)
    }

    let contents: CommandPaletteContents
    let latestMessageID: String?
    let searchMessages: (SidebarMessageSearch) async throws -> [UUID: SidebarMessageSearch.Match]
    let filesLocation: WorkspaceFilesLocation?
    let activeFilesLocation: () -> WorkspaceFilesLocation?
    let finish: (CommandPaletteAction?) -> Void

    @State private var session: CommandPaletteSession
    @FocusState private var focusedField: SearchField?

    init(contents: CommandPaletteContents, latestMessageID: String?, startingAt session: CommandPaletteSession = .init(),
         filesLocation: WorkspaceFilesLocation? = nil, activeFilesLocation: @escaping () -> WorkspaceFilesLocation? = { nil },
         searchMessages: @escaping (SidebarMessageSearch) async throws -> [UUID: SidebarMessageSearch.Match],
         finish: @escaping (CommandPaletteAction?) -> Void) {
        self.contents = contents
        self.latestMessageID = latestMessageID
        self.filesLocation = filesLocation
        self.activeFilesLocation = activeFilesLocation
        self.searchMessages = searchMessages
        self.finish = finish
        _session = State(initialValue: session)
    }

    private var search: CommandPaletteSession.Search? {
        session.messageSearch(in: contents, latestMessageID: latestMessageID)
    }

    private func groups(for search: CommandPaletteSession.Search?) -> [CommandPaletteGroup] {
        if let mode = session.fileSearchMode {
            guard filesLocation == activeFilesLocation(), case let .success(result) = fileResult,
                  !result.matches.isEmpty else { return [] }
            return [CommandPaletteGroup(id: mode == .files ? .files : .contents, rows: result.matches.map { match in
                let destination = match.destination
                let path = destination.target.path
                if let line = destination.line {
                    return CommandPaletteRow(action: .openWorkspaceFile(destination), title: "\(path):\(line)",
                                             icon: "doc.text", detail: match.snippet)
                }
                return CommandPaletteRow(action: .openWorkspaceFile(destination),
                                         title: String(path.split(separator: "/").last ?? ""),
                                         icon: "doc", detail: path)
            })]
        }
        return contents.groups(for: session.query, choosingProject: session.choosingProject, search: search?.request,
                        matches: session.messageMatches(for: search) ?? [:])
    }

    private var fileSearch: CommandPaletteSession.FileSearch? { session.fileSearch(at: filesLocation) }

    private var fileResult: Result<WorkspaceFileSearch.Results, Error>? { session.fileResult(for: fileSearch) }

    private var searchField: SearchField { session.fileSearchMode.map(SearchField.workspace) ?? .command }

    private var prompt: String {
        switch session.fileSearchMode {
        case .files: "Search files…"
        case .contents: "Search file contents…"
        case nil: session.choosingProject ? "Search..." : "Search commands, projects, threads, and messages..."
        }
    }

    private var fileStatus: String? {
        guard let mode = session.fileSearchMode else { return nil }
        guard filesLocation != nil else { return "Open a thread with an available checkout to search its files." }
        if mode == .contents {
            if session.query.utf16.count > WorkspaceFileSearch.queryLimit {
                return "Search is limited to \(WorkspaceFileSearch.queryLimit) characters."
            }
            if fileSearch == nil { return "Type to search file contents." }
        }
        switch fileResult {
        case nil: return mode == .files && session.query.isEmpty ? "Indexing workspace files…" : "Searching…"
        case .failure(let error): return error.localizedDescription
        case .success(let result):
            if result.invalidRegex { return "Invalid regular expression. Showing literal matches." }
            if result.limited { return "Search limit reached. Refine your query for more matches." }
            if result.matches.isEmpty { return mode == .files ? "No matching files" : "No matching lines" }
            return nil
        }
    }

    var body: some View {
        let search = self.search
        let groups = groups(for: search)
        let rows = groups.flatMap(\.rows)
        let selected = session.selected(in: rows)?.id
        let searching = search != nil && session.messageMatches(for: search) == nil
        let fileSearch = self.fileSearch
        let mode = session.fileSearchMode
        let fileStatus = self.fileStatus
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if session.choosingProject || mode != nil {
                    Button(action: back) {
                        Label("Back", systemImage: "arrow.left").labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("command-palette-back")
                }
                TextField(prompt, text: $session.query)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: searchField)
                .accessibilityIdentifier("command-palette-search")
                .disabled(mode != nil && filesLocation == nil)
                .id(searchField)
                if mode == .contents {
                    searchOption("Aa", label: "Match case", id: "match-case", value: $session.fileOptions.caseSensitive)
                    searchOption("ab", label: "Match whole word", id: "whole-word", value: $session.fileOptions.wholeWord)
                    searchOption(".*", label: "Use regular expression", id: "regex", value: $session.fileOptions.regex)
                }
            }
            if rows.isEmpty {
                Text(fileStatus ?? (searching ? "Searching messages…" : "No results"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .accessibilityIdentifier(mode != nil ? "command-palette-file-status" :
                                             searching ? "command-palette-searching" : "command-palette-empty")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(groups) { group in
                                Text(group.id.rawValue)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 9)
                                    .padding(.top, 4)
                                    .accessibilityAddTraits(.isHeader)
                                    .accessibilityIdentifier(group.id == .messages ? "command-palette-in-messages" : "command-palette-group-\(group.id)")
                                ForEach(group.rows) { row in
                                    resultRow(row, selected: row.id == selected)
                                        .id(row.id)
                                }
                            }
                        }
                    }
                    .frame(height: min(330, CGFloat(rows.count * 40 + groups.count * 22)))
                    .onChange(of: selected) { _, id in
                        if let id { reader.scrollTo(id) }
                    }
                }
            }
            if let fileStatus, !rows.isEmpty {
                Text(fileStatus).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("command-palette-file-status")
            }
            HStack {
                Text("↑ ↓ Navigate")
                if selected != nil { Text(mode == nil ? "↩ Select" : "↩ Open File") }
                if session.choosingProject { Text("⌫ Back") }
                if mode != nil { Text("⎋ Back") }
                Spacer()
                if searching && !rows.isEmpty {
                    Text("Searching messages…").accessibilityIdentifier("command-palette-searching")
                }
                Button("Cancel") { finish(nil) }
                    .accessibilityIdentifier("command-palette-cancel")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .files ? "File picker" : mode == .contents ? "Search project contents" : "Command palette")
        .accessibilityIdentifier(mode == .files ? "project-file-picker" : mode == .contents ? "project-content-search" : "command-palette")
        .defaultFocus($focusedField, searchField)
        .task(id: searchField) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedField = searchField
        }
        .onChange(of: filesLocation) { _, _ in
            if mode != nil {
                session.resetResults()
                focusedField = searchField
            }
        }
        .task(id: search) {
            guard let search else { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
                let matches = try await searchMessages(search.request)
                try Task.checkCancellation()
                session.receive(matches, for: search)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                session.receive([:], for: search)
            }
        }
        .task(id: fileSearch) {
            guard let fileSearch else { return }
            do {
                if !fileSearch.request.query.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                let result = try await fileSearch.request.run()
                try Task.checkCancellation()
                guard activeFilesLocation() == fileSearch.request.location else { return }
                session.receive(.success(result), for: fileSearch)
            } catch {
                guard !Task.isCancelled, activeFilesLocation() == fileSearch.request.location else { return }
                session.receive(.failure(error), for: fileSearch)
            }
        }
        .background {
            WindowKeyMonitor { event, window in
                guard let key = CommandPaletteSession.Key(event) else { return false }
                switch key {
                case .escape, .toggle: break
                default:
                    guard focusedField == searchField,
                          (window.firstResponder as? NSTextView)?.isFieldEditor == true else { return false }
                }
                let currentRows = self.groups(for: self.search).flatMap(\.rows)
                return handle(session.handle(key, rows: currentRows, repeated: event.isARepeat,
                                             composing: (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true))
            }
        }
    }

    private func resultRow(_ row: CommandPaletteRow, selected: Bool) -> some View {
        let identifier = if session.choosingProject {
            row.action.identifier
        } else {
            switch row.action {
            case .newThread(let id): "new-thread-in-context-\(id)"
            case .newScratchThread: "new-thread-without-project"
            default: row.action.identifier
            }
        }
        return Button {
            guard groups(for: search).contains(where: { $0.rows.contains { $0.id == row.id } }) else { return }
            _ = handle(session.select(row.action))
        } label: {
            HStack(spacing: 9) {
                Image(systemName: row.icon)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                if (row.action.isMessage || session.fileSearchMode == .contents), let snippet = row.detail {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).lineLimit(1)
                        Text(snippet).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(row.title).lineLimit(1)
                    if let detail = row.detail {
                        Text(detail)
                            .truncationMode(.head)
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if row.action == .chooseProject {
                    Image(systemName: "chevron.right").font(.caption)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.title)
        .accessibilityHint(row.detail ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("command-palette-\(identifier)")
    }

    private func searchOption(_ title: String, label: String, id: String, value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
            focusedField = searchField
        } label: {
            Text(title).font(.system(.caption, design: .monospaced)).frame(minWidth: 18)
        }
        .tint(value.wrappedValue ? .accentColor : .secondary)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier("command-palette-" + id)
        .disabled(filesLocation == nil)
    }

    private func back() {
        session.back()
        focusedField = searchField
    }

    private func handle(_ response: CommandPaletteSession.Response) -> Bool {
        switch response {
        case .ignored: return false
        case .handled: focusedField = searchField
        case .close: finish(nil)
        case .run(let action):
            if case .openWorkspaceFile(let destination) = action,
               activeFilesLocation() != destination.target.location { return true }
            finish(action)
        }
        return true
    }
}

private extension CommandPaletteAction {
    var isMessage: Bool {
        if case .openMessage = self { return true }
        return false
    }
}
