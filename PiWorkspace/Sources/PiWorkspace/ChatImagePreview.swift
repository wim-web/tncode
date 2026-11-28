import Carbon
import SwiftUI
import UniformTypeIdentifiers

enum ChatAttachment {
    enum Owner: Hashable {
        case composer(ComposerAttachmentTarget)
        case queued(thread: UUID, message: UUID)
        case sent(thread: UUID, message: String)

        var threadID: UUID {
            switch self {
            case .composer(let target): target.threadID
            case .queued(let thread, _), .sent(let thread, _): thread
            }
        }
    }

    struct Opener: Hashable {
        let owner: Owner
        let attachmentID: UUID
    }
}

struct ChatImagePreview {
    let opener: ChatAttachment.Opener
    var selectedID: UUID

    init(_ opener: ChatAttachment.Opener) {
        self.opener = opener
        selectedID = opener.attachmentID
    }

    func index(in images: [ImageItem]) -> Int? {
        guard images.contains(where: { $0.id == opener.attachmentID }) else { return nil }
        return images.firstIndex { $0.id == selectedID }
    }

    struct ImageItem: Identifiable {
        let id: UUID
        let name: String
        let payload: ComposerAttachment.Payload?

        init?(_ attachment: ComposerAttachment) {
            guard let payload = attachment.payload, payload.isImage else { return nil }
            self.init(id: attachment.id, name: attachment.name, payload: payload)
        }

        init?(_ attachment: SentAttachment) {
            guard attachment.hasImage == true else { return nil }
            self.init(id: attachment.id, name: attachment.name, payload: nil)
        }

        private init(id: UUID, name: String, payload: ComposerAttachment.Payload?) {
            self.id = id
            self.name = name
            self.payload = payload
        }
    }
}

struct ChatAttachmentPreviewButton<Label: View>: View {
    let opener: ChatAttachment.Opener
    let name: String
    let identifier: String
    let focus: FocusState<ChatAttachment.Opener?>.Binding
    let open: (ChatAttachment.Opener) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { open(opener) } label: { label() }
            .focusable()
            .focused(focus, equals: opener)
            .help("Preview \(name)")
            .accessibilityLabel("Preview \(name)")
            .accessibilityIdentifier(identifier)
    }
}

struct SentImageThumbnail: View {
    let name: String
    let load: () async -> ComposerAttachment.Payload?
    @State private var raster: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let raster {
                    Image(nsImage: raster).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo")
                }
            }
            .frame(width: 34, height: 34)
            Text(name).lineLimit(1)
        }
        .task {
            guard let payload = await load(), !Task.isCancelled else { return }
            raster = ComposerAttachment.preview(payload, maximumSize: 96)
        }
    }
}

struct ChatImagePreviewDialog: View {
    let items: [ChatImagePreview.ImageItem]
    let index: Int
    let close: () -> Void
    let navigate: (Int) -> Void
    let load: (ChatImagePreview.ImageItem) async -> ComposerAttachment.Payload?
    let pasteboard: NSPasteboard
    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                HStack {
                    if items.count > 1 {
                        Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
                            .help("Previous media")
                            .accessibilityLabel("Previous media")
                            .accessibilityIdentifier("previous-image-preview")
                        Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                            .help("Next media")
                            .accessibilityLabel("Next media")
                            .accessibilityIdentifier("next-image-preview")
                    }
                    Spacer()
                    Button("Close Image Preview", action: close)
                        .focusable()
                        .focused($closeFocused)
                        .accessibilityIdentifier("close-image-preview")
                }
                ChatImagePreviewContent(item: items[index], pasteboard: pasteboard, load: load,
                                        close: close, navigate: items.count > 1 ? navigate : nil)
                    .id(items[index].id)
                Text(items.count == 1 ? items[index].name : "\(items[index].name) (\(index + 1)/\(items.count))")
                    .font(.callout)
                    .accessibilityIdentifier("image-preview-caption")
            }
            .padding()
            .frame(maxWidth: 760, maxHeight: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(20)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Expanded image preview")
            .accessibilityIdentifier("attachment-image-preview")
        }
        .task { closeFocused = true }
    }
}

private struct ChatImagePreviewContent: View {
    let item: ChatImagePreview.ImageItem
    let pasteboard: NSPasteboard
    let load: (ChatImagePreview.ImageItem) async -> ComposerAttachment.Payload?
    let close: () -> Void
    let navigate: ((Int) -> Void)?
    @State private var image: ImageState = .loading
    @State private var actionError: String?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1

    private enum ImageState {
        case loading
        case unavailable
        case loaded(ComposerAttachment.Payload, NSImage?)

        var raster: NSImage? {
            if case .loaded(_, let raster) = self { return raster }
            return nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            Group {
                if case .loaded(let payload, let raster?) = image {
                    let fit = fitted(raster.size, in: viewport)
                    let scale = clampedZoom(zoom * magnification)
                    Image(nsImage: raster)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .scaleEffect(scale)
                        .offset(boundedPan(pan + drag, fit: fit, viewport: viewport, scale: scale))
                        .frame(width: viewport.width, height: viewport.height)
                        .contentShape(Rectangle())
                        .clipped()
                        .onTapGesture { updateZoom(zoom > 1 ? 1 : 2, fit: fit, viewport: viewport) }
                        .gesture(DragGesture().updating($drag) { gesture, state, _ in state = gesture.translation }
                            .onEnded { pan = boundedPan(pan + $0.translation, fit: fit, viewport: viewport, scale: zoom) })
                        .gesture(MagnifyGesture().updating($magnification) { gesture, state, _ in
                            state = gesture.magnification
                        }.onEnded { updateZoom(zoom * $0.magnification, fit: fit, viewport: viewport) })
                        .focusable()
                        .onKeyPress(keys: [.return, .space]) { _ in
                            updateZoom(zoom > 1 ? 1 : 2, fit: fit, viewport: viewport)
                            return .handled
                        }
                        .accessibilityLabel(item.name)
                        .accessibilityIdentifier("expanded-attachment-\(item.id)")
                        .accessibilityAction(named: "Toggle Zoom") {
                            updateZoom(zoom > 1 ? 1 : 2, fit: fit, viewport: viewport)
                        }
                        .accessibilityAction(named: "Copy Image") { copy(payload) }
                } else if case .loading = image {
                    ProgressView("Loading image…")
                        .accessibilityIdentifier("image-preview-loading")
                } else {
                    Text("Image unavailable. The file may have been moved or deleted.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("image-preview-unavailable")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                if case .loaded(let payload, let raster) = image {
                    Button("Save Image…") { save(payload) }
                        .accessibilityIdentifier("save-preview-image")
                    Button("Copy Image") { copy(payload) }
                        .disabled(raster == nil)
                        .accessibilityIdentifier("copy-preview-image")
                }
            }
            .background {
                WindowKeyMonitor { event, _ in handleKey(event, viewport: viewport) }
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        .task(id: item.payload) {
            let payload = await load(item)
            guard !Task.isCancelled else { return }
            if let payload {
                image = .loaded(payload, ComposerAttachment.preview(payload, maximumSize: 2_000))
            } else {
                image = .unavailable
            }
        }
        if let actionError {
            Text(actionError)
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityIdentifier("image-preview-action-error")
        }
    }

    private func handleKey(_ event: NSEvent, viewport: CGSize) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        let fit = image.raster.map { fitted($0.size, in: viewport) } ?? .zero
        switch Int(event.keyCode) {
        case kVK_Escape: close()
        case kVK_LeftArrow, kVK_RightArrow:
            let direction = event.keyCode == kVK_LeftArrow ? -1 : 1
            if fit.width * zoom > viewport.width {
                pan = boundedPan(pan + CGSize(width: CGFloat(-direction) * 48, height: 0),
                                 fit: fit, viewport: viewport, scale: zoom)
            } else {
                guard let navigate else { return false }
                navigate(direction)
            }
        case kVK_UpArrow, kVK_DownArrow:
            guard zoom > 1 else { return false }
            let direction: CGFloat = event.keyCode == kVK_UpArrow ? 1 : -1
            pan = boundedPan(pan + CGSize(width: 0, height: direction * 48),
                             fit: fit, viewport: viewport, scale: zoom)
        default:
            guard image.raster != nil else { return false }
            switch event.charactersIgnoringModifiers {
            case "+", "=": updateZoom(zoom * 1.5, fit: fit, viewport: viewport)
            case "-": updateZoom(zoom / 1.5, fit: fit, viewport: viewport)
            case "0": updateZoom(1, fit: fit, viewport: viewport)
            default: return false
            }
        }
        return true
    }

    private func fitted(_ image: CGSize, in viewport: CGSize) -> CGSize {
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func updateZoom(_ value: CGFloat, fit: CGSize, viewport: CGSize) {
        zoom = clampedZoom(value)
        pan = boundedPan(pan, fit: fit, viewport: viewport, scale: zoom)
    }

    private func clampedZoom(_ scale: CGFloat) -> CGFloat { min(max(scale, 1), 8) }

    private func boundedPan(_ offset: CGSize, fit: CGSize, viewport: CGSize, scale: CGFloat) -> CGSize {
        let x = max(0, (fit.width * scale - viewport.width) / 2)
        let y = max(0, (fit.height * scale - viewport.height) / 2)
        return CGSize(width: min(max(offset.width, -x), x), height: min(max(offset.height, -y), y))
    }

    private func copy(_ payload: ComposerAttachment.Payload) {
        actionError = nil
        guard let png = ComposerAttachment.pngForCopy(payload) else {
            actionError = String(localized: "Could not copy image.")
            return
        }
        pasteboard.clearContents()
        if !pasteboard.setData(png, forType: .png) { actionError = String(localized: "Could not copy image.") }
    }

    private func save(_ payload: ComposerAttachment.Payload) {
        actionError = nil
        let panel = NSSavePanel()
        let type: UTType = payload.mimeType == "image/jpeg" ? .jpeg : .png
        let name = item.name as NSString
        panel.nameFieldStringValue = UTType(filenameExtension: name.pathExtension) == type
            ? item.name : "\(name.deletingPathExtension).\(type == .jpeg ? "jpg" : "png")"
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try payload.data.write(to: url, options: .atomic)
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private func + (left: CGSize, right: CGSize) -> CGSize {
    CGSize(width: left.width + right.width, height: left.height + right.height)
}
