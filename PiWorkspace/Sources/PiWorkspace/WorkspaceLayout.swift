import Foundation

struct WorkspaceLayout {
    static let defaultSidebarWidth: CGFloat = 256
    static let defaultRightPanelWidth: CGFloat = 540
    static let dividerWidth: CGFloat = 1
    static let headerHeight: CGFloat = 52
    static let detailsWidth: CGFloat = 280
    static let detailsInset: CGFloat = 12
    static let editorInset: CGFloat = 13

    private static let minimumSplitWidth: CGFloat = 360
    private static let chatGutter: CGFloat = 48
    private static let maximumComposerWidth: CGFloat = 736
    private static let detailsClearance: CGFloat = 32
    private static let minimumDetailsChatWidth: CGFloat = 640

    let viewportWidth: CGFloat
    let workspaceSize: CGSize
    let preferredRightPanelWidth: CGFloat?
    let rightPanelDrag: CGFloat
    let showingDetails: Bool

    static func sidebarWidth(in viewportWidth: CGFloat, preferred: CGFloat, drag: CGFloat = 0) -> CGFloat {
        let limits = 177...max(defaultSidebarWidth, floor(viewportWidth) - 640)
        let start = min(limits.upperBound, max(limits.lowerBound, preferred))
        return min(limits.upperBound, max(limits.lowerBound, start + drag))
    }

    var rightPanelOverlaysChat: Bool { viewportWidth <= 980 }

    var rightPanelWidth: CGFloat {
        guard preferredRightPanelWidth != nil else { return 0 }
        if rightPanelOverlaysChat {
            return min(workspaceSize.width, min(448, max(320, viewportWidth * 0.42)))
        }
        return resizedRightPanelWidth(drag: rightPanelDrag)
    }

    func resizedRightPanelWidth(drag: CGFloat) -> CGFloat {
        let minimum = Self.minimumSplitWidth
        let maximum = max(minimum, min(floor(viewportWidth * 0.7), floor(workspaceSize.width) - minimum))
        let preferred = preferredRightPanelWidth ?? Self.defaultRightPanelWidth
        let start = min(maximum, max(minimum, preferred))
        return min(maximum, max(minimum, start - drag))
    }

    var chatWidth: CGFloat {
        workspaceSize.width - (rightPanelOverlaysChat ? 0 : rightPanelWidth)
    }

    var detailsHeight: CGFloat {
        max(0, workspaceSize.height - Self.headerHeight - Self.detailsInset * 2)
    }

    private var detailsLaneEnd: CGFloat {
        chatWidth - Self.detailsWidth - Self.detailsInset - Self.detailsClearance
    }

    var detailsFitInline: Bool {
        detailsHeight >= 160 && detailsLaneEnd - Self.chatGutter >= Self.minimumDetailsChatWidth
    }

    var composerWidth: CGFloat {
        // Give the existing composer controls room when a resized sidebar and panel share a narrow window.
        let gutter = min(Self.chatGutter, max(16, (chatWidth - 240) / 2))
        let laneEnd = showingDetails && detailsFitInline ? detailsLaneEnd : chatWidth - gutter
        return max(0, min(Self.maximumComposerWidth, min(chatWidth - gutter * 2, laneEnd - gutter)))
    }

    var composerLeading: CGFloat {
        let centered = (chatWidth - composerWidth) / 2
        guard showingDetails && detailsFitInline else { return centered }
        return min(centered, detailsLaneEnd - composerWidth)
    }
}
