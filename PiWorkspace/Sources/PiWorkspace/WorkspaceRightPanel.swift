import SwiftUI

enum WorkspacePanelTab: Hashable, Identifiable {
    case browser, files, changes, terminal(Int), sideChat(UUID)

    var id: String {
        switch self {
        case .browser: "browser"
        case .files: "files"
        case .changes: "changes"
        case .terminal(let number): "terminal-\(number)"
        case .sideChat(let id): "side-chat-\(id)"
        }
    }

    var title: String {
        switch self {
        case .browser: "Browser"
        case .files: "Files"
        case .changes: "Changes"
        case .terminal(let number): "Terminal \(number)"
        case .sideChat: "Side chat"
        }
    }

    var icon: String {
        switch self {
        case .browser: "globe"
        case .files: "folder"
        case .changes: "doc.text"
        case .terminal: "terminal"
        case .sideChat: "bubble.left.and.bubble.right"
        }
    }
}

struct WorkspaceRightPanelState {
    struct TerminalGroup {
        var panes: [Int]
        var selectedPane: Int
        var direction: ThreadTerminalDrawerState.SplitDirection = .horizontal

        var canSplit: Bool { panes.count < ThreadTerminal.maxPanesPerGroup }
    }

    var isOpen = false
    private(set) var tabs: [WorkspacePanelTab] = []
    private(set) var selected: WorkspacePanelTab?
    private(set) var terminals: [WorkspacePanelTab: TerminalGroup] = [:]
    private(set) var location: ThreadTerminalLocation?
    private(set) var nextNumber = 1
    private(set) var focusRequest = 0

    var visibleTab: WorkspacePanelTab? { isOpen ? selected : nil }
    var visibleTerminal: TerminalGroup? { visibleTab.flatMap { terminals[$0] } }

    mutating func show(_ tab: WorkspacePanelTab) {
        if !tabs.contains(tab) { tabs.append(tab) }
        isOpen = true
        selected = tab
        if terminals[tab] != nil { focusRequest += 1 }
    }

    mutating func addTerminal(_ number: Int, at location: ThreadTerminalLocation) {
        if self.location != location { close(Array(terminals.keys)) }
        self.location = location
        nextNumber = number + 1
        let tab = WorkspacePanelTab.terminal(number)
        terminals[tab] = TerminalGroup(panes: [number], selectedPane: number)
        show(tab)
    }

    mutating func selectPane(_ pane: Int, in tab: WorkspacePanelTab) {
        guard terminals[tab]?.panes.contains(pane) == true else { return }
        terminals[tab]?.selectedPane = pane
        show(tab)
    }

    mutating func split(_ direction: ThreadTerminalDrawerState.SplitDirection, allocating pane: Int) {
        guard let tab = visibleTab, var group = terminals[tab], group.canSplit else { return }
        nextNumber = pane + 1
        group.panes.append(pane)
        group.direction = direction
        terminals[tab] = group
        selectPane(pane, in: tab)
    }

    mutating func cycle(by offset: Int) -> Bool {
        guard let tab = visibleTab, let active = terminals[tab]?.selectedPane else { return false }
        let order = tabs.flatMap { terminals[$0]?.panes ?? [] }
        guard order.count > 1, let index = order.firstIndex(of: active) else { return false }
        let pane = order[(index + offset + order.count) % order.count]
        guard let target = tabs.first(where: { terminals[$0]?.panes.contains(pane) == true }) else { return false }
        selectPane(pane, in: target)
        return true
    }

    mutating func closePane(_ pane: Int, in tab: WorkspacePanelTab) {
        guard var group = terminals[tab], group.panes.contains(pane) else { return }
        group.panes.removeAll { $0 == pane }
        guard let last = group.panes.last else { close([tab]); return }
        if group.selectedPane == pane {
            group.selectedPane = last
            if visibleTab == tab { focusRequest += 1 }
        }
        terminals[tab] = group
    }

    mutating func close(_ targets: [WorkspacePanelTab]) {
        let index = selected.flatMap { tabs.firstIndex(of: $0) }
        tabs.removeAll { targets.contains($0) }
        for tab in targets { terminals.removeValue(forKey: tab) }
        if terminals.isEmpty { location = nil }
        if let selected, targets.contains(selected) {
            self.selected = index.flatMap { tabs.isEmpty ? nil : tabs[min($0, tabs.count - 1)] }
            if let visibleTab, terminals[visibleTab] != nil { focusRequest += 1 }
        }
        if tabs.isEmpty { isOpen = false }
    }

    mutating func move(_ tab: WorkspacePanelTab, to target: WorkspacePanelTab) {
        guard let from = tabs.firstIndex(of: tab), let to = tabs.firstIndex(of: target), from != to else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }
}

struct RightPanelBounds: PreferenceKey {
    struct Bounds {
        var panel: Anchor<CGRect>?
        var terminal: Anchor<CGRect>?
    }

    static let defaultValue = Bounds()
    static func reduce(value: inout Bounds, nextValue: () -> Bounds) {
        let next = nextValue()
        value.panel = next.panel ?? value.panel
        value.terminal = next.terminal ?? value.terminal
    }
}

struct WorkspaceTerminalGroupView: View {
    let group: WorkspaceRightPanelState.TerminalGroup
    let directory: String
    let bounds: CGRect?
    let focusRequest: Int
    let select: (Int) -> Void
    let cycle: (Int) -> Bool
    let command: (ThreadTerminal.Command) -> Void
    @State private var lastBounds = CGRect(x: 0, y: 0, width: 360, height: TerminalDrawerHeight.defaultContent)

    var body: some View {
        let frame = bounds ?? lastBounds
        let visible = bounds != nil
        let layout = group.direction == .horizontal
            ? AnyLayout(HStackLayout(spacing: 1))
            : AnyLayout(VStackLayout(spacing: 1))
        layout {
            ForEach(group.panes, id: \.self) { pane in
                let active = pane == group.selectedPane
                ThreadTerminal(directory: directory, number: pane, visible: visible,
                               focusRequest: visible && active ? focusRequest : nil,
                               onFocus: { if !active { select(pane) } }, onCycle: cycle,
                               identifier: "right-terminal-pane-\(pane)", onCommand: command)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        if active && group.panes.count > 1 {
                            Rectangle().strokeBorder(Color.accentColor.opacity(0.65))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .background(.quaternary)
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(!visible)
        .allowsHitTesting(visible)
        .position(x: frame.midX, y: frame.midY)
        .onChange(of: bounds, initial: true) { _, bounds in
            if let bounds { lastBounds = bounds }
        }
    }
}

struct WorkspacePanelTabs<AddButton: View>: View {
    let panel: WorkspaceRightPanelState
    let select: (WorkspacePanelTab) -> Void
    let close: ([WorkspacePanelTab]) -> Void
    let move: (WorkspacePanelTab, WorkspacePanelTab) -> Void
    let hide: () -> Void
    var titleForTab: (WorkspacePanelTab) -> String = { $0.title }
    @ViewBuilder let addButton: () -> AddButton
    @State private var tabFrames: [WorkspacePanelTab: CGRect] = [:]
    @Namespace private var tabStrip

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(panel.tabs) { tab in
                                tabButton(tab).id(tab)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: panel.selected, initial: true) { _, selected in
                        if let selected { scroll.scrollTo(selected) }
                    }
                }
                addButton()
                panelIcon("Hide Right Panel", icon: "sidebar.right", id: "hide-right-panel", action: hide)
            }
            .frame(height: 32)
            .padding(.horizontal, 8)
            Divider()
        }
        .coordinateSpace(name: tabStrip)
        .onPreferenceChange(TabFrames.self) { tabFrames = $0 }
    }

    private func tabButton(_ tab: WorkspacePanelTab) -> some View {
        let active = panel.selected == tab
        let title = panel.terminals[tab].map { WorkspacePanelTab.terminal($0.selectedPane).title } ?? titleForTab(tab)
        let index = panel.tabs.firstIndex(of: tab) ?? 0
        let toRight = Array(panel.tabs.dropFirst(index + 1))
        return HStack(spacing: 2) {
            Button { select(tab) } label: {
                Label(title, systemImage: tab.icon)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityIdentifier("right-panel-tab-\(tab.id)")
            panelIcon("Close \(title)", icon: "xmark", id: "close-right-panel-\(tab.id)") { close([tab]) }
                .font(.system(size: 9, weight: .medium))
        }
        .buttonStyle(.plain)
        .font(.caption)
        .background(active ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: TabFrames.self, value: [tab: geometry.frame(in: .named(tabStrip))])
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(tabStrip))
                .onEnded { drag in
                    if let target = panel.tabs.first(where: { tabFrames[$0]?.contains(drag.location) == true }) {
                        move(tab, target)
                    }
                }
        )
        .contextMenu {
            Button("Close") { close([tab]) }
            Button("Close Others") { close(panel.tabs.filter { $0 != tab }) }
                .disabled(panel.tabs.count <= 1)
            Button("Close to the Right") { close(toRight) }
                .disabled(toRight.isEmpty)
            Button("Close All") { close(panel.tabs) }
        }
    }

    private struct TabFrames: PreferenceKey {
        static var defaultValue: [WorkspacePanelTab: CGRect] { [:] }
        static func reduce(value: inout [WorkspacePanelTab: CGRect], nextValue: () -> [WorkspacePanelTab: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, next in next })
        }
    }
}

func panelIcon(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
    .accessibilityIdentifier(id)
}
