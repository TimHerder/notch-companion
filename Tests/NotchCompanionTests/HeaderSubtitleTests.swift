import XCTest
@testable import NotchCompanion

/// The full-session header's subtitle says what the transcript shows, never
/// "Connects when you send" for a session that worked or is working.
@MainActor final class HeaderSubtitleTests: XCTestCase {
    private let idle = "Connects when you send a message."
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func session(_ state: WorkState, outcome: WorkState? = nil, endedAgo: TimeInterval? = nil) -> CompanionSession {
        let prompt = ChatMessage(id: "prompt", role: "user", text: "Run the tests.", createdAt: now.addingTimeInterval(-42), turnID: "turn")
        var session = CompanionSession(state: state)
        session.runtime = .codex
        session.messages = [prompt]
        if let endedAgo { session.turnEndedAt[prompt.id] = now.addingTimeInterval(-endedAgo) }
        if let outcome { session.turnOutcome[prompt.id] = outcome }
        return session
    }

    private func subtitle(_ session: CompanionSession?, connected: Bool = false, message: String? = nil,
                          needsSetup: Bool = false) -> String {
        FullSessionView.subtitle(session, needsSetup: needsSetup, connected: connected,
                                 connectionMessage: message ?? idle, now: now)
    }

    func testLiveTurnsShowTheirStateNotTheConnectionHint() {
        XCTAssertEqual(subtitle(session(.working)), "Codex · Working for 0:42")
        XCTAssertEqual(subtitle(session(.waiting)), "Codex · Needs your answer")
    }

    func testEndedTurnsSayWhenAndHowTheyEnded() {
        XCTAssertEqual(subtitle(session(.finished, outcome: .finished, endedAgo: 150)), "Codex · Worked 2 min ago")
        XCTAssertEqual(subtitle(session(.failed, outcome: .failed, endedAgo: 7_300), connected: true, message: "Codex connected"),
                       "Codex · Failed 2 h ago")
        XCTAssertEqual(subtitle(session(.interrupted, outcome: .interrupted, endedAgo: 5)), "Codex · Stopped just now")
    }

    func testConnectHintOnlyBeforeAnythingRan() {
        var fresh = CompanionSession()
        fresh.runtime = .codex
        XCTAssertEqual(subtitle(fresh), idle)
        XCTAssertEqual(subtitle(fresh, connected: true, message: "Codex connected"), "Codex connected")
        XCTAssertEqual(subtitle(fresh, needsSetup: true), "Connect a harness in Settings.")
    }

    func testConnectionProblemShowsWhileIdleButNeverHidesLiveWork() {
        XCTAssertEqual(subtitle(session(.finished, endedAgo: 60), message: "Codex is not installed"), "Codex is not installed")
        XCTAssertEqual(subtitle(session(.working), message: "Codex is not installed"), "Codex · Working for 0:42")
    }

    func testStatesToActOnKeepTheirWord() {
        var unconfirmed = session(.failed)
        unconfirmed.pendingSubmission = PendingSubmission(id: "pending", draft: "Possibly delivered", userTurnCount: 1, attachmentIDs: [])
        XCTAssertEqual(NotchHeaderView.actionWord(unconfirmed), "Send unconfirmed")
        XCTAssertEqual(subtitle(unconfirmed), "Codex · Send unconfirmed")
        var unverified = session(.interrupted)
        unverified.nativeActivityUnverified = "Check native children"
        XCTAssertEqual(NotchHeaderView.actionWord(unverified), "Check native work")
        XCTAssertNil(NotchHeaderView.actionWord(session(.finished)))
        XCTAssertNil(NotchHeaderView.actionWord(session(.working)))
    }

    func testAgoReadsInWholeUnits() {
        XCTAssertEqual(FullSessionView.ago(-3), "just now")
        XCTAssertEqual(FullSessionView.ago(59), "just now")
        XCTAssertEqual(FullSessionView.ago(60), "1 min ago")
        XCTAssertEqual(FullSessionView.ago(3_599), "59 min ago")
        XCTAssertEqual(FullSessionView.ago(3_600), "1 h ago")
        XCTAssertEqual(FullSessionView.ago(2 * 86_400 + 5), "2 d ago")
    }
}
