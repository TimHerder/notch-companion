import XCTest
@testable import NotchCompanion

final class CollapsedStatusTests: XCTestCase {
    func testRunningWorkWinsOverOlderFinishedSessions() {
        let complete = CompanionSession(state: .finished)
        let running = CompanionSession(state: .working)
        XCTAssertEqual(CollapsedStatus.resolve(sessions: [complete, running]), .running)
    }

    func testBackgroundCompletionVisibleEvenWithBlankSelectedSession() {
        XCTAssertEqual(CollapsedStatus.resolve(sessions: [CompanionSession(), CompanionSession(state: .finished)]), .finished)
    }

    func testLiveChildCannotShowGreenFinishedIndicator() {
        let parent = CompanionSession(state: .finished, agents: [ChildAgent(id: "child", title: "Still running")])
        XCTAssertEqual(CollapsedStatus.resolve(sessions: [parent]), .running)
        let waitingChild = CompanionSession(state: .finished, agents: [ChildAgent(id: "waiting", title: "Needs input", state: .waiting)])
        XCTAssertEqual(CollapsedStatus.resolve(sessions: [waitingChild]), .waiting)
        XCTAssertTrue(waitingChild.isBusy)
    }

    func testFailureAndWaitingAreNotMisrepresentedAsCompleted() {
        let old = CompanionSession(state: .finished, updatedAt: Date(timeIntervalSince1970: 10))
        let failed = CompanionSession(state: .failed, updatedAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(CollapsedStatus.resolve(sessions: [old, failed]), .failed)
        XCTAssertEqual(CollapsedStatus.resolve(sessions: [CompanionSession(state: .waiting)]), .waiting)
        XCTAssertEqual(CollapsedStatus.resolve(sessions: [CompanionSession()]), .none)
    }

    func testPhysicalStatusLightHasVisibleSpaceOutsideCamera() {
        let geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1728, height: 1117), topInset: 32,
                                     leftArea: CGRect(x: 0, y: 1085, width: 764, height: 32),
                                     rightArea: CGRect(x: 964, y: 1085, width: 764, height: 32))
        XCTAssertEqual(geometry.statusShoulderWidth, 24)
        XCTAssertEqual(geometry.collapsedFrame.width, 282)
        XCTAssertGreaterThan(geometry.collapsedStatusCenter.x - 2.5, geometry.hardware.maxX)
        XCTAssertLessThan(geometry.collapsedStatusCenter.x + 2.5, geometry.collapsedFrame.maxX)
        XCTAssertEqual(geometry.collapsedFrame.height, geometry.hardware.height)
    }

    func testSingleProgressControlsTranscriptVisibility() {
        XCTAssertEqual(UnifiedNotchView.contentOpacity(progress: 0), 0)
        XCTAssertEqual(UnifiedNotchView.contentOpacity(progress: 0.82), 0)
        XCTAssertEqual(UnifiedNotchView.contentOpacity(progress: 0.9), 0.5, accuracy: 0.0001)
        XCTAssertEqual(UnifiedNotchView.contentOpacity(progress: 0.98), 1)
        XCTAssertEqual(UnifiedNotchView.contentOpacity(progress: 1), 1)
    }
}
