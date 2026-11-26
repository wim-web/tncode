import Darwin
import Foundation

struct WorkspaceFilesLocation: Hashable, Sendable {
    let threadID: UUID
    let directory: String

    init?(thread: Conversation, project: Project) {
        guard !thread.workingLocation.needsWorktree else { return nil }
        threadID = thread.id
        directory = thread.workingLocation.directory(in: project)
    }
}

struct WorkspaceFileTarget: Hashable, Sendable {
    let location: WorkspaceFilesLocation
    let path: String
}

enum WorkspaceFileError: LocalizedError, Equatable {
    case missing
    case unsupportedPath
    case readOnly
    case changed
    case inactive
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .missing: "The file or folder is missing."
        case .unsupportedPath: "This path cannot be opened from the workspace."
        case .readOnly: "This file is read-only."
        case .changed: "The file changed on disk. Copy your edits or discard them to reload the file."
        case .inactive: "Return to the file’s thread and checkout before saving."
        case .tooLarge: "This edit exceeds the 1 MiB save limit."
        }
    }
}

struct WorkspaceFileEntry: Identifiable, Sendable {
    let path: String
    let kind: Kind

    enum Kind: Sendable { case folder, file, link }

    var id: String { path }
    var name: String { String(path.split(separator: "/").last ?? "") }
    var parent: String { path.lastIndex(of: "/").map { String(path[..<$0]) } ?? "" }
}

struct WorkspaceFileTree: Sendable {
    let entries: [WorkspaceFileEntry]
    let truncated: Bool

    func matching(_ query: String) -> [WorkspaceFileEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? [] : entries.filter { $0.path.localizedStandardContains(term) }
    }
}

struct WorkspaceFileText: Sendable {
    let text: String
    let writable: Bool
    fileprivate let revision: FileRevision
    fileprivate let bytes: Data

    func matches(_ other: Self) -> Bool { revision == other.revision && bytes == other.bytes }
}

enum WorkspaceFilePreview: Sendable {
    case text(WorkspaceFileText)
    case largeText(prefix: String, size: Int64)
    case binary(prefix: Data, size: Int64)
}

struct WorkspaceFileDraft {
    let target: WorkspaceFileTarget
    let original: WorkspaceFileText
    var text: String

    var isEdited: Bool { !text.utf8.elementsEqual(original.text.utf8) }

    func save(whileActive active: WorkspaceFileTarget?) throws -> WorkspaceFileText {
        guard target == active else { throw WorkspaceFileError.inactive }
        guard isEdited else { return original }
        return try WorkspaceFiles(directory: target.location.directory).save(self)
    }
}

struct WorkspaceFiles: Sendable {
    static let textLimit = 1024 * 1024
    private static let entryLimit = 20_000
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    private let root: URL

    init(directory: String) {
        // Foundation keeps these macOS aliases in otherwise resolved workspace paths.
        let systemAlias = ["/etc", "/tmp", "/var"].contains { directory == $0 || directory.hasPrefix($0 + "/") }
        root = URL(fileURLWithPath: systemAlias ? "/private" + directory : directory, isDirectory: true)
    }

    func tree() throws -> WorkspaceFileTree {
        let directory = try openRoot()
        defer { close(directory) }
        var entries: [WorkspaceFileEntry] = []
        var truncated = false
        try scan(directory, parent: "", depth: 0, entries: &entries, truncated: &truncated)
        return WorkspaceFileTree(entries: entries, truncated: truncated)
    }

    func preview(_ path: String) throws -> WorkspaceFilePreview {
        try withParent(of: path) { folder, name in
            let file = try openFile(in: folder, name: name)
            defer { close(file) }
            let metadata = try status(file)
            let data = try read(file, limit: Self.textLimit + 1)
            guard FileRevision(metadata) == FileRevision(try status(file)) else { throw WorkspaceFileError.changed }
            let large = metadata.st_size > Self.textLimit || data.count > Self.textLimit
            let prefix = large ? Data(data.prefix(Self.textLimit)) : data
            if let text = decode(prefix, truncated: large) {
                return large ? .largeText(prefix: text, size: metadata.st_size) : .text(
                    WorkspaceFileText(text: text, writable: canWrite(in: folder, name: name),
                                      revision: FileRevision(metadata), bytes: data)
                )
            }
            return .binary(prefix: Data(data.prefix(4096)), size: metadata.st_size)
        }
    }

    fileprivate func save(_ draft: WorkspaceFileDraft) throws -> WorkspaceFileText {
        var bytes = Data()
        if draft.original.bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        bytes.append(contentsOf: draft.text.utf8)
        guard bytes.count <= Self.textLimit else { throw WorkspaceFileError.tooLarge }

        return try withParent(of: draft.target.path) { folder, name in
            let file = try openFile(in: folder, name: name)
            defer { close(file) }
            try verify(file, matches: draft.original)
            guard canWrite(in: folder, name: name) else { throw WorkspaceFileError.readOnly }

            let temporaryName = ".pi-workspace-save-\(UUID().uuidString)"
            let temporary = openat(folder, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard temporary >= 0 else { throw fileError() }
            defer {
                close(temporary)
                unlinkat(folder, temporaryName, 0)
            }

            guard fcopyfile(file, temporary, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw fileError()
            }
            try write(temporary, bytes: bytes)
            guard fsync(temporary) == 0 else { throw fileError() }
            let updated = FileRevision(try status(temporary))

            // Reopen the path before replacement to catch directory moves as well as file edits.
            try withParent(of: draft.target.path) { currentFolder, currentName in
                guard FileRevision(try status(folder)).sameFile(as: FileRevision(try status(currentFolder))) else {
                    throw WorkspaceFileError.changed
                }
                let current = try openFile(in: currentFolder, name: currentName)
                defer { close(current) }
                try verify(current, matches: draft.original)
                guard canWrite(in: currentFolder, name: currentName) else { throw WorkspaceFileError.readOnly }
                guard renameat(folder, temporaryName, currentFolder, currentName) == 0 else { throw fileError() }
            }
            return WorkspaceFileText(text: draft.text, writable: true, revision: updated, bytes: bytes)
        }
    }

    func fileURL(_ path: String) throws -> URL {
        try withParent(of: path) { folder, name in
            let file = try openFile(in: folder, name: name)
            close(file)
            return root.appendingPathComponent(path)
        }
    }

    private func scan(_ folder: Int32, parent: String, depth: Int, entries: inout [WorkspaceFileEntry],
                      truncated: inout Bool) throws {
        guard depth < 64, entries.count < Self.entryLimit else {
            truncated = true
            return
        }
        let copy = dup(folder)
        guard copy >= 0 else { throw fileError() }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw fileError()
        }
        defer { closedir(stream) }

        var children: [WorkspaceFileEntry] = []
        while entries.count + children.count < Self.entryLimit {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw fileError() }
                break
            }
            let name = withUnsafeBytes(of: &item.pointee.d_name) {
                String(bytes: $0.prefix(Int(item.pointee.d_namlen)), encoding: .utf8)
            }
            guard let name, Self.allowsComponent(name) else { continue }
            var metadata = stat()
            guard fstatat(folder, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind: WorkspaceFileEntry.Kind
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR: kind = .folder
            case S_IFREG: kind = .file
            case S_IFLNK: kind = .link
            default: continue
            }
            children.append(.init(path: parent.isEmpty ? name : parent + "/" + name, kind: kind))
        }
        for entry in children.sorted(by: Self.treeOrder) {
            guard entries.count < Self.entryLimit else {
                truncated = true
                return
            }
            entries.append(entry)
            if entry.kind == .folder {
                let child = openat(folder, entry.name, Self.directoryFlags)
                guard child >= 0 else { continue }
                defer { close(child) }
                try scan(child, parent: entry.path, depth: depth + 1, entries: &entries, truncated: &truncated)
            }
        }
        if children.count == Self.entryLimit { truncated = true }
    }

    private static func treeOrder(_ lhs: WorkspaceFileEntry, _ rhs: WorkspaceFileEntry) -> Bool {
        if (lhs.kind == .folder) != (rhs.kind == .folder) { return lhs.kind == .folder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func allowsComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." &&
            component.lowercased() != ".git" && !component.utf8.contains(0)
    }

    private func openRoot() throws -> Int32 {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else { throw fileError() }
        return directory
    }

    private func withParent<T>(of path: String, _ use: (Int32, String) throws -> T) throws -> T {
        let parts = path.components(separatedBy: "/")
        guard let name = parts.last, parts.allSatisfy(Self.allowsComponent) else {
            throw WorkspaceFileError.unsupportedPath
        }
        var directory = try openRoot()
        defer { close(directory) }
        for part in parts.dropLast() {
            let child = openat(directory, part, Self.directoryFlags)
            guard child >= 0 else { throw fileError() }
            close(directory)
            directory = child
        }
        return try use(directory, name)
    }

    private func openFile(in folder: Int32, name: String) throws -> Int32 {
        let file = openat(folder, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw fileError() }
        do {
            guard try status(file).st_mode & S_IFMT == S_IFREG else { throw WorkspaceFileError.unsupportedPath }
            return file
        } catch {
            close(file)
            throw error
        }
    }

    private func verify(_ file: Int32, matches original: WorkspaceFileText) throws {
        guard FileRevision(try status(file)) == original.revision,
              try read(file, limit: Self.textLimit + 1) == original.bytes,
              FileRevision(try status(file)) == original.revision else { throw WorkspaceFileError.changed }
    }

    private func canWrite(in folder: Int32, name: String) -> Bool {
        faccessat(folder, name, W_OK, AT_EACCESS | AT_SYMLINK_NOFOLLOW) == 0 &&
            faccessat(folder, ".", W_OK | X_OK, AT_EACCESS) == 0
    }

    private func status(_ descriptor: Int32) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw fileError() }
        return metadata
    }

    private func read(_ descriptor: Int32, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw fileError() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func write(_ descriptor: Int32, bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, start + written, buffer.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw fileError() }
                written += count
            }
        }
    }

    private func decode(_ data: Data, truncated: Bool) -> String? {
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard !bytes.contains(where: { $0 < 32 && !(9...13).contains($0) }) else { return nil }
        for trailing in 0...(truncated ? 3 : 0) {
            if let text = String(bytes: bytes.dropLast(trailing), encoding: .utf8) { return text }
        }
        return nil
    }

    private func fileError() -> any Error {
        switch errno {
        case ENOENT: WorkspaceFileError.missing
        case ELOOP, ENOTDIR: WorkspaceFileError.unsupportedPath
        case EROFS: WorkspaceFileError.readOnly
        default: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private struct FileRevision: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        size = metadata.st_size
        modifiedSeconds = metadata.st_mtimespec.tv_sec
        modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
    }

    func sameFile(as other: Self) -> Bool { device == other.device && inode == other.inode }
}
