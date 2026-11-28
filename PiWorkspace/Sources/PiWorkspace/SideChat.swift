import Combine
import Foundation

struct SideChatScope: Hashable {
    let projectID: UUID
    let parentID: UUID
    let id: UUID
}

struct SideChatOpenRequest: Equatable {
    let id = UUID()
    let scope: SideChatScope
}

struct SideChat: Codable, Identifiable {
    let id: UUID
    let cutoff: String?
    let model: ModelSettings
    var title = "Side chat"
    /// The stored default title is English; show it in the interface language.
    var displayTitle: String { title == "Side chat" ? String(localized: "Side chat") : title }
    var draft = ""
    var attachments: [ComposerAttachment]?
    var sourceDraft: String?
    var submissionID: UUID?
    var hasStarted = false

    var prompt: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func command(in text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let command = parts.first?.lowercased(), command == "/side" || command == "/btw" else { return nil }
        return parts.dropFirst().first.map(String.init) ?? ""
    }

    static func context(after cutoff: String?, in parent: [ChatMessage]) -> String {
        let framing = "You are in a side chat beside the main thread. Answer the user's question without continuing the main thread's task."
        let start = cutoff.flatMap { id in parent.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        let header = framing + "\n\nMain thread activity since this side chat's starting point:\n"
        let messages = excerpt(parent.dropFirst(start), byteLimit: 8000 - header.utf8.count)
        return messages.isEmpty ? framing : header + messages
    }

    func reference(to messages: [ChatMessage]) -> ComposerAttachment {
        let text = Self.excerpt(messages[...], byteLimit: ComposerAttachment.maxTextBytes)
        return ComposerAttachment(id: id, name: "Side chat: " + title,
                                  payload: .init(mimeType: "text/plain", data: Data(text.utf8)), sideChatReference: true)
    }

    private static func excerpt(_ messages: ArraySlice<ChatMessage>, byteLimit: Int) -> String {
        var remaining = byteLimit
        var lines: [String] = []
        for message in messages.reversed() where !message.text.isEmpty && message.incompleteReply != .interrupted {
            let prefix = message.role == .user ? "User: " : "Assistant: "
            remaining -= prefix.utf8.count + 2
            guard remaining > 0 else { break }
            let tail = message.text.utf8.suffix(remaining)
            let text = String(decoding: tail.drop(while: { $0 & 0xC0 == 0x80 }), as: UTF8.self)
                .replacingOccurrences(of: "\0", with: "?")
            lines.append(prefix + text)
            remaining -= text.utf8.count
        }
        return lines.reversed().joined(separator: "\n\n")
    }
}

@MainActor
final class SideChatSession: ObservableObject {
    let scope: SideChatScope
    @Published var phase: WorkspaceModel.Phase = .closed
    @Published var messages: [ChatMessage] = []
    @Published var partial = ""
    @Published var error: String?
    @Published var approval: ToolApproval?
    @Published var question: WorkspaceModel.PendingAgentQuestion?
    var process: (any PiConnection)?
    var turnID: UUID?
    var supportsImages = false
    var sendWhenReady = false
    var releaseWhenIdle = false
    var discardWhenIdle = false
    var emptySlash: String?

    init(scope: SideChatScope) {
        self.scope = scope
    }

    func disconnect() {
        process?.close()
        process = nil
        turnID = nil
        approval = nil
        question = nil
        partial = ""
        phase = .closed
    }
}
