import Carbon
import SwiftUI

struct SidebarProjectScopePicker<ProjectMenu: View>: View {
    @ObservedObject var model: WorkspaceModel
    @Binding var grouped: Bool
    let dismiss: () -> Void
    @ViewBuilder let projectMenu: (Project) -> ProjectMenu

    @State private var query = ""
    @State private var highlight: Choice?
    @FocusState private var searchFocused: Bool

    private enum Choice: Hashable {
        case all
        case project(UUID)
    }

    private var searchTerm: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let projects = SidebarProjectFilter.orderedProjects(model.projects)
        let matches = searchTerm.isEmpty ? projects : projects.filter { $0.title.localizedStandardContains(searchTerm) }
        let choices = (searchTerm.isEmpty ? [Choice.all] : []) + matches.map { Choice.project($0.id) }
        let active = highlight.flatMap { choices.contains($0) ? $0 : nil } ?? choices.first
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search projects", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("project-filter-search")
                .onChange(of: query) { highlight = nil }
            if choices.isEmpty {
                Text("No matching projects.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .accessibilityIdentifier("project-filter-no-results")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if searchTerm.isEmpty {
                                Button("All Projects") { select(.all) }
                                    .accessibilityIdentifier("project-filter-all")
                                    .accessibilityAddTraits(active == .all ? .isSelected : [])
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4)
                                    .frame(height: 26)
                                    .background(highlightBackground(active == .all))
                                    .id(Choice.all)
                            }
                            ForEach(matches) { project in
                                let choice = Choice.project(project.id)
                                SidebarProjectScopeRow(
                                    project: project,
                                    setIncluded: { included in model.updateSidebarScope {
                                        $0.setSelected(project.id, included)
                                    } },
                                    selectOnly: { select(choice) },
                                    highlighted: active == choice,
                                    openSettings: {
                                        dismiss()
                                        model.openSettings(.project, projectID: project.id)
                                    }
                                )
                                .padding(.horizontal, 4)
                                .frame(height: 26)
                                .background(highlightBackground(active == choice))
                                .contextMenu { projectMenu(project) }
                                .id(choice)
                            }
                        }
                    }
                    .frame(height: CGFloat(min(choices.count, 9)) * 26)
                    .onChange(of: active) { _, choice in
                        if let choice { reader.scrollTo(choice) }
                    }
                }
            }
            Divider()
            Toggle("Group by Project", isOn: $grouped)
                .accessibilityIdentifier("group-threads-by-project")
            Toggle("Show Archive", isOn: $model.showArchive)
                .accessibilityIdentifier("show-thread-archive")
            Button("Done", action: dismiss)
                .accessibilityIdentifier("close-thread-filters")
        }
        .padding(12)
        .frame(width: 230)
        .defaultFocus($searchFocused, true)
        .onAppear { searchFocused = true }
        .background {
            WindowKeyMonitor { event, window in
                guard searchFocused, let editor = window.firstResponder as? NSTextView,
                      editor.isFieldEditor, !editor.hasMarkedText() else { return false }
                return handleKey(event, choices: choices, active: active)
            }
        }
    }

    private func highlightBackground(_ highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(highlighted ? Color.accentColor.opacity(0.18) : .clear)
    }

    private func select(_ choice: Choice) {
        model.updateSidebarScope {
            switch choice {
            case .all: $0.clear()
            case .project(let id): $0.selectOnly(id)
            }
        }
        dismiss()
    }

    private func handleKey(_ event: NSEvent, choices: [Choice], active: Choice?) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_DownArrow:
            guard modifiers.isEmpty else { return false }
            if let active, let index = choices.firstIndex(of: active) {
                let offset = event.keyCode == kVK_UpArrow ? -1 : 1
                highlight = choices[(index + offset + choices.count) % choices.count]
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard modifiers.isEmpty || modifiers == .shift else { return false }
            guard let active, !event.isARepeat else { return true }
            if modifiers.isEmpty {
                select(active)
            } else if case .project(let id) = active {
                model.updateSidebarScope { $0.setSelected(id, !$0.selection.contains(id)) }
            }
        case kVK_Escape where modifiers.isEmpty:
            if !event.isARepeat { dismiss() }
        default:
            return false
        }
        return true
    }
}
