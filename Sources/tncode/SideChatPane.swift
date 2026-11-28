import SwiftUI

struct SideChatPane: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var session: SideChatSession
    let child: SideChat
    let parentTitle: String
    let pasteboard: NSPasteboard
    let focus: FocusState<UUID?>.Binding
    let openParent: () -> Void
    let delete: () -> Void
    let close: () -> Void

    private var scope: SideChatScope { session.scope }
    private var canSend: Bool {
        session.phase == .ready && child.submissionID == nil &&
            (!child.prompt.isEmpty || !(child.attachments ?? []).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(child.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Button("Add to chat") { model.addSideChatToParent(scope) }
                    .buttonStyle(.borderless)
                    .help("Attach this side chat to the parent’s next message.")
                    .accessibilityIdentifier("add-side-chat-to-chat")
                    .disabled(!model.canAddSideChatToParent(scope))
                panelIcon("Delete side chat", icon: "trash", id: "delete-side-chat", action: delete)
                    .disabled(session.phase == .connecting || session.phase.isRunning)
                panelIcon("Close side chat", icon: "xmark", id: "close-side-chat", action: close)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            Divider()
            Button(action: openParent) {
                Label(parentTitle, systemImage: "arrow.turn.up.left")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .help("Open parent thread")
            .accessibilityLabel("Open parent thread: \(parentTitle)")
            .accessibilityIdentifier("open-side-chat-parent")
            .padding(10)
            transcript
            composer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("side-chat-pane")
        .task(id: scope) {
            await Task.yield()
            if !Task.isCancelled { focus.wrappedValue = scope.id }
        }
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == .user ? "You" : "Pi")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            transcriptText(message.text)
                            ForEach(message.attachments ?? []) { attachment in
                                Label(attachment.name, systemImage: "paperclip").font(.caption)
                            }
                        }
                        .accessibilityIdentifier("side-chat-message-\(message.id)")
                    }
                    if !session.partial.isEmpty { transcriptText(session.partial) }
                    Color.clear.frame(height: 1).id("side-chat-bottom")
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: session.messages.last?.id, initial: true) { _, _ in reader.scrollTo("side-chat-bottom") }
            .onChange(of: session.partial) { _, _ in reader.scrollTo("side-chat-bottom") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("side-chat-transcript")
    }

    private func transcriptText(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = session.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("side-chat-error")
            }
            if session.phase == .closed {
                Button("Reconnect") { model.retrySideChat(scope) }
                    .accessibilityIdentifier("reconnect-side-chat")
            }
            if let approval = session.approval, let directory = model.workingDirectory {
                ToolApprovalCard(approval: approval, directory: directory) {
                    model.approveSideChatTool(approval, in: scope, decision: $0)
                }
            }
            if let question = session.question {
                AgentQuestionCard(request: question.request, submitting: question.submitting, error: question.error,
                                  respond: { model.answerSideChatQuestion(question.request.scope, in: scope, decision: $0) },
                                  stop: { model.stopSideChat(scope) })
                    .id(question.request.scope.requestID)
            } else {
                ForEach(child.attachments ?? []) { attachment in
                    HStack {
                        Label(attachment.name, systemImage: "paperclip").lineLimit(1)
                        Spacer()
                        panelIcon(String(localized: "Remove \(attachment.name)"), icon: "xmark",
                                  id: "remove-side-file-\(attachment.id)") {
                            model.removeSideChatFile(attachment.id, in: scope)
                        }
                        .disabled(child.submissionID != nil)
                    }
                    .font(.caption)
                }
                ComposerTextField(target: .init(threadID: child.id), placeholder: String(localized: "Ask a side question"),
                                  text: Binding(get: { model.sideChat(scope)?.draft ?? "" },
                                                set: { model.editSideChat($0, in: scope) }),
                                  pasteboard: pasteboard,
                                  drop: .init(canDrop: false, perform: { _ in false }, isTargeted: { _ in }),
                                  fileMentionRevision: nil, identifier: "side-chat-composer",
                                  foldPastedText: { _, _ in false })
                    .focused(focus, equals: scope.id)
                    .focusedValue(\.editingComposer, true)
                    .accessibilityIdentifier("side-chat-composer")
                    .disabled(child.submissionID != nil)
                HStack {
                    Text(child.model.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if session.phase.isRunning {
                        Button("Stop") { model.stopSideChat(scope) }
                            .accessibilityIdentifier("stop-side-chat")
                            .disabled(!session.phase.canStop)
                    } else {
                        Button("Send") { model.sendSideChat(scope) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("send-side-chat")
                            .disabled(!canSend)
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.36), in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }
}

struct SideChatDeletion {
    let scope: SideChatScope
    let title: String
}

struct SideChatDeleteConfirmation: View {
    let request: SideChatDeletion
    let finish: (Bool) -> Void
    private enum Choice { case cancel, confirm }
    @FocusState private var choice: Choice?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete side chat \"\(request.title)\"?").font(.headline)
                .accessibilityIdentifier("side-chat-delete-title")
            Text("This permanently clears its conversation history.")
                .accessibilityIdentifier("side-chat-delete-message")
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }
                    .focused($choice, equals: .cancel)
                    .accessibilityIdentifier("cancel-side-chat-delete")
                Button("Confirm", role: .destructive) { finish(true) }
                    .focused($choice, equals: .confirm)
                    .accessibilityIdentifier("confirm-side-chat-delete")
            }
        }
        .onExitCommand { finish(false) }
        .onKeyPress(.return) {
            finish(choice == .confirm)
            return .handled
        }
        .padding(20)
        .frame(width: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 18)
        .task { choice = .cancel }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("side-chat-delete-confirmation")
    }
}
