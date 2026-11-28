import AppKit
import SwiftUI

struct WorkspaceSQLiteView: View {
    let file: WorkspaceSQLiteFile
    let retry: () -> Void

    private struct Selection: Hashable {
        var table = 0
        var page = 0
    }

    private struct Load {
        let selection: Selection
        let result: Result<WorkspaceSQLite.Page, Error>
    }

    @State private var selection = Selection()
    @State private var load: Load?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Read-only SQLite preview")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .accessibilityIdentifier("files-sqlite-preview")
            if file.tables.isEmpty {
                notice("No tables to preview.", id: "files-sqlite-no-tables")
            } else {
                tablePreview
            }
        }
    }

    private var tablePreview: some View {
        let selection = selection
        let table = file.tables[selection.table]
        let pageSize = Int64(WorkspaceSQLite.rowsPerPage)
        let offset = Int64(selection.page) * pageSize
        let result = load?.selection == selection ? load?.result : nil
        let pageIsReady = (try? result?.get()) != nil

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                SQLiteTablePicker(
                    titles: file.tables.map {
                        "\($0.name) (\($0.rowCount.formatted()) "
                            + ($0.rowCount == 1 ? String(localized: "row") : String(localized: "rows")) + ")"
                    },
                    selection: selection.table,
                    select: { self.selection = Selection(table: $0) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    fileButton("Previous Rows", "chevron.left", id: "files-sqlite-previous") {
                        self.selection.page -= 1
                    }
                    .disabled(!pageIsReady || selection.page == 0)
                    Text(table.rowCount == 0 ? "0 rows" :
                        "\((offset + 1).formatted())–\(min(offset + pageSize, table.rowCount).formatted()) of \(table.rowCount.formatted())")
                        .monospacedDigit()
                        .accessibilityIdentifier("files-sqlite-range")
                    fileButton("Next Rows", "chevron.right", id: "files-sqlite-next") {
                        self.selection.page += 1
                    }
                    .disabled(!pageIsReady || offset + pageSize >= table.rowCount)
                }
                Text("Up to 50 columns and 1,024 characters per cell. BLOB contents are omitted.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding([.horizontal, .bottom], 8)
            Divider()
            switch result {
            case .success(let page):
                if page.rows.isEmpty {
                    notice("This table has no rows.", id: "files-sqlite-no-rows")
                }
                WorkspaceReadOnlyTable(columns: page.columns, rows: page.rows, label: "SQLite Rows",
                                       identifier: "files-sqlite-rows", cellIdentifier: "files-sqlite-cell")
                    .id(selection)
            case .failure(let error):
                notice(error.localizedDescription, id: "files-sqlite-error")
                Button("Retry", action: retry)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("files-preview-retry")
            case nil:
                ProgressView().controlSize(.small).padding(8)
                    .accessibilityLabel("Loading rows")
            }
        }
        .task(id: selection) { await read(selection) }
    }

    private func read(_ selection: Selection) async {
        load = nil
        let result: Result<WorkspaceSQLite.Page, Error>
        let file = file
        do {
            result = .success(try await loadWorkspaceFiles { try file.page(table: selection.table, index: selection.page) })
        } catch {
            result = .failure(error)
        }
        guard !Task.isCancelled else { return }
        load = Load(selection: selection, result: result)
    }

    private func notice(_ message: String, id: String) -> some View {
        Text(localized: message).font(.callout).foregroundStyle(.secondary).padding(8)
            .accessibilityIdentifier(id)
    }
}

private struct SQLiteTablePicker: NSViewRepresentable {
    let titles: [String]
    let selection: Int
    let select: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let picker = NSPopUpButton()
        picker.controlSize = .small
        picker.cell?.lineBreakMode = .byTruncatingMiddle
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.setAccessibilityElement(true)
        picker.setAccessibilityRole(.popUpButton)
        picker.setAccessibilityLabel(String(localized: "Table"))
        picker.setAccessibilityIdentifier("files-sqlite-table")
        picker.addItems(withTitles: titles)
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        return picker
    }

    func updateNSView(_ picker: NSPopUpButton, context: Context) {
        context.coordinator.select = select
        picker.selectItem(at: selection)
    }

    final class Coordinator: NSObject {
        var select: ((Int) -> Void)?

        @objc func changed(_ sender: NSPopUpButton) {
            if sender.indexOfSelectedItem >= 0 { select?(sender.indexOfSelectedItem) }
        }
    }
}
