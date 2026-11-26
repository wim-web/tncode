import Foundation

enum TranscriptSearchTerm: Hashable, Sendable {
    case literal(String)
    case words([String])
    case phrase([String])

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.literal(let a), .literal(let b)): a.utf8.elementsEqual(b.utf8)
        case (.words(let a), .words(let b)), (.phrase(let a), .phrase(let b)): a == b
        default: false
        }
    }

    var text: String {
        switch self {
        case .literal(let text): text
        case .words(let words), .phrase(let words): words.joined(separator: " ")
        }
    }

    static func quotedPhrase(in query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    init?(paletteQuery query: String) {
        let phrase = Self.quotedPhrase(in: query)
        let words = (phrase ?? query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.contains(where: { word in
            word.count >= 3 || (word.count == 2 && word.range(
                of: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#, options: .regularExpression
            ) != nil)
        }) else { return nil }
        self = phrase == nil ? .words(words) : .phrase(words)
    }

    func ranges(in message: String, firstOnly: Bool = false) -> [NSRange] {
        let source = message as NSString
        let full = NSRange(location: 0, length: source.length)
        func occurrences(in haystack: NSString, of needle: String, options: NSString.CompareOptions,
                         locale: Locale? = nil) -> [NSRange] {
            guard !needle.isEmpty else { return [] }
            var ranges: [NSRange] = []
            var start = 0
            while start < haystack.length && !Task.isCancelled {
                let range = haystack.range(of: needle, options: options,
                                           range: NSRange(location: start, length: haystack.length - start), locale: locale)
                guard range.location != NSNotFound, range.length > 0 else { break }
                ranges.append(range)
                if firstOnly { break }
                start = NSMaxRange(range)
            }
            return ranges
        }
        switch self {
        case .literal(let text):
            // T3 thread Find folds case, both sigmas and curly apostrophes while preserving UTF-16 offsets.
            func folded(_ value: String) -> String {
                value.replacingOccurrences(of: "İ", with: "I", options: .literal).lowercased()
                    .replacingOccurrences(of: "ς", with: "σ", options: .literal)
                    .replacingOccurrences(of: "‘", with: "'", options: .literal)
                    .replacingOccurrences(of: "’", with: "'", options: .literal)
            }
            return occurrences(in: folded(message) as NSString, of: folded(text), options: .literal)
        case .phrase(let words):
            let pattern = words.map(NSRegularExpression.escapedPattern).joined(separator: #"\s{1,16}"#)
            guard !words.isEmpty, let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            else { return [] }
            if firstOnly { return regex.firstMatch(in: message, range: full).map { [$0.range] } ?? [] }
            return regex.matches(in: message, range: full).map(\.range)
        case .words(let words):
            let phrase = occurrences(in: source, of: text, options: .caseInsensitive, locale: .current)
            if !phrase.isEmpty { return phrase }
            var anchor = ""
            for word in words {
                guard source.range(of: word, options: .caseInsensitive, range: full,
                                   locale: Locale.current).location != NSNotFound else { return [] }
                if word.count > anchor.count { anchor = word }
            }
            return occurrences(in: source, of: anchor, options: .caseInsensitive, locale: .current)
        }
    }
}

struct TranscriptOccurrence: Hashable, Sendable {
    let messageID: String
    let range: NSRange
}

enum TranscriptText {
    static func rendered(_ text: String, role: ChatMessage.Role) -> AttributedString {
        if role == .assistant, let markdown = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) { return markdown }
        return AttributedString(text)
    }
}
