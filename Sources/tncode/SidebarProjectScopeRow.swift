import SwiftUI

struct SidebarProjectScopeRow: View {
    let project: Project
    let setIncluded: (Bool) -> Void
    let selectOnly: () -> Void
    var highlighted = false
    var openSettings: (() -> Void)? = nil

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
                HStack(spacing: 8) {
                    ProjectIconView(icon: project.icon, fallback: project.pinned == true ? "pin.fill" : "folder",
                                    projectName: project.title)
                        .accessibilityHidden(true)
                    Text(project.title).font(.system(size: 14))
                    if project.pinned == true {
                        Image(systemName: "pin").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Filter by \(project.title). Shift-click to add or remove this project.")
            .accessibilityIdentifier("project-filter-choice-\(project.id)")
            .accessibilityAddTraits(highlighted ? .isSelected : [])
            if let openSettings {
                Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 12)) }
                    .buttonStyle(T3IconButtonStyle(size: 24))
                    .help("Project settings for \(project.title)")
                    .accessibilityLabel("Project settings for \(project.title)")
                    .accessibilityIdentifier("project-filter-settings-\(project.id)")
            }
        }
    }
}
