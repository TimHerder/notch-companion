import XCTest
@testable import NotchCompanion

final class EyeMotionTests: XCTestCase {
    func testMoodComesFromRealSessionState() {
        var session = CompanionSession(state: .working, messages: [ChatMessage(role: "user", text: "Go")])
        XCTAssertEqual(CompanionMood.resolve(overall: .working, current: session), .thinking)
        session.tools = [ToolActivity(id: "t", name: "read_file", detail: "")]
        XCTAssertEqual(CompanionMood.resolve(overall: .working, current: session), .working)
        session.tools[0].state = .finished
        session.messages.append(ChatMessage(role: "assistant", text: "Done"))
        XCTAssertEqual(CompanionMood.resolve(overall: .working, current: session), .answering)
        XCTAssertEqual(CompanionMood.resolve(overall: .working, current: nil), .working)
        XCTAssertEqual(CompanionMood.resolve(overall: .waiting, current: session), .waiting)
        XCTAssertEqual(CompanionMood.resolve(overall: .interrupted, current: nil), .ready)
    }

    func testCollapsedWorkKeepsPointerTrackingThroughMoodChanges() {
        let moods: [CompanionMood] = [.ready, .thinking, .working, .answering]
        for mood in moods {
            for previous in moods {
                for reducedMotion in [false, true] {
                    for time in [0.0, 0.1, 0.4, 1.3, 7.9] {
                        let eyes = EyeMotion.expression(mood: mood, previous: previous, sinceMood: time,
                                                        expanded: false, time: time, feeding: 0,
                                                        sinceGlance: 0.3, sinceChomp: 100,
                                                        reducedMotion: reducedMotion)
                        XCTAssertEqual(eyes, EyeExpression(), "\(previous) → \(mood) at \(time)")
                    }
                }
            }
        }
    }

    func testExpandedWorkKeepsItsAttentionAndAnimation() {
        let thinking = EyeMotion.pose(.thinking, expanded: true, time: 0, since: 1, reducedMotion: false)
        XCTAssertEqual(thinking.pointer, 0)
        XCTAssertLessThan(thinking.gazeY, 0)
        for mood in [CompanionMood.thinking, .working] {
            XCTAssertNotEqual(EyeMotion.pose(mood, expanded: true, time: 0, since: 1, reducedMotion: false).gazeX,
                              EyeMotion.pose(mood, expanded: true, time: 0.5, since: 1, reducedMotion: false).gazeX)
        }
        for mood in [CompanionMood.working, .answering] {
            let eyes = EyeMotion.pose(mood, expanded: true, time: 0, since: 1, reducedMotion: false)
            XCTAssertEqual(eyes.pointer, 0)
            XCTAssertGreaterThan(eyes.gazeX, 0)
            XCTAssertGreaterThan(eyes.gazeY, 0)
        }
    }

    func testCompletionSmilesBrieflyThenSettles() {
        let smiling = EyeMotion.pose(.done, expanded: true, time: 0, since: 0.6, reducedMotion: false)
        XCTAssertEqual(smiling.smile, 1, accuracy: 0.001)
        XCTAssertEqual(EyeMotion.pose(.done, expanded: true, time: 0, since: 3, reducedMotion: false).smile, 0)
    }

    func testReducedMotionHoldsStaticPoses() {
        for time in [0.0, 0.4, 1.3, 7.9] {
            XCTAssertEqual(EyeMotion.pose(.working, expanded: true, time: time, since: time, reducedMotion: true),
                           EyeMotion.pose(.working, expanded: true, time: 0, since: 0, reducedMotion: true))
            XCTAssertEqual(EyeMotion.pose(.waiting, expanded: false, time: time, since: time, reducedMotion: true).hop, 0)
        }
        let chomp = EyeMotion.expression(mood: .ready, previous: .ready, sinceMood: 100, expanded: true, time: 0,
                                         feeding: 0, sinceGlance: 0.3, sinceChomp: 0.05, reducedMotion: true)
        XCTAssertEqual(chomp, EyeExpression())
    }

    func testMoodChangesBlendFromThePreviousPose() {
        let start = EyeMotion.expression(mood: .failed, previous: .ready, sinceMood: 0, expanded: false, time: 0,
                                         feeding: 0, sinceGlance: 100, sinceChomp: 100, reducedMotion: false)
        XCTAssertEqual(start, EyeExpression())
        let settled = EyeMotion.expression(mood: .failed, previous: .ready, sinceMood: 1, expanded: false, time: 0,
                                           feeding: 0, sinceGlance: 100, sinceChomp: 100, reducedMotion: false)
        XCTAssertEqual(settled.tilt, -16)
        XCTAssertEqual(settled.pointer, 0)
    }

    func testNoddingOffDroopsFluttersThenSettlesIntoTheDoze() {
        func eyes(_ since: TimeInterval, reduced: Bool = false) -> EyeExpression {
            EyeMotion.expression(mood: .sleeping, previous: .ready, sinceMood: since, expanded: false, time: 0,
                                 feeding: 0, sinceGlance: 100, sinceChomp: 100, reducedMotion: reduced)
        }
        XCTAssertEqual(eyes(0), EyeExpression())
        XCTAssertEqual(eyes(0.55).height, 0.42, accuracy: 0.01)
        XCTAssertEqual(eyes(0.55).doze, 0)
        XCTAssertGreaterThan(eyes(0.8).height, eyes(0.55).height, "lids flutter back open")
        XCTAssertEqual(eyes(EyeMotion.nodOffDuration), EyeMotion.pose(.sleeping, expanded: false, time: 0, since: 0, reducedMotion: false))
        XCTAssertEqual(eyes(0.55, reduced: true).doze, 1, "reduced motion closes at once")
    }

    func testWakingStartlesWideThenSettles() {
        func eyes(_ since: TimeInterval) -> EyeExpression {
            EyeMotion.expression(mood: .ready, previous: .sleeping, sinceMood: since, expanded: false, time: 0,
                                 feeding: 0, sinceGlance: 100, sinceChomp: 100, reducedMotion: false)
        }
        XCTAssertGreaterThan(eyes(0.2).height, 1.2)
        XCTAssertGreaterThan(eyes(0.2).hop, 0.9)
        XCTAssertEqual(eyes(0.2).doze, 0, accuracy: 0.01)
        XCTAssertEqual(eyes(EyeMotion.startleDuration), EyeExpression())
    }

    func testFinishingSparklesBesideTheEyesOneAfterAnother() {
        XCTAssertTrue(EyeMotion.sparkles(sinceDone: -1, reducedMotion: false).isEmpty)
        XCTAssertTrue(EyeMotion.sparkles(sinceDone: 0.3, reducedMotion: true).isEmpty)
        XCTAssertTrue(EyeMotion.sparkles(sinceDone: EyeMotion.sparkleDuration, reducedMotion: false).isEmpty)
        XCTAssertEqual(EyeMotion.sparkles(sinceDone: 0.1, reducedMotion: false).count, 1)
        XCTAssertEqual(EyeMotion.sparkles(sinceDone: 0.5, reducedMotion: false).count, 3)
        for step in 0..<110 {
            for sparkle in EyeMotion.sparkles(sinceDone: Double(step) / 100, reducedMotion: false) {
                // Inside the 58-point mascot extension and the resting band.
                XCTAssertLessThanOrEqual(abs(sparkle.x) + sparkle.radius, 19)
                XCTAssertLessThanOrEqual(abs(sparkle.y) + sparkle.radius, 11)
                XCTAssertGreaterThanOrEqual(sparkle.radius, 0)
            }
        }
    }

    func testFeedingWidensThenDropChompsAndSmiles() {
        func eyes(_ sinceChomp: TimeInterval) -> EyeExpression {
            EyeMotion.expression(mood: .ready, previous: .ready, sinceMood: 100, expanded: true, time: 0,
                                 feeding: 1, sinceGlance: 100, sinceChomp: sinceChomp, reducedMotion: false)
        }
        XCTAssertEqual(eyes(100).height, EyeMotion.feedingPose.height)
        XCTAssertLessThan(eyes(0.05).height, 0.2)
        XCTAssertLessThan(eyes(0.3).height, 0.2)
        XCTAssertEqual(eyes(0.8).smile, 1, accuracy: 0.001)
    }

    func testPokedEyesFlinchThenSmileWithABounceAndSettle() {
        func eyes(_ sincePoke: TimeInterval, reducedMotion: Bool = false) -> EyeExpression {
            EyeMotion.expression(mood: .ready, previous: .ready, sinceMood: 100, expanded: false, time: 0,
                                 feeding: 0, sinceGlance: 100, sinceChomp: 100, sincePoke: sincePoke,
                                 reducedMotion: reducedMotion)
        }
        XCTAssertLessThan(eyes(0.07).height, 0.4, "flinches shut")
        XCTAssertEqual(eyes(0.07).pointer, 0)
        XCTAssertEqual(eyes(0.4).smile, 1, accuracy: 0.001)
        XCTAssertGreaterThan(eyes(0.35).hop, 0.9)
        XCTAssertEqual(eyes(EyeMotion.pokeDuration), EyeExpression())
        XCTAssertEqual(eyes(0.4, reducedMotion: true), EyeExpression())
    }
}
