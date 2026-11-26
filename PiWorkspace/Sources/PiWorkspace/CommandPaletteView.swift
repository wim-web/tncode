import SwiftUI

struct CommandPaletteView: View {
    let contents: CommandPaletteContents
    let finish: (CommandPaletteAction?) -> Void

    @State private var session = CommandPaletteSession()
    @FocusState private var searchFocused: Bool

    var body: some View {
        let rows = contents.results(for: session.query, choosingProject: session.choosingProject)
        let selected = session.selected(in: rows)?.id
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if session.choosingProject {
                    Button(action: back) {
                        Label("Back", systemImage: "arrow.left").labelStyle(.iconOnly)
                    }
                    .accessibilityIdentifier("command-palette-back")
                }
                TextField(
                    session.choosingProject ? "Search..." : "Search commands, projects, and threads...",
                    text: $session.query
                )
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("command-palette-search")
            }
            if session.choosingProject {
                Text("Projects").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("No results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .accessibilityIdentifier("command-palette-empty")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(rows) { row in
                                resultRow(row, selected: row.id == selected)
                                    .id(row.id)
                            }
                        }
                    }
                    .frame(height: min(330, CGFloat(rows.count) * 38))
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
        .background {
            CommandPaletteKeys { event, window in
                guard let key = CommandPaletteSession.Key(event) else { return false }
                let editor = window.firstResponder as? NSTextView
                let editing = editor?.isFieldEditor == true
                guard key == .escape || key == .toggle || (searchFocused && editing) else { return false }
                let currentRows = contents.results(for: session.query, choosingProject: session.choosingProject)
                return handle(session.handle(key, rows: currentRows, repeated: event.isARepeat,
                                             composing: editor?.hasMarkedText() == true))
            }
        }
    }

    private func resultRow(_ row: CommandPaletteRow, selected: Bool) -> some View {
        Button {
            _ = handle(session.select(row.action))
        } label: {
            HStack(spacing: 9) {
                Image(systemName: row.icon)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(row.title)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .truncationMode(.head)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .accessibilityIdentifier("command-palette-\(row.id.identifier)")
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

private struct CommandPaletteKeys: NSViewRepresentable {
    let handle: (NSEvent, NSWindow) -> Bool

    final class Coordinator {
        var monitor: Any?
        var handle: (NSEvent, NSWindow) -> Bool

        init(handle: @escaping (NSEvent, NSWindow) -> Bool) {
            self.handle = handle
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak anchor, weak coordinator] event in
            guard let window = anchor?.window, window === event.window,
                  coordinator?.handle(event, window) == true else { return event }
            return nil
        }
        return anchor
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.handle = handle
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }
}
