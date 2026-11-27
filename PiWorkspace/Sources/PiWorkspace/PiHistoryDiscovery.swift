import Darwin
import Foundation

enum PiHistoryDiscovery {
    struct FolderID: Hashable, Sendable {
        private let device: dev_t
        private let inode: ino_t

        init?(_ path: String) {
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    struct Session: Identifiable, Sendable {
        let id: String
        let title: String
        let modified: Date
    }

    struct Candidate: Identifiable, Sendable {
        let id: FolderID
        let folder: URL
        let sessions: [Session]

        var title: String { folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent }

        func checkedFolder() throws -> URL {
            guard let current = try? ProjectFolder.existing(at: folder), FolderID(current.path) == id else {
                throw WorkspaceError("The folder for \(title) changed or is unavailable. Scan again to update the list.")
            }
            return current
        }
    }

    struct Result: Sendable {
        var candidates: [Candidate] = []
        var skipped = 0
        var limited = false
    }

    private struct Header: Decodable {
        let type: String
        let version: Int?
        let id: String
        let cwd: String
    }

    private struct Entry: Decodable {
        struct Message: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }

            let role: String
            let content: String?

            init(from decoder: Decoder) throws {
                let fields = try decoder.container(keyedBy: CodingKeys.self)
                role = try fields.decode(String.self, forKey: .role)
                if let text = try? fields.decode(String.self, forKey: .content) {
                    content = text
                } else {
                    let blocks = try? fields.decode([Block].self, forKey: .content)
                    content = blocks?.filter { $0.type == "text" }.compactMap(\.text).joined(separator: " ")
                }
            }

            private enum CodingKeys: CodingKey { case role, content }
        }

        let type: String
        let name: String?
        let message: Message?
    }

    static var localAgentDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent", isDirectory: true)
    }

    static func scan(agentDirectory: URL) throws -> Result {
        let sessions = agentDirectory.appendingPathComponent("sessions", isDirectory: true)
        let fd = Darwin.open(sessions.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return Result() }
            throw WorkspaceError("Could not read the local Pi sessions folder. \(WorkspaceHistory.accessError(errno).localizedDescription)")
        }

        var result = Result()
        var entriesLeft = 4096
        var bytesLeft = 32 * 1024 * 1024
        var histories: [FolderID: [(URL, Session)]] = [:]
        try visitDirectory(fd, budget: &entriesLeft) { root, name, kind, budget in
            guard kind == DT_DIR || kind == DT_UNKNOWN else { return }
            let bucket = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard bucket >= 0 else {
                if errno != ENOTDIR { result.skipped += 1 }
                return
            }
            try visitDirectory(bucket, budget: &budget) { directory, name, kind, _ in
                guard name.hasSuffix(".jsonl"), bytesLeft > 0 else { return }
                guard kind == DT_REG || kind == DT_UNKNOWN else {
                    result.skipped += 1
                    return
                }
                let readLimit = min(bytesLeft, 1024 * 1024)
                do {
                    let (folder, session, limited) = try readSession(in: directory, name: name, limit: readLimit,
                                                                     bytesLeft: &bytesLeft)
                    guard let identity = FolderID(folder.path) else { throw WorkspaceError("Missing project folder.") }
                    histories[identity, default: []].append((folder, session))
                    result.limited = result.limited || limited
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result.skipped += 1
                }
            }
        }

        result.limited = result.limited || entriesLeft == 0 || bytesLeft == 0
        result.candidates = histories.compactMap { identity, histories in
            let sorted = histories.sorted {
                if $0.1.modified != $1.1.modified { return $0.1.modified > $1.1.modified }
                return ($0.0.path, $0.1.id, $0.1.title) < ($1.0.path, $1.1.id, $1.1.title)
            }
            guard let folder = sorted.first?.0 else { return nil }
            var seen = Set<String>()
            let sessions = sorted.map(\.1).filter { seen.insert($0.id).inserted }
            return Candidate(id: identity, folder: folder, sessions: sessions)
        }.sorted {
            if $0.sessions[0].modified != $1.sessions[0].modified {
                return $0.sessions[0].modified > $1.sessions[0].modified
            }
            return $0.folder.path < $1.folder.path
        }
        return result
    }

    private static func visitDirectory(_ fd: Int32, budget: inout Int,
                                       _ visit: (Int32, String, Int32, inout Int) throws -> Void) throws {
        guard let directory = fdopendir(fd) else {
            let failure = errno
            close(fd)
            throw WorkspaceHistory.accessError(failure)
        }
        defer { closedir(directory) }
        while budget > 0 {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw WorkspaceHistory.accessError(errno) }
                return
            }
            budget -= 1
            let kind = Int32(entry.pointee.d_type)
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingUTF8: $0) }
            }
            guard let name, !name.hasPrefix(".") else { continue }
            try visit(fd, name, kind, &budget)
        }
    }

    private static func readSession(in directory: Int32, name: String, limit: Int,
                                    bytesLeft: inout Int) throws -> (URL, Session, Bool) {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceHistory.accessError(errno) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw WorkspaceError("Expected a regular Pi session file.")
        }

        let data = try file.read(upToCount: limit) ?? Data()
        bytesLeft -= data.count
        let limited = info.st_size > data.count
        let complete = limited ? data.lastIndex(of: 0x0A).map { data[...$0] } ?? Data() : data
        let lines = complete.split(separator: 0x0A)
        let decoder = JSONDecoder()
        guard let first = lines.first, let header = try? decoder.decode(Header.self, from: first),
              header.type == "session", (1...3).contains(header.version ?? 1), !header.id.isEmpty,
              header.cwd.hasPrefix("/"), !header.cwd.utf8.contains(0) else {
            throw WorkspaceError("Invalid Pi session header.")
        }
        let folder = try ProjectFolder.existing(at: URL(fileURLWithPath: header.cwd, isDirectory: true))
        var sessionName: String?
        var firstMessage: String?
        for line in lines.dropFirst() {
            try Task.checkCancellation()
            guard let entry = try? decoder.decode(Entry.self, from: line) else { continue }
            if entry.type == "session_info" { sessionName = title(entry.name) }
            if firstMessage == nil, entry.type == "message", entry.message?.role == "user" {
                firstMessage = title(entry.message?.content)
            }
        }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) +
                            Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let id = UUID(uuidString: header.id)?.uuidString ?? header.id
        return (folder, Session(id: id, title: sessionName ?? firstMessage ?? "Pi session", modified: modified), limited)
    }

    private static func title(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(whereSeparator: \.isNewline).first else { return nil }
        return String(first.prefix(120))
    }
}
