import SwiftUI

struct ChatFilePreview: View {
    let name: String
    let origin: String
    let localText: String?
    let load: (() async -> ComposerAttachment.Payload?)?
    let remove: (() -> Void)?
    let save: () -> Void
    let close: () -> Void
    @State private var sentText: String?
    @State private var loading = true
    @FocusState private var closeFocused: Bool

    var body: some View {
        let text = localText ?? sentText
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(name).font(.headline).textSelection(.enabled)
                        Text(origin).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save File", action: save)
                        .disabled(text == nil)
                        .accessibilityIdentifier("save-file-preview")
                    if let remove {
                        Button("Remove from Draft", action: remove)
                            .accessibilityIdentifier("remove-file-preview")
                    }
                    Button("Close", action: close)
                        .focusable()
                        .focused($closeFocused)
                        .accessibilityIdentifier("close-file-preview")
                }
                if let text {
                    FileTextView(text: text, editable: false, wraps: true, identifier: "file-preview-contents")
                } else if loading {
                    ProgressView("Loading attachment…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Attachment unavailable.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("file-preview-unavailable")
                }
            }
            .padding()
            .frame(maxWidth: 760, maxHeight: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(20)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("File preview")
            .accessibilityIdentifier("attachment-file-preview")
        }
        .task {
            closeFocused = true
            let payload = await load?()
            guard !Task.isCancelled else { return }
            sentText = payload?.text
            loading = false
        }
    }
}

@MainActor
struct ChatFileSavePicker {
    typealias Completion = (Result<URL?, Error>) -> Void
    let present: (NSWindow, String, @escaping Completion) -> () -> Void

    static let native = Self { window, name, complete in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (name as NSString).lastPathComponent
        panel.beginSheetModal(for: window) { [weak panel] response in
            if response == .abort {
                complete(.failure(WorkspaceError("Could not open the save dialog.")))
            } else {
                complete(.success(response == .OK ? panel?.url : nil))
            }
        }
        return { panel.cancel(nil) }
    }
}

struct ChatFileSavePanel: NSViewRepresentable {
    struct Request: Identifiable {
        let id: UUID
        let name: String
        let load: () async -> ComposerAttachment.Payload?
        let isCurrent: () -> Bool
        let finish: (String?) -> Void
    }

    let request: Request?
    let picker: ChatFileSavePicker

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(request, in: view, picker: picker)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor final class Coordinator {
        private var requestID: UUID?
        private var task: Task<Void, Never>?
        private var cancelPicker: (() -> Void)?

        func update(_ request: Request?, in view: NSView, picker: ChatFileSavePicker) {
            guard requestID != request?.id else { return }
            cancel()
            guard let request else { return }
            requestID = request.id
            task = Task { [weak self, weak view] in
                let payload = await request.load()
                guard let self, self.requestID == request.id, !Task.isCancelled, request.isCurrent() else { return }
                guard let payload, let window = view?.window else {
                    request.finish("Attachment unavailable.")
                    return
                }
                self.cancelPicker = picker.present(window, request.name) { [weak self] result in
                    guard let self, self.requestID == request.id, request.isCurrent() else { return }
                    self.cancelPicker = nil
                    do {
                        if let url = try result.get() {
                            try payload.data.write(to: url, options: .atomic)
                        }
                    } catch {
                        request.finish(error.localizedDescription)
                        return
                    }
                    request.finish(nil)
                }
            }
        }

        func cancel() {
            requestID = nil
            task?.cancel()
            task = nil
            cancelPicker?()
            cancelPicker = nil
        }
    }
}
