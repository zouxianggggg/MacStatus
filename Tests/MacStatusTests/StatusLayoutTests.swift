import AppKit
import XCTest
@testable import MacStatus

final class StatusLayoutTests: XCTestCase {
    func testSpeedChangesKeepTheFrameAndIconAnchorStable() {
        let view = StatusContentView(frame: NSRect(x: 0, y: 0, width: StatusLayout.width(for: .both), height: 24))
        let originalFrame = view.frame
        let anchor = StatusLayout.anchor(height: view.bounds.height)
        for mode in [MenuSpeedMode.download, .upload, .both] {
            XCTAssertEqual(StatusLayout.width(for: mode), originalFrame.width)
            let speeds: [Double] = [0, 512, 1024, 1_048_576, 999 * 1_048_576, 1_073_741_824]
            for speed in speeds {
                view.update(mode: mode, network: NetworkReading(download: speed, upload: speed / 2, received: 0, sent: 0, interfaces: []))
                XCTAssertEqual(view.frame, originalFrame)
                XCTAssertEqual(StatusLayout.anchor(height: view.bounds.height), anchor)
            }
        }
        XCTAssertEqual(StatusLayout.anchor(height: 24), anchor)
    }

    func testDrawnContentDoesNotInterceptStatusButtonClicks() {
        let view = StatusContentView(frame: NSRect(x: 0, y: 0, width: 88, height: 24))
        XCTAssertNil(view.hitTest(NSPoint(x: 12, y: 12)))
        XCTAssertNil(view.hitTest(NSPoint(x: 60, y: 12)))
    }
}
