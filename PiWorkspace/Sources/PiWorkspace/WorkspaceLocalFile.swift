import Foundation

enum WorkspaceLocalFile {
    static func isLocal(_ url: URL) -> Bool {
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        return url.isFileURL && (host.isEmpty || host == "localhost")
    }

    static func read(_ url: URL, limit: Int, sizeError: () -> Error) throws -> Data {
        guard isLocal(url) else { throw WorkspaceError("Choose a local file.") }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceError("Could not read \(url.lastPathComponent).") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw WorkspaceError("Choose a regular local file.")
        }
        guard info.st_size <= limit else { throw sizeError() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw sizeError() }
        return data
    }
}
