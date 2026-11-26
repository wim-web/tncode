import AppKit
import SwiftTerm

@MainActor
enum AuditBitmap {
    private static var timer: Timer?

    static func configure() {
        guard CommandLine.arguments.contains("--audit-bitmap-inbox") else { return }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    static func start() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--audit-bitmap-inbox"),
              args.indices.contains(index + 1), timer == nil else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: true) { _ in
            MainActor.assumeIsolated { respond(directory) }
        }
    }

    private static func respond(_ directory: URL) {
        let request = directory.appendingPathComponent("request")
        guard let name = try? String(contentsOf: request, encoding: .utf8),
              name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { return }
        try? FileManager.default.removeItem(at: request)
        let result: [String: Any]
        do {
            result = try render(directory.appendingPathComponent(name + ".png"))
        } catch {
            result = ["error": error.localizedDescription]
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
        }
    }

    private static func render(_ destination: URL) throws -> [String: Any] {
        let app = NSApplication.shared
        guard let window = app.windows.first(where: { $0.title == "Pi Workspace" && $0.sheetParent == nil }),
              let content = window.contentView else {
            throw NSError(domain: "AuditBitmap.NoWindow", code: 1)
        }
        let bounds = content.bounds
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard width == 1080, height == 720 else {
            throw NSError(domain: "AuditBitmap.UnexpectedContentSize.\(width)x\(height)", code: 2)
        }
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "AuditBitmap.NoContext", code: 3)
        }
        func layer(_ view: NSView) throws -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded()
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "AuditBitmap.NoLayer", code: 4)
            }
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: image)
            }
            return image
        }
        let background = try layer(content)
        let sheet = window.attachedSheet
        let sheetImage = try sheet?.contentView.map(layer)
        let contentOrigin = window.convertToScreen(content.convert(bounds, to: nil)).origin
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        background.draw(in: NSRect(origin: .zero, size: bounds.size))
        func terminalView(in view: NSView) -> TerminalView? {
            guard !view.isHidden else { return nil }
            return view as? TerminalView ?? view.subviews.lazy.compactMap { terminalView(in: $0) }.first
        }
        var terminalRect: NSRect?
        if let terminal = terminalView(in: content), terminal.bounds.height > 0 {
            let area = content.convert(terminal.bounds, from: terminal)
            let cg = context.cgContext
            cg.saveGState()
            let y = content.isFlipped ? bounds.height - area.maxY : area.minY
            cg.translateBy(x: area.minX, y: y)
            terminalRect = NSRect(origin: CGPoint(x: area.minX, y: y), size: area.size)
            terminal.effectiveAppearance.performAsCurrentDrawingAppearance {
                terminal.draw(terminal.bounds)
            }
            cg.restoreGState()
        }
        var sheetRect: NSRect?
        if let sheet, let overlay = sheet.contentView, let sheetImage {
            var area = sheet.convertToScreen(overlay.convert(overlay.bounds, to: nil))
            area.origin.x -= contentOrigin.x
            area.origin.y -= contentOrigin.y
            sheetImage.draw(in: area)
            sheetRect = area
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "AuditBitmap.NoPNG", code: 5)
        }
        try png.write(to: destination, options: .atomic)
        var metadata: [String: Any] = [
            "capture": "AppKit contentView cacheDisplay, app-local supplementary build",
            "contentPoints": [bounds.width, bounds.height], "pixels": [width, height],
            "backingScaleFactor": window.backingScaleFactor,
            "appearance": content.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "",
            "preferredLanguage": Locale.preferredLanguages.first ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        if let terminalRect { metadata["terminalRectBottomOrigin"] = [terminalRect.minX, terminalRect.minY, terminalRect.width, terminalRect.height] }
        if let sheetRect { metadata["sheetRectBottomOrigin"] = [sheetRect.minX, sheetRect.minY, sheetRect.width, sheetRect.height] }
        return metadata
    }
}
