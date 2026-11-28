import AppKit
import SwiftUI

/// The selected row exposes its native text range to accessibility and scrolls that range into view.
struct FoundTranscriptText: NSViewRepresentable {
    let rendered: AttributedString
    let selection: ThreadFindSession.Selection

    final class View: NSTextView {
        var rendered: AttributedString?
        var findSelection: ThreadFindSession.Selection?
        var needsReveal = false

        override func layout() {
            super.layout()
            guard needsReveal, window != nil, bounds.width > 0, let findSelection else { return }
            needsReveal = false
            scrollRangeToVisible(findSelection.occurrence.range)
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.setAccessibilityIdentifier("thread-find-selected-text")
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        let changed = view.rendered != rendered
        guard changed || view.findSelection != selection else { return }
        if changed {
            view.textStorage?.setAttributedString(styledText())
            view.rendered = rendered
        }
        let full = NSRange(location: 0, length: view.string.utf16.count)
        view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        let range = selection.occurrence.range
        guard NSMaxRange(range) <= full.length else { return }
        view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor, forCharacterRange: range)
        view.setSelectedRange(range)
        view.findSelection = selection
        view.needsReveal = true
        view.needsLayout = true
    }

    private func styledText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let content = NSMutableAttributedString(attributedString: NSAttributedString(rendered))
        let full = NSRange(location: 0, length: content.length)
        content.addAttributes([.paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor], range: full)
        content.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            let intent = InlinePresentationIntent(rawValue: (value as? NSNumber)?.uintValue ?? 0)
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                                              : NSFont.systemFont(ofSize: 14)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            content.addAttribute(.font, value: font, range: range)
            if intent.contains(.strikethrough) {
                content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: View, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let container = nsView.textContainer,
              let layout = nsView.layoutManager else { return nil }
        container.containerSize = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let size = layout.usedRect(for: container).size
        return CGSize(width: min(width, ceil(size.width)), height: ceil(size.height))
    }
}
