import XCTest
@testable import NotchCompanion

/// Live activity, interactive glance, swipes, dozing eyes and the first-run hello.
final class LivingIslandTests: XCTestCase {
    private func physical(dots: Int = 0, live: CGFloat = 0) -> NotchGeometry {
        var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
                                     leftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                     rightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                     indicatorCount: dots)
        geometry.liveContentWidth = live
        geometry.liveSessionIDs = live > 0 ? ["live"] : []
        return geometry
    }

    private func external(dots: Int = 0, live: CGFloat = 0) -> NotchGeometry {
        var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0,
                                     leftArea: nil, rightArea: nil, indicatorCount: dots)
        geometry.liveContentWidth = live
        geometry.liveSessionIDs = live > 0 ? ["live"] : []
        return geometry
    }

    private func session(_ id: String, _ state: WorkState, startedSecondsAgo: Double = 60,
                         tools: [ToolActivity] = []) -> CompanionSession {
        var value = CompanionSession(id: id, runtimeID: "native-\(id)", title: id.capitalized, state: state,
                                     messages: [ChatMessage(role: "user", text: "Go",
                                                            createdAt: Date().addingTimeInterval(-startedSecondsAgo))],
                                     tools: tools)
        value.updatedAt = Date().addingTimeInterval(-startedSecondsAgo / 2)
        return value
    }

    // MARK: Live activity

    func testLiveActivityShowsEveryBusySessionNeedsYouFirst() {
        XCTAssertNil(LiveActivity.resolve(sessions: [session("idle", .idle), session("done", .finished)]))
        let older = session("older", .working, startedSecondsAgo: 600)
        let newer = session("newer", .working, startedSecondsAgo: 30,
                            tools: [ToolActivity(id: "t", name: "Bash", detail: "swift test")])
        let working = LiveActivity.resolve(sessions: [older, newer, session("idle", .idle)])
        XCTAssertEqual(working?.sessionIDs, ["newer", "older"])
        XCTAssertEqual(working?.items.first?.kind, .working)
        XCTAssertEqual(working?.items.first?.symbol, "terminal.fill")
        let asks = session("asks", .waiting, startedSecondsAgo: 900)
        let waiting = LiveActivity.resolve(sessions: [older, newer, asks])
        XCTAssertEqual(waiting?.sessionIDs, ["asks", "newer", "older"])
        XCTAssertEqual(waiting?.items.first?.kind, .waiting)
        XCTAssertEqual(waiting?.items.first?.symbol, "questionmark")
        let crowd = (0..<6).map { session("s\($0)", .working, startedSecondsAgo: Double(10 + $0)) }
        XCTAssertEqual(LiveActivity.resolve(sessions: crowd)?.items.count, LiveActivity.maxItems)
    }

    func testToolGlyphsMatchEachHarnessesNames() {
        let expectations: [(String, String)] = [
            ("terminal", "terminal.fill"), ("Bash", "terminal.fill"), ("commandExecution", "terminal.fill"),
            ("python", "terminal.fill"), ("read_file", "doc.text.fill"), ("Read", "doc.text.fill"),
            ("write_file", "pencil"), ("Edit", "pencil"), ("fileChange", "pencil"), ("apply_patch", "pencil"),
            ("Grep", "magnifyingglass"), ("Glob", "magnifyingglass"), ("web_search", "globe"),
            ("WebFetch", "globe"), ("browser_navigate", "globe"), ("delegate_task", "person.2.fill"),
            ("Task", "person.2.fill"), ("TodoWrite", "checklist"), ("mcpToolCall", "wrench.and.screwdriver.fill"),
            ("mcp_tools", "wrench.and.screwdriver.fill"), ("something_else", "gearshape.fill")
        ]
        for (name, symbol) in expectations {
            XCTAssertEqual(LiveActivity.symbol(forTool: name), symbol, name)
        }
        XCTAssertEqual(LiveActivity.tokens("commandExecution"), ["command", "execution"])
        XCTAssertEqual(LiveActivity.tokens("read_file"), ["read", "file"])
        XCTAssertEqual(LiveActivity.tokens("WebFetch"), ["web", "fetch"])
        // Phases without a tool.
        XCTAssertEqual(LiveActivity.symbol(for: session("think", .working)), "sparkles")
        var writing = session("write", .working)
        writing.messages.append(ChatMessage(role: "assistant", text: "Partial"))
        XCTAssertEqual(LiveActivity.symbol(for: writing), "text.alignleft")
    }

    func testGlyphRowWidthGrowsPerSessionAndHitsTheGlyphUnderThePointer() {
        func activity(_ count: Int) -> LiveActivity {
            LiveActivity(items: (0..<count).map { .init(sessionID: "s\($0)", title: "S", kind: .working, symbol: "sparkles") })
        }
        XCTAssertEqual(activity(1).contentWidth, activity(2).contentWidth)
        XCTAssertGreaterThan(activity(3).contentWidth, activity(2).contentWidth)
        XCTAssertEqual(activity(4).contentWidth - activity(3).contentWidth, LiveActivity.glyphSize + LiveActivity.spacing)
        // One glyph roughly mirrors the eyes' 58-point extension on a physical notch.
        let shoulder = physical(live: activity(1).contentWidth).restShoulderWidth
        XCTAssertGreaterThan(shoulder, 50)
        XCTAssertLessThan(shoulder, 80)
        let three = activity(3)
        XCTAssertEqual(three.sessionID(atDistanceFromEnd: 2), "s2")
        XCTAssertEqual(three.sessionID(atDistanceFromEnd: 25), "s1")
        XCTAssertEqual(three.sessionID(atDistanceFromEnd: 46), "s0")
        XCTAssertEqual(three.sessionID(atDistanceFromEnd: 200), "s0")
        XCTAssertEqual(three.sessionID(atDistanceFromEnd: -5), "s2")
    }

    func testLiveShoulderGrowsOnTheCameraSideAndKeepsOtherDots() {
        let plain = physical(dots: 1)
        let live = physical(dots: 1, live: 44)
        XCTAssertTrue(live.showsLiveActivity)
        XCTAssertEqual(live.collapsedFrame.minX, plain.collapsedFrame.minX)
        XCTAssertEqual(live.collapsedFrame.height, plain.collapsedFrame.height)
        XCTAssertGreaterThan(live.collapsedFrame.width, plain.collapsedFrame.width + 40)
        let span = live.liveSpan
        // After the camera, before the remaining dot, exactly the content's width.
        XCTAssertGreaterThanOrEqual(span.lowerBound, live.hardware.maxX - live.collapsedFrame.minX + NotchGeometry.liveCameraGap - 0.001)
        XCTAssertEqual(span.upperBound - span.lowerBound, 44, accuracy: 0.001)
        let dotLeft = live.indicatorLayout.center(at: 0, in: live.collapsedFrame.size).x - SessionIndicatorLayout.diameter / 2
        XCTAssertLessThan(span.upperBound, dotLeft)
        // Alone, the live content ends at the band's 12-point margin.
        let solo = physical(live: 44)
        XCTAssertEqual(solo.liveSpan.upperBound, solo.collapsedFrame.width - 12, accuracy: 0.001)
        // External bands widen modestly and stay centred.
        let externalLive = external(live: 44)
        XCTAssertEqual(externalLive.collapsedFrame.width, external().collapsedFrame.width + NotchGeometry.externalLiveGrowth)
        XCTAssertEqual(externalLive.collapsedFrame.midX, external().collapsedFrame.midX)
        XCTAssertGreaterThan(externalLive.liveSpan.lowerBound, externalLive.mascotWidth)
    }

    func testAnnouncementsTakeTheShoulderAndTheGlanceCoversTheLiveBand() {
        var geometry = physical(dots: 1, live: 44)
        geometry.glanceRows = 2
        XCTAssertTrue(geometry.glanceFrame.contains(geometry.collapsedFrame))
        XCTAssertEqual(NotchPresentation.resting(geometry).live, 1)
        geometry.announcing = true
        XCTAssertFalse(geometry.showsLiveActivity)
        XCTAssertEqual(NotchPresentation.resting(geometry).live, 0)
        XCTAssertEqual(NotchPresentation.resting(geometry).announce, 1)
    }

    func testLiveShoulderSpringsOpenAndRetractsGently() {
        let plain = NotchPresentation.resting(physical(dots: 1))
        let live = NotchPresentation.resting(physical(live: 44))
        let opening = UnifiedNotchMotion(from: plain, to: live, startedAt: 0)
        XCTAssertEqual(opening.curve, .spring)
        for step in 0...46 {
            let sample = opening.presentation(at: Double(step) * 0.01)
            // The eyes' side never moves; the live scalar stays within its endpoints.
            XCTAssertEqual(sample.frame.minX, plain.frame.minX, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(sample.live, 0)
            XCTAssertLessThanOrEqual(sample.live, 1)
        }
        let closing = UnifiedNotchMotion(from: live, to: plain, startedAt: 0)
        XCTAssertEqual(closing.curve, .easeOut)
        XCTAssertEqual(closing.duration, UnifiedNotchMotion.announcementCollapseDuration, accuracy: 0.0001)
        // An announcement replacing the live activity still springs.
        var announcing = physical(dots: 1, live: 44)
        announcing.announcing = true
        XCTAssertEqual(UnifiedNotchMotion(from: live, to: .resting(announcing), startedAt: 0).curve, .spring)
        XCTAssertEqual(UnifiedNotchMotion(from: .resting(announcing), to: live, startedAt: 0).curve, .spring)
    }

    // MARK: Interactive glance

    func testQuickRepliesOnlyForSimpleRequests() {
        let approval = PendingRequest(id: "a", kind: .approval, title: "Claude Code needs permission", detail: "ls",
                                      choices: ["once", "session", "deny"], sessionID: "native")
        let reply = GlanceQuickReply.make(for: approval)
        XCTAssertEqual(reply?.choices.map(\.value), ["deny", "once"])
        XCTAssertEqual(reply?.choices.map(\.label), ["Deny", "Allow once"])
        XCTAssertEqual(reply?.choices.map(\.primary), [false, true])
        // Without a one-time approval, the full card decides.
        XCTAssertNil(GlanceQuickReply.make(for: PendingRequest(id: "b", kind: .approval, title: "", detail: "",
                                                               choices: ["session", "deny"], sessionID: "native")))
        let short = PendingRequest(id: "c", kind: .clarification, title: "", detail: "Which first?",
                                   choices: ["The glance", "The aura"], sessionID: "native")
        XCTAssertEqual(GlanceQuickReply.make(for: short)?.choices.map(\.value), ["The glance", "The aura"])
        var multiple = short
        multiple.multiSelect = true
        XCTAssertNil(GlanceQuickReply.make(for: multiple))
        var openEnded = short
        openEnded.choices = []
        XCTAssertNil(GlanceQuickReply.make(for: openEnded))
        var long = short
        long.choices = ["A deliberately long option that keeps going", "Another fairly long option here"]
        XCTAssertNil(GlanceQuickReply.make(for: long))
        var many = short
        many.choices = ["A", "B", "C", "D", "E"]
        XCTAssertNil(GlanceQuickReply.make(for: many))
    }

    func testGlanceRowsCarryRepliesAndStopAndTheIslandMakesRoom() {
        let request = PendingRequest(id: "a", kind: .approval, title: "Hermes needs permission", detail: "rm build",
                                     choices: ["once", "deny"], sessionID: "native-asks")
        let entries = SessionDigest.entries(sessions: [session("asks", .waiting), session("busy", .working)],
                                            requests: [request])
        XCTAssertEqual(entries.map(\.id), ["asks", "busy"])
        XCTAssertEqual(entries[0].quickReply?.requestID, "a")
        XCTAssertFalse(entries[0].canStop)
        XCTAssertNil(entries[1].quickReply)
        XCTAssertTrue(entries[1].canStop)
        var geometry = physical()
        geometry.glanceRows = 2
        let plainHeight = geometry.glanceFrame.height
        geometry.glanceActionRows = 1
        XCTAssertEqual(geometry.glanceFrame.height, plainHeight + NotchGeometry.glanceActionHeight)
    }

    @MainActor func testGlanceAnswersAndStopsTheRightSessionWithoutOpeningIt() async throws {
        let transport = RecordingTransport()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-living-\(UUID().uuidString)/sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false, client: transport)
        defer {
            model.shutdown()
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        var asks = session("asks", .waiting)
        asks.runtimeID = "native-asks"
        var busy = session("busy", .working)
        busy.runtimeID = "native-busy"
        model.sessions = [asks, busy, CompanionSession(id: "current", title: "Current")]
        model.currentID = "current"
        model.requests = [PendingRequest(id: "a", kind: .approval, title: "Hermes needs permission", detail: "ls",
                                         choices: ["once", "deny"], sessionID: "native-asks")]
        var opened = 0
        model.activatePanel = { opened += 1 }
        model.answerFromGlance(requestID: "a", choice: "once")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.calls.first?.method, "approval.respond")
        XCTAssertEqual(transport.calls.first?.params["choice"] as? String, "once")
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(model.sessions.first { $0.id == "asks" }?.state, .working)
        model.stopFromGlance("busy")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.calls.last?.method, "session.interrupt")
        XCTAssertEqual(transport.calls.last?.params["session_id"] as? String, "native-busy")
        XCTAssertEqual(model.sessions.first { $0.id == "busy" }?.state, .interrupted)
        // Neither action selects or opens anything.
        XCTAssertEqual(model.currentID, "current")
        XCTAssertEqual(opened, 0)
    }

    // MARK: Press

    func testPressSqueezesTheIslandAboutItsCentreBelowTheScreenEdge() {
        let resting = NotchPresentation.resting(physical(dots: 1))
        let squeezed = resting.pressed
        XCTAssertEqual(squeezed.frame.midX, resting.frame.midX, accuracy: 0.0001)
        XCTAssertEqual(squeezed.frame.maxY, resting.frame.maxY, accuracy: 0.0001)
        XCTAssertEqual(squeezed.frame.height, resting.frame.height, "the resting band keeps the notch height")
        XCTAssertLessThan(squeezed.frame.width, resting.frame.width - 6)
        XCTAssertGreaterThan(squeezed.frame.width, resting.frame.width - 16)
        XCTAssertEqual(squeezed.progress, resting.progress)
        var geometry = physical(dots: 1)
        geometry.glanceRows = 2
        let glance = NotchPresentation.glance(geometry)
        XCTAssertLessThan(glance.pressed.frame.height, glance.frame.height)
        XCTAssertEqual(glance.pressed.frame.maxY, glance.frame.maxY, accuracy: 0.0001)
        XCTAssertGreaterThan(glance.pressed.frame.height, glance.frame.height - 10)
    }

    // MARK: Swipes

    func testSwipesFollowTheFingerAndActOncePerGesture() {
        var swipe = NotchSwipe()
        // Natural scrolling: a downward finger reports positive deltas.
        XCTAssertNil(swipe.update(began: true, ended: false, momentum: false, deltaY: 10, inverted: true, tier: .resting))
        XCTAssertEqual(swipe.update(began: false, ended: false, momentum: false, deltaY: 20, inverted: true, tier: .resting), .open)
        XCTAssertNil(swipe.update(began: false, ended: false, momentum: false, deltaY: 40, inverted: true, tier: .resting))
        XCTAssertNil(swipe.update(began: false, ended: true, momentum: false, deltaY: 0, inverted: true, tier: .expanded))
        // Classic scrolling reverses the reported sign, not the gesture.
        XCTAssertEqual(swipe.update(began: true, ended: false, momentum: false, deltaY: -30, inverted: false, tier: .glance), .open)
        XCTAssertEqual(swipe.update(began: true, ended: false, momentum: false, deltaY: 30, inverted: false, tier: .expanded), .close)
        XCTAssertEqual(swipe.update(began: true, ended: false, momentum: false, deltaY: -30, inverted: true, tier: .glance), .close)
        // Nothing to close at rest, nothing to open when open, and momentum never acts.
        XCTAssertNil(swipe.update(began: true, ended: false, momentum: false, deltaY: -30, inverted: true, tier: .resting))
        XCTAssertNil(swipe.update(began: true, ended: false, momentum: false, deltaY: 30, inverted: true, tier: .expanded))
        XCTAssertNil(swipe.update(began: true, ended: false, momentum: true, deltaY: 300, inverted: true, tier: .resting))
    }

    func testWritingWaveformSpeaksAsTextArrives() {
        var session = CompanionSession(state: .working, messages: [ChatMessage(role: "user", text: "Go"),
                                                                  ChatMessage(role: "assistant", text: "Hello")])
        session.runtimeID = "r"
        let item = LiveActivity.resolve(sessions: [session])?.items.first
        XCTAssertEqual(item?.symbol, LiveActivity.writingSymbol)
        XCTAssertEqual(item?.written, 5)
        session.tools = [ToolActivity(id: "t", name: "Bash", detail: "")]
        XCTAssertEqual(LiveActivity.resolve(sessions: [session])?.items.first?.written, 0)
        XCTAssertEqual(LiveActivity.voice(sinceText: 0), 1, accuracy: 0.001)
        XCTAssertLessThan(LiveActivity.voice(sinceText: 1.5), 0.3)
        XCTAssertGreaterThanOrEqual(LiveActivity.voice(sinceText: 100), 0.25)
        for step in 0..<200 {
            for index in 0..<3 {
                let height = LiveActivity.barHeight(index, time: Double(step) / 60, voice: 1)
                XCTAssertGreaterThanOrEqual(height, 2)
                XCTAssertLessThanOrEqual(height, 7)
            }
        }
        XCTAssertLessThanOrEqual(LiveActivity.barHeight(0, time: 0.3, voice: 0.25), 2 + 5 * 0.25 + 0.001)
    }

    func testWorkingHighlightsSweepThenRest() {
        let centres = (0..<180).map { WorkingShimmer.center(at: Double($0) / 100) }
        XCTAssertLessThan(centres.min()!, -0.3)
        XCTAssertGreaterThan(centres.max()!, 1.3, "the sweep rests off the trailing edge")
        let laps = (0..<400).map { WorkingRimLight.head(at: Double($0) / 100) }
        XCTAssertEqual(laps.min()!, 0)
        XCTAssertGreaterThan(laps.max()!, 1.1, "the light leaves the far side before its next lap")
    }

    // MARK: Personality

    func testOnlyACalmCompanionDozesAndItsEyesCloseAndBreathe() {
        XCTAssertTrue(CompanionMood.ready.canDoze)
        XCTAssertTrue(CompanionMood.done.canDoze)
        for mood in [CompanionMood.thinking, .working, .answering, .waiting, .failed] { XCTAssertFalse(mood.canDoze) }
        let asleep = EyeMotion.pose(.sleeping, expanded: false, time: 0, since: 10, reducedMotion: false)
        XCTAssertEqual(asleep.doze, 1)
        XCTAssertLessThan(asleep.height, 0.25)
        XCTAssertEqual(asleep.pointer, 0)
        XCTAssertEqual(EyeMotion.pose(.ready, expanded: false, time: 0, since: 10, reducedMotion: false).doze, 0)
        let breath = (0..<42).map { EyeMotion.pose(.sleeping, expanded: false, time: Double($0) / 10, since: 10, reducedMotion: false).gazeY }
        XCTAssertGreaterThan(breath.max()! - breath.min()!, 0.3)
        // Reduced motion keeps a still, closed pose.
        let still = (0..<42).map { EyeMotion.pose(.sleeping, expanded: false, time: Double($0) / 10, since: 10, reducedMotion: true).gazeY }
        XCTAssertEqual(Set(still).count, 1)
        XCTAssertEqual(CompanionMood(announcement: .hello), .done)
    }

    @MainActor func testWelcomeOpensOnceAndEndsWithHello() {
        let suite = "notch-living-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite)/sessions.json")
        let model = AppModel(storageURL: file, playsSounds: false, client: RecordingTransport(), preferences: preferences)
        let original = model.statusEffects
        defer {
            model.statusEffects = original
            model.shutdown()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        var opened = 0, dismissed = 0
        model.activatePanel = { opened += 1 }
        model.dismissPanel = { dismissed += 1 }
        model.statusEffects = true
        model.welcomeIfFirstLaunch()
        XCTAssertEqual(model.page, .welcome(step: 0))
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(preferences.bool(forKey: AppModel.welcomeKey))
        model.page = .session
        model.welcomeIfFirstLaunch()
        XCTAssertEqual(model.page, .session, "the welcome opens only once")

        // The chosen agent becomes the default and the untouched draft's harness.
        model.chooseWelcomeRuntime(.codex)
        XCTAssertEqual(model.defaultRuntime, .codex)
        XCTAssertEqual(model.current?.runtime, .codex)

        // An update preview closes the panel, then hands back to the same step.
        model.page = .welcome(step: 2)
        model.previewStatusEffect(title: "Sample update")
        XCTAssertEqual(dismissed, 1)
        model.clearAnnouncement(model.announcement!.id)
        XCTAssertEqual(opened, 2)
        XCTAssertEqual(model.page, .welcome(step: 2))
        // Settings' preview does not reopen the panel.
        model.page = .settings
        model.previewStatusEffect()
        model.clearAnnouncement(model.announcement!.id)
        XCTAssertEqual(opened, 2)

        // Finishing closes the panel and waves from the band, if status effects allow.
        model.page = .welcome(step: 3)
        model.finishWelcome()
        XCTAssertEqual(model.page, .session)
        XCTAssertEqual(model.announcement?.kind, .hello)
        XCTAssertEqual(model.announcement?.sessionID, AppModel.helloAnnouncementID)
        XCTAssertTrue(NotchAuraTimeline.duration(.hello, reducedMotion: false) > 1)
        model.clearAnnouncement(model.announcement!.id)
        model.statusEffects = false
        model.finishWelcome()
        XCTAssertNil(model.announcement)

        // Someone with conversations already is not welcomed, and is not asked again.
        preferences.removeObject(forKey: AppModel.welcomeKey)
        model.sessions[0].messages = [ChatMessage(role: "user", text: "Earlier work")]
        model.welcomeIfFirstLaunch()
        XCTAssertEqual(model.page, .session)
        XCTAssertTrue(preferences.bool(forKey: AppModel.welcomeKey))
    }
}

private final class RecordingTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    private(set) var calls: [(method: String, params: [String: Any])] = []
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        calls.append((method, params))
        return [:]
    }
}
