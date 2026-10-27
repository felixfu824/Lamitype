import AppKit
import XCTest
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
            XCTAssertFalse(path.contains(CGPoint(x: 31, y: barBottom + 1)), "bar has its own rounded corners")
            XCTAssertFalse(path.contains(CGPoint(x: 5, y: barBottom + 24)), "bar is narrower than preview")
        }
    }
}
