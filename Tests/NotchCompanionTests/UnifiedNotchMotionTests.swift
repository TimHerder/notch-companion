import XCTest
@testable import NotchCompanion

final class UnifiedNotchMotionTests: XCTestCase {
    private func geometry() -> NotchGeometry {
        NotchGeometry(screen: CGRect(x: -1920, y: 120, width: 1920, height: 1080),
                      topInset: 0, leftArea: nil, rightArea: nil)
    }

    func testRestingPresentationHasOnlyVisibleNotchBounds() {
        let geometry = geometry()
        let resting = NotchPresentation.resting(geometry)
        XCTAssertEqual(resting.frame, geometry.collapsedFrame)
        XCTAssertEqual(resting.size, CGSize(width: 258, height: 32))
        XCTAssertEqual(resting.progress, 0)
        XCTAssertEqual(resting.bandHeight, 32)
        XCTAssertEqual(resting.bodyVisibleHeight, 0)
        XCTAssertFalse(resting.contentIsInteractive)
        XCTAssertFalse(resting.contains(CGPoint(x: 100, y: 33)))
    }

    func testOneProgressKeepsWindowHeaderAndConversationRevealInLockstepWhileTheWidthTrails() {
        let geometry = geometry()
        let motion = UnifiedNotchMotion(from: .resting(geometry), to: .expanded(geometry), startedAt: 5)
        XCTAssertEqual(motion.curve, .panelSpring)
        var previous: CGFloat = 0
        var overshoot: CGFloat = 0
        for step in 0...60 {
            let sample = motion.presentation(at: 5 + Double(step) / 60 * motion.duration)
            XCTAssertEqual(sample.frame.maxY, geometry.screen.maxY, accuracy: 0.00001)
            XCTAssertEqual(sample.frame.midX, geometry.collapsedFrame.midX, accuracy: 0.00001)
            XCTAssertEqual(sample.bandHeight, 32 + 32 * sample.progress, accuracy: 0.00001)
            XCTAssertGreaterThanOrEqual(sample.progress, previous)
            XCTAssertLessThanOrEqual(sample.progress, 1)
            if sample.progress < 1 {
                // Until the spring first reaches the panel, one value drives the
                // height and reveal; the width trails it, so the island stretches.
                XCTAssertLessThanOrEqual(sample.frame.width, 258 + 302 * sample.progress + 0.00001)
                XCTAssertEqual(sample.frame.height, 32 + 512 * sample.progress, accuracy: 0.00001)
                XCTAssertEqual(sample.bodyVisibleHeight, 480 * sample.progress, accuracy: 0.00001)
            } else {
                // Then only the outline breathes past the panel, by a few points.
                XCTAssertGreaterThanOrEqual(sample.frame.height, 544 - 0.00001)
                overshoot = max(overshoot, sample.frame.height - 544)
            }
            XCTAssertLessThan(sample.frame.width, 560 * 1.02)
            previous = sample.progress
        }
        XCTAssertGreaterThan(overshoot, 2)
        XCTAssertLessThan(overshoot, 544 * 0.02)
        XCTAssertEqual(motion.presentation(at: 6), .expanded(geometry))
    }

    private func physical() -> NotchGeometry {
        NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
                      leftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                      rightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
    }

    func testLaunchPopsADropWithTheEyesInItsMiddle() {
        for geometry in [geometry(), physical()] {
            let hello = NotchPresentation.hello(geometry)
            let seed = NotchPresentation.launchSeed(geometry)
            XCTAssertEqual(seed.frame.maxY, geometry.screen.maxY)
            // It emerges from the physical notch itself, bare and with the eyes
            // behind it, or from a bead on the top edge.
            if geometry.hasHardware {
                XCTAssertEqual(seed.frame, geometry.hardware)
                XCTAssertLessThan(seed.restingEyeCenter(geometry).y + 8, geometry.bandHeight)
            } else {
                XCTAssertEqual(seed.frame.height, 1)
            }
            XCTAssertEqual(seed.flare, 0)
            XCTAssertEqual(seed.frame.midX, hello.frame.midX, accuracy: 0.0001)
            XCTAssertGreaterThan(hello.frame.height, geometry.bandHeight + 20)
            // The eyes sit in the middle of the drop, below any camera.
            let eyes = hello.restingEyeCenter(geometry)
            XCTAssertEqual(eyes.x, hello.frame.width / 2, accuracy: 0.0001)
            XCTAssertGreaterThan(eyes.y, geometry.hasHardware ? geometry.bandHeight + 8 : hello.frame.height / 2 - 0.0001)
            let motion = UnifiedNotchMotion(from: seed, to: hello, startedAt: 0, curve: .liquid)
            XCTAssertEqual(motion.duration, UnifiedNotchMotion.liquidDuration)
            var stretched = false
            for step in 0...140 {
                let sample = motion.presentation(at: Double(step) * 0.01)
                XCTAssertEqual(sample.frame.maxY, geometry.screen.maxY, accuracy: 0.0001)
                XCTAssertEqual(sample.frame.midX, hello.frame.midX, accuracy: 0.0001)
                // It stretches past the drop (tall and narrow first, from a bead).
                if sample.frame.height > hello.frame.height + 3
                    && (geometry.hasHardware || sample.frame.width < hello.frame.width * 0.8) { stretched = true }
                XCTAssertGreaterThanOrEqual(sample.frame.width, seed.frame.width - 0.0001)
            }
            XCTAssertTrue(stretched)
            XCTAssertEqual(motion.presentation(at: 2), hello)
        }
    }

    func testHelloSpreadsBeforeItIsDrawnIntoTheBandAndTheEyesStayClearOfTheCamera() {
        let geometry = physical()
        let hello = NotchPresentation.hello(geometry)
        let motion = UnifiedNotchMotion(from: hello, to: .resting(geometry), startedAt: 0, curve: .liquid)
        var spreadFirst = false
        for step in 0...140 {
            let sample = motion.presentation(at: Double(step) * 0.01)
            XCTAssertEqual(sample.frame.maxY, geometry.screen.maxY, accuracy: 0.0001)
            // Never shorter than the band, which would bare the camera's edge.
            XCTAssertGreaterThanOrEqual(sample.frame.height, geometry.bandHeight - 0.0001)
            if sample.frame.width > geometry.collapsedFrame.width - 4 && sample.frame.height > hello.frame.height - 4 { spreadFirst = true }
            // The eyes (about 12 points either side at hello size) never pass behind the camera.
            let eyes = sample.restingEyeCenter(geometry)
            let x = sample.frame.minX + eyes.x
            if eyes.y - 8 < geometry.bandHeight {
                XCTAssertFalse(x + 12 > geometry.hardware.minX && x - 12 < geometry.hardware.maxX, "t = \(Double(step) * 0.01)")
            }
        }
        XCTAssertTrue(spreadFirst)
        XCTAssertEqual(motion.presentation(at: 2), .resting(geometry))
        XCTAssertEqual(NotchPresentation.resting(geometry).restingEyeCenter(geometry), CGPoint(x: 29, y: geometry.eyeCenterY(progress: 0)))
    }

    func testFlaresFormWithTheDropAndGrowWithinTheWindowMargin() {
        let geometry = geometry()
        XCTAssertLessThan(NotchPresentation.launchSeed(geometry).flare, 1)
        let resting = NotchPresentation.resting(geometry).flare
        XCTAssertGreaterThan(resting, 0)
        for open in [NotchPresentation.glance(geometry), .stage(geometry), .expanded(geometry)] {
            XCTAssertGreaterThan(open.flare, resting)
            XCTAssertLessThanOrEqual(open.flare, NotchPresentation.flareMargin)
        }
    }

    func testCollapseFinishesAtRestWithoutAnInvisibleConversationWindow() {
        let geometry = geometry()
        let motion = UnifiedNotchMotion(from: .expanded(geometry), to: .resting(geometry), startedAt: 2)
        XCTAssertEqual(motion.presentation(at: 2), .expanded(geometry))
        let finished = motion.presentation(at: 3)
        XCTAssertEqual(finished, .resting(geometry))
        XCTAssertEqual(finished.frame.height, finished.bandHeight)
        XCTAssertFalse(finished.contains(CGPoint(x: 129, y: 100)))
    }

    func testReversalStartsAtEveryCurrentPresentationProperty() {
        let geometry = geometry()
        let opening = UnifiedNotchMotion(from: .resting(geometry), to: .expanded(geometry), startedAt: 1)
        let live = opening.presentation(at: 1.16)
        let closing = UnifiedNotchMotion(from: live, to: .resting(geometry), startedAt: 1.16)
        XCTAssertEqual(closing.presentation(at: 1.16), live)
        let liveAgain = closing.presentation(at: 1.23)
        let reopening = UnifiedNotchMotion(from: liveAgain, to: .expanded(geometry), startedAt: 1.23)
        XCTAssertEqual(reopening.presentation(at: 1.23), liveAgain)
        XCTAssertEqual(reopening.presentation(at: 2), .expanded(geometry))
        XCTAssertGreaterThan(liveAgain.progress, 0)
        XCTAssertLessThan(liveAgain.progress, live.progress)
    }

    func testOpenBecomesInteractiveWithinQuarterSecondAndCloseSettlesSooner() {
        let geometry = geometry()
        let opening = UnifiedNotchMotion(from: .resting(geometry), to: .expanded(geometry), startedAt: 1)
        XCTAssertFalse(opening.presentation(at: 1.12).contentIsInteractive)
        XCTAssertTrue(opening.presentation(at: 1.24).contentIsInteractive)
        XCTAssertEqual(opening.duration, UnifiedNotchMotion.panelSpringDuration)
        XCTAssertTrue(opening.isComplete(at: 1.5))
        let closing = UnifiedNotchMotion(from: .expanded(geometry), to: .resting(geometry), startedAt: 2)
        XCTAssertTrue(closing.isComplete(at: 2.21))
        XCTAssertEqual(closing.presentation(at: 2.21), .resting(geometry))
    }

    func testEarlyReversalClosesWithoutWaitingForAFullMorph() {
        let geometry = geometry()
        let opening = UnifiedNotchMotion(from: .resting(geometry), to: .expanded(geometry), startedAt: 1)
        let live = opening.presentation(at: 1.02)
        let closing = UnifiedNotchMotion(from: live, to: .resting(geometry), startedAt: 1.02)
        XCTAssertEqual(closing.presentation(at: 1.02), live)
        XCTAssertTrue(closing.isComplete(at: 1.07))
        XCTAssertEqual(closing.presentation(at: 1.07), .resting(geometry))
    }

    func testGeometryRetargetCanAnimateAtTheSameExpansionProgress() {
        let original = NotchPresentation.expanded(geometry())
        var resized = original
        resized.frame.size.width += 20
        resized.frame.origin.x -= 10
        let motion = UnifiedNotchMotion(from: original, to: resized, startedAt: 1)
        XCTAssertFalse(motion.isComplete(at: 1))
        XCTAssertEqual(motion.presentation(at: 1), original)
        let midway = motion.presentation(at: 1 + motion.duration / 2)
        XCTAssertGreaterThan(midway.frame.width, original.frame.width)
        XCTAssertLessThan(midway.frame.width, resized.frame.width)
        XCTAssertEqual(midway.progress, 1)
        XCTAssertEqual(motion.presentation(at: 2), resized)
    }

    func testReducedMotionCanSnapAllPresentationPropertiesTogether() {
        let geometry = geometry()
        let motion = UnifiedNotchMotion(from: .resting(geometry), to: .expanded(geometry), startedAt: 1, duration: 0)
        XCTAssertTrue(motion.isComplete(at: 1))
        XCTAssertEqual(motion.presentation(at: 1), .expanded(geometry))
    }

    func testHitShapeHasSquareTopRoundedBottomAndNoOffscreenContent() {
        let expanded = NotchPresentation.expanded(geometry())
        XCTAssertTrue(expanded.contains(CGPoint(x: 0, y: 0)))
        XCTAssertTrue(expanded.contains(CGPoint(x: 559, y: 0)))
        XCTAssertFalse(expanded.contains(CGPoint(x: 1, y: 543)))
        XCTAssertFalse(expanded.contains(CGPoint(x: 559, y: 543)))
        XCTAssertTrue(expanded.contains(CGPoint(x: 280, y: 543)))
        XCTAssertFalse(expanded.contains(CGPoint(x: -1, y: 200)))
        XCTAssertFalse(expanded.contains(CGPoint(x: 560, y: 200)))
        XCTAssertFalse(expanded.contains(CGPoint(x: 280, y: 544)))
        XCTAssertTrue(expanded.contentIsInteractive)
        XCTAssertEqual(expanded.cornerRadius, 22)
    }
}
