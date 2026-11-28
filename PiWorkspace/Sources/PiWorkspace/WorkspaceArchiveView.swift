import SwiftUI

struct WorkspaceArchiveView: View {
    let file: WorkspaceArchiveFile
    let retry: () -> Void

    private typealias Folder = [Data]

    private enum Destination: Hashable, Sendable {
        case folder(Folder)
        case entry(Int, in: Folder)
    }

    private struct Row: Identifiable, Sendable {
        let id: Int
        let name: Data
        let destination: Destination
        var size: Int
        var modified: Date?

        var isFolder: Bool {
            if case .folder = destination { return true }
            return false
        }
    }

    private enum Content: Sendable {
        case folder([Row])
        case text(String, clipped: Bool)
        case image(WorkspaceImageFile)
    }

    @State private var destination = Destination.folder([])
    @State private var loaded: (Destination, Result<Content, Error>)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if let loaded, loaded.0 == destination {
                switch loaded.1 {
                case .success(.folder(let rows)):
                    listing(rows)
                case .success(.text(let text, let clipped)):
                    if clipped {
                        notice("Preview limited to the first 1 MiB.", id: "files-archive-text-limit")
                    }
                    FileTextView(text: text, editable: false, wraps: true, identifier: "files-archive-text")
                case .success(.image(let image)):
                    WorkspaceImageView(file: image, name: title)
                        .id(image.id)
                case .failure(let error):
                    notice(error.localizedDescription, id: "files-archive-error")
                    let failure = error as? WorkspaceArchiveError
                    if failure != .unsupportedEntry && failure != .entryTooLarge {
                        Button("Retry", action: retry)
                            .padding(.horizontal, 8)
                            .accessibilityIdentifier("files-preview-retry")
                    }
                }
            } else {
                ProgressView().controlSize(.small).padding(8)
            }
        }
        .task(id: destination) { await load(destination) }
    }

    private var toolbar: some View {
        let (back, label): (Destination?, String) = switch destination {
        case .folder(let folder):
            (folder.isEmpty ? nil : .folder(Array(folder.dropLast())), String(localized: "Parent Folder"))
        case .entry(_, let folder):
            (.folder(folder), String(localized: "Back to Archive"))
        }
        return HStack(spacing: 6) {
            fileButton(label, "chevron.left", id: "files-archive-back") {
                if let back { destination = back }
            }
            .disabled(back == nil)
            VStack(alignment: .leading) {
                Text(verbatim: title)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("files-archive-path")
                if case .entry(let index, _) = destination {
                    let entry = file.entries[index]
                    Text("\(sizeLabel(entry.size)) · \(dateLabel(entry.modified))")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("files-archive-entry-metadata")
                }
            }
            Spacer(minLength: 0)
            Text(verbatim: "\(file.entries.count.formatted()) "
                 + (file.entries.count == 1 ? String(localized: "entry") : String(localized: "entries"))
                 + " · \(sizeLabel(Int(file.size)))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("files-archive-summary")
        }
        .font(.caption)
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-archive-preview")
    }

    private var title: String {
        switch destination {
        case .folder(let folder):
            folder.isEmpty ? String(localized: "Archive contents") : folder.map(archiveString).joined(separator: "/") + "/"
        case .entry(let index, _):
            file.entries[index].path
        }
    }

    @ViewBuilder
    private func listing(_ rows: [Row]) -> some View {
        if rows.isEmpty {
            let inArchive = destination == .folder([])
            notice(inArchive ? "This archive is empty." : "This folder is empty.", id: "files-archive-empty")
        } else {
            HStack {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Size").frame(width: 82, alignment: .trailing)
                Text("Modified").frame(width: 86, alignment: .trailing)
            }
            .foregroundStyle(.secondary)
            .padding(8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        let name = archiveString(row.name)
                        Button {
                            destination = row.destination
                        } label: {
                            HStack {
                                Image(systemName: row.isFolder ? "folder" : "doc")
                                Text(verbatim: name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(sizeLabel(row.size)).frame(width: 82, alignment: .trailing)
                                    .monospacedDigit()
                                Text(dateLabel(row.modified)).frame(width: 86, alignment: .trailing)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                        .accessibilityLabel(
                            "\(name), \(row.isFolder ? String(localized: "folder, ") : "")\(sizeLabel(row.size)), \(dateLabel(row.modified))")
                        .accessibilityIdentifier("files-archive-row-\(row.id)")
                        Divider()
                    }
                }
            }
            .accessibilityIdentifier("files-archive-entries")
            .id(destination)
        }
    }

    private func load(_ requested: Destination) async {
        let file = file
        let result: Result<Content, Error>
        do {
            result = .success(try await loadWorkspaceFiles {
                try file.validate()
                switch requested {
                case .folder(let folder): return .folder(Self.rows(file.entries, in: folder))
                case .entry(let index, _): return try Self.preview(file.entries[index])
                }
            })
        } catch {
            result = .failure(error)
        }
        guard !Task.isCancelled, destination == requested else { return }
        loaded = (requested, result)
    }

    private nonisolated static func rows(_ entries: [WorkspaceArchive.Entry], in folder: Folder) -> [Row] {
        var rows: [Row] = []
        var directories: [Data: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let parts = entry.path.utf8.split(separator: 47).map { Data($0) }
            guard parts.count > folder.count, parts.starts(with: folder) else { continue }
            let name = parts[folder.count]
            let next: Destination
            let modified: Date?
            if parts.count > folder.count + 1 {
                next = .folder(folder + [name])
                modified = nil
            } else if case .directory = entry.kind {
                next = .folder(folder + [name])
                modified = entry.modified
            } else {
                next = .entry(index, in: folder)
                modified = entry.modified
            }
            if case .folder = next {
                if let existing = directories[name] {
                    rows[existing].size += entry.size
                    if let modified { rows[existing].modified = modified }
                    continue
                }
                directories[name] = rows.count
            }
            rows.append(Row(id: index, name: name, destination: next, size: entry.size, modified: modified))
        }
        return rows.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            let order = archiveString($0.name).localizedStandardCompare(archiveString($1.name))
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private nonisolated static func preview(_ entry: WorkspaceArchive.Entry) throws -> Content {
        guard case .file(let bytes) = entry.kind else { throw WorkspaceArchiveError.unsupportedEntry }
        guard let bytes else { throw WorkspaceArchiveError.entryTooLarge }
        let name = entry.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        if let format = WorkspaceMediaFormat(fileName: name), format != .pdf,
           case .image(let image) = try format.preview(bytes) {
            return .image(image)
        }

        let lowerName = name.lowercased()
        let textExtensions: Set<String> = [
            "txt", "log", "json", "jsonc", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "conf", "config", "env",
            "csv", "tsv", "xml", "css", "scss", "sass", "less", "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts",
            "py", "pyi", "rb", "go", "rs", "swift", "kt", "kts", "java", "c", "h", "cc", "cpp", "hpp", "cs", "php",
            "sh", "bash", "zsh", "fish", "sql", "graphql", "gql", "vue", "svelte", "r", "lua", "ex", "exs", "erl",
            "hs", "clj", "dart", "diff", "patch", "lock", "properties", "gradle", "html", "htm", "md", "markdown",
            "mdown", "mkd", "mdx", "mmd", "mermaid"
        ]
        let textName = lowerName.range(of: #"^(dockerfile|makefile|gemfile|rakefile|license|readme|\.gitignore|\.gitattributes|\.editorconfig|\.env)(\.|$)"#,
                                       options: .regularExpression) != nil
        let suffix = (lowerName as NSString).pathExtension
        guard textName || textExtensions.contains(suffix) else { throw WorkspaceArchiveError.unsupportedEntry }

        let clipped = bytes.count > WorkspaceFiles.textLimit
        let prefix = bytes.prefix(WorkspaceFiles.textLimit)
        guard !prefix.contains(0) else { throw WorkspaceArchiveError.unsupportedEntry }
        for trailing in 0...(clipped ? 3 : 0) {
            if let text = String(bytes: prefix.dropLast(trailing), encoding: .utf8) {
                return .text(text, clipped: clipped)
            }
        }
        throw WorkspaceArchiveError.unsupportedEntry
    }

    private func sizeLabel(_ size: Int) -> String { "\(size.formatted()) B" }
    private func dateLabel(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .omitted) ?? "—" }

    private func notice(_ text: String, id: String) -> some View {
        Text(localized: text).font(.callout).foregroundStyle(.secondary).padding(8).accessibilityIdentifier(id)
    }
}
