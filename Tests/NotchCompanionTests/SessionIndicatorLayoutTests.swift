import XCTest
@testable import NotchCompanion

final class SessionIndicatorLayoutTests: XCTestCase {
    func testMultiplePhysicalNotchDotsStayOutsideCameraAtExactNotchHeight() {
        let geometry = NotchGeometry(screen: CGRect(x: -1728, y: 180, width: 1728, height: 1117), topInset: 32,
                                     leftArea: CGRect(x: -1728, y: 1265, width: 764, height: 32),
                                     rightArea: CGRect(x: -764, y: 1265, width: 764, height: 32), indicatorCount: 9)
        XCTAssertEqual(geometry.statusShoulderWidth, 88)
        XCTAssertEqual(geometry.collapsedFrame.height, geometry.hardware.height)
        for index in 0..<9 {
            let center = geometry.indicatorLayout.center(at: index, in: geometry.collapsedFrame.size)
            let globalX = geometry.collapsedFrame.minX + center.x
            XCTAssertGreaterThan(globalX - 2.5, geometry.hardware.maxX)
            XCTAssertLessThan(globalX + 2.5, geometry.collapsedFrame.maxX)
        }
        var acknowledged = geometry
        acknowledged.indicatorCount = 2
        XCTAssertEqual(acknowledged.expandedFrame, geometry.expandedFrame)
        XCTAssertLessThan(acknowledged.collapsedFrame.width, geometry.collapsedFrame.width)
    }

    func testConcurrentSessionsHaveDistinctEvenlySpacedDots() {
        let layout = SessionIndicatorLayout(count: 9, availableWidth: 200)
        let size = CGSize(width: 258, height: 32)
        let points = (0..<9).map { layout.center(at: $0, in: size) }
        XCTAssertEqual(layout.rows, 1)
        XCTAssertEqual(layout.width, 88)
        XCTAssertEqual(points.last?.x, 246)
        for index in 1..<points.count {
            XCTAssertEqual(points[index].x - points[index - 1].x, 8)
            XCTAssertEqual(points[index].y, 16)
        }
    }

    func testDotsWrapWithinNarrowAvailableSpaceInsteadOfDroppingSessions() {
        let layout = SessionIndicatorLayout(count: 12, availableWidth: 48)
        let size = CGSize(width: 48, height: 32)
        let points = (0..<12).map { layout.center(at: $0, in: size) }
        XCTAssertEqual(layout.rows, 3)
        XCTAssertEqual(layout.columns, 4)
        for point in points {
            XCTAssertGreaterThan(point.x - 2.5, 0)
            XCTAssertLessThan(point.x + 2.5, size.width)
            XCTAssertGreaterThan(point.y - 2.5, 0)
            XCTAssertLessThan(point.y + 2.5, size.height)
        }
        XCTAssertEqual(Set(points.map { "\($0.x),\($0.y)" }).count, 12)
    }
}
