import AppKit
import SwiftUI

struct WorkspaceMarkdownView: NSViewRepresentable {
    let markdown: AttributedString
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.importsGraphics = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Rendered Markdown")
        view.setAccessibilityIdentifier("files-rendered-markdown")
        view.textStorage?.setAttributedString(renderText())
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.openLink = openLink
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openLink: ((URL) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { openLink?(url) }
            return true
        }
    }

    private func renderText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        var blockID: Int?
        var firstRun = true
        var endsInNewline = false
        var paragraph = NSMutableParagraphStyle()
        var baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var baseColor = NSColor.labelColor
        var listItems = Set<Int>()
        var table: (id: Int, view: NSTextTable)?

        for run in markdown.runs {
            var content = String(markdown[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let block = components.first
            if firstRun || blockID != block?.identity {
                if !firstRun && !endsInNewline {
                    result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
                }
                firstRun = false
                blockID = block?.identity

                paragraph = NSMutableParagraphStyle()
                paragraph.paragraphSpacing = 7
                baseFont = .systemFont(ofSize: NSFont.systemFontSize)
                baseColor = .labelColor
                var indent: CGFloat = 0
                for component in components.reversed() {
                    switch component.kind {
                    case .header(let level):
                        baseFont = .systemFont(ofSize: max(14, 28 - CGFloat(level) * 2.5), weight: .bold)
                        paragraph.paragraphSpacingBefore = 6
                    case .blockQuote:
                        indent += 14
                        baseColor = .secondaryLabelColor
                    case .codeBlock:
                        baseFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
                        indent += 8
                    case .unorderedList, .orderedList:
                        indent += 16
                    case .thematicBreak:
                        baseColor = .separatorColor
                    default:
                        break
                    }
                }
                paragraph.firstLineHeadIndent = indent
                paragraph.headIndent = indent

                if let item = components.firstIndex(where: {
                    if case .listItem = $0.kind { return true }
                    return false
                }),
                   case .listItem(let ordinal) = components[item].kind {
                    paragraph.headIndent += 18
                    if listItems.insert(components[item].identity).inserted {
                        let marker: String
                        switch content.prefix(4) {
                        case "[x] ", "[X] ":
                            marker = "☑"
                            content.removeFirst(4)
                        case "[ ] ":
                            marker = "☐"
                            content.removeFirst(4)
                        default:
                            marker = components.dropFirst(item + 1).first?.kind == .orderedList ? "\(ordinal)." : "•"
                        }
                        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                        content = marker + "\t" + content
                    } else {
                        paragraph.firstLineHeadIndent = paragraph.headIndent
                    }
                }

                if components.count >= 3,
                   case .tableCell(let column) = components[0].kind,
                   case .table(let columns) = components[2].kind, columns.indices.contains(column) {
                    if table?.id != components[2].identity {
                        let view = NSTextTable()
                        view.numberOfColumns = columns.count
                        view.collapsesBorders = true
                        table = (components[2].identity, view)
                    }
                    let row: Int
                    switch components[1].kind {
                    case .tableRow(let index): row = index
                    default:
                        row = 0
                        baseFont = .boldSystemFont(ofSize: NSFont.systemFontSize)
                    }
                    if let table {
                        let cell = NSTextTableBlock(table: table.view, startingRow: row, rowSpan: 1,
                                                    startingColumn: column, columnSpan: 1)
                        cell.setWidth(5, type: .absoluteValueType, for: .padding)
                        cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                        cell.setBorderColor(.separatorColor)
                        if row == 0 { cell.backgroundColor = .quaternaryLabelColor }
                        paragraph.textBlocks = [cell]
                        paragraph.paragraphSpacing = 0
                        switch columns[column].alignment {
                        case .left: paragraph.alignment = .left
                        case .center: paragraph.alignment = .center
                        case .right: paragraph.alignment = .right
                        @unknown default: break
                        }
                    }
                }
            }

            let inline = run.inlinePresentationIntent ?? []
            var font = inline.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular) : baseFont
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: baseColor, .paragraphStyle: paragraph
            ]
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if inline.contains(.code) { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
            if let link = run.link, run.imageURL == nil {
                switch link.scheme?.lowercased() {
                case nil, "http", "https", "mailto": attributes[.link] = link
                default: break
                }
            }
            endsInNewline = content.last?.isNewline == true
            result.append(NSAttributedString(string: content, attributes: attributes))
        }
        return result
    }
}
