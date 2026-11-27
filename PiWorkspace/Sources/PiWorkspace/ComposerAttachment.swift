import AppKit
import CoreTransferable
import Darwin
import ImageIO
import UniformTypeIdentifiers

struct ComposerAttachmentTarget: Hashable {
    let threadID: UUID
    var queueEditID: UUID?
    var draftGeneration: UUID?
}

enum ComposerAttachmentInput: Transferable {
    case file(URL)
    case image(Data, UTType)
    case pastedText(String)

    private static let imageInputTypes: [UTType] = [.png, .jpeg, .tiff]
    static let contentTypes: [UTType] = [.fileURL] + imageInputTypes
    static let pastedTextThreshold = 32 * 1024
    static let inlinePasteUTF16Limit = 120_000

    static func readAttachments(from items: [NSPasteboardItem]) -> [Self] {
        Array(items.lazy.compactMap(Self.init(pasteboardItem:)).prefix(ComposerAttachment.maxCount + 1))
    }

    static func fileURL(from item: NSPasteboardItem) -> URL? {
        guard let string = item.string(forType: .fileURL), let url = URL(string: string),
              WorkspaceLocalFile.isLocal(url) else { return nil }
        return url
    }

    init?(pasteboardItem item: NSPasteboardItem) {
        for type in Self.contentTypes {
            let format = NSPasteboard.PasteboardType(type.identifier)
            guard item.types.contains(format) else { continue }
            if type == .fileURL {
                guard let url = Self.fileURL(from: item) else { return nil }
                self = .file(url)
            } else {
                guard let data = item.data(forType: format) else { return nil }
                self = .image(data, type)
            }
            return
        }
        return nil
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .fileURL) { data in
            guard let url = URL(dataRepresentation: data, relativeTo: nil), WorkspaceLocalFile.isLocal(url) else {
                throw WorkspaceError("Choose a local file.")
            }
            return Self.file(url)
        }
        DataRepresentation(importedContentType: .png) { Self.image($0, .png) }
        DataRepresentation(importedContentType: .jpeg) { Self.image($0, .jpeg) }
        DataRepresentation(importedContentType: .tiff) { Self.image($0, .tiff) }
    }

    func name(among attachments: [ComposerAttachment]) -> String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .image(_, .jpeg): "Pasted Image.jpg"
        case .image: "Pasted Image.png"
        case .pastedText:
            Self.pastedTextName(among: attachments)
        }
    }

    private static func pastedTextName(among attachments: [ComposerAttachment]) -> String {
        let names = Set(attachments.map { $0.name.lowercased() })
        if !names.contains("pasted-text.txt") { return "pasted-text.txt" }
        var sequence = 2
        while names.contains("pasted-text-\(sequence).txt") { sequence += 1 }
        return "pasted-text-\(sequence).txt"
    }

    func keepsUnavailableFile(after error: Error) -> Bool {
        if case .file = self { return !(error is ComposerImageError) }
        return false
    }

    func nameForStorage(_ name: String, payload: ComposerAttachment.Payload?) -> String {
        guard case .file(let url) = self, payload?.mimeType == "image/png",
              let type = UTType(filenameExtension: url.pathExtension), type == .tiff else { return name }
        return (name as NSString).deletingPathExtension + ".png"
    }

    func load() throws -> ComposerAttachment.Payload {
        switch self {
        case .file(let url):
            let data = try ComposerAttachment.read(url)
            let source = ComposerAttachment.imageSource(for: data)
            if let source, let type = CGImageSourceGetType(source) as String?,
               let format = UTType(type), Self.imageInputTypes.contains(format) {
                return try ComposerAttachment.prepareImage(data, source: source, type: format)
            }
            return try ComposerAttachment.payload(for: data)
        case .image(let data, let type):
            guard data.count <= ComposerAttachment.maxImageSourceBytes else {
                throw ComposerImageError.sourceBytes
            }
            guard let source = ComposerAttachment.imageSource(for: data),
                  CGImageSourceGetType(source) as String? == type.identifier else {
                throw ComposerImageError.unreadable
            }
            return try ComposerAttachment.prepareImage(data, source: source, type: type)
        case .pastedText(let text):
            guard text.utf8.count <= ComposerAttachment.maxTextBytes else {
                throw WorkspaceError("Pasted text must be 64 KB or smaller to attach. Paste a smaller excerpt or use Paste and Match Style.")
            }
            return try ComposerAttachment.textPayload(for: Data(text.utf8))
        }
    }
}

private enum ComposerImageError: LocalizedError {
    case sourceBytes, unreadable, multipleFrames, tooLarge

    var errorDescription: String? {
        switch self {
        case .sourceBytes: "Image sources must be 50 MB or smaller."
        case .unreadable: "The image is damaged or too large to decode."
        case .multipleFrames: "This image has multiple frames. Attach a single-frame PNG or JPEG."
        case .tooLarge: "The image is too large to attach, even after compression."
        }
    }
}

struct ComposerAttachment: Codable, Equatable, Identifiable {
    struct Payload: Codable, Equatable {
        let mimeType: String
        let data: Data

        var isImage: Bool { mimeType.hasPrefix("image/") }
        var text: String? {
            guard mimeType == "text/plain", !data.isEmpty, data.count <= ComposerAttachment.maxTextBytes,
                  !data.contains(0), String(data: data, encoding: .utf8) != nil else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static let maxCount = 10
    static let maxBytes = 4 * 1024 * 1024
    static let maxTextBytes = 64 * 1024
    static let imageTypes: [UTType: String] = [.png: "image/png", .jpeg: "image/jpeg"]
    fileprivate static let maxImageSourceBytes = 50 * 1024 * 1024
    private static let maxImageEdge = 2000
    // Pi's default resize budget is strictly below 4.5 MiB of base64.
    private static let maxImageBytes = (9 * 1024 * 1024 / 2 / 4 - 1) * 3

    let id: UUID
    let name: String
    var payload: Payload?
    let sideChatReference: Bool?

    init(id: UUID = UUID(), name: String, payload: Payload?, sideChatReference: Bool? = nil) {
        self.id = id
        self.name = name
        self.payload = payload
        self.sideChatReference = sideChatReference
    }

    private enum CodingKeys: String, CodingKey { case id, name, payload, sideChatReference }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(UUID.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        sideChatReference = try fields.decodeIfPresent(Bool.self, forKey: .sideChatReference)
        if let saved = try? fields.decode(Payload.self, forKey: .payload),
           (try? Self.payload(for: saved.data))?.mimeType == saved.mimeType {
            payload = saved
        }
    }

    fileprivate static func read(_ url: URL) throws -> Data {
        try WorkspaceLocalFile.read(url, limit: maxImageSourceBytes) {
            sourceSizeError(for: url)
        }
    }

    private static func sourceSizeError(for url: URL) -> Error {
        if let type = UTType(filenameExtension: url.pathExtension), imageTypes[type] != nil || type == .tiff {
            return ComposerImageError.sourceBytes
        }
        return WorkspaceError("Files must be 4 MB or smaller.")
    }

    static func payload(for data: Data) throws -> Payload {
        guard !data.isEmpty else { throw WorkspaceError("The file is empty.") }
        guard data.count <= maxBytes else { throw WorkspaceError("Files must be 4 MB or smaller.") }
        if let source = imageSource(for: data), let type = CGImageSourceGetType(source) {
            guard let mimeType = imageTypes[UTType(type as String) ?? .image] else {
                throw WorkspaceError("Choose a PNG or JPEG image.")
            }
            guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  previewEdge(source) != nil else {
                throw WorkspaceError("The image is damaged or too large to preview.")
            }
            return Payload(mimeType: mimeType, data: data)
        }
        return try textPayload(for: data)
    }

    fileprivate static func textPayload(for data: Data) throws -> Payload {
        guard !data.isEmpty, !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw WorkspaceError("Choose a PNG, JPEG, or UTF-8 text file.")
        }
        guard data.count <= maxTextBytes else { throw WorkspaceError("Text files must be 64 KB or smaller.") }
        return Payload(mimeType: "text/plain", data: data)
    }

    fileprivate static func imageSource(for data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    fileprivate static func prepareImage(_ data: Data, source: CGImageSource, type: UTType) throws -> Payload {
        guard let edge = previewEdge(source), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ComposerImageError.unreadable
        }
        if let mimeType = imageTypes[type], data.count <= maxImageBytes, edge <= maxImageEdge {
            return Payload(mimeType: mimeType, data: data)
        }
        guard CGImageSourceGetCount(source) == 1 else { throw ComposerImageError.multipleFrames }

        let destination: UTType = type == .jpeg ? .jpeg : .png
        let qualities = destination == .jpeg ? [0.92, 0.85, 0.78, 0.68] : [1.0]
        let baseEdge = min(edge, maxImageEdge)
        for scale in [1.0, 0.75, 0.55, 0.35] {
            let size = max(1, Int((Double(baseEdge) * scale).rounded()))
            guard let image = thumbnail(source, maximumSize: size) else { throw ComposerImageError.unreadable }
            // Shrink PNGs without swapping to a codec that discards transparency.
            for quality in qualities {
                if let data = encode(image, as: destination, quality: quality), data.count <= maxImageBytes {
                    return try payload(for: data)
                }
            }
        }
        throw ComposerImageError.tooLarge
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? (data as Data) : nil
    }

    func preview(maximumSize: Int) -> NSImage? {
        guard let payload else { return nil }
        return Self.preview(payload, maximumSize: maximumSize)
    }

    static func pngForCopy(_ payload: Payload) -> Data? {
        if payload.mimeType == "image/png" { return payload.data }
        guard payload.mimeType == "image/jpeg", let source = imageSource(for: payload.data),
              let edge = previewEdge(source), let image = thumbnail(source, maximumSize: edge) else { return nil }
        return encode(image, as: .png, quality: 1)
    }

    static func preview(_ payload: Payload, maximumSize: Int) -> NSImage? {
        guard let type = imageTypes.first(where: { $0.value == payload.mimeType })?.key,
              let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
              CGImageSourceGetType(source) == type.identifier as CFString,
              previewEdge(source) != nil,
              let image = thumbnail(source, maximumSize: maximumSize) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private static func previewEdge(_ source: CGImageSource) -> Int? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int, (1...8192).contains(width),
              let height = properties?[kCGImagePropertyPixelHeight] as? Int, (1...8192).contains(height) else {
            return nil
        }
        return width * height <= 24_000_000 ? max(width, height) : nil
    }

    private static func thumbnail(_ source: CGImageSource, maximumSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumSize
        ] as CFDictionary)
    }
}

struct SentAttachment: Decodable, Identifiable {
    let id: UUID
    let name: String
    let mimeType: String
    let hasImage: Bool?
    var hasText: Bool? = nil
}
