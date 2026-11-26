import SwiftUI

struct DraftProjectPicker: View {
    enum Destination: Hashable {
        case project(UUID)
        case noProject
        case addProject
    }

    let projects: [Project]
    let currentProject: UUID
    let isScratch: Bool
    let finish: (Destination?) -> Void

    @State private var query = ""
    @State private var highlight: Destination?
    @FocusState private var searchFocused: Bool

    private var matches: [Project] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? projects : projects.filter { $0.title.localizedStandardContains(term) }
    }

    var body: some View {
        let matches = self.matches
        let browsing = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let actions: [Destination] = browsing ? (isScratch ? [.addProject] : [.noProject, .addProject]) : []
        let destinations = matches.map { Destination.project($0.id) } + actions
        let selected = highlight.flatMap { destinations.contains($0) ? $0 : nil } ?? destinations.first
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search projects", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("draft-project-search")
                .onChange(of: query) { highlight = nil }
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
                                row(project.title, icon: project.pinned == true ? "pin" : "folder",
                                    destination: destination, selected: selected,
                                    current: project.id == currentProject)
                                    .help(project.path)
                                    .accessibilityIdentifier("draft-project-\(project.id)")
                                    .id(destination)
                            }
                            if !matches.isEmpty && !actions.isEmpty { Divider() }
                            if actions.contains(.noProject) {
                                row("No project", icon: "doc", destination: .noProject, selected: selected)
                                    .accessibilityIdentifier("draft-no-project")
                                    .id(Destination.noProject)
                            }
                            if actions.contains(.addProject) {
                                row("Add project", icon: "folder.badge.plus", destination: .addProject, selected: selected)
                                    .accessibilityIdentifier("draft-add-project")
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
        .background {
            WindowKeyMonitor { event, window in
                guard let key = CommandPaletteSession.Key(event),
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return false }
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

    private func row(_ title: String, icon: String, destination: Destination,
                     selected: Destination?, current: Bool = false) -> some View {
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
            .background(destination == selected ? Color.accentColor.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
