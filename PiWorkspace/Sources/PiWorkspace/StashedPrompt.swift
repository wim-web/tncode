import Foundation

struct StashedPrompt: Codable, Identifiable {
    static let maxCount = 20
    // Match the original composer's JavaScript trim, including BOM and excluding NEL.
    private static let whitespace = CharacterSet(charactersIn: "\t\n\u{000B}\u{000C}\r \u{00A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
        .union(CharacterSet(charactersIn: "\u{2000}"..."\u{200A}"))

    let id: UUID
    let createdAt: Date
    let prompt: String
    let attachments: [ComposerAttachment]

    init(prompt: String, attachments: [ComposerAttachment]) {
        self.id = UUID()
        self.createdAt = Date()
        self.prompt = prompt
        self.attachments = attachments
    }

    static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: whitespace) }

    func appending(to text: String) -> String {
        guard !prompt.isEmpty else { return text }
        let scalars = text.unicodeScalars
        guard let last = scalars.lastIndex(where: { !Self.whitespace.contains($0) }) else { return prompt }
        return String(scalars[...last]) + "\n\n" + prompt
    }

    var snippet: String {
        let text = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !text.isEmpty { return text.count > 90 ? String(text.prefix(90)) + "…" : text }
        if let item = attachments.first, attachments.count == 1 { return item.name }
        return "\(attachments.count) attachments"
    }
}
