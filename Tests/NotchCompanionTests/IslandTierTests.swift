import XCTest
@testable import NotchCompanion

/// Glance, announcement, and aura tiers on the one presentation clock.
final class IslandTierTests: XCTestCase {
    private func external(rows: Int = 3, dots: Int = 1) -> NotchGeometry {
        var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0,
                                     leftArea: nil, rightArea: nil, indicatorCount: dots)
        geometry.glanceRows = rows
        return geometry
    }

    private func physical(rows: Int = 3, dots: Int = 1) -> NotchGeometry {
        var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
                                     leftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                     rightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                     indicatorCount: dots)
        geometry.glanceRows = rows
        return geometry
    }

    // MARK: Geometry

    func testGlanceIsASlightlyLargerTopAnchoredIslandSizedToItsRows() {
        let geometry = external()
        let glance = geometry.glanceFrame
        XCTAssertEqual(glance.width, 420)
        // Header (32 + 4), three 44-point rows, New session (34), bottom (10).
        XCTAssertEqual(glance.height, 212)
        XCTAssertEqual(glance.maxY, geometry.screen.maxY)
        XCTAssertEqual(glance.midX, geometry.collapsedFrame.midX)
        XCTAssertTrue(glance.contains(geometry.collapsedFrame))
        XCTAssertLessThan(glance.width, geometry.expandedFrame.width)
        XCTAssertLessThan(glance.height, geometry.expandedFrame.height / 2)
        // No activity shows one New session row alone; more than three are capped.
        XCTAssertEqual(external(rows: 0).glanceFrame.height, 32 + 4 + 44 + 10)
        XCTAssertEqual(external(rows: 9).glanceFrame.height, glance.height)
    }

    func testPhysicalGlanceCoversTheCameraAndKeepsBandTextBesideIt() {
        let geometry = physical()
        let glance = geometry.glanceFrame
        XCTAssertTrue(glance.contains(geometry.collapsedFrame))
        XCTAssertLessThan(glance.minX, geometry.hardware.minX - 58)
        XCTAssertEqual(glance.maxY, geometry.screen.maxY)
        XCTAssertEqual(geometry.glanceCameraMaxX, geometry.hardware.maxX - glance.minX)
        // At least room for a compact summary to the right of the camera.
        XCTAssertGreaterThan(glance.maxX - geometry.hardware.maxX, 80)
    }

    func testGlanceCoversManyDotsAndClampsOnSmallScreens() {
        let crowded = physical(dots: 30)
        XCTAssertTrue(crowded.glanceFrame.contains(crowded.collapsedFrame))
        var small = NotchGeometry(screen: CGRect(x: -360, y: 0, width: 360, height: 400), topInset: 0,
                                  leftArea: nil, rightArea: nil, indicatorCount: 1)
        small.glanceRows = 3
        XCTAssertEqual(small.glanceFrame.minX, -360 + 12)
        XCTAssertEqual(small.glanceFrame.maxX, -12)
    }

    func testAnnouncementWidensOnlyTheRightShoulderAtTheSameHeight() {
        var geometry = physical()
        let resting = geometry.collapsedFrame
        geometry.announcing = true
        geometry.announcementWidth = 180
        let announced = geometry.collapsedFrame
        XCTAssertEqual(announced.height, resting.height)
        XCTAssertEqual(announced.minY, resting.minY)
        XCTAssertEqual(announced.minX, resting.minX)
        XCTAssertEqual(announced.width, resting.width + 190)
        let span = geometry.announcementLabelSpan
        // After the camera, before the dots, and as wide as the label needs.
        XCTAssertEqual(span.lowerBound, geometry.hardware.maxX - announced.minX + 10)
        XCTAssertGreaterThanOrEqual(span.upperBound - span.lowerBound, 180)
        let dotLeft = geometry.indicatorLayout.center(at: 0, in: announced.size).x - SessionIndicatorLayout.diameter / 2
        XCTAssertLessThan(span.upperBound, dotLeft)
        // Glance and expanded bounds ignore the announcement.
        var plain = geometry
        plain.announcing = false
        XCTAssertEqual(geometry.glanceFrame, plain.glanceFrame)
        XCTAssertEqual(geometry.expandedFrame, plain.expandedFrame)
    }

    func testAnnouncementLabelPutsTheTitleFirstAndTheMessageInTheRoomLeft() {
        let plain = NotchAnnouncement(kind: .finished, sessionID: "s", title: "Website accessibility review")
        // Icon and color carry the verb, so every kind measures alike.
        for kind in NotchAnnouncement.Kind.allCases {
            XCTAssertEqual(NotchAnnouncement(kind: kind, sessionID: "s", title: plain.title).labelWidth, plain.labelWidth)
        }
        XCTAssertEqual(NotchAnnouncement(kind: .failed, sessionID: "s", title: "Fix").labelWidth, 120, "short labels keep a minimum")
        // A short title leaves room, so the message follows in it and widens the band.
        let short = NotchAnnouncement(kind: .finished, sessionID: "s", title: "Notes", detail: "Drafted the changelog")
        XCTAssertTrue(short.bandShowsMessage)
        XCTAssertGreaterThan(short.labelWidth, NotchAnnouncement(kind: .finished, sessionID: "s", title: "Notes").labelWidth)
        XCTAssertLessThan(short.labelWidth, NotchAnnouncement.maxLabelWidth)
        let told = NotchAnnouncement(kind: .needsInput, sessionID: "s", title: "Plan the release",
                                     detail: "Which milestone should ship first: the glance or the aura?")
        XCTAssertTrue(told.bandShowsMessage)
        XCTAssertEqual(told.labelWidth, 230, "a long message truncates within the baseline cap")
        // A title that leaves under ~70 points drops the message instead of showing a stub.
        var long = plain
        long.detail = "Ready for review"
        XCTAssertFalse(long.bandShowsMessage)
        XCTAssertEqual(long.labelWidth, plain.labelWidth, "the band sizes to the whole title alone")
        XCTAssertLessThan(long.labelWidth, 230)
        let huge = NotchAnnouncement(kind: .needsInput, sessionID: "s",
                                     title: "Compare the implementation options for the release", detail: told.detail)
        XCTAssertFalse(huge.bandShowsMessage)
        XCTAssertEqual(huge.labelWidth, 230, "a long title truncates at the cap, never past it")
        // VoiceOver keeps the verb and the message the band left out.
        XCTAssertEqual(long.spoken, "Done: \(long.title). Ready for review")
        XCTAssertEqual(plain.spoken, "Done: Website accessibility review")
    }

    @MainActor func testPanelToastPutsTheTitleFirstToo() {
        let roomy = NotchAnnouncement(kind: .finished, sessionID: "s", title: "Website accessibility review",
                                      detail: "Option B keeps one presentation clock.")
        XCTAssertTrue(PanelToastView.showsMessage(roomy))
        let crowded = NotchAnnouncement(kind: .finished, sessionID: "s", title: "Compare the implementation options for the release",
                                        detail: roomy.detail)
        XCTAssertFalse(PanelToastView.showsMessage(crowded), "too little room beside the title: no stub")
        XCTAssertFalse(PanelToastView.showsMessage(NotchAnnouncement(kind: .finished, sessionID: "s", title: "Notes")))
    }

    func testExternalAnnouncementStaysCenteredAndVisiblyGrows() {
        var geometry = external()
        let resting = geometry.collapsedFrame
        geometry.announcing = true
        geometry.announcementWidth = 120
        XCTAssertEqual(geometry.collapsedFrame.width, resting.width + 48)
        XCTAssertEqual(geometry.collapsedFrame.midX, resting.midX)
        geometry.announcementWidth = 230
        let span = geometry.announcementLabelSpan
        XCTAssertGreaterThanOrEqual(span.upperBound - span.lowerBound, 230)
        XCTAssertEqual(span.lowerBound, 64)
    }

    // MARK: Motion

    func testGlanceOpensOnASpringThatSettlesExactlyAndKeepsScalarsBounded() {
        let geometry = physical()
        let motion = UnifiedNotchMotion(from: .resting(geometry), to: .glance(geometry), startedAt: 0)
        XCTAssertEqual(motion.curve, .spring)
        XCTAssertEqual(motion.duration, UnifiedNotchMotion.springDuration)
        var overshoot: CGFloat = 0
        for step in 0...92 {
            let sample = motion.presentation(at: Double(step) * 0.005)
            XCTAssertEqual(sample.frame.maxY, geometry.screen.maxY, accuracy: 0.0001)
            XCTAssertEqual(sample.progress, 0)
            XCTAssertGreaterThanOrEqual(sample.peek, 0)
            XCTAssertLessThanOrEqual(sample.peek, 1)
            overshoot = max(overshoot, sample.frame.height - geometry.glanceFrame.height)
        }
        // A light, island-like bounce: present but only a few points.
        XCTAssertGreaterThan(overshoot, 0.5)
        XCTAssertLessThan(overshoot, 8)
        XCTAssertEqual(motion.presentation(at: 0.46), .glance(geometry))
        XCTAssertTrue(motion.presentation(at: 0.2).glanceIsInteractive)
    }

    func testGlanceClosesWithEaseOutAndPromotesOnThePanelSpring() {
        let geometry = external()
        let closing = UnifiedNotchMotion(from: .glance(geometry), to: .resting(geometry), startedAt: 0)
        XCTAssertEqual(closing.curve, .easeOut)
        XCTAssertEqual(closing.duration, UnifiedNotchMotion.collapseDuration, accuracy: 0.0001)
        let promoting = UnifiedNotchMotion(from: .glance(geometry), to: .expanded(geometry), startedAt: 0)
        XCTAssertEqual(promoting.curve, .panelSpring)
        XCTAssertEqual(promoting.duration, UnifiedNotchMotion.panelSpringDuration, accuracy: 0.0001)
        let midway = promoting.presentation(at: 0.13)
        XCTAssertEqual(midway.progress + midway.peek, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(midway.frame.height, geometry.glanceFrame.height)
        XCTAssertEqual(promoting.presentation(at: 0.5), .expanded(geometry))
        XCTAssertEqual(NotchPresentation.glance(geometry).cornerRadius, 18)
    }

    func testAnnouncementOpensOnASpringAndRetractsGently() {
        var geometry = physical()
        let plain = NotchPresentation.resting(geometry)
        geometry.announcing = true
        let announced = NotchPresentation.resting(geometry)
        XCTAssertEqual(announced.announce, 1)
        let opening = UnifiedNotchMotion(from: plain, to: announced, startedAt: 0)
        XCTAssertEqual(opening.curve, .spring)
        // The camera-side edge never moves, even through the overshoot.
        for step in 0...46 { XCTAssertEqual(opening.presentation(at: Double(step) * 0.01).frame.minX, plain.frame.minX, accuracy: 0.0001) }
        let closing = UnifiedNotchMotion(from: announced, to: plain, startedAt: 0)
        XCTAssertEqual(closing.curve, .easeOut)
        XCTAssertEqual(closing.duration, UnifiedNotchMotion.announcementCollapseDuration, accuracy: 0.0001)
        XCTAssertEqual(closing.presentation(at: 1), plain)
    }

    func testDotRetargetAtRestKeepsItsOriginalTiming() {
        let one = NotchPresentation.resting(physical(dots: 1))
        let two = NotchPresentation.resting(physical(dots: 2))
        let motion = UnifiedNotchMotion(from: one, to: two, startedAt: 0)
        XCTAssertEqual(motion.curve, .easeOut)
        XCTAssertEqual(motion.duration, UnifiedNotchMotion.expansionDuration)
    }

    // MARK: Digest

    private func session(_ id: String, _ state: WorkState, minutesAgo: Double, messages: [ChatMessage] = [ChatMessage(role: "user", text: "Go")]) -> CompanionSession {
        var value = CompanionSession(id: id, runtimeID: "native-\(id)", title: id.capitalized, state: state, messages: messages)
        value.updatedAt = Date().addingTimeInterval(-minutesAgo * 60)
        return value
    }

    func testGlanceOrdersNeedsYouThenWorkThenUnreadThenRecent() {
        var read = session("read", .finished, minutesAgo: 1)
        read.acknowledgeResult()
        var archived = session("archived", .finished, minutesAgo: 0)
        archived.acknowledgeResult()
        archived.isArchived = true
        let sessions = [read, archived,
                        session("done", .finished, minutesAgo: 3),
                        session("broken", .failed, minutesAgo: 30),
                        session("busy", .working, minutesAgo: 9),
                        session("asks", .waiting, minutesAgo: 60),
                        CompanionSession(id: "draft", title: "New session")]
        let all = SessionDigest.entries(sessions: sessions, requests: [], limit: 10)
        XCTAssertEqual(all.map(\.id), ["asks", "busy", "broken", "done", "read"])
        XCTAssertEqual(all.map(\.status), [.needsInput, .working, .failed, .finished, .finished])
        XCTAssertEqual(all.map(\.unread), [true, true, true, true, false])
        XCTAssertEqual(SessionDigest.entries(sessions: sessions, requests: []).count, 3)
        let summary = GlanceSummary(sessions: sessions)
        XCTAssertEqual(summary, { var s = GlanceSummary(sessions: []); s.needsInput = 1; s.working = 1; s.unread = 2; return s }())
        XCTAssertTrue(GlanceSummary(sessions: [read]).isQuiet)
    }

    func testGlanceDetailsDescribeRealWork() {
        let request = PendingRequest(id: "q", kind: .clarification, title: "Hermes has a question",
                                     detail: "Ship  the\nglance first?", choices: [], sessionID: "native-asks")
        let asks = SessionDigest.entry(session("asks", .waiting, minutesAgo: 0), requests: [request])
        XCTAssertEqual(asks.detail, "Ship the glance first?")

        var tool = session("tool", .working, minutesAgo: 0)
        tool.tools = [ToolActivity(id: "t", name: "terminal", detail: "swift test\n--parallel")]
        XCTAssertEqual(SessionDigest.entry(tool, requests: []).detail, "Terminal · swift test --parallel")

        let started = Date().addingTimeInterval(-90)
        let thinking = SessionDigest.entry(session("think", .working, minutesAgo: 0,
                                                   messages: [ChatMessage(role: "user", text: "Hi", createdAt: started)]), requests: [])
        XCTAssertEqual(thinking.detail, "Thinking…")
        XCTAssertEqual(thinking.since, started)

        let writing = SessionDigest.entry(session("write", .working, minutesAgo: 0, messages: [
            ChatMessage(role: "user", text: "Hi"), ChatMessage(role: "assistant", text: "**Bold** start of an answer")]), requests: [])
        XCTAssertTrue(writing.streaming)
        XCTAssertEqual(writing.detail, "Bold start of an answer")

        var failed = session("fail", .failed, minutesAgo: 0)
        failed.agents = [ChildAgent(id: "c", title: "Check links", state: .failed, turnID: failed.latestUserTurnID)]
        XCTAssertEqual(SessionDigest.entry(failed, requests: []).detail, "Check links failed")

        let done = SessionDigest.entry(session("done", .finished, minutesAgo: 0, messages: [
            ChatMessage(role: "user", text: "Review"),
            ChatMessage(role: "assistant", text: "## Ready for review\nAll checks pass.")]), requests: [])
        XCTAssertEqual(done.detail, "Ready for review — All checks pass.")
    }

    func testCompactTimes() {
        XCTAssertEqual(SessionDigest.compactAge(10), "now")
        XCTAssertEqual(SessionDigest.compactAge(240), "4m")
        XCTAssertEqual(SessionDigest.compactAge(7_300), "2h")
        XCTAssertEqual(SessionDigest.compactAge(200_000), "2d")
        XCTAssertEqual(SessionDigest.elapsed(42), "0:42")
        XCTAssertEqual(SessionDigest.elapsed(723), "12:03")
        XCTAssertEqual(SessionDigest.elapsed(3_730), "1:02:10")
    }

    // MARK: Aura

    func testAuraIsDarkOutsideItsWindowAndBoundedWithin() {
        for kind in NotchAnnouncement.Kind.allCases {
            for reduced in [false, true] {
                let duration = NotchAuraTimeline.duration(kind, reducedMotion: reduced)
                XCTAssertTrue(NotchAuraTimeline.sample(kind, elapsed: -0.01, reducedMotion: reduced).isDark)
                XCTAssertTrue(NotchAuraTimeline.sample(kind, elapsed: duration, reducedMotion: reduced).isDark)
                var lit = false
                for step in 0..<Int(duration * 100) {
                    let s = NotchAuraTimeline.sample(kind, elapsed: Double(step) / 100, reducedMotion: reduced)
                    for value in [s.head, s.headGlow, s.trail, s.flash, s.ripple, s.rippleOpacity, s.bloom, s.energy] {
                        XCTAssertGreaterThanOrEqual(value, 0)
                        XCTAssertLessThanOrEqual(value, 1.0001)
                    }
                    if reduced {
                        XCTAssertEqual(s.head, 0)
                        XCTAssertEqual(s.rippleOpacity, 0)
                    }
                    lit = lit || s.flash > 0.5
                }
                XCTAssertTrue(lit, "\(kind) never lights the edge")
            }
        }
    }

    func testCompletionTracesTheEdgeBeforeItFlares() {
        let early = NotchAuraTimeline.sample(.finished, elapsed: 0.3, reducedMotion: false)
        XCTAssertGreaterThan(early.head, 0.1)
        XCTAssertLessThan(early.head, 0.9)
        XCTAssertLessThan(early.flash, 0.05)
        let traced = NotchAuraTimeline.sample(.finished, elapsed: NotchAuraTimeline.traceDuration, reducedMotion: false)
        XCTAssertEqual(traced.head, 1)
        XCTAssertGreaterThan(NotchAuraTimeline.sample(.finished, elapsed: 0.8, reducedMotion: false).flash, 0.95)
        XCTAssertGreaterThan(NotchAuraTimeline.sample(.finished, elapsed: 1.1, reducedMotion: false).rippleOpacity, 0)
        // A failure flickers, and the island shakes only briefly.
        XCTAssertNotEqual(UnifiedNotchMotion.shakeOffset(0.05), 0)
        XCTAssertEqual(UnifiedNotchMotion.shakeOffset(UnifiedNotchMotion.shakeDuration), 0)
        XCTAssertEqual(UnifiedNotchMotion.shakeOffset(0), 0)
        let swings = (1..<50).map { UnifiedNotchMotion.shakeOffset(Double($0) / 100) }
        XCTAssertLessThanOrEqual(swings.map(abs).max()!, 6)
        XCTAssertGreaterThan(abs(swings[2]), abs(swings[45]))
        XCTAssertLessThan(NotchAuraTimeline.sample(.failed, elapsed: 0.11, reducedMotion: false).flash, 0.5)
    }

    func testAuraOutlineFollowsTheSilhouetteEdge() {
        let halves = NotchAuraView.halves(notch: CGSize(width: 300, height: 32), radius: 10, margin: 40, inflate: 0)
        XCTAssertEqual(halves.count, 2)
        let left = halves[0].boundingRect
        let right = halves[1].boundingRect
        XCTAssertEqual(left.minX, 40, accuracy: 0.01)
        XCTAssertEqual(right.maxX, 340, accuracy: 0.01)
        XCTAssertEqual(left.maxY, 32, accuracy: 0.01)
        XCTAssertEqual(left.minY, 0, accuracy: 0.01)
        XCTAssertEqual(NotchAuraPanel.frame(around: CGRect(x: 100, y: 1000, width: 300, height: 32)),
                       CGRect(x: 60, y: 960, width: 380, height: 72))
    }

    // MARK: Model

    @MainActor private func makeModel() -> (AppModel, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-island-\(UUID().uuidString)/sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false, client: IslandTestTransport())
        model.sessions[0].runtimeID = "parent"
        model.sessions[0].title = "Release notes"
        return (model, file)
    }

    @MainActor func testResultsAnnounceTheirSessionOnlyWithStatusEffects() {
        let (model, file) = makeModel()
        let original = model.statusEffects
        defer {
            model.statusEffects = original
            model.shutdown()
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        model.statusEffects = true
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Done"])
        XCTAssertEqual(model.announcement?.kind, .finished)
        XCTAssertEqual(model.announcement?.title, "Release notes")
        XCTAssertEqual(model.announcement?.sessionID, model.sessions[0].id)
        let first = model.announcement!.id
        model.receive("approval.request", payload: ["session_id": "parent", "request_id": "r", "command": "ls"])
        XCTAssertEqual(model.announcement?.kind, .needsInput)
        model.clearAnnouncement(first)
        XCTAssertNotNil(model.announcement, "clearing a superseded announcement keeps the newer one")
        model.statusEffects = false
        XCTAssertNil(model.announcement)
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "Boom"])
        XCTAssertNil(model.announcement)
        // The dot and receipt behave as before regardless of effects.
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.failed])
    }

    @MainActor func testAnnouncementsSnapshotTheMessageTheMomentIsAbout() {
        let (model, file) = makeModel()
        let original = model.statusEffects
        defer {
            model.statusEffects = original
            model.shutdown()
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        model.statusEffects = true
        func turn(_ prompt: String, startedAgo: TimeInterval = 0) {
            model.sessions[0].messages.append(ChatMessage(role: "user", text: prompt, createdAt: Date().addingTimeInterval(-startedAgo)))
            model.receive("message.start", payload: ["session_id": "parent"])
        }
        // Finished: the answer, as one plain line, with the turn's work time.
        turn("Write the release notes.", startedAgo: 134)
        model.receive("message.complete", payload: ["session_id": "parent", "text": "## Notes\nShipped the glance and the aura."])
        XCTAssertEqual(model.announcement?.kind, .finished)
        XCTAssertEqual(model.announcement?.detail, "Notes — Shipped the glance and the aura.")
        XCTAssertEqual(model.announcement?.worked ?? 0, 134, accuracy: 5)
        // Needs input: the question itself.
        model.receive("clarify.request", payload: ["session_id": "parent", "request_id": "q", "question": "Which tag?\nv2 or v3"])
        XCTAssertEqual(model.announcement?.kind, .needsInput)
        XCTAssertEqual(model.announcement?.detail, "Which tag? v2 or v3")
        model.receive("clarify.expire", payload: ["session_id": "parent", "request_id": "q"])
        // Failed: the error event's reason, kept on the stage after the session moves on.
        turn("Tag it.")
        model.receive("session.error", payload: ["session_id": "parent", "message": "Rate limit reached.\nTry again at 14:00."])
        XCTAssertEqual(model.announcement?.kind, .failed)
        XCTAssertEqual(model.announcement?.detail, "Rate limit reached. Try again at 14:00.")
        model.sessions[0].state = .working
        XCTAssertEqual(StageContent.make(model.announcement!, sessions: model.sessions, requests: model.requests).detail,
                       "Rate limit reached. Try again at 14:00.", "never the live Thinking…")
        // A failed turn whose terminal event names no reason uses this turn's notice (Codex, ACP)…
        turn("Try again.")
        model.receive("runtime.notice", payload: ["session_id": "parent", "message": "The model is overloaded."])
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": ""])
        XCTAssertEqual(model.announcement?.detail, "The model is overloaded.")
        // …its own error field when it carries one (OpenClaw, Pi)…
        turn("Once more.")
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "", "error": "Provider unavailable"])
        XCTAssertEqual(model.announcement?.detail, "Provider unavailable")
        // …else this turn's last answer, never the prompt or an earlier turn's notice.
        turn("Last try.")
        model.receive("message.delta", payload: ["session_id": "parent", "text": "Tagged v3, pushing"])
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": "Tagged v3, pushing"])
        XCTAssertEqual(model.announcement?.detail, "Tagged v3, pushing")
        turn("Quiet failure.")
        model.receive("message.complete", payload: ["session_id": "parent", "status": "error", "text": ""])
        XCTAssertEqual(model.announcement?.detail, "Something went wrong")
        // The first-launch hello shows where to hover.
        XCTAssertEqual(AppModel.helloAnnouncement.title, "Hi!")
        XCTAssertEqual(AppModel.helloAnnouncement.detail, "Hover here to begin")
        XCTAssertEqual(AppModel.helloAnnouncement.spoken, "Hi! Hover here to begin", "its title is its verb, said once")
    }

    @MainActor func testApprovalStageShowsTheSameCommandOnceAnsweredAndSpeechStaysBounded() throws {
        let (model, file) = makeModel()
        let original = model.statusEffects
        defer {
            model.statusEffects = original
            model.shutdown()
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        model.statusEffects = true
        let heredoc = "cat <<'EOF' > notes.md\n" + String(repeating: "line of release notes\n", count: 300) + "EOF"
        model.receive("approval.request", payload: ["session_id": "parent", "request_id": "r", "command": heredoc])
        let asked = try XCTUnwrap(model.announcement)
        XCTAssertTrue(asked.isApproval)
        XCTAssertTrue(asked.detail.hasSuffix("line of release notes EOF"), "the snapshot keeps the whole command")
        XCTAssertLessThanOrEqual(asked.spoken.count, "Needs you: Release notes. ".count + NotchAnnouncement.spokenLimit,
                                 "VoiceOver hears a bounded command, like a failure's reason")
        let open = StageContent.make(asked, sessions: model.sessions, requests: model.requests)
        XCTAssertFalse(open.answered)
        // Answered: the stage keeps the same field for its 'Answer sent' moment.
        model.requests = []
        model.sessions[0].state = .working
        let landed = StageContent.make(asked, sessions: model.sessions, requests: model.requests)
        XCTAssertTrue(landed.answered)
        XCTAssertEqual(landed.detail, "Wants to run")
        XCTAssertEqual(landed.command, open.command, "the field does not change as the answer lands")
        XCTAssertEqual(landed.commandLines, 3)
        XCTAssertEqual(landed.commandFieldHeight, open.commandFieldHeight)
        // A question is not an approval.
        model.receive("clarify.request", payload: ["session_id": "parent", "request_id": "q", "question": "Which tag?"])
        XCTAssertEqual(model.announcement?.isApproval, false)
    }

    @MainActor func testSettingsPreviewClosesThePanelAndAnnouncesWithoutTouchingSessions() {
        let (model, file) = makeModel()
        let original = model.statusEffects
        defer {
            model.statusEffects = original
            model.shutdown()
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        let before = model.sessions
        var dismissed = 0
        var opened = 0
        model.dismissPanel = { dismissed += 1 }
        model.activatePanel = { opened += 1 }
        model.statusEffects = true
        model.previewStatusEffect()
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(model.announcement?.kind, .finished)
        XCTAssertEqual(model.sessions, before)
        // Clicking the previewed band simply opens the panel.
        model.notchPresentation.announce = 1
        model.openAnnouncedSession()
        XCTAssertEqual(opened, 1)
        XCTAssertNil(model.announcement)
        model.statusEffects = false
        model.previewStatusEffect()
        XCTAssertEqual(dismissed, 1)
        XCTAssertNil(model.announcement)
    }

    @MainActor func testPanelToastOpensItsSessionAndReadingIsScopedToTheOpenConversation() {
        let (model, file) = makeModel()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.sessions.append(CompanionSession(id: "other", title: "Other", state: .finished))
        let current = model.currentID!
        XCTAssertFalse(model.isReading(current), "a collapsed notch reads nothing")
        model.expanded = true
        XCTAssertTrue(model.isReading(current))
        model.page = .sessions
        XCTAssertFalse(model.isReading(current))
        model.page = .session
        var opened = 0
        model.activatePanel = { opened += 1 }
        model.panelToast = NotchAnnouncement(kind: .finished, sessionID: "other", title: "Other")
        model.openPanelToast()
        XCTAssertNil(model.panelToast)
        XCTAssertEqual(model.currentID, "other")
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(model.isReading("other"))
    }

    @MainActor func testGlanceNeverAcknowledgesAndRowsOpenTheirSession() {
        let (model, file) = makeModel()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.receive("message.complete", payload: ["session_id": "parent", "text": "Done"])
        model.sessions.append(CompanionSession(id: "other", title: "Other", state: .idle, messages: [ChatMessage(role: "user", text: "x")]))
        model.currentID = "other"
        model.glancing = true
        XCTAssertEqual(model.glanceEntries.first?.title, "Release notes")
        XCTAssertEqual(model.glanceEntries.first?.unread, true)
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
        var opened = 0
        model.activatePanel = { opened += 1 }
        model.openSessionFromNotch(model.sessions[0].id)
        XCTAssertEqual(model.currentID, model.sessions[0].id)
        XCTAssertEqual(model.page, .session)
        XCTAssertEqual(opened, 1)
        // Opening selects; only actually reading the expanded conversation acknowledges.
        XCTAssertEqual(model.sessionIndicators.map(\.status), [.finished])
    }

    @MainActor func testGlanceNewSessionReusesAnUntouchedDraftAndOpensIt() {
        let (model, file) = makeModel()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var opened = 0
        model.activatePanel = { opened += 1 }
        model.sessions[0].messages = [ChatMessage(role: "user", text: "Started")]
        model.startSessionFromNotch()
        XCTAssertEqual(model.sessions.count, 2)
        let draft = model.currentID
        XCTAssertNotEqual(draft, model.sessions[1].id)
        XCTAssertEqual(model.page, .session)
        XCTAssertEqual(opened, 1)
        model.selectSession(model.sessions[1].id)
        model.startSessionFromNotch()
        XCTAssertEqual(model.sessions.count, 2, "Repeated glance clicks reuse the empty draft")
        XCTAssertEqual(model.currentID, draft)
        XCTAssertEqual(opened, 2)
    }

    @MainActor func testGlanceCacheFollowsSessionAndRequestChanges() {
        let (model, file) = makeModel()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.sessions[0].state = .waiting
        model.sessions[0].messages = [ChatMessage(role: "user", text: "Go")]
        XCTAssertEqual(model.glanceEntries.first?.detail, "Needs your answer")
        model.requests = [PendingRequest(id: "q", kind: .clarification, title: "Q", detail: "Which one?", choices: [], sessionID: "parent")]
        XCTAssertEqual(model.glanceEntries.first?.detail, "Which one?")
        model.sessions[0].state = .working
        model.requests = []
        XCTAssertEqual(model.glanceEntries.first?.status, .working)
    }
}

private final class IslandTestTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
