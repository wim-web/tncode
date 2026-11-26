import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

struct ComposerAttachment: Codable, Equatable, Identifiable {
    struct Payload: Codable, Equatable {
        let mimeType: String
        let data: Data

        var isImage: Bool { mimeType.hasPrefix("image/") }
    }

    static let maxCount = 10
    static let maxBytes = 4 * 1024 * 1024
    static let maxTextBytes = 64 * 1024
    static let imageTypes: [UTType: String] = [.png: "image/png", .jpeg: "image/jpeg"]

    let id: UUID
    let name: String
    var payload: Payload?

    init(id: UUID = UUID(), name: String, payload: Payload?) {
        self.id = id
        self.name = name
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case id, name, payload }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        if let saved = try? fields.decode(Payload.self, forKey: .payload),
           (try? Self.payload(for: saved.data))?.mimeType == saved.mimeType {
            payload = saved
        }
    }

    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw WorkspaceError("Choose a local file.") }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceError("Could not read \(url.lastPathComponent).") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw WorkspaceError("Choose a regular local file.")
        }
        guard info.st_size <= Self.maxBytes else { throw WorkspaceError("Files must be 4 MB or smaller.") }
        let data = try file.read(upToCount: Self.maxBytes + 1) ?? Data()
        guard data.count <= Self.maxBytes else { throw WorkspaceError("Files must be 4 MB or smaller.") }
        return data
    }

    static func payload(for data: Data) throws -> Payload {
        guard !data.isEmpty else { throw WorkspaceError("The file is empty.") }
        guard data.count <= maxBytes else { throw WorkspaceError("Files must be 4 MB or smaller.") }
        if let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) {
            guard let mimeType = imageTypes[UTType(type as String) ?? .image] else {
                throw WorkspaceError("Choose a PNG or JPEG image.")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  let width = properties?[kCGImagePropertyPixelWidth] as? Int, (1...8192).contains(width),
                  let height = properties?[kCGImagePropertyPixelHeight] as? Int, (1...8192).contains(height),
                  width * height <= 24_000_000 else {
                throw WorkspaceError("The image is damaged or too large to preview.")
            }
            return Payload(mimeType: mimeType, data: data)
        }
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw WorkspaceError("Choose a PNG, JPEG, or UTF-8 text file.")
        }
        guard data.count <= maxTextBytes else { throw WorkspaceError("Text files must be 64 KB or smaller.") }
        return Payload(mimeType: "text/plain", data: data)
    }

    func preview(maximumSize: Int) -> NSImage? {
        guard let payload, payload.isImage,
              let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumSize
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

struct SentAttachment: Decodable, Identifiable {
    let id: UUID
    let name: String
    let mimeType: String
}
