import XCTest
@testable import NotchCompanion

final class ExpandedGeometryTests: XCTestCase {
    func testExternalDisplayPreservesRestingNotchAndOpensLargeJoinedSurface() {
        let geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0, leftArea: nil, rightArea: nil)
        XCTAssertEqual(geometry.collapsedFrame.size, CGSize(width: 258, height: 32))
        XCTAssertEqual(geometry.expandedBandFrame.size, CGSize(width: 560, height: 64))
        XCTAssertEqual(geometry.bodyFrame.size, CGSize(width: 560, height: 480))
        XCTAssertEqual(geometry.expandedFrame.size, CGSize(width: 560, height: 544))
        XCTAssertEqual(geometry.expandedBandFrame.maxY, geometry.screen.maxY)
        XCTAssertEqual(geometry.expandedBandFrame.midX, geometry.collapsedFrame.midX)
        XCTAssertEqual(geometry.expandedBandFrame.minY, geometry.bodyFrame.maxY)
        XCTAssertEqual(geometry.expandedBandFrame.minX, geometry.bodyFrame.minX)
        // Eyes center in the 36-point top row; their left edge sits on the 20-point margin.
        XCTAssertEqual(geometry.expandedMascotCenter.x - geometry.expandedBandFrame.minX, 20 + 9 * 1.7, accuracy: 0.0001)
        XCTAssertEqual(geometry.expandedMascotCenter.y, geometry.screen.maxY - 18)
        XCTAssertEqual(geometry.eyeCenterY(progress: 0), 16)
        XCTAssertNil(geometry.expandedCameraMinX)
    }

    func testPhysicalNotchOnOffsetDisplayKeepsExactRestingHeightAndCameraClear() {
        let screen = CGRect(x: -1728, y: 180, width: 1728, height: 1117)
        let geometry = NotchGeometry(screen: screen, topInset: 32,
                                     leftArea: CGRect(x: -1728, y: 1265, width: 764, height: 32),
                                     rightArea: CGRect(x: -764, y: 1265, width: 764, height: 32))
        XCTAssertTrue(geometry.hasHardware)
        XCTAssertEqual(geometry.collapsedFrame.height, geometry.hardware.height)
        XCTAssertEqual(geometry.collapsedFrame.minY, geometry.hardware.minY)
        XCTAssertEqual(geometry.collapsedFrame.maxY, screen.maxY)
        XCTAssertEqual(geometry.expandedFrame.midX, geometry.collapsedFrame.midX)
        XCTAssertEqual(geometry.expandedFrame.maxY, screen.maxY)
        XCTAssertLessThan(geometry.expandedMascotCenter.x + 28, geometry.hardware.minX)
        // The top row is the camera band plus 4 points (eyes beside the camera);
        // the title row is below it.
        XCTAssertEqual(geometry.expandedTopRowHeight, geometry.hardware.height + 4)
        XCTAssertEqual(geometry.expandedBandHeight, geometry.hardware.height + 32)
        XCTAssertEqual(geometry.expandedMascotCenter.y, screen.maxY - 18.5)
        XCTAssertEqual(geometry.expandedCameraMinX, geometry.hardware.minX - geometry.expandedFrame.minX)
        XCTAssertGreaterThanOrEqual(geometry.expandedFrame.minX, screen.minX)
        XCTAssertLessThanOrEqual(geometry.expandedFrame.maxX, screen.maxX)
    }

    func testSmallerDisplayClampsExpandedSizeWithinScreen() {
        let screen = CGRect(x: -360, y: -240, width: 360, height: 430)
        let geometry = NotchGeometry(screen: screen, topInset: 0, leftArea: nil, rightArea: nil)
        XCTAssertEqual(geometry.panelWidth, 336)
        XCTAssertEqual(geometry.bodyHeight, 342)
        XCTAssertEqual(geometry.expandedFrame.minY, screen.minY + 24)
        XCTAssertEqual(geometry.expandedFrame.minX, screen.minX + 12)
        XCTAssertEqual(geometry.expandedFrame.maxX, screen.maxX - 12)
        XCTAssertEqual(geometry.expandedFrame.maxY, screen.maxY)
    }

    func testTitleRowAlwaysSitsBelowPhysicalCamera() {
        let geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1200, height: 900), topInset: 80,
                                     leftArea: CGRect(x: 0, y: 820, width: 500, height: 80),
                                     rightArea: CGRect(x: 700, y: 820, width: 500, height: 80))
        XCTAssertEqual(geometry.expandedBandHeight, 81 + 32)
        XCTAssertEqual(geometry.expandedBandFrame.maxY, 900)
        XCTAssertEqual(geometry.expandedBandFrame.minY, geometry.bodyFrame.maxY)
    }

    func testPhysicalNotchCoversBottomSeamInEveryRestingTier() {
        let screen = CGRect(x: -1470, y: 180, width: 1470, height: 956)
        var geometry = NotchGeometry(screen: screen, topInset: 32,
                                     leftArea: CGRect(x: -1470, y: 1104, width: 645.5, height: 32),
                                     rightArea: CGRect(x: -645.5, y: 1104, width: 645.5, height: 32))
        for tier in 0..<3 {
            geometry.announcing = tier == 1
            geometry.liveContentWidth = tier == 2 ? 38 : 0
            let resting = NotchPresentation.resting(geometry)
            XCTAssertEqual(resting.frame.height, 33)
            XCTAssertEqual(resting.frame.maxY, screen.maxY)
            XCTAssertEqual(resting.frame.minY, 1103)
            XCTAssertEqual(resting.bandHeight, 33)
            XCTAssertEqual(geometry.mascotCenter.y, resting.frame.midY)
            XCTAssertTrue(resting.contains(CGPoint(x: 29, y: 32.5)))
            XCTAssertFalse(resting.contains(CGPoint(x: 29, y: 33)))
            XCTAssertEqual(resting.pressed.frame.height, 33)
        }
    }

}
