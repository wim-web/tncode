import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ProjectIcon: Codable, Equatable {
    enum Symbol: String, CaseIterable, Codable {
        case folder = "folder"
        case code = "chevron.left.forwardslash.chevron.right"
        case terminal = "terminal"
        case globe = "globe"
        case server = "server.rack"
        case database = "cylinder"
        case sparkles = "sparkles"
        case mobile = "iphone"
        case desktop = "desktopcomputer"
        case cloud = "cloud"
        case package = "shippingbox"
        case book = "book"
        case science = "flask"
        case shield = "checkmark.shield"
        case game = "gamecontroller"
        case music = "music.note"
        case picture = "photo"
        case shopping = "bag"
        case branch = "point.topleft.down.to.point.bottomright.curvepath"
        case tools = "wrench"
        case layers = "square.3.layers.3d"

        var title: String { NSLocalizedString(String(describing: self).capitalized, comment: "Project icon symbol") }
    }

    enum Tint: String, CaseIterable, Codable {
        case gray, red, orange, yellow, green, teal, cyan, blue, indigo, purple, pink

        var title: String { NSLocalizedString(rawValue.capitalized, comment: "Project icon color") }
    }

    case symbol(Symbol, Tint)
    case emoji(String)
    case monogram(String, Tint)
    case image(png: Data)

    private static let imageEdge = 128
    private static let maximumPNGBytes = 128 * 1024
    private static let fileExtensions = WorkspaceMediaFormat.imageExtensions + ["svg", "icns"]
    static var contentTypes: [UTType] { fileExtensions.compactMap { UTType(filenameExtension: $0) } }

    var summary: String {
        switch self {
        case .symbol(let symbol, let tint): "\(symbol.title), \(tint.title)"
        case .emoji(let emoji): emoji
        case .monogram(let letters, let tint): "\(letters), \(tint.title)"
        case .image: String(localized: "Imported image")
        }
    }

    static func monogramText(_ input: String) -> String? {
        let text = input.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard text.utf8.count <= 128, (1...2).contains(text.count),
              text.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }

    static func firstEmoji(in input: String) -> String? {
        guard let first = input.trimmingCharacters(in: .whitespacesAndNewlines).first else { return nil }
        let emoji = String(first)
        guard emoji.utf8.count <= 128,
              emoji.range(of: #"\p{Extended_Pictographic}|^\p{Regional_Indicator}{2}$|^[#*0-9]\uFE0F?\u20E3$"#,
                          options: .regularExpression) != nil else { return nil }
        return emoji
    }

    static func importing(_ url: URL) throws -> Self {
        let suffix = url.pathExtension.lowercased()
        guard fileExtensions.contains(suffix),
              let format = suffix == "icns" ? .image : WorkspaceMediaFormat(fileName: url.lastPathComponent) else {
            throw WorkspaceError("Choose an image file.")
        }
        let data = try WorkspaceLocalFile.read(url, limit: 8 * 1024 * 1024) {
            WorkspaceError("Choose an icon file of 8 MiB or smaller.")
        }
        let image = try format.imageBitmap(data, maximumEdge: imageEdge)
        let scale = min(1, Double(imageEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WorkspaceMediaError.image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let png = NSMutableData()
        guard let bitmap = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw WorkspaceMediaError.image
        }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination), png.length <= maximumPNGBytes else {
            throw WorkspaceMediaError.image
        }
        return .image(png: png as Data)
    }

    static func bitmap(from png: Data) -> CGImage? {
        guard png.count <= maximumPNGBytes,
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...imageEdge).contains(width), (1...imageEdge).contains(height) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
