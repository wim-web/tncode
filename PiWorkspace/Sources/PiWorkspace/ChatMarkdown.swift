import SwiftUI

/// Block-level Markdown for assistant replies: paragraphs, headings, lists, fenced code, quotes, rules and tables.
/// Inline syntax inside each block uses Foundation's Markdown parser.
enum ChatMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(ordered: Bool, start: Int, items: [ListItem])
    case code(language: String?, text: String)
    case quote(String)
    case rule
    case table(header: [String], rows: [[String]])

    struct ListItem: Equatable {
        var text: String
        var depth: Int
        var task: Bool?
    }

    static func parse(_ source: String) -> [ChatMarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = Self.fence(trimmed) {
                flushParagraph()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(language: language.isEmpty ? nil : language, text: code.joined(separator: "\n")))
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }
            if Self.isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoted.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, Self.isTableDivider(lines[index + 1]) {
                flushParagraph()
                let header = Self.cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix("|") else { break }
                    rows.append(Self.cells(current))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if let first = Self.listMarker(line) {
                flushParagraph()
                var items: [ListItem] = []
                let baseIndent = first.indent
                while index < lines.count {
                    let current = lines[index]
                    if let marker = Self.listMarker(current), marker.ordered == first.ordered || marker.indent > baseIndent {
                        var text = marker.text
                        var task: Bool?
                        if text.hasPrefix("[ ] ") { task = false; text.removeFirst(4) }
                        else if text.lowercased().hasPrefix("[x] ") { task = true; text.removeFirst(4) }
                        items.append(.init(text: text, depth: max(0, (marker.indent - baseIndent) / 2), task: task))
                        index += 1
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty,
                              current.hasPrefix("  ") || current.hasPrefix("\t"), !items.isEmpty,
                              Self.listMarker(current) == nil {
                        items[items.count - 1].text += "\n" + current.trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(ordered: first.ordered, start: first.number, items: items))
                continue
            }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func fence(_ line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ line: String) -> ChatMarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private struct Marker: Equatable {
        let indent: Int
        let ordered: Bool
        let number: Int
        let text: String
    }

    private static func listMarker(_ line: String) -> Marker? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        if let bullet = body.first, "-*+".contains(bullet), body.dropFirst().first == " " {
            return Marker(indent: indent, ordered: false, number: 1, text: String(body.dropFirst(2)))
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let dot = rest.first, dot == "." || dot == ")", rest.dropFirst().first == " " else { return nil }
        return Marker(indent: indent, ordered: true, number: Int(digits) ?? 1, text: String(rest.dropFirst(2)))
    }
}

struct ChatMarkdownView: View {
    let text: String
    /// Assistant prose is foreground at 90%; user text uses the full foreground.
    var emphasis: Double = 0.9
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.t3Themes) private var t3Themes

    private var palette: T3Palette { T3Palette(colorScheme, t3Themes) }

    var body: some View {
        let blocks = ChatMarkdownBlock.parse(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : Self.gap(blocks[index - 1], block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// CSS block margins collapse to the larger of the neighbours' margins.
    private static func gap(_ previous: ChatMarkdownBlock, _ next: ChatMarkdownBlock) -> CGFloat {
        func top(_ block: ChatMarkdownBlock) -> CGFloat {
            switch block {
            case .heading: 20
            case .rule: 0
            default: 10.4
            }
        }
        func bottom(_ block: ChatMarkdownBlock) -> CGFloat {
            switch block {
            case .heading: 8
            case .rule: 0
            default: 10.4
            }
        }
        return max(bottom(previous), top(next))
    }

    @ViewBuilder
    private func view(for block: ChatMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text)
        case .heading(let level, let text):
            Text(inlineText(text, size: Self.headingSize(level)))
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .lineSpacing(Self.headingSize(level) * 0.1)
                .foregroundStyle(level == 6 ? palette.mutedForeground : palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Group {
                            if let task = item.task {
                                Image(systemName: task ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12))
                            } else if ordered {
                                Text(Self.orderedMarker(start + offset, depth: item.depth)).monospacedDigit()
                            } else {
                                Text(["•", "◦", "▪"][min(item.depth, 2)])
                            }
                        }
                        .font(.system(size: T3Type.body))
                        .foregroundStyle(palette.foreground.opacity(emphasis))
                        .frame(width: 20, alignment: ordered ? .trailing : .center)
                        .padding(.trailing, ordered ? 4 : 2)
                        inline(item.text)
                    }
                    .padding(.leading, CGFloat(item.depth) * 20)
                }
            }
        case .code(let language, let text):
            ChatCodeBlock(language: language, code: text, palette: palette)
        case .quote(let text):
            inline(text)
                .padding(.leading, 12.8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.foreground.opacity(emphasis * 0.35)).frame(width: 2)
                }
        case .rule:
            Rectangle().fill(palette.isDark ? palette.mutedForeground : palette.foreground).frame(height: 1)
        case .table(let header, let rows):
            ChatMarkdownTable(header: header, rows: rows, palette: palette, emphasis: emphasis,
                              render: { inlineText($0) })
        }
    }

    private static func orderedMarker(_ number: Int, depth: Int) -> String {
        switch depth {
        case 0: return "\(number)."
        case 1:
            let scalar = UnicodeScalar(UInt8(96 + min(max(number, 1), 26)))
            return "\(Character(scalar))."
        default:
            let numerals = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"]
            return (number >= 1 && number <= numerals.count ? numerals[number - 1] : "\(number)") + "."
        }
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 20
        case 2: 18
        case 3: 16
        default: T3Type.body
        }
    }

    /// 14/22.75: CSS half-leading appears above the first and below the last line.
    private func inline(_ text: String) -> some View {
        Text(inlineText(text))
            .font(.system(size: T3Type.body))
            .lineSpacing(T3Type.bodyLineSpacing)
            .padding(.vertical, T3Type.bodyLineSpacing / 2)
            .foregroundStyle(palette.foreground.opacity(emphasis))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func inlineText(_ text: String, size: CGFloat = T3Type.body) -> AttributedString {
        Self.inlineAttributed(text, size: size, palette: palette)
    }

    static func inlineAttributed(_ text: String, size: CGFloat, palette: T3Palette) -> AttributedString {
        var attributed = (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in attributed.runs {
            if run.link != nil {
                attributed[run.range].foregroundColor = palette.link
                attributed[run.range].underlineStyle = Text.LineStyle?.none
            }
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                attributed[run.range].font = .system(size: (size * 0.85).rounded(.toNearestOrEven), design: .monospaced)
                attributed[run.range].backgroundColor = palette.inlineCodeBackground
            }
            if intent.contains(.stronglyEmphasized) {
                attributed[run.range].font = .system(size: size, weight: .bold)
            }
        }
        return attributed
    }
}

private struct ChatCodeBlock: View {
    let language: String?
    let code: String
    let palette: T3Palette
    @State private var copied = false
    @State private var wraps = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Text(language ?? "text")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.foreground.opacity(0.72))
                Spacer(minLength: 0)
                Button { wraps.toggle() } label: {
                    Image(systemName: "arrow.turn.down.left").font(.system(size: 11))
                }
                .buttonStyle(T3IconButtonStyle(size: 24, active: wraps))
                .help(wraps ? "Disable word wrap" : "Enable word wrap")
                .accessibilityLabel("Toggle word wrap")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(T3IconButtonStyle(size: 24, foreground: copied ? palette.primary : nil))
                .help("Copy code")
                .accessibilityLabel("Copy code")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.top, 6)
            Group {
                if wraps {
                    codeText.fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        codeText.fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.codeBorder) }
    }

    private var codeText: some View {
        Text(verbatim: code)
            .font(.system(size: T3Type.code, design: .monospaced))
            .lineSpacing(13 * 1.375 - 15.5)
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, 14.4)
            .padding(.top, 6)
            .padding(.bottom, 12.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatMarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let palette: T3Palette
    let emphasis: Double
    let render: (String) -> AttributedString

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        Text(render(cell)).font(.system(size: 14, weight: .semibold))
                            .padding(.leading, index == 0 ? 0 : 12)
                            .padding(.trailing, index == header.count - 1 ? 0 : 12)
                            .padding(.vertical, 8.8)
                    }
                }
                separator
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            Text(render(cell)).font(.system(size: 14))
                                .padding(.leading, index == 0 ? 0 : 12)
                                .padding(.trailing, index == row.count - 1 ? 0 : 12)
                                .padding(.vertical, 7.2)
                        }
                    }
                    separator
                }
            }
            .foregroundStyle(palette.foreground.opacity(emphasis))
        }
    }

    private var separator: some View {
        Rectangle().fill(palette.border.opacity(0.6)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
    }
}
