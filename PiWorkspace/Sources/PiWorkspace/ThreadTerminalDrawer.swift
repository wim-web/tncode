import AppKit
import SwiftUI

struct ThreadTerminalLocation: Hashable {
    let thread: UUID
    let path: String
}

struct ThreadTerminalDrawerState: Identifiable {
    enum SplitDirection { case horizontal, vertical }

    struct Group: Identifiable {
        let id = UUID()
        let number: Int
        var panes: [Int]
        var direction: SplitDirection = .horizontal
    }

    let id: ThreadTerminalLocation
    var isOpen = true
    private(set) var groups = [Group(number: 1, panes: [1])]
    private(set) var activePane = 1
    private(set) var focusRequest = 0
    private var nextPane = 2

    init(id: ThreadTerminalLocation) {
        self.id = id
    }

    var activeGroup: Group? { groups.first { $0.panes.contains(activePane) } }
    var canSplit: Bool { activeGroup.map { $0.panes.count < 4 } ?? false }
    var panes: [Int] { groups.flatMap(\.panes) }

    mutating func select(_ pane: Int) {
        guard panes.contains(pane) else { return }
        activePane = pane
        focusRequest += 1
    }

    mutating func cycle(by offset: Int) -> Bool {
        let order = panes
        guard order.count > 1, let index = order.firstIndex(of: activePane) else { return false }
        select(order[(index + offset + order.count) % order.count])
        return true
    }

    mutating func newTab() {
        let pane = nextPane
        nextPane += 1
        groups.append(Group(number: pane, panes: [pane]))
        select(pane)
    }

    mutating func split(_ direction: SplitDirection) {
        guard canSplit,
              let group = groups.firstIndex(where: { $0.panes.contains(activePane) }),
              let index = groups[group].panes.firstIndex(of: activePane) else { return }
        let pane = nextPane
        nextPane += 1
        groups[group].panes.insert(pane, at: index + 1)
        groups[group].direction = direction
        select(pane)
    }

    mutating func close(_ pane: Int) {
        guard let group = groups.firstIndex(where: { $0.panes.contains(pane) }),
              let index = groups[group].panes.firstIndex(of: pane) else { return }
        let creationOrder = panes.sorted()
        groups[group].panes.remove(at: index)
        let siblings = groups[group].panes
        if siblings.isEmpty { groups.remove(at: group) }
        if pane == activePane,
           let next = siblings.isEmpty
            ? creationOrder.first(where: { $0 > pane }) ?? creationOrder.last(where: { $0 < pane })
            : siblings[min(index, siblings.count - 1)] {
            select(next)
        }
        if groups.isEmpty { isOpen = false }
    }
}

struct TerminalDrawerHeight {
    static let defaultHeight: CGFloat = 280
    static let toolbar: CGFloat = 30
    static let divider: CGFloat = 1
    static let defaultContent = defaultHeight - toolbar - divider
    private static let minimumHeight: CGFloat = 180

    let maximum: CGFloat
    var minimum: CGFloat { min(Self.minimumHeight, maximum) }

    init(viewport: CGFloat, reserved: CGFloat) {
        let windowCap = max(Self.minimumHeight, floor(viewport * 0.75))
        maximum = min(windowCap, max(0, floor(viewport - reserved)))
    }

    func clamp(_ height: CGFloat) -> CGFloat {
        let height = height.isFinite ? height.rounded() : Self.defaultHeight
        return min(maximum, max(minimum, height))
    }
}

struct ThreadTerminalDrawer: View {
    @Binding var drawer: ThreadTerminalDrawerState
    let selected: Bool
    let limits: TerminalDrawerHeight
    let removeDrawer: () -> Void
    @AppStorage private var preferredHeight: Double?
    @State private var closingPane: Int?
    @State private var dragHeight: CGFloat?

    init(drawer: Binding<ThreadTerminalDrawerState>, selected: Bool, limits: TerminalDrawerHeight,
         removeDrawer: @escaping () -> Void) {
        _drawer = drawer
        self.selected = selected
        self.limits = limits
        self.removeDrawer = removeDrawer
        _preferredHeight = AppStorage("terminal-drawer-height.\(drawer.wrappedValue.id.thread.uuidString)")
    }

    private var visible: Bool { selected && drawer.isOpen }

    var body: some View {
        let height = limits.clamp(dragHeight ?? preferredHeight.map { CGFloat($0) } ?? TerminalDrawerHeight.defaultHeight)
        VStack(spacing: 0) {
            if visible { toolbar }
            ZStack {
                ForEach(drawer.groups) { group in
                    let presented = visible && drawer.activeGroup?.id == group.id
                    let layout = group.direction == .horizontal
                        ? AnyLayout(HStackLayout(spacing: 1))
                        : AnyLayout(VStackLayout(spacing: 1))
                    layout {
                        ForEach(group.panes, id: \.self) { pane in
                            paneView(pane, presented: presented)
                        }
                    }
                    .background(.quaternary)
                    .opacity(presented ? 1 : 0)
                    .accessibilityHidden(!presented)
                    .allowsHitTesting(presented)
                }
            }
            .frame(height: max(0, height - TerminalDrawerHeight.toolbar - TerminalDrawerHeight.divider))
        }
        .frame(height: visible ? height : 0, alignment: .top)
        .clipped()
        .overlay(alignment: .top) {
            if visible && height > 0 {
                TerminalDrawerDivider(height: height, limits: limits, onDrag: { dragHeight = $0 }) {
                    preferredHeight = Double($0)
                }
                .frame(height: min(6, height))
            }
        }
        .onChange(of: visible) { _, visible in
            if !visible { dragHeight = nil }
        }
        .onChange(of: limits.maximum) { _, maximum in
            if let dragHeight {
                self.dragHeight = maximum > 0 ? limits.clamp(dragHeight) : nil
            }
        }
        .onChange(of: drawer.groups.isEmpty) { _, empty in
            if empty {
                preferredHeight = nil
                removeDrawer()
            }
        }
        .alert("Close Terminal \(closingPane ?? drawer.activePane)?", isPresented: Binding(
            get: { closingPane != nil },
            set: { if !$0 { closingPane = nil } }
        ), presenting: closingPane) { pane in
            Button("Cancel", role: .cancel) {
                closingPane = nil
                drawer.select(drawer.activePane)
            }
            .accessibilityIdentifier("cancel-close-terminal")
            Button("Close Terminal", role: .destructive) {
                drawer.close(pane)
            }
            .accessibilityIdentifier("confirm-close-terminal")
        } message: { _ in
            Text("This stops the shell and clears its output.")
        }
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            Divider().frame(height: TerminalDrawerHeight.divider)
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(drawer.groups) { group in
                            let active = drawer.activeGroup?.id == group.id
                            Button {
                                if let pane = active ? drawer.activePane : group.panes.first {
                                    drawer.select(pane)
                                }
                            } label: {
                                Text("Terminal \(group.number)")
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(active ? Color.accentColor.opacity(0.16) : .clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                            }
                            .accessibilityAddTraits(active ? .isSelected : [])
                            .accessibilityIdentifier("terminal-tab-\(group.number)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                toolbarButton("New Terminal", icon: "plus", id: "new-terminal") { drawer.newTab() }
                toolbarButton("Split Terminal Horizontally", icon: "rectangle.split.2x1", id: "split-terminal-horizontal") {
                    drawer.split(.horizontal)
                }
                .disabled(!drawer.canSplit)
                toolbarButton("Split Terminal Vertically", icon: "rectangle.split.1x2", id: "split-terminal-vertical") {
                    drawer.split(.vertical)
                }
                .disabled(!drawer.canSplit)
                toolbarButton("Hide Terminal", icon: "chevron.down", id: "hide-terminal") { drawer.isOpen = false }
                toolbarButton("Close Terminal", icon: "xmark", id: "close-terminal") { closingPane = drawer.activePane }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .frame(height: TerminalDrawerHeight.toolbar)
            .padding(.horizontal, 12)
        }
    }

    private func paneView(_ pane: Int, presented: Bool) -> some View {
        let active = drawer.activePane == pane
        let outlined = active && (drawer.activeGroup?.panes.count ?? 0) > 1
        return ThreadTerminal(directory: drawer.id.path, number: pane, visible: presented,
                              focusRequest: presented && active ? drawer.focusRequest : nil,
                              onFocus: { if drawer.activePane != pane { drawer.select(pane) } },
                              onCycle: { drawer.cycle(by: $0) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                Rectangle().strokeBorder(Color.accentColor.opacity(outlined ? 0.65 : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private func toolbarButton(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 22, height: 22)
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

private struct TerminalDrawerDivider: NSViewRepresentable {
    let height: CGFloat
    let limits: TerminalDrawerHeight
    let onDrag: (CGFloat?) -> Void
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> TerminalDrawerDividerView {
        TerminalDrawerDividerView()
    }

    func updateNSView(_ view: TerminalDrawerDividerView, context: Context) {
        view.update(height: height, limits: limits, onDrag: onDrag, onResize: onResize)
    }
}

final class TerminalDrawerDividerView: NSView {
    private struct Drag {
        let startY: CGFloat
        let startHeight: CGFloat

        func height(at event: NSEvent, within limits: TerminalDrawerHeight) -> CGFloat {
            limits.clamp(startHeight + event.locationInWindow.y - startY)
        }
    }

    private var height: CGFloat = TerminalDrawerHeight.defaultHeight
    private var limits = TerminalDrawerHeight(viewport: 0, reserved: 0)
    private var onDrag: ((CGFloat?) -> Void)?
    private var onResize: ((CGFloat) -> Void)?
    private var drag: Drag?

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(.horizontal)
        setAccessibilityLabel("Resize Terminal Drawer")
        setAccessibilityIdentifier("terminal-drawer-resize-handle")
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    func update(height: CGFloat, limits: TerminalDrawerHeight, onDrag: @escaping (CGFloat?) -> Void,
                onResize: @escaping (CGFloat) -> Void) {
        let changed = self.height != height
        self.height = height
        self.limits = limits
        self.onDrag = onDrag
        self.onResize = onResize
        setAccessibilityMinValue(NSNumber(value: Double(limits.minimum)))
        setAccessibilityMaxValue(NSNumber(value: Double(limits.maximum)))
        if changed { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    override func resetCursorRects() {
        if #available(macOS 15, *) {
            addCursorRect(bounds, cursor: .rowResize(directions: .all))
        } else {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        drag = Drag(startY: event.locationInWindow.y, startHeight: height)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        onDrag?(drag.height(at: event, within: limits))
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        onDrag?(nil)
        let end = drag.height(at: event, within: limits)
        if end > 0, end != limits.clamp(drag.startHeight) { onResize?(end) }
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: Double(height))
    }

    override func setAccessibilityValue(_ value: Any?) {
        guard let value = value as? NSNumber, value.doubleValue.isFinite else { return }
        adjustHeight(to: CGFloat(value.doubleValue))
    }

    override func accessibilityPerformIncrement() -> Bool {
        adjustHeight(to: height + 16)
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjustHeight(to: height - 16)
    }

    @discardableResult
    private func adjustHeight(to proposed: CGFloat) -> Bool {
        let end = limits.clamp(proposed)
        guard drag == nil, end != height, end > 0, let onResize else { return false }
        onResize(end)
        return true
    }
}
