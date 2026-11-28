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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private var palette: T3Palette { T3Palette(colorScheme, t3Themes) }

    private enum Choice: Hashable {
        case all
        case project(UUID)
    }

    private var results: (matches: [Project], choices: [Choice]) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let projects = SidebarProjectFilter.orderedProjects(model.projects)
        let matches = term.isEmpty ? projects : projects.filter { $0.title.localizedStandardContains(term) }
        let choices = (term.isEmpty ? [Choice.all] : []) + matches.map { Choice.project($0.id) }
        return (matches, choices)
    }

    var body: some View {
        let (matches, choices) = results
        let active = activeChoice(in: choices)
        VStack(alignment: .leading, spacing: 8) {
            SidebarProjectSearch(text: Binding(get: { query }, set: { value in
                if value != query { highlight = nil }
                query = value
            }), handleKey: handleKey)
                .focused($searchFocused)
                .accessibilityIdentifier("project-filter-search")
            if choices.isEmpty {
                Text("No matching projects.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .accessibilityIdentifier("project-filter-no-results")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if choices.first == .all {
                                Button("All Projects") { select(.all) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 14))
                                    .accessibilityIdentifier("project-filter-all")
                                    .accessibilityAddTraits(active == .all ? .isSelected : [])
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .frame(height: 32)
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
                                .padding(.horizontal, 8)
                                .frame(height: 32)
                                .background(highlightBackground(active == choice))
                                .contextMenu { projectMenu(project) }
                                .id(choice)
                            }
                        }
                    }
                    .frame(height: CGFloat(min(choices.count, 9)) * 32)
                    .onChange(of: active) { _, choice in
                        if let choice { reader.scrollTo(choice) }
                    }
                }
            }
            Rectangle().fill(palette.border.opacity(0.7)).frame(height: 1)
            Toggle("Group by Project", isOn: $grouped)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .accessibilityIdentifier("group-threads-by-project")
            Toggle("Show Archive", isOn: $model.showArchive)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .accessibilityIdentifier("show-thread-archive")
            HStack {
                Spacer()
                Button("Done", action: dismiss)
                    .buttonStyle(T3SmallButtonStyle(kind: .ghost, height: 24))
                    .accessibilityIdentifier("close-thread-filters")
            }
        }
        .padding(8)
        .frame(width: 288)
        .tint(palette.primary)
        .defaultFocus($searchFocused, true)
        .onAppear { searchFocused = true }
    }

    private func highlightBackground(_ highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(highlighted ? palette.itemHighlight : .clear)
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

    private func activeChoice(in choices: [Choice]) -> Choice? {
        if let highlight, choices.contains(highlight) { return highlight }
        return choices.first
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch Int(event.keyCode) {
        case kVK_UpArrow, kVK_DownArrow:
            guard modifiers.isEmpty else { return false }
            let choices = results.choices
            if let active = activeChoice(in: choices), let index = choices.firstIndex(of: active) {
                let offset = event.keyCode == kVK_UpArrow ? -1 : 1
                highlight = choices[(index + offset + choices.count) % choices.count]
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard modifiers.isEmpty || modifiers == .shift else { return false }
            guard !event.isARepeat, let active = activeChoice(in: results.choices) else { return true }
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

private struct SidebarProjectSearch: NSViewRepresentable {
    @Binding var text: String

    let handleKey: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.bezelStyle = .roundedBezel
        field.placeholderString = String(localized: "Search projects")
        let coordinator = context.coordinator
        field.delegate = coordinator
        coordinator.monitor = WindowKeyMonitor.observeKeys(in: field, includesPopoverFieldEditor: true) {
            [weak field, weak coordinator] event, window in
            // SwiftUI focus can change while AppKit still has this field's editor as first responder.
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  editor.window === window, field?.currentEditor() === editor, !editor.hasMarkedText() else { return false }
            return coordinator?.search.handleKey(event) == true
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.search = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var search: SidebarProjectSearch
        var monitor: Any?

        init(_ search: SidebarProjectSearch) { self.search = search }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { search.text = field.stringValue }
        }
    }
}
