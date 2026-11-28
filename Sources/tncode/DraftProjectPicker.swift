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

    private var projects: [Project] {
        var sorted = SidebarProjectFilter.orderedProjects(model.projects.sorted { $0.lastActivity > $1.lastActivity })
        if let current = sorted.firstIndex(where: { $0.id == model.project?.id }), current != 0 {
            let preferred = sorted.remove(at: current)
            sorted.insert(preferred, at: 0)
        }
        return sorted
    }

    private var results: (matches: [Project], actions: [Destination], destinations: [Destination]) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rank = Dictionary(uniqueKeysWithValues: projectOrder.enumerated().map { ($1, $0) })
        let matches = projects.filter { term.isEmpty || $0.title.localizedStandardContains(term) }.sorted {
            rank[$0.id, default: projectOrder.count] < rank[$1.id, default: projectOrder.count]
        }
        let browseActions: [Destination] = model.project?.isScratch == true ? [.addProject] : [.noProject, .addProject]
        let actions = term.isEmpty ? browseActions : []
        let destinations = matches.map { Destination.project($0.id) } + actions
        return (matches, actions, destinations)
    }

    private var currentDestination: Destination? { highlightedDestination(in: results.destinations) }

    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.t3Themes) private var t3Themes
    private var palette: T3Palette { T3Palette(colorScheme, t3Themes) }

    var body: some View {
        let (matches, actions, destinations) = results
        let selected = highlightedDestination(in: destinations)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.mutedForeground.opacity(0.55))
                TextField("Search projects", text: Binding(get: { query }, set: { value in
                    if query != value { highlight = nil }
                    query = value
                }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .accessibilityIdentifier("draft-project-search")
                    .onSubmit { if let currentDestination { finish(currentDestination) } }
                    .submitScope()
            }
            .frame(height: 26)
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(searchFocused ? palette.ring : palette.border.opacity(0.7)).frame(height: 1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            if destinations.isEmpty {
                Text("No matching projects.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("draft-project-no-results")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(matches) { project in
                                let destination = Destination.project(project.id)
                                row(project.title, icon: "folder", destination: destination, selected: selected,
                                    identifier: "draft-project-\(project.id)", project: project)
                                    .id(destination)
                            }
                            if !matches.isEmpty && !actions.isEmpty {
                                Rectangle().fill(palette.border).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
                            }
                            if actions.contains(.noProject) {
                                row(String(localized: "No project"), icon: "doc", destination: .noProject, selected: selected,
                                    identifier: "draft-no-project")
                                    .id(Destination.noProject)
                            }
                            if actions.contains(.addProject) {
                                row(String(localized: "Add project"), icon: "folder.badge.plus", destination: .addProject, selected: selected,
                                    identifier: "draft-add-project")
                                    .id(Destination.addProject)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(height: min(296, CGFloat(destinations.count * 32 + 9)))
                    .onChange(of: selected) { _, value in
                        if let value { reader.scrollTo(value) }
                    }
                }
            }
        }
        .padding(4)
        .frame(width: 320)
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
            WindowKeyMonitor(includesPopoverFieldEditor: true) { event, window in
                guard (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
                let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if searchFocused, modifiers == [.command, .shift],
                   event.charactersIgnoringModifiers?.lowercased() == "p", case .project(let id)? = currentDestination {
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
                    let destinations = results.destinations
                    if let selected = highlightedDestination(in: destinations), let index = destinations.firstIndex(of: selected) {
                        let offset = key == .up ? -1 : 1
                        highlight = destinations[(index + offset + destinations.count) % destinations.count]
                    }
                    return true
                case .select:
                    if !event.isARepeat, let currentDestination { finish(currentDestination) }
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
                    Group {
                        if let project {
                            ProjectIconView(icon: project.icon, projectName: project.title)
                        } else {
                            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(palette.mutedForeground)
                        }
                    }
                    .frame(width: 16)
                    .accessibilityHidden(true)
                    Text(title).lineLimit(1).font(.system(size: 14))
                    Spacer()
                    if current { Image(systemName: "checkmark").font(.system(size: 12)).accessibilityHidden(true) }
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(project?.path ?? "")
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityIdentifier(identifier)
            if let project {
                let pinned = project.pinned == true
                let action = pinned ? String(localized: "Unpin \(project.title)") : String(localized: "Pin \(project.title)")
                Button { togglePin(project.id) } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.mutedForeground)
                        .opacity(pinned || destination == selected ? 1 : 0)
                        .frame(width: 24, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(action) (⌘⇧P)")
                .accessibilityLabel(action)
                .accessibilityIdentifier("draft-project-pin-\(project.id)")
            }
        }
        .onHover { hovering in
            if hovering { highlight = destination }
        }
        .background(destination == selected ? palette.itemHighlight : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }
}
