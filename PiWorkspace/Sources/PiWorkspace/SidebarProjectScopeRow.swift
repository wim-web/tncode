import SwiftUI

struct SidebarProjectScopeRow: View {
    let project: Project
    let setIncluded: (Bool) -> Void
    let selectOnly: () -> Void

    private var included: Bool { project.inSidebarScope == true }

    var body: some View {
        HStack(spacing: 6) {
            Toggle(project.title, isOn: Binding(get: { included }, set: setIncluded))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(project.title)
                .accessibilityIdentifier("project-filter-\(project.id)")
            Button {
                if let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
                   event.modifierFlags.contains(.shift) {
                    setIncluded(!included)
                } else {
                    selectOnly()
                }
            } label: {
                Label(project.title, systemImage: project.pinned == true ? "pin.fill" : "folder")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Filter by \(project.title). Shift-click to add or remove this project.")
            .accessibilityIdentifier("project-filter-choice-\(project.id)")
        }
    }
}
