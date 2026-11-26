import AppKit
import SwiftUI

enum WorkspaceFileRenderFormat: Equatable, Sendable {
    case markdown
    case table(WorkspaceDelimitedTable.Delimiter)

    init?(path: String) {
        guard let dot = path.lastIndex(of: ".") else { return nil }
        switch path[path.index(after: dot)...].lowercased() {
        case "md", "mdx", "markdown", "mdown", "mkd": self = .markdown
        case "csv": self = .table(.comma)
        case "tsv": self = .table(.tab)
        default: return nil
        }
    }

    func toggleLabel(rendered: Bool) -> String {
        switch self {
        case .markdown: rendered ? "Show markdown source" : "Show rendered markdown"
        case .table: rendered ? "Show source" : "Show table"
        }
    }
}

struct WorkspaceRenderedFileView: View {
    let format: WorkspaceFileRenderFormat
    let text: String
    let openLink: (URL) -> Void

    private struct Input: Equatable, Sendable {
        let format: WorkspaceFileRenderFormat
        let text: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.format == rhs.format && lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }

        func render() throws -> Document {
            guard text.utf8.count <= WorkspaceFiles.textLimit else { throw WorkspaceFileError.tooLarge }
            switch format {
            case .markdown:
                return .markdown(try AttributedString(markdown: text, options: .init(interpretedSyntax: .full)))
            case .table(let delimiter):
                return .table(try WorkspaceDelimitedTable(text: text, delimiter: delimiter))
            }
        }
    }

    private enum Document: Sendable {
        case markdown(AttributedString)
        case table(WorkspaceDelimitedTable)
    }

    private struct Rendered {
        let id = UUID()
        let input: Input
        let result: Result<Document, Error>
    }

    @State private var rendered: Rendered?

    var body: some View {
        let input = Input(format: format, text: text)
        Group {
            if let rendered, rendered.input == input {
                switch rendered.result {
                case .success(.markdown(let markdown)):
                    WorkspaceMarkdownView(markdown: markdown, openLink: openLink)
                        .id(rendered.id)
                case .success(.table(let table)):
                    if table.rows.isEmpty {
                        notice("This file is empty.", id: "files-rendered-table-empty")
                    } else {
                        if table.clippedColumns {
                            notice("Showing the first \(table.columnCount) columns.", id: "files-rendered-table-limit")
                        }
                        WorkspaceDelimitedTableView(table: table)
                            .id(rendered.id)
                    }
                case .failure(let error):
                    notice(error.localizedDescription + " Switch to source to view the file.",
                           id: "files-rendered-preview-error")
                }
            } else {
                ProgressView().controlSize(.small).padding(12)
            }
        }
        .task(id: input) {
            let result: Result<Document, Error>
            do {
                result = .success(try await loadWorkspaceFiles { try input.render() })
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            rendered = Rendered(input: input, result: result)
        }
    }

    private func notice(_ message: String, id: String) -> some View {
        Text(message).font(.callout).foregroundStyle(.secondary).padding(8)
            .accessibilityIdentifier(id)
    }
}

private struct WorkspaceDelimitedTableView: NSViewRepresentable {
    let table: WorkspaceDelimitedTable

    func makeCoordinator() -> Coordinator { Coordinator(table: table) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTableView()
        view.setAccessibilityLabel("Delimited Table")
        view.setAccessibilityIdentifier("files-rendered-table")
        view.style = .plain
        view.columnAutoresizingStyle = .noColumnAutoresizing
        view.allowsColumnReordering = false
        view.usesAlternatingRowBackgroundColors = true
        view.gridStyleMask = [.solidVerticalGridLineMask]
        for index in 0..<table.columnCount {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = table.rows[0].indices.contains(index) ? table.rows[0][index] : "Column \(index + 1)"
            column.width = DelimitedCell.columnWidth
            column.resizingMask = []
            view.addTableColumn(column)
        }
        view.dataSource = context.coordinator
        view.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let table: WorkspaceDelimitedTable

        init(table: WorkspaceDelimitedTable) { self.table = table }

        func numberOfRows(in tableView: NSTableView) -> Int { table.rows.count - 1 }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            var height = tableView.rowHeight
            for value in table.rows[row + 1] {
                if value.utf8.count <= 8, value.utf8.allSatisfy({ (32...126).contains($0) }) { continue }
                let bounds = (value as NSString).boundingRect(
                    with: NSSize(width: DelimitedCell.textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: DelimitedCell.font]
                )
                height = max(height, ceil(bounds.height) + 2 * DelimitedCell.verticalInset)
            }
            return height
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, let index = Int(column.identifier.rawValue) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("DelimitedCell")
            let label = (tableView.makeView(withIdentifier: identifier, owner: nil) as? DelimitedCell)
                ?? DelimitedCell()
            let values = table.rows[row + 1]
            label.field.stringValue = values.indices.contains(index) ? values[index] : ""
            label.field.setAccessibilityIdentifier("files-table-cell-\(row + 1)-\(index + 1)")
            return label
        }
    }
}

private final class DelimitedCell: NSTableCellView {
    static let columnWidth: CGFloat = 152
    static let verticalInset: CGFloat = 4
    private static let horizontalInset: CGFloat = 8
    static var textWidth: CGFloat { columnWidth - 2 * horizontalInset }
    static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let field = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("DelimitedCell")
        field.font = Self.font
        field.preferredMaxLayoutWidth = Self.textWidth
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            field.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
