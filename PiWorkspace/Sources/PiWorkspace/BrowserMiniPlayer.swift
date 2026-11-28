import SwiftUI

struct BrowserMiniPlayerPlacement: Equatable {
    static let gap: CGFloat = 12
    let aspect: CGFloat
    var origin: CGPoint?
    var width: CGFloat?

    init(source: CGSize) {
        aspect = source.width > 0 && source.height > 0 ? source.width / source.height : 1
    }

    func frame(in canvas: CGSize, avoiding obstacles: [CGRect] = []) -> CGRect {
        let gap = Self.gap
        let bounds = CGRect(x: gap, y: gap, width: max(0, canvas.width - 2 * gap), height: max(0, canvas.height - 2 * gap))
        let minimumWidth = max(240, 150 * aspect)
        let preferred = width ?? max(minimumWidth, min(320, 320 * aspect))
        let initial = fitted(width: preferred, inside: bounds, near: origin)
        var spaces = [bounds]
        for obstacle in obstacles {
            let blocked = obstacle.insetBy(dx: -gap, dy: -gap)
            spaces = spaces.flatMap { space -> [CGRect] in
                let cut = space.intersection(blocked)
                guard !cut.isNull, !cut.isEmpty else { return [space] }
                return [
                    CGRect(x: space.minX, y: space.minY, width: cut.minX - space.minX, height: space.height),
                    CGRect(x: cut.maxX, y: space.minY, width: space.maxX - cut.maxX, height: space.height),
                    CGRect(x: space.minX, y: space.minY, width: space.width, height: cut.minY - space.minY),
                    CGRect(x: space.minX, y: cut.maxY, width: space.width, height: space.maxY - cut.maxY)
                ].filter { !$0.isEmpty }
            }
        }
        let candidates = spaces.map { fitted(width: preferred, inside: $0, near: initial.origin) }
        return candidates.min { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            func distance(_ frame: CGRect) -> CGFloat {
                abs(frame.minX - initial.minX) + abs(frame.minY - initial.minY)
            }
            return distance(lhs) < distance(rhs)
        } ?? initial
    }

    private func fitted(width: CGFloat, inside space: CGRect, near origin: CGPoint?) -> CGRect {
        let width = min(width, space.width, space.height * aspect)
        let height = width / aspect
        let x = min(max(origin?.x ?? space.maxX, space.minX), space.maxX - width)
        let y = min(max(origin?.y ?? space.maxY, space.minY), space.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func moved(from start: CGRect, by delta: CGSize, in canvas: CGSize, avoiding obstacles: [CGRect]) -> Self {
        var next = self
        next.origin = CGPoint(x: start.minX + delta.width, y: start.minY + delta.height)
        next.origin = next.frame(in: canvas, avoiding: obstacles).origin
        return next
    }

    func resized(from start: CGRect, edge: BrowserResizeHandle, by delta: CGSize, in canvas: CGSize,
                 avoiding obstacles: [CGRect]) -> Self {
        let dx = edge.horizontal, dy = edge.vertical
        let change = (dx * delta.width + dy * delta.height / aspect) / (dx * dx + dy * dy / (aspect * aspect))
        let maxWidth = dx < 0 ? start.maxX - Self.gap : canvas.width - Self.gap - start.minX
        let maxHeight = dy < 0 ? start.maxY - Self.gap : canvas.height - Self.gap - start.minY
        let minimum = min(start.width, max(240, 150 * aspect))
        let newWidth = max(0, min(maxWidth, maxHeight * aspect, max(start.width + change, minimum)))
        var next = self
        next.width = newWidth
        next.origin = CGPoint(x: dx < 0 ? start.maxX - newWidth : start.minX,
                              y: dy < 0 ? start.maxY - newWidth / aspect : start.minY)
        let result = next.frame(in: canvas, avoiding: obstacles)
        next.width = result.width
        next.origin = result.origin
        return next
    }
}

enum BrowserResizeHandle: String, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var horizontal: CGFloat {
        switch self {
        case .topLeft, .bottomLeft, .left: -1
        case .topRight, .bottomRight, .right: 1
        case .top, .bottom: 0
        }
    }

    var vertical: CGFloat {
        switch self {
        case .topLeft, .topRight, .top: -1
        case .bottomLeft, .bottomRight, .bottom: 1
        case .left, .right: 0
        }
    }
}

enum BrowserMiniPlayerObstacle: Hashable { case composer, details }

struct BrowserMiniPlayerObstacles: PreferenceKey {
    static let defaultValue: [BrowserMiniPlayerObstacle: Anchor<CGRect>] = [:]

    static func reduce(value: inout [BrowserMiniPlayerObstacle: Anchor<CGRect>], nextValue: () -> [BrowserMiniPlayerObstacle: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct BrowserMiniPlayer: View {
    @ObservedObject var tab: BrowserPreviewSession
    let placement: BrowserMiniPlayerPlacement
    let canvas: CGSize
    let obstacles: [CGRect]
    let place: (BrowserMiniPlayerPlacement) -> Void
    let dock: () -> Void
    let popOut: () -> Void
    let close: () -> Void
    @State private var gestureStart: CGRect?

    var body: some View {
        let rect = placement.frame(in: canvas, avoiding: obstacles)
        ZStack(alignment: .topLeading) {
            BrowserPageContent(session: tab, surface: .miniPlayer, emptyHint: "Open a URL in the Browser panel.")
            if case .notice(let message) = tab.problem {
                Text(localized: message).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .frame(width: 24, height: 23).contentShape(Rectangle())
                    .gesture(gesture(from: rect, edge: nil))
                    .help("Move Mini Player")
                    .accessibilityLabel("Move Mini Player")
                    .accessibilityIdentifier("browser-mini-move")
                control("Open in Browser Panel", "sidebar.right", "browser-mini-dock", dock)
                control("Open in Floating Window", "macwindow", "browser-mini-undock", popOut)
                control("Close Mini Player", "xmark", "browser-mini-close", close)
            }
            .padding(.horizontal, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
        .overlay {
            ForEach(BrowserResizeHandle.allCases, id: \.self) { edge in
                Color.clear
                    .frame(width: edge.horizontal == 0 ? max(0, rect.width - 26) : 12,
                           height: edge.vertical == 0 ? max(0, rect.height - 26) : 12)
                    .contentShape(Rectangle())
                    .gesture(gesture(from: rect, edge: edge))
                    .position(x: rect.width / 2 + edge.horizontal * (rect.width / 2 - 6),
                              y: rect.height / 2 + edge.vertical * (rect.height / 2 - 6))
                    .accessibilityHidden(true)
            }
        }
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.5)).allowsHitTesting(false) }
        .shadow(radius: 5, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating browser preview")
        .accessibilityIdentifier("browser-mini-player")
        .position(x: rect.midX, y: rect.midY)
    }

    private func gesture(from rect: CGRect, edge: BrowserResizeHandle?) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { value in
                let start = gestureStart ?? rect
                gestureStart = start
                if let edge {
                    place(placement.resized(from: start, edge: edge, by: value.translation, in: canvas, avoiding: obstacles))
                } else {
                    place(placement.moved(from: start, by: value.translation, in: canvas, avoiding: obstacles))
                }
            }
            .onEnded { _ in gestureStart = nil }
    }

    private func control(_ title: String, _ symbol: String, _ id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 19, height: 23).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(Text(localized: title)).accessibilityLabel(Text(localized: title)).accessibilityIdentifier(id)
    }
}
