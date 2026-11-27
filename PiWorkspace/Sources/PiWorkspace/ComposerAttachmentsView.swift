import SwiftUI
import UniformTypeIdentifiers

struct ComposerAttachmentsView<Prompt: View, Controls: View>: View {
    @ObservedObject var model: WorkspaceModel
    let threadID: UUID
    @State private var choosingFiles = false
    @State private var picker: FilePicker?
    let previewFocus: FocusState<ChatAttachment.Opener?>.Binding
    let openPreview: (ChatAttachment.Opener) -> Void
    let openFilePreview: (ChatAttachment.Opener) -> Void
    @ViewBuilder let prompt: () -> Prompt
    @ViewBuilder let controls: () -> Controls

    private struct FilePicker {
        let target: ComposerAttachmentTarget
        let threadRevision: Int
        let replacementID: UUID?
    }

    private var target: ComposerAttachmentTarget {
        model.attachmentTarget(for: threadID)
    }

    var body: some View {
        let pasteTarget = target
        VStack(alignment: .leading, spacing: 4) {
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
                if let error = model.attachmentSendError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("attachment-send-error")
                }
                prompt()
            }
            .padding(.horizontal, WorkspaceLayout.editorInset)
            .padding(.top, WorkspaceLayout.editorInset)

            HStack(spacing: 8) {
                Button {
                    chooseFiles(replacing: nil)
                } label: {
                    Label("Attach Files", systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Attach files")
                .accessibilityIdentifier("attach-files")
                .disabled(!model.canEditAttachments)
                PasteButton(supportedContentTypes: ComposerAttachmentInput.contentTypes) {
                    model.pasteAttachments($0, to: pasteTarget)
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Paste files or images")
                .accessibilityLabel("Paste files or images")
                .accessibilityIdentifier("paste-attachments")
                .disabled(!model.canEditAttachments)
                Spacer(minLength: 0)
                controls()
            }
            .font(.system(size: 14))
            .frame(minHeight: 32)
            .padding(.horizontal, 9)
            .padding(.bottom, 9)
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: picker?.replacementID == nil) { result in
            guard let picker, picker.target == target, model.conversation?.id == threadID,
                  picker.threadRevision == model.threadSelectionRevision else { return }
            self.picker = nil
            switch result {
            case .success(let urls):
                model.attach(urls.map(ComposerAttachmentInput.file), to: picker.target, replacing: picker.replacementID)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { model.error = error.localizedDescription }
            }
        }
        .fileDialogDefaultDirectory(model.workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) })
        .onChange(of: target) { _, _ in closePicker() }
        .onChange(of: model.threadSelectionRevision) { _, _ in closePicker() }
    }

    private func chooseFiles(replacing id: UUID?) {
        picker = FilePicker(target: target, threadRevision: model.threadSelectionRevision, replacementID: id)
        choosingFiles = true
    }

    private func closePicker() {
        picker = nil
        choosingFiles = false
    }

    private func tile(_ attachment: ComposerAttachment) -> some View {
        let owner = target
        return HStack(spacing: 6) {
            if let item = ChatImagePreview.ImageItem(attachment) {
                ChatAttachmentPreviewButton(opener: .init(owner: .composer(owner), attachmentID: item.id),
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
                attachmentName(attachment.name)
            } else if attachment.payload != nil {
                ChatAttachmentPreviewButton(opener: .init(owner: .composer(owner), attachmentID: attachment.id),
                                            name: attachment.name, identifier: "preview-attachment-\(attachment.id)",
                                            focus: previewFocus, open: openFilePreview) {
                    Label { attachmentName(attachment.name) } icon: { Image(systemName: "doc.text") }
                }
            } else {
                Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                VStack(alignment: .leading) {
                    attachmentName(attachment.name)
                    Button("Attach Again") { chooseFiles(replacing: attachment.id) }
                        .disabled(!model.canEditAttachments)
                        .accessibilityLabel("Attach \(attachment.name) again")
                        .accessibilityIdentifier("reattach-attachment-\(attachment.id)")
                }
            }
            Button {
                model.removeAttachment(attachment.id, in: owner)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .disabled(!model.canEditAttachments)
            .help("Remove \(attachment.name)")
            .accessibilityLabel("Remove \(attachment.name)")
            .accessibilityIdentifier("remove-attachment-\(attachment.id)")
        }
        .padding(5)
        .buttonStyle(.borderless)
        .font(.callout)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-attachment-\(attachment.id)")
    }

    private func attachmentName(_ name: String) -> some View {
        Text(name)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180)
    }
}
