import AppKit
import SwiftUI

enum Variant: String, CaseIterable, Encodable {
    case baseline
    case detailsOverlay = "details-overlay"
    case detailsSplit = "details-split"
    case rightSplit = "right-split"
    case rightAdaptive = "right-adaptive"
}

enum Anchor: String {
    case sidebar, chatHeader, detailsButton, composer, editor, detailsPanel, surfacePanel
}

struct Rectangles: PreferenceKey {
    static let defaultValue: [Anchor: CGRect] = [:]

    static func reduce(value: inout [Anchor: CGRect], nextValue: () -> [Anchor: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func measure(_ anchor: Anchor) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: Rectangles.self, value: [anchor: geometry.frame(in: .named("window"))])
            }
        }
    }
}

struct Probe: View {
    let variant: Variant
    let report: ([Anchor: CGRect]) -> Void

    private let sidebarWidth: CGFloat = 257
    private let headerHeight: CGFloat = 52
    private let detailsWidth: CGFloat = 296

    var body: some View {
        GeometryReader { window in
            HStack(spacing: 0) {
                Text("Sidebar")
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .background(.gray.opacity(0.18))
                    .measure(.sidebar)
                workspace(windowWidth: window.size.width)
            }
        }
        .coordinateSpace(name: "window")
        .environment(\.displayScale, 1)
        .onPreferenceChange(Rectangles.self, perform: report)
    }

    @ViewBuilder
    private func workspace(windowWidth: CGFloat) -> some View {
        if variant == .detailsSplit {
            HSplitView {
                chat(hasRightSplit: false)
                panel("Details", anchor: .detailsPanel).frame(width: detailsWidth)
            }
        } else if variant == .rightAdaptive && windowWidth <= 980 {
            chat(hasRightSplit: false)
                .overlay(alignment: .trailing) {
                    panel("Tools", anchor: .surfacePanel)
                        .frame(width: min(448, max(320, windowWidth * 0.42)))
                }
        } else if variant == .rightSplit || variant == .rightAdaptive {
            let workspaceWidth = windowWidth - sidebarWidth
            let panelWidth = min(540, max(360, min(floor(windowWidth * 0.7), workspaceWidth - 360)))
            HSplitView {
                chat(hasRightSplit: true)
                // The reference's outer panel width includes its 1-point divider.
                panel("Tools", anchor: .surfacePanel).frame(width: panelWidth - 1)
            }
        } else {
            chat(hasRightSplit: false)
                .overlay(alignment: .topTrailing) {
                    if variant == .detailsOverlay {
                        panel("Details", anchor: .detailsPanel)
                            .frame(width: detailsWidth, height: 247)
                            .padding(.trailing, 4)
                            .padding(.top, headerHeight)
                    }
                }
        }
    }

    private func chat(hasRightSplit: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Draft").padding(.leading, 20)
                Spacer()
                Image(systemName: "info.circle")
                    .frame(width: 28, height: 28)
                    .measure(.detailsButton)
                    .padding(.trailing, hasRightSplit ? 12 : 77)
            }
            .frame(height: headerHeight)
            .background(.gray.opacity(0.10))
            .measure(.chatHeader)

            VStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.blue.opacity(0.22))
                    .overlay(Text("Input"))
                    .frame(height: 53.5)
                    .measure(.editor)
                    .padding(13)
                    .frame(height: 143.5, alignment: .top)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .measure(.composer)
            }
            .frame(maxWidth: 768)
            .padding(.horizontal, 48)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func panel(_ title: String, anchor: Anchor) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .background(.gray.opacity(0.24))
            .measure(anchor)
    }
}

struct Sample: Encodable {
    let variant: Variant
    let window: [CGFloat]
    let layoutScale: CGFloat
    let windowBackingScale: CGFloat
    let anchors: [String: [CGFloat]]
}

@MainActor
func measure(variant: Variant, width: CGFloat) -> Sample {
    var anchors: [Anchor: CGRect] = [:]
    let host = NSHostingView(rootView: Probe(variant: variant) { anchors = $0 })
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    window.setContentSize(NSSize(width: width, height: 720))

    var required: Set<Anchor> = [.sidebar, .chatHeader, .detailsButton, .composer, .editor]
    switch variant {
    case .baseline: break
    case .detailsOverlay, .detailsSplit: required.insert(.detailsPanel)
    case .rightSplit, .rightAdaptive: required.insert(.surfacePanel)
    }

    // Allow the hosted view and HSplitView divider to finish their layout passes.
    let deadline = Date.now.addingTimeInterval(2)
    var previous: [Anchor: CGRect] = [:]
    var stable = 0
    repeat {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.02))
        stable = anchors == previous ? stable + 1 : 0
        previous = anchors
    } while (stable < 3 || Set(anchors.keys) != required) && Date.now < deadline
    precondition(stable >= 3 && Set(anchors.keys) == required,
                 "Unstable or incomplete layout for \(variant.rawValue) at \(width): \(anchors)")

    let measured = Dictionary(uniqueKeysWithValues: anchors.map { anchor, rect in
        precondition(rect.width > 0 && rect.height > 0 && !rect.isInfinite && !rect.isNull)
        return (anchor.rawValue, [rect.minX, rect.minY, rect.width, rect.height])
    })
    return Sample(
        variant: variant, window: [host.bounds.width, host.bounds.height],
        layoutScale: 1, windowBackingScale: window.backingScaleFactor, anchors: measured)
}

@main
enum LayoutExperiment {
    @MainActor
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reverse = CommandLine.arguments.dropFirst() == ["--reverse"]
        let variants = reverse ? Array(Variant.allCases.reversed()) : Variant.allCases
        for width: CGFloat in [900, 1080, 1440] {
            for variant in variants {
                let sample = measure(variant: variant, width: width)
                let data = try encoder.encode(sample)
                print(String(decoding: data, as: UTF8.self))
            }
        }
    }
}
