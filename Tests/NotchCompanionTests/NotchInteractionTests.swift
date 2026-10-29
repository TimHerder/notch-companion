import XCTest
@testable import NotchCompanion

final class NotchInteractionTests: XCTestCase {
    func testDisabledHoverKeepsNotchClosedButClickAndShortcutStillOpen() {
        var state = NotchInteraction()
        XCTAssertNil(state.update(now: 0, insideTrigger: true, insideRegion: true, openOnHover: false))
        XCTAssertNil(state.update(now: 10, insideTrigger: true, insideRegion: true, openOnHover: false))
        XCTAssertEqual(state.mode, .closed)
        XCTAssertEqual(state.activate(), .activate)
        XCTAssertNil(state.update(now: 20, insideTrigger: false, insideRegion: false, openOnHover: false))
        XCTAssertEqual(state.mode, .intentional)
        XCTAssertEqual(state.toggle(), .close)
        XCTAssertEqual(state.toggle(), .activate)
    }

    func testDisablingHoverClearsPendingDwellAndReenablingStartsFresh() {
        var state = NotchInteraction()
        XCTAssertNil(state.update(now: 0, insideTrigger: true, insideRegion: true))
        XCTAssertNil(state.update(now: 0.1, insideTrigger: true, insideRegion: true, openOnHover: false))
        XCTAssertNil(state.update(now: 1, insideTrigger: true, insideRegion: true))
        XCTAssertNil(state.update(now: 1.1, insideTrigger: true, insideRegion: true))
        XCTAssertEqual(state.update(now: 1.121, insideTrigger: true, insideRegion: true), .showPassively)
    }

    func testDisabledHoverPreservesFileDragOpeningAndLeaveDelay() {
        var state = NotchInteraction()
        XCTAssertNil(state.update(now: 0, insideTrigger: true, insideRegion: true, openOnHover: false))
        XCTAssertEqual(state.dragChanged(source: "notch", active: true, now: 1), .showPassively)
        XCTAssertNil(state.update(now: 2, insideTrigger: false, insideRegion: false, openOnHover: false))
        XCTAssertNil(state.dragChanged(source: "notch", active: false, now: 3))
        XCTAssertNil(state.update(now: 3.2, insideTrigger: false, insideRegion: false, openOnHover: false))
        XCTAssertEqual(state.update(now: 3.301, insideTrigger: false, insideRegion: false, openOnHover: false), .close)
        XCTAssertNil(state.update(now: 4, insideTrigger: true, insideRegion: true, openOnHover: false))
        XCTAssertNil(state.update(now: 5, insideTrigger: true, insideRegion: true, openOnHover: false))
    }

    func testHoverDwellIgnoresBriefPassAndDoesNotRepeatOpen() {
        var state = NotchInteraction()
        XCTAssertNil(state.update(now: 1, insideTrigger: true, insideRegion: true))
        XCTAssertNil(state.update(now: 1.08, insideTrigger: false, insideRegion: false))
        XCTAssertNil(state.update(now: 2, insideTrigger: true, insideRegion: true))
        XCTAssertNil(state.update(now: 2.1, insideTrigger: true, insideRegion: true))
        XCTAssertEqual(state.update(now: 2.121, insideTrigger: true, insideRegion: true), .showPassively)
        XCTAssertEqual(state.mode, .hover)
        XCTAssertNil(state.update(now: 3, insideTrigger: true, insideRegion: true))
    }

    func testHoverCanCrossIntoBodyAndClosesOnlyAfterLeavingWholeRegion() {
        var state = NotchInteraction()
        _ = state.update(now: 0, insideTrigger: true, insideRegion: true)
        _ = state.update(now: 0.13, insideTrigger: true, insideRegion: true)
        XCTAssertNil(state.update(now: 0.2, insideTrigger: false, insideRegion: true))
        XCTAssertNil(state.update(now: 0.3, insideTrigger: false, insideRegion: false))
        XCTAssertNil(state.update(now: 0.55, insideTrigger: false, insideRegion: false))
        XCTAssertNil(state.update(now: 0.56, insideTrigger: false, insideRegion: true))
        XCTAssertNil(state.update(now: 1, insideTrigger: false, insideRegion: false))
        XCTAssertEqual(state.update(now: 1.301, insideTrigger: false, insideRegion: false), .close)
        XCTAssertEqual(state.mode, .closed)
        XCTAssertNil(state.update(now: 2, insideTrigger: false, insideRegion: false))
    }

    func testClickWhileHoverOpenPromotesToIntentionalAndKeepsEditingOpen() {
        var state = NotchInteraction()
        _ = state.update(now: 0, insideTrigger: true, insideRegion: true)
        _ = state.update(now: 0.13, insideTrigger: true, insideRegion: true)
        XCTAssertEqual(state.activate(), .activate)
        XCTAssertEqual(state.mode, .intentional)
        XCTAssertNil(state.update(now: 2, insideTrigger: false, insideRegion: false))
        XCTAssertNil(state.update(now: 200, insideTrigger: false, insideRegion: false))
    }

    func testEscapeDoesNotImmediatelyReopenUnderStationaryPointer() {
        var state = NotchInteraction()
        _ = state.activate()
        XCTAssertEqual(state.dismiss(), .close)
        XCTAssertNil(state.update(now: 1, insideTrigger: true, insideRegion: true))
        XCTAssertNil(state.update(now: 2, insideTrigger: true, insideRegion: true))
        XCTAssertTrue(state.suppressedUntilTriggerExit)
        XCTAssertNil(state.update(now: 3, insideTrigger: false, insideRegion: false))
        XCTAssertFalse(state.suppressedUntilTriggerExit)
        XCTAssertNil(state.update(now: 4, insideTrigger: true, insideRegion: true))
        XCTAssertEqual(state.update(now: 4.13, insideTrigger: true, insideRegion: true), .showPassively)
    }

    func testKeyboardShortcutTogglesOpenHoverAndIntentionalStates() {
        var state = NotchInteraction()
        XCTAssertEqual(state.toggle(), .activate)
        XCTAssertEqual(state.toggle(), .close)
        _ = state.update(now: 0, insideTrigger: false, insideRegion: false)
        _ = state.update(now: 1, insideTrigger: true, insideRegion: true)
        _ = state.update(now: 1.13, insideTrigger: true, insideRegion: true)
        XCTAssertEqual(state.mode, .hover)
        XCTAssertEqual(state.toggle(), .close)
    }

    func testDragOpensBeforeDropAndBridgesTwoPanelDestinations() {
        var state = NotchInteraction()
        XCTAssertEqual(state.dragChanged(source: "mascot", active: true, now: 0), .showPassively)
        XCTAssertEqual(state.mode, .hover)
        XCTAssertNil(state.dragChanged(source: "mascot", active: false, now: 0.1))
        XCTAssertNil(state.update(now: 0.3, insideTrigger: false, insideRegion: false))
        XCTAssertNil(state.dragChanged(source: "body", active: true, now: 0.31))
        XCTAssertNil(state.update(now: 1, insideTrigger: false, insideRegion: false))
        XCTAssertNil(state.dragChanged(source: "mascot", active: false, now: 1.1))
        XCTAssertTrue(state.hasActiveDrag)
        XCTAssertNil(state.dragChanged(source: "body", active: false, now: 2))
        XCTAssertNil(state.update(now: 2.25, insideTrigger: false, insideRegion: false))
        XCTAssertEqual(state.update(now: 2.301, insideTrigger: false, insideRegion: false), .close)
    }

    func testDropPromotionStaysOpenAfterNativeDragFinishes() {
        var state = NotchInteraction()
        _ = state.dragChanged(source: "mascot", active: true, now: 0)
        XCTAssertEqual(state.activate(), .activate)
        _ = state.dragChanged(source: "mascot", active: false, now: 0.7)
        XCTAssertNil(state.update(now: 10, insideTrigger: false, insideRegion: false))
        XCTAssertEqual(state.mode, .intentional)
    }

    func testDismissedDragCannotReopenFromAnOldDestinationCallback() {
        var state = NotchInteraction()
        _ = state.dragChanged(source: "mascot", active: true, now: 0)
        _ = state.dismiss()
        XCTAssertNil(state.update(now: 1, insideTrigger: false, insideRegion: false))
        XCTAssertFalse(state.hasActiveDrag)
        XCTAssertEqual(state.mode, .closed)
        XCTAssertEqual(state.dragChanged(source: "body", active: true, now: 2), .showPassively)
    }

    func testMenuModalAndActiveEditorHoldPeekUntilProtectionEnds() {
        var state = NotchInteraction()
        XCTAssertNil(state.update(now: 0, insideTrigger: true, insideRegion: true, protected: true))
        XCTAssertNil(state.update(now: 1, insideTrigger: true, insideRegion: true, protected: true))
        XCTAssertNil(state.update(now: 2, insideTrigger: true, insideRegion: true))
        XCTAssertEqual(state.update(now: 2.13, insideTrigger: true, insideRegion: true), .showPassively)
        XCTAssertNil(state.update(now: 3, insideTrigger: false, insideRegion: false, protected: true))
        XCTAssertNil(state.update(now: 100, insideTrigger: false, insideRegion: false, protected: true))
        XCTAssertNil(state.update(now: 101, insideTrigger: false, insideRegion: false))
        XCTAssertEqual(state.update(now: 101.301, insideTrigger: false, insideRegion: false), .close)
    }

    func testPointerPullReachesTowardANearbyPointerAndSettlesWithoutWobble() {
        // Strongest close by, never past the pointer, nothing at the edge or out of range.
        XCTAssertEqual(NotchPull.targetDepth(distance: 0), 0)
        XCTAssertEqual(NotchPull.targetDepth(distance: NotchPull.radius), 0)
        for distance in stride(from: CGFloat(1), to: NotchPull.radius, by: 3) {
            let depth = NotchPull.targetDepth(distance: distance)
            XCTAssertGreaterThan(depth, 0)
            XCTAssertLessThan(depth, distance)
            XCTAssertLessThanOrEqual(depth, NotchPull.reach)
        }
        XCTAssertGreaterThan(NotchPull.targetDepth(distance: 20), NotchPull.targetDepth(distance: 60))

        let size = CGSize(width: 260, height: 32)
        let below = CGPoint(x: 130, y: 52)
        var pull = NotchPull()
        for _ in 0..<60 { pull = pull.stepped(toward: below, size: size, elapsed: 1.0 / 60) }
        XCTAssertEqual(pull.depth, NotchPull.targetDepth(distance: 20), accuracy: 0.05)
        XCTAssertEqual(pull.pointer, below)

        // Only the contour near the pointer yields; the top edge stays on the screen edge.
        let path = NotchPullShape(pull: pull, depth: pull.depth, cornerRadius: 10).path(in: CGRect(origin: .zero, size: size))
        XCTAssertEqual(path.boundingRect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxY, size.height + pull.depth, accuracy: 0.5)
        XCTAssertFalse(path.contains(CGPoint(x: 30, y: size.height + 2)))
        XCTAssertTrue(path.contains(CGPoint(x: 130, y: size.height + pull.depth / 2)))

        // Leaving releases it in place on a soft spring: no overshoot, back to rest.
        var previous = pull.depth
        for _ in 0..<90 {
            pull = pull.stepped(toward: CGPoint(x: 130, y: 400), size: size, elapsed: 1.0 / 60)
            XCTAssertLessThanOrEqual(pull.depth, previous)
            XCTAssertGreaterThanOrEqual(pull.depth, 0)
            XCTAssertEqual(pull.pointer, below)
            previous = pull.depth
        }
        XCTAssertEqual(pull, NotchPull(pointer: below))
        XCTAssertTrue(NotchPullShape(pull: pull, depth: pull.depth, cornerRadius: 10).path(in: CGRect(origin: .zero, size: size)).isEmpty)
    }
}
