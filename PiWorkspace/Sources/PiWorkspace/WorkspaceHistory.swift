import Darwin
import Foundation

enum WorkspaceHistory {
    static func open(in rootFD: Int32, projectID: UUID, threadID: UUID) throws -> FileHandle? {
        var directoryFD = dup(rootFD)
        guard directoryFD >= 0 else { throw accessError(errno) }
        for component in WorkspaceStore.historyComponents(project: projectID, conversation: threadID) {
            let child = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(directoryFD)
            guard child >= 0 else {
                if code == ENOENT { return nil }
                throw accessError(code)
            }
            directoryFD = child
        }
        guard let directory = fdopendir(directoryFD) else {
            let code = errno
            close(directoryFD)
            throw accessError(code)
        }
        defer { closedir(directory) }
        var history: String?
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw accessError(errno) }
                break
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name, name.hasSuffix(".jsonl") else { continue }
            guard history == nil else { throw WorkspaceError("This conversation has more than one history file.") }
            history = name
        }
        guard let history else { return nil }
        let fd = openat(directoryFD, history, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw accessError(errno) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw accessError(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw WorkspaceError("Expected a regular conversation history.")
        }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw accessError(errno) }
        return file
    }

    static func readLines(in file: FileHandle, _ visit: (Data) throws -> Void) throws {
        var line = Data()
        while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            var start = chunk.startIndex
            for end in chunk.indices where chunk[end] == 0x0A {
                line.append(chunk[start..<end])
                try Task.checkCancellation()
                try visit(line)
                line.removeAll(keepingCapacity: true)
                start = end + 1
            }
            line.append(chunk[start...])
        }
        if !line.isEmpty { try visit(line) }
    }

    static func accessError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
