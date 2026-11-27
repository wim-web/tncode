import SwiftUI

struct DraftProjectPicker: View {
    enum Destination: Hashable {
        case project(UUID)
        case noProject
        case addProject
    }

    @ObservedObject var model: WorkspaceModel
    let finish: (Destination?) -> Void

    @State private var query = ""
    @State private var highlight: Destination?
    @State private var projectOrder: [UUID] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        let projects = SidebarProjectFilter.orderedProjects(model.projects.sorted { $0.lastActivity > $1.lastActivity })
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rank = Dictionary(uniqueKeysWithValues: projectOrder.enumerated().map { ($1, $0) })
        let matches = projects.filter { term.isEmpty || $0.title.localizedStandardContains(term) }.sorted {
            rank[$0.id, default: projectOrder.count] < rank[$1.id, default: projectOrder.count]
        }
        let browseActions: [Destination] = model.project?.isScratch == true ? [.addProject] : [.noProject, .addProject]
        let actions = term.isEmpty ? browseActions : []
        let destinations = matches.map { Destination.project($0.id) } + actions
        let selected = highlightedDestination(in: destinations)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search projects", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("draft-project-search")
                .onChange(of: query) { highlight = nil }
                .onSubmit { if let selected { finish(selected) } }
                .submitScope()
            if destinations.isEmpty {
                Text("No matching projects.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("draft-project-no-results")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(matches) { project in
                                let destination = Destination.project(project.id)
                                row(project.title, icon: "folder", destination: destination, selected: selected,
                                    identifier: "draft-project-\(project.id)", project: project)
                                    .id(destination)
                            }
                            if !matches.isEmpty && !actions.isEmpty { Divider() }
                            if actions.contains(.noProject) {
                                row("No project", icon: "doc", destination: .noProject, selected: selected,
                                    identifier: "draft-no-project")
                                    .id(Destination.noProject)
                            }
                            if actions.contains(.addProject) {
                                row("Add project", icon: "folder.badge.plus", destination: .addProject, selected: selected,
                                    identifier: "draft-add-project")
                                    .id(Destination.addProject)
                            }
                        }
                    }
                    .frame(height: min(230, CGFloat(destinations.count * 30 + 4)))
                    .onChange(of: selected) { _, value in
                        if let value { reader.scrollTo(value) }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 292)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Draft project chooser")
        .accessibilityIdentifier("draft-project-chooser")
        .defaultFocus($searchFocused, true)
        .onAppear { searchFocused = true }
        .onChange(of: projects.map(\.id), initial: true) { _, ids in
            // Keep rows in place until the picker reopens, including while filtering.
            let known = Set(projectOrder)
            let newIDs = ids.filter { !known.contains($0) }
            if !newIDs.isEmpty { projectOrder.append(contentsOf: newIDs) }
        }
        .background {
            WindowKeyMonitor { event, window in
                guard (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
                let selected = highlightedDestination(in: destinations)
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if searchFocused, modifiers == [.command, .shift],
                   event.charactersIgnoringModifiers?.lowercased() == "p", case .project(let id)? = selected {
                    if !event.isARepeat { togglePin(id) }
                    return true
                }
                guard let key = CommandPaletteSession.Key(event) else { return false }
                if key == .escape {
                    if !event.isARepeat { finish(nil) }
                    return true
                }
                guard searchFocused else { return false }
                switch key {
                case .up, .down:
                    if let selected, let index = destinations.firstIndex(of: selected) {
                        let offset = key == .up ? -1 : 1
                        highlight = destinations[(index + offset + destinations.count) % destinations.count]
                    }
                    return true
                case .select:
                    if let selected, !event.isARepeat { finish(selected) }
                    return true
                default:
                    return false
                }
            }
        }
    }

    private func highlightedDestination(in destinations: [Destination]) -> Destination? {
        highlight.flatMap { destinations.contains($0) ? $0 : nil } ?? destinations.first
    }

    private func togglePin(_ id: UUID) {
        guard let project = model.projects.first(where: { $0.id == id }) else { return }
        model.setProjectPinned(id, pinned: project.pinned != true)
    }

    private func row(_ title: String, icon: String, destination: Destination,
                     selected: Destination?, identifier: String, project: Project? = nil) -> some View {
        let current = model.project.map { $0.id == project?.id } ?? false
        return HStack(spacing: 0) {
            Button { finish(destination) } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .frame(width: 17)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(title).lineLimit(1)
                    Spacer()
                    if current { Image(systemName: "checkmark").accessibilityHidden(true) }
                }
                .padding(.horizontal, 7)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(project?.path ?? "")
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityIdentifier(identifier)
            if let project {
                let pinned = project.pinned == true
                let action = pinned ? "Unpin \(project.title)" : "Pin \(project.title)"
                Button { togglePin(project.id) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(action) (⌘⇧P)")
                .accessibilityLabel(action)
                .accessibilityIdentifier("draft-project-pin-\(project.id)")
            }
        }
        .background(destination == selected ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }
}
