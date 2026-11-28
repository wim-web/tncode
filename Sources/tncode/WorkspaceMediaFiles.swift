import AppKit
import ImageIO
import UniformTypeIdentifiers

enum WorkspaceMediaError: LocalizedError {
    case image, pdf, tooLarge, imageDimensions, externalSVGResources, pdfPages, lockedPDF

    var errorDescription: String? {
        switch self {
        case .image: String(localized: "Unable to load image.")
        case .pdf: String(localized: "Unable to open PDF.")
        case .tooLarge: String(localized: "Preview limited to files of 50 MiB or smaller.")
        case .imageDimensions: String(localized: "This image is too large to display.")
        case .externalSVGResources: String(localized: "This SVG refers to external resources.")
        case .pdfPages: String(localized: "Preview limited to 2,000 pages.")
        case .lockedPDF: String(localized: "This PDF is password protected. Open it in the default app to unlock it.")
        }
    }
}

struct WorkspaceImageFile: Sendable {
    let bitmap: CGImage
    let animation: Data?
    let id = UUID()

    var size: CGSize { CGSize(width: bitmap.width, height: bitmap.height) }
}

struct WorkspacePDFFile: Sendable {
    let data: Data
    let id = UUID()
}

enum WorkspaceMediaFormat {
    case image, svg, pdf

    static let byteLimit = 50 * 1024 * 1024
    static let imageExtensions = ["avif", "bmp", "gif", "ico", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"]

    init?(fileName: String) {
        switch fileName.split(separator: ".", omittingEmptySubsequences: false).dropFirst().last?.lowercased() {
        case "pdf": self = .pdf
        case "svg": self = .svg
        case let suffix? where Self.imageExtensions.contains(suffix):
            self = .image
        default: return nil
        }
    }

    func preview(_ data: Data) throws -> WorkspaceFilePreview {
        switch self {
        case .image: return .image(try rasterImage(data))
        case .svg: return .image(try vectorImage(data))
        case .pdf:
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider) else { throw WorkspaceMediaError.pdf }
            guard document.isUnlocked else { throw WorkspaceMediaError.lockedPDF }
            guard document.numberOfPages <= 2_000 else { throw WorkspaceMediaError.pdfPages }
            guard document.numberOfPages > 0, document.page(at: 1) != nil else { throw WorkspaceMediaError.pdf }
            return .pdf(WorkspacePDFFile(data: data))
        }
    }

    func imageBitmap(_ data: Data, maximumEdge: Int) throws -> CGImage {
        switch self {
        case .image: try rasterImage(data, maximumEdge: maximumEdge).bitmap
        case .svg: try vectorImage(data).bitmap
        case .pdf: throw WorkspaceMediaError.image
        }
    }

    private func rasterImage(_ data: Data, maximumEdge: Int? = nil) throws -> WorkspaceImageFile {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              identifier != UTType.pdf.identifier,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw WorkspaceMediaError.image
        }
        try validateImageSize(width: Double(width), height: Double(height))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maximumEdge ?? Int.max),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw WorkspaceMediaError.image
        }
        return WorkspaceImageFile(bitmap: image,
                                  animation: identifier == UTType.gif.identifier && CGImageSourceGetCount(source) > 1 ? data : nil)
    }

    private func vectorImage(_ data: Data) throws -> WorkspaceImageFile {
        guard let xml = try? XMLDocument(data: data, options: .nodeLoadExternalEntitiesNever),
              xml.rootElement()?.localName == "svg" else {
            throw WorkspaceMediaError.image
        }
        // AppKit can load a file URL referenced inside SVG data.
        try validateSVGResources(xml)
        guard let image = NSImage(data: xml.xmlData), image.size.width > 0, image.size.height > 0 else {
            throw WorkspaceMediaError.image
        }
        try validateImageSize(width: image.size.width, height: image.size.height)
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WorkspaceMediaError.image
        }
        return WorkspaceImageFile(bitmap: bitmap, animation: nil)
    }

    private func validateSVGResources(_ xml: XMLDocument) throws {
        guard xml.dtd == nil, try xml.nodes(forXPath: "//processing-instruction()").isEmpty else {
            throw WorkspaceMediaError.externalSVGResources
        }
        for node in try xml.nodes(forXPath: "//*") {
            guard let element = node as? XMLElement else { continue }
            switch element.localName {
            case "foreignObject", "script", "animate", "animateMotion", "animateTransform", "set":
                throw WorkspaceMediaError.externalSVGResources
            case "style":
                try validateSVGStyle(element.stringValue ?? "")
            default: break
            }
            for attribute in element.attributes ?? [] {
                let value = (attribute.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                switch attribute.localName {
                case "href", "src":
                    guard value.hasPrefix("#") else { throw WorkspaceMediaError.externalSVGResources }
                case "base": throw WorkspaceMediaError.externalSVGResources
                default: try validateSVGStyle(value)
                }
            }
        }
    }

    private func validateSVGStyle(_ value: String) throws {
        let local = value.replacingOccurrences(of: #"(?i)\burl\(\s*(['"]?)#[^'")\s]+\1\s*\)"#,
                                               with: "", options: .regularExpression)
        if local.range(of: #"(?i)\b(?:url|src|image|image-set)\s*\(|@|\\|/\*"#,
                       options: .regularExpression) != nil {
            throw WorkspaceMediaError.externalSVGResources
        }
    }

    private func validateImageSize(width: Double, height: Double) throws {
        guard (1...16_384).contains(width), (1...16_384).contains(height), width * height <= 40_000_000 else {
            throw WorkspaceMediaError.imageDimensions
        }
    }
}
