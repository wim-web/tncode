import XCTest
@testable import PiWorkspace

final class WorkspaceLayoutTests: XCTestCase {
    func testDefaultEditorGeometryAtRecordedWidths() {
        let samples: [(viewport: CGFloat, details: Bool, right: CGFloat?, x: CGFloat, width: CGFloat)] = [
            (900, false, nil, 318, 521),
            (900, true, nil, 318, 521),
            (900, false, 378, 318, 521),
            (1080, false, nil, 318, 701),
            (1080, true, nil, 318, 701),
            (1080, false, 463, 318, 238),
            (1440, false, nil, 493.5, 710),
            (1440, true, nil, 393, 710),
            (1440, false, 540, 318, 521),
        ]

        for sample in samples {
            let sidebar = WorkspaceLayout.sidebarWidth(in: sample.viewport, preferred: WorkspaceLayout.defaultSidebarWidth)
            let workspaceX = sidebar + WorkspaceLayout.dividerWidth
            let layout = WorkspaceLayout(
                viewportWidth: sample.viewport,
                workspaceSize: CGSize(width: sample.viewport - workspaceX, height: 720),
                preferredRightPanelWidth: sample.right.map { _ in WorkspaceLayout.defaultRightPanelWidth },
                rightPanelDrag: 0,
                showingDetails: sample.details
            )
            XCTAssertEqual(workspaceX, 257)
            XCTAssertEqual(layout.rightPanelWidth, sample.right ?? 0)
            if sample.right != nil {
                XCTAssertEqual(layout.rightPanelOverlaysChat, sample.viewport == 900)
            }
            if sample.details {
                XCTAssertEqual(layout.detailsFitInline, sample.viewport == 1440)
            }
            XCTAssertEqual(workspaceX + layout.composerLeading + WorkspaceLayout.editorInset, sample.x)
            XCTAssertEqual(layout.composerWidth - 2 * WorkspaceLayout.editorInset, sample.width)
        }
    }

    func testDraggingStartsAtTheVisibleWidthWhenThePreferredWidthIsClamped() {
        XCTAssertEqual(WorkspaceLayout.sidebarWidth(in: 900, preferred: 400, drag: -20), 240)
        XCTAssertEqual(WorkspaceLayout.sidebarWidth(in: 1080, preferred: 400), 400)

        let layout = WorkspaceLayout(
            viewportWidth: 1080,
            workspaceSize: CGSize(width: 823, height: 720),
            preferredRightPanelWidth: 540,
            rightPanelDrag: 20,
            showingDetails: false
        )
        XCTAssertEqual(layout.rightPanelWidth, 443)
        XCTAssertEqual(layout.chatWidth, 380)
        XCTAssertEqual(layout.resizedRightPanelWidth(drag: 200), 360)
    }
}
