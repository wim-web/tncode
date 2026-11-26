import SwiftUI
import UniformTypeIdentifiers

struct ComposerAttachmentsView: View {
    @ObservedObject var model: WorkspaceModel
    let threadID: UUID
    @State private var choosingFiles = false
    @State private var replacementID: UUID?
    @State private var pickerTarget: ComposerAttachmentTarget?
    let previewFocus: FocusState<ChatImagePreview.Opener?>.Binding
    let openPreview: (ChatImagePreview.Opener) -> Void
    private var target: ComposerAttachmentTarget {
        model.attachmentTarget(for: threadID)
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
                PasteButton(supportedContentTypes: ComposerAttachmentInput.contentTypes) {
                    model.pasteAttachments($0, to: pasteTarget)
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
    }

    private func chooseFiles(replacing id: UUID?) {
        pickerTarget = target
        replacementID = id
        choosingFiles = true
    }

    private func tile(_ attachment: ComposerAttachment) -> some View {
        HStack(spacing: 6) {
            if let item = ChatImagePreview.ImageItem(attachment) {
                ChatImagePreviewButton(opener: .init(owner: .composer(target), attachmentID: item.id),
                                       name: item.name, identifier: "preview-attachment-\(item.id)",
                                       focus: previewFocus, open: openPreview) {
                    Group {
                        if let image = attachment.preview(maximumSize: 96) {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Image(systemName: "photo")
                        }
                    }
                    .frame(width: 34, height: 34)
                }
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
