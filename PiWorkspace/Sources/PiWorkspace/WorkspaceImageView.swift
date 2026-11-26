import AppKit
import SwiftUI

struct WorkspaceImageView: View {
    let file: WorkspaceImageFile
    let name: String
    @State private var zoom: CGFloat?
    @State private var expanded = false

    private let minimumZoom: CGFloat = 0.05
    private let maximumZoom: CGFloat = 8
    private let padding: CGFloat = 16
    private let toolbarHeight: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            let viewport = CGSize(width: geometry.size.width,
                                  height: max(0, geometry.size.height - toolbarHeight - 1))
            let scale = zoom ?? min(1, max(1, viewport.width - 2 * padding) / file.size.width,
                                    max(1, viewport.height - 2 * padding) / file.size.height)
            VStack(spacing: 0) {
                toolbar(scale: scale)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    Button { expanded = true } label: {
                        WorkspaceImageContent(file: file)
                            .frame(width: file.size.width * scale, height: file.size.height * scale)
                            .accessibilityHidden(true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom \(name)")
                    .accessibilityIdentifier("files-image-expand")
                    .padding(padding)
                    .frame(minWidth: viewport.width, minHeight: viewport.height)
                }
                .defaultScrollAnchor(.center)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image Preview")
        .accessibilityIdentifier("files-image-preview")
        .sheet(isPresented: $expanded) {
            VStack(spacing: 12) {
                HStack {
                    Text(name).lineLimit(1)
                    Spacer()
                    fileButton("Close image preview", "xmark", id: "files-image-close-expanded") { expanded = false }
                        .keyboardShortcut(.cancelAction)
                }
                WorkspaceImageContent(file: file)
                    .aspectRatio(file.size, contentMode: .fit)
                    .accessibilityLabel(name)
                    .accessibilityIdentifier("files-image-expanded")
            }
            .padding(16)
            .frame(idealWidth: 640, idealHeight: 460)
        }
    }

    private func toolbar(scale: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text("\(file.bitmap.width) × \(file.bitmap.height)")
                .accessibilityIdentifier("files-image-dimensions")
            Spacer(minLength: 0)
            fileButton("Zoom out", "minus", id: "files-image-zoom-out") { zoom = max(minimumZoom, scale / 1.25) }
                .disabled(scale <= minimumZoom)
            Text("\(Int((scale * 100).rounded()))%")
                .accessibilityIdentifier("files-image-zoom")
            fileButton("Zoom in", "plus", id: "files-image-zoom-in") { zoom = min(maximumZoom, scale * 1.25) }
                .disabled(scale >= maximumZoom)
            fileButton("Fit image", "arrow.down.right.and.arrow.up.left", id: "files-image-fit") { zoom = nil }
                .accessibilityAddTraits(zoom == nil ? .isSelected : [])
            fileButton("Actual image size", "arrow.up.left.and.arrow.down.right", id: "files-image-actual-size") { zoom = 1 }
                .accessibilityAddTraits(zoom == 1 ? .isSelected : [])
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .frame(height: toolbarHeight)
    }
}

private struct WorkspaceImageContent: View {
    let file: WorkspaceImageFile

    var body: some View {
        if let data = file.animation {
            AnimatedWorkspaceImage(data: data)
        } else {
            Image(decorative: file.bitmap, scale: 1).resizable()
        }
    }
}

private struct AnimatedWorkspaceImage: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.image = NSImage(data: data)
        view.animates = true
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}
