import AppKit
import Observation
import PDFKit
import SwiftUI

struct WorkspacePDFPosition {
    let page: Int
    let point: CGPoint
    let zoom: CGFloat?
}

struct WorkspacePDFView: View {
    let file: WorkspacePDFFile
    let name: String
    let position: () -> WorkspacePDFPosition?
    let remember: (WorkspacePDFPosition) -> Void
    let retry: () -> Void
    let save: () -> Void

    @State private var reader = WorkspacePDFReader()
    @State private var query = ""
    @State private var failed = false
    @FocusState private var finding: Bool

    var body: some View {
        VStack(spacing: 0) {
            if failed {
                Text(WorkspaceMediaError.pdf.localizedDescription)
                    .accessibilityIdentifier("files-preview-error")
                Button("Retry", action: retry)
                    .accessibilityIdentifier("files-preview-retry")
            } else {
                toolbar
                Divider()
                findBar
                Divider()
                PDFCanvasHost(canvas: reader.canvas, name: name)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PDF Preview")
        .accessibilityIdentifier("files-pdf-preview")
        .task(id: file.id) {
            failed = !reader.open(file, at: reader.position ?? position())
            let focus = $finding
            reader.canvas.focusFind = { focus.wrappedValue = true }
        }
        .task(id: FindRequest(file: file.id, query: query)) {
            reader.clearSearch()
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                reader.find(term)
            } catch {}
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: reader.canvas)) { _ in
            reader.updatePage()
        }
        .onDisappear {
            if let position = reader.position { remember(position) }
            reader.clearSearch()
            reader.canvas.focusFind = nil
        }
    }

    private struct FindRequest: Equatable {
        let file: UUID
        let query: String
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Text(verbatim: "\(reader.page + 1) / \(reader.pageCount) "
                 + (reader.pageCount == 1 ? String(localized: "page") : String(localized: "pages")))
                .accessibilityIdentifier("files-pdf-page")
                .opacity(reader.pageCount > 0 ? 1 : 0)
            Spacer(minLength: 0)
            fileButton("Previous page", "chevron.up", id: "files-pdf-previous-page") { reader.go(to: reader.page - 1) }
                .disabled(reader.page == 0)
            fileButton("Next page", "chevron.down", id: "files-pdf-next-page") { reader.go(to: reader.page + 1) }
                .disabled(reader.page + 1 >= reader.pageCount)
            fileButton("Zoom out", "minus", id: "files-pdf-zoom-out") { reader.stepZoom(-0.25) }
                .disabled(!reader.canZoomOut)
            Text(reader.zoom.map { "\(Int(($0 * 100).rounded()))%" } ?? String(localized: "Fit width"))
                .accessibilityIdentifier("files-pdf-zoom")
            fileButton("Zoom in", "plus", id: "files-pdf-zoom-in") { reader.stepZoom(0.25) }
                .disabled(!reader.canZoomIn)
            fileButton("Fit width", "arrow.left.and.right", id: "files-pdf-fit") { reader.setZoom(nil) }
            fileButton("Save file", "square.and.arrow.down", id: "files-pdf-save", action: save)
                .disabled(reader.pageCount == 0)
        }
        .font(.caption.monospacedDigit())
        .padding(8)
    }

    private var findBar: some View {
        HStack(spacing: 5) {
            TextField("Find in PDF", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("files-pdf-find")
                .focused($finding)
                .onSubmit { reader.nextMatch() }
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Text(reader.searching ? "Searching…" : "\(reader.matchNumber)/\(reader.matchCount)")
                    .accessibilityIdentifier("files-pdf-find-results")
                fileButton("Next matching page", "chevron.down", id: "files-pdf-next-match") { reader.nextMatch() }
                    .disabled(reader.matchCount == 0)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

@MainActor @Observable
final class WorkspacePDFReader: NSObject, @preconcurrency PDFDocumentDelegate, @preconcurrency PDFViewDelegate {
    let canvas = WorkspacePDFCanvas()
    private(set) var page = 0
    private(set) var pageCount = 0
    private(set) var zoom: CGFloat?
    private(set) var searching = false
    private(set) var matchNumber = 0
    private var matches: [Int: [PDFSelection]] = [:]
    private var matchingPages: [Int] = []

    var matchCount: Int { matchingPages.count }
    var canZoomOut: Bool { pageCount > 0 && (zoom ?? canvas.fitScale) > 0.25 }
    var canZoomIn: Bool { pageCount > 0 && (zoom ?? canvas.fitScale) < 3 }

    var position: WorkspacePDFPosition? {
        guard pageCount > 0 else { return nil }
        return WorkspacePDFPosition(page: page, point: canvas.currentDestination?.point ?? .zero, zoom: zoom)
    }

    override init() {
        super.init()
        canvas.delegate = self
    }

    func open(_ file: WorkspacePDFFile, at position: WorkspacePDFPosition?) -> Bool {
        clearSearch()
        canvas.document?.delegate = nil
        guard let document = PDFDocument(data: file.data), document.pageCount > 0, !document.isLocked else {
            canvas.document = nil
            pageCount = 0
            return false
        }
        document.delegate = self
        canvas.document = document
        pageCount = document.pageCount
        setZoom(position?.zoom)
        let index = min(position?.page ?? 0, pageCount - 1)
        if let position, index == position.page, let page = document.page(at: index) {
            let bounds = page.bounds(for: canvas.displayBox)
            let point = CGPoint(x: min(max(position.point.x, bounds.minX), bounds.maxX),
                                y: min(max(position.point.y, bounds.minY), bounds.maxY))
            canvas.go(to: PDFDestination(page: page, at: point))
            updatePage()
        } else {
            go(to: index)
        }
        return true
    }

    func updatePage() {
        if let document = canvas.document, let current = canvas.currentPage {
            page = document.index(for: current)
        }
    }

    func go(to index: Int) {
        guard (0..<pageCount).contains(index), let page = canvas.document?.page(at: index) else { return }
        canvas.go(to: page)
        updatePage()
    }

    func setZoom(_ scale: CGFloat?) {
        zoom = scale
        canvas.requestedScale = scale
        canvas.applyScale()
    }

    func stepZoom(_ delta: CGFloat) {
        setZoom(min(3, max(0.25, (zoom ?? canvas.fitScale) + delta)))
    }

    func clearSearch() {
        searching = false
        canvas.document?.cancelFindString()
        canvas.highlightedSelections = nil
        matches.removeAll()
        matchingPages.removeAll()
        matchNumber = 0
    }

    func find(_ term: String) {
        guard let document = canvas.document else { return }
        searching = true
        document.beginFindString(term, withOptions: .caseInsensitive)
    }

    func documentDidFindMatch(_ notification: Notification) {
        guard searching, let document = canvas.document, notification.object as? PDFDocument === document,
              let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection,
              let page = selection.pages.first else { return }
        let index = document.index(for: page)
        selection.color = .systemYellow
        matches[index, default: []].append(selection)
        if matchingPages.isEmpty {
            matchingPages = [index]
            nextMatch()
        }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        guard searching, notification.object as? PDFDocument === canvas.document else { return }
        searching = false
        matchingPages = matches.keys.sorted()
        canvas.highlightedSelections = matchingPages.flatMap { matches[$0] ?? [] }
    }

    func nextMatch() {
        guard !matchingPages.isEmpty else { return }
        matchNumber = matchNumber % matchingPages.count + 1
        let index = matchingPages[matchNumber - 1]
        go(to: index)
        if let match = matches[index]?.first, let page = match.pages.first {
            canvas.go(to: match.bounds(for: page), on: page)
        }
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }
}

final class WorkspacePDFCanvas: PDFView {
    var requestedScale: CGFloat?
    var focusFind: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        autoScales = false
        minScaleFactor = 0.001
        maxScaleFactor = 64
        pageBreakMargins = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
    }

    required init?(coder: NSCoder) { nil }

    var fitScale: CGFloat {
        guard let page = document?.page(at: 0) else { return 1 }
        let box = page.bounds(for: displayBox)
        let width = page.rotation % 180 == 0 ? box.width : box.height
        return max(bounds.width - 32, 1) / max(width, 1)
    }

    override func layout() {
        super.layout()
        applyScale()
    }

    func applyScale() {
        let scale = requestedScale ?? fitScale
        guard document != nil, bounds.width > 32, abs(scaleFactor - scale) > 0.0001 else { return }
        let destination = currentDestination
        scaleFactor = scale
        if let destination { go(to: destination) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "f",
           let responder = window?.firstResponder as? NSView,
           responder === self || responder.isDescendant(of: self) {
            focusFind?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func perform(_ action: PDFAction) {
        if action is PDFActionGoTo || action is PDFActionURL { super.perform(action) }
    }
}

private struct PDFCanvasHost: NSViewRepresentable {
    let canvas: WorkspacePDFCanvas
    let name: String

    func makeNSView(context: Context) -> WorkspacePDFCanvas { canvas }
    func updateNSView(_ view: WorkspacePDFCanvas, context: Context) {
        view.setAccessibilityLabel(name)
        view.setAccessibilityIdentifier("files-pdf-document")
    }
}
