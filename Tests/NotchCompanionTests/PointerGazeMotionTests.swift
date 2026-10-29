import XCTest
@testable import NotchCompanion

final class PointerGazeMotionTests: XCTestCase {
    func testGazeFollowsPointersFarToEitherSideAndBelowTheNotch() {
        let screen = CGRect(x: -1_500, y: -600, width: 3_000, height: 1_800)
        let center = CGPoint(x: 0, y: 1_184)
        XCTAssertEqual(PointerGazeMotion.target(at: CGPoint(x: 1_000, y: 1_184),
                                              mascotCenter: center, screen: screen), CGSize(width: 3, height: 0))
        XCTAssertEqual(PointerGazeMotion.target(at: CGPoint(x: -1_000, y: 1_184),
                                              mascotCenter: center, screen: screen), CGSize(width: -3, height: 0))
        XCTAssertEqual(PointerGazeMotion.target(at: CGPoint(x: 0, y: 184),
                                              mascotCenter: center, screen: screen), CGSize(width: 0, height: 2))
    }

    func testGazeReturnsToRestOutsideTheBroadRadiusOrOnAnotherDisplay() {
        let screen = CGRect(x: -1_500, y: -600, width: 3_000, height: 1_800)
        XCTAssertEqual(PointerGazeMotion.target(at: CGPoint(x: 0, y: -200),
                                              mascotCenter: CGPoint(x: 0, y: 1_184), screen: screen), .zero)
        let adjacentScreen = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        XCTAssertEqual(PointerGazeMotion.target(at: CGPoint(x: 1_010, y: 800),
                                              mascotCenter: CGPoint(x: 950, y: 984), screen: adjacentScreen), .zero)
    }

    func testExpandedTrackingRangeStillHonorsReducedMotion() {
        XCTAssertEqual(PointerGazeMotion.target(at: CGPoint(x: 500, y: 184),
                                              mascotCenter: CGPoint(x: 0, y: 1_184),
                                              screen: CGRect(x: -1_500, y: -600, width: 3_000, height: 1_800),
                                              reducedMotion: true), .zero)
    }

    func testGazeTracksMostOfMouseMovementWithinThreeFrames() {
        let target = CGSize(width: 3, height: -2)
        var offset = PointerGazeMotion.step(from: .zero, toward: target,
                                          elapsed: PointerGazeMotion.sampleInterval)
        XCTAssertGreaterThan(offset.width, target.width / 2)
        for _ in 0..<2 {
            offset = PointerGazeMotion.step(from: offset, toward: target,
                                           elapsed: PointerGazeMotion.sampleInterval)
        }
        XCTAssertGreaterThan(offset.width, target.width * 0.9)
        XCTAssertLessThan(offset.height, target.height * 0.9)
        XCTAssertLessThan(offset.width, target.width)
        XCTAssertGreaterThan(offset.height, target.height)
    }

    func testMouseReversalRespondsNextFrameWithoutSpringOvershoot() {
        var offset = CGSize(width: 3, height: 2)
        let target = CGSize(width: -3, height: -2)
        offset = PointerGazeMotion.step(from: offset, toward: target,
                                       elapsed: PointerGazeMotion.sampleInterval)
        XCTAssertLessThan(offset.width, 0)
        XCTAssertLessThan(offset.height, 0)
        for _ in 0..<10 {
            offset = PointerGazeMotion.step(from: offset, toward: target,
                                           elapsed: PointerGazeMotion.sampleInterval)
            XCTAssertGreaterThanOrEqual(offset.width, target.width)
            XCTAssertGreaterThanOrEqual(offset.height, target.height)
        }
        XCTAssertEqual(offset, target)
    }

    func testTrackingResponseIsIndependentOfTimerCadence() {
        let target = CGSize(width: 3, height: 2)
        let delayed = PointerGazeMotion.step(from: .zero, toward: target, elapsed: 0.05)
        var regular = CGSize.zero
        for _ in 0..<3 {
            regular = PointerGazeMotion.step(from: regular, toward: target, elapsed: 0.05 / 3)
        }
        XCTAssertEqual(regular.width, delayed.width, accuracy: 0.00001)
        XCTAssertEqual(regular.height, delayed.height, accuracy: 0.00001)
    }

    func testReducedMotionImmediatelyReturnsEyesToRest() {
        XCTAssertEqual(PointerGazeMotion.step(from: CGSize(width: 3, height: -2),
                                             toward: CGSize(width: -3, height: 2), elapsed: 0,
                                             reducedMotion: true), .zero)
    }
}
