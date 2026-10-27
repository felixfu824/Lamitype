import AppKit
import XCTest
import SwiftUI
@testable import HushType

final class FloatingOverlayGeometryTests: XCTestCase {
    func testLiveSilhouetteHasTransparentGapAndIndependentRoundedCorners() {
        let bounds = CGRect(x: 0, y: 0, width: 380, height: 208)
        for flipped in [false, true] {
            let path = FloatingOverlayGeometry.liveSilhouette(in: bounds, flipped: flipped)
            let gapY: CGFloat = flipped ? 152 : 56
            for x: CGFloat in [0, 20, 190, 360, 380] {
                XCTAssertFalse(path.contains(CGPoint(x: x, y: gapY)), "gap must reveal the desktop")
            }
            let previewTop: CGFloat = flipped ? 0 : 64
            XCTAssertFalse(path.contains(CGPoint(x: 1, y: previewTop + 1)), "preview corner must be transparent")
            XCTAssertTrue(path.contains(CGPoint(x: 190, y: previewTop + 30)))
            let barBottom: CGFloat = flipped ? 160 : 0
            XCTAssertTrue(path.contains(CGPoint(x: 190, y: barBottom + 24)))
            XCTAssertFalse(path.contains(CGPoint(x: 1, y: barBottom + 1)), "bar has its own rounded corners")
            XCTAssertTrue(path.contains(CGPoint(x: 5, y: barBottom + 24)), "bar must align with the preview")
        }
    }

    @MainActor
    func testLiveAndStandardRenderedWidthsMatchAcrossStates() {
        _ = NSApplication.shared
        let model = OverlayStateModel()
        let host = NSHostingView(rootView: FloatingOverlayView(model: model))
        model.live = LiveOverlayState(draft: "完整的即時預覽文字")
        host.layoutSubtreeIfNeeded()
        let liveWidth = host.fittingSize.width
        XCTAssertEqual(liveWidth, 380, accuracy: 0.5)
        model.live = nil
        for state: OverlayState in [.recording(level: 0.03, provider: nil), .transcribing(provider: nil),
                                    .recording(level: 0.03, provider: "Gemini"), .transcribing(provider: "Gemini"), .polishing] {
            model.state = state
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, liveWidth, accuracy: 0.5, "\(state)")
            XCTAssertEqual(host.fittingSize.height, 48, accuracy: 0.5, "\(state)")
        }
        model.state = .notice(message: String(repeating: "Long recording failure notice. ", count: 8))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, liveWidth, accuracy: 0.5)
        XCTAssertGreaterThan(host.fittingSize.height, 48)
    }
}
