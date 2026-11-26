import SwiftUI
import UniformTypeIdentifiers

struct ComposerAttachmentsView: View {
    @ObservedObject var model: WorkspaceModel
    let threadID: UUID
    @State private var choosingFiles = false
    @State private var replacementID: UUID?
    @State private var pickerTarget: ComposerAttachmentTarget?
    @State private var preview: ComposerAttachment?
    private var target: ComposerAttachmentTarget {
        ComposerAttachmentTarget(threadID: threadID, queueID: model.editingQueuedMessageID)
    }

    var body: some View {
        let pasteTarget = target
        VStack(alignment: .leading, spacing: 6) {
            if !model.composerAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.composerAttachments) { attachment in
                            tile(attachment)
                        }
                    }
                }
                .accessibilityIdentifier("composer-attachments")
            }
            HStack {
                Button {
                    chooseFiles(replacing: nil)
                } label: {
                    Label("Attach Files", systemImage: "paperclip")
                }
                .accessibilityIdentifier("attach-files")
                .disabled(!model.canEditAttachments)
                PasteButton(payloadType: ComposerAttachmentInput.self) {
                    model.attach($0, to: pasteTarget)
                }
                .help("Paste files or images")
                .accessibilityLabel("Paste files or images")
                .accessibilityIdentifier("paste-attachments")
                .disabled(!model.canEditAttachments)
                if let error = model.attachmentSendError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("attachment-send-error")
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: replacementID == nil) { result in
            switch result {
            case .success(let urls):
                guard let pickerTarget else { return }
                model.attach(urls.map(ComposerAttachmentInput.file), to: pickerTarget, replacing: replacementID)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { model.error = error.localizedDescription }
            }
        }
        .fileDialogDefaultDirectory(model.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) })
        .sheet(item: $preview) { attachment in
            VStack(alignment: .trailing, spacing: 12) {
                HStack {
                    Text(attachment.name).font(.headline)
                    Spacer()
                    Button("Close Image Preview") { preview = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("close-image-preview")
                }
                if let image = attachment.preview(maximumSize: 1600) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(attachment.name)
                        .accessibilityIdentifier("expanded-attachment-\(attachment.id)")
                }
            }
            .padding()
            .frame(width: 640, height: 460)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("attachment-image-preview")
        }
    }

    private func chooseFiles(replacing id: UUID?) {
        pickerTarget = target
        replacementID = id
        choosingFiles = true
    }

    private func tile(_ attachment: ComposerAttachment) -> some View {
        HStack(spacing: 6) {
            if let image = attachment.preview(maximumSize: 96) {
                Button { preview = attachment } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                }
                .help("Preview \(attachment.name)")
                .accessibilityLabel("Preview \(attachment.name)")
                .accessibilityIdentifier("preview-attachment-\(attachment.id)")
            } else {
                Image(systemName: attachment.payload == nil ? "exclamationmark.triangle" : "doc.text")
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading) {
                Text(attachment.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
                if attachment.payload == nil {
                    Button("Attach Again") { chooseFiles(replacing: attachment.id) }
                        .disabled(!model.canEditAttachments)
                        .accessibilityLabel("Attach \(attachment.name) again")
                        .accessibilityIdentifier("reattach-attachment-\(attachment.id)")
                }
            }
            Button {
                model.removeAttachment(attachment.id, in: target)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .disabled(!model.canEditAttachments)
            .help("Remove \(attachment.name)")
            .accessibilityLabel("Remove \(attachment.name)")
            .accessibilityIdentifier("remove-attachment-\(attachment.id)")
        }
        .padding(5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-attachment-\(attachment.id)")
    }
}
