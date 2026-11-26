import SwiftUI

struct QueuedMessagesView: View {
    @ObservedObject var model: WorkspaceModel
    let focusComposer: () -> Void
    @State private var expanded = false

    var body: some View {
        let items = model.queuedMessages
        let collapsible = items.count > 3
        let visible = Array(items.prefix(collapsible && !expanded ? 2 : items.count))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(items.count == 1 ? "1 queued message" : "\(items.count) queued messages")
                        .accessibilityIdentifier("queue-count")
                    Spacer()
                    if model.queuePaused && model.canStartQueuedMessage {
                        Button("Resume Queue", action: model.resumeQueuedMessages)
                            .disabled(model.editingQueuedMessageID == items.first?.id)
                            .accessibilityIdentifier("resume-queue")
                    }
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(visible) { item in row(item, first: item.id == items.first?.id) }
                    }
                }
                .frame(height: min(CGFloat(visible.count) * 32, 146))
                if collapsible {
                    Button(expanded ? "Show fewer" : "\(items.count - visible.count) more queued messages") {
                        expanded.toggle()
                    }
                    .accessibilityIdentifier("toggle-queued-messages")
                }
            }
            .font(.callout)
            .padding(.horizontal, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("queued-messages")
            .onChange(of: collapsible) { _, collapsible in
                if !collapsible { expanded = false }
            }
        }
    }

    private func row(_ item: QueuedMessage, first: Bool) -> some View {
        let editing = model.editingQueuedMessageID == item.id
        let sendLabel = if model.canStartQueuedMessage {
            "Start a turn with this message"
        } else if model.canSkipCompaction {
            "Skip compaction and send this message"
        } else {
            "Send into the current turn"
        }
        return HStack(spacing: 6) {
            Text(item.text.isEmpty ? (item.attachments ?? []).map(\.name).joined(separator: ", ") : item.text)
                .lineLimit(1)
                .help(item.text)
                .accessibilityIdentifier("queued-message-\(item.id)")
            if let attachments = item.attachments, !attachments.isEmpty {
                Label("\(attachments.count)", systemImage: "paperclip")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(attachments.count) attachments")
            }
            Spacer(minLength: 0)
            if editing {
                Text("Editing").foregroundStyle(.secondary)
            } else {
                if model.canStartQueuedMessage || model.canSteer || model.canSkipCompaction {
                    Button {
                        model.sendQueuedMessageNow(item.id)
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .help(sendLabel)
                    .accessibilityLabel(sendLabel)
                    .accessibilityIdentifier("queue-send-now-\(item.id)")
                }
                Menu {
                    Button("Edit in Composer") {
                        model.editQueuedMessage(item.id)
                        focusComposer()
                    }
                    .disabled(!model.canStartEditingQueuedMessage)
                    .accessibilityIdentifier("queue-edit-\(item.id)")
                    if !first {
                        Button("Move to Front") { model.moveQueuedMessageToFront(item.id) }
                            .accessibilityIdentifier("queue-move-first-\(item.id)")
                    }
                    Button("Remove Queued Message") { model.removeQueuedMessage(item.id) }
                        .accessibilityIdentifier("queue-remove-\(item.id)")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!model.canEditQueue)
                .accessibilityLabel("Queued message actions")
                .accessibilityIdentifier("queue-item-actions-\(item.id)")
            }
        }
        .buttonStyle(.borderless)
        .frame(height: 30)
    }
}
