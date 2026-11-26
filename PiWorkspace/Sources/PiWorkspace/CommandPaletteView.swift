import SwiftUI

struct CommandPaletteView: View {
    let contents: CommandPaletteContents
    let latestMessageID: String?
    let searchMessages: (SidebarMessageSearch) async throws -> [UUID: SidebarMessageSearch.Match]
    let finish: (CommandPaletteAction?) -> Void

    @State private var session: CommandPaletteSession
    @FocusState private var searchFocused: Bool

    init(contents: CommandPaletteContents, latestMessageID: String?, choosingProject: Bool = false,
         searchMessages: @escaping (SidebarMessageSearch) async throws -> [UUID: SidebarMessageSearch.Match],
         finish: @escaping (CommandPaletteAction?) -> Void) {
        self.contents = contents
        self.latestMessageID = latestMessageID
        self.searchMessages = searchMessages
        self.finish = finish
        _session = State(initialValue: CommandPaletteSession(choosingProject: choosingProject))
    }

    private var search: CommandPaletteSession.Search? {
        session.messageSearch(in: contents, latestMessageID: latestMessageID)
    }

    private func groups(for search: CommandPaletteSession.Search?) -> [CommandPaletteGroup] {
        contents.groups(for: session.query, choosingProject: session.choosingProject, search: search?.request,
                        matches: session.messageMatches(for: search) ?? [:])
    }

    var body: some View {
        let search = self.search
        let groups = groups(for: search)
        let rows = groups.flatMap(\.rows)
        let selected = session.selected(in: rows)?.id
        let searching = search != nil && session.messageMatches(for: search) == nil
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if session.choosingProject {
                    Button(action: back) {
                        Label("Back", systemImage: "arrow.left").labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("command-palette-back")
                }
                TextField(
                    session.choosingProject ? "Search..." : "Search commands, projects, threads, and messages...",
                    text: $session.query
                )
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("command-palette-search")
            }
            if rows.isEmpty {
                Text(searching ? "Searching messages…" : "No results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .accessibilityIdentifier(searching ? "command-palette-searching" : "command-palette-empty")
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
            HStack {
                Text("↑ ↓ Navigate")
                if selected != nil { Text("↩ Select") }
                if session.choosingProject { Text("⌫ Back") }
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
        .accessibilityLabel("Command palette")
        .accessibilityIdentifier("command-palette")
        .defaultFocus($searchFocused, true)
        .onAppear { searchFocused = true }
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
        .background {
            WindowKeyMonitor { event, window in
                guard let key = CommandPaletteSession.Key(event) else { return false }
                let editor = window.firstResponder as? NSTextView
                let editing = editor?.isFieldEditor == true
                guard key == .escape || key == .toggle || (searchFocused && editing) else { return false }
                let currentRows = self.groups(for: self.search).flatMap(\.rows)
                return handle(session.handle(key, rows: currentRows, repeated: event.isARepeat,
                                             composing: editor?.hasMarkedText() == true))
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
                if case .openMessage = row.action, let snippet = row.detail {
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

    private func back() {
        session.back()
        searchFocused = true
    }

    private func handle(_ response: CommandPaletteSession.Response) -> Bool {
        switch response {
        case .ignored: return false
        case .handled: searchFocused = true
        case .close: finish(nil)
        case .run(let action): finish(action)
        }
        return true
    }
}
