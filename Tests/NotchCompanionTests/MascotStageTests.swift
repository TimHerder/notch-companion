import AppKit
import XCTest
@testable import NotchCompanion

/// The mascot stage tier, the clip clock, and the rendered assets' contract.
final class MascotStageTests: XCTestCase {
    private func physical() -> NotchGeometry {
        NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
                      leftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                      rightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32), indicatorCount: 2)
    }

    private func external() -> NotchGeometry {
        NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0,
                      leftArea: nil, rightArea: nil, indicatorCount: 1)
    }

    // MARK: Geometry and motion

    func testStageIsALargerTopAnchoredIslandCoveringTheBand() {
        for geometry in [physical(), external()] {
            let stage = geometry.stageFrame
            XCTAssertEqual(stage.width, NotchGeometry.stageWidth)
            XCTAssertEqual(stage.height, geometry.bandHeight + NotchGeometry.mascotStageBodyHeight)
            XCTAssertEqual(stage.maxY, geometry.screen.maxY)
            XCTAssertTrue(stage.contains(geometry.collapsedFrame))
            XCTAssertLessThan(stage.height, geometry.expandedFrame.height / 2)
            var measured = geometry
            measured.stageBodyHeight = 192
            XCTAssertEqual(measured.stageFrame.height, geometry.bandHeight + 192)
            XCTAssertEqual(measured.stageFrame.maxY, stage.maxY, "taller content grows it downward")
            measured.stageBodyHeight = 64
            XCTAssertEqual(measured.stageFrame.width, stage.width, "only the height follows the content")
            XCTAssertTrue(measured.stageFrame.contains(geometry.collapsedFrame), "a short stage still covers the band")
        }
        XCTAssertEqual(physical().stageFrame.midX, physical().glanceFrame.midX, "centred like the glance")
    }

    func testStageSpringsOpenRetractsGentlyAndPromotesOnThePanelSpring() {
        let geometry = physical()
        let opening = UnifiedNotchMotion(from: .resting(geometry), to: .stage(geometry), startedAt: 0)
        XCTAssertEqual(opening.curve, .spring)
        XCTAssertEqual(opening.duration, UnifiedNotchMotion.springDuration)
        for step in 0...46 {
            let sample = opening.presentation(at: Double(step) / 100)
            XCTAssertTrue((0...1).contains(sample.stage))
            XCTAssertEqual(sample.progress, 0)
        }
        XCTAssertEqual(opening.presentation(at: 1), .stage(geometry))
        let retracting = UnifiedNotchMotion(from: .stage(geometry), to: .resting(geometry), startedAt: 0)
        XCTAssertEqual(retracting.curve, .easeOut)
        XCTAssertEqual(retracting.duration, UnifiedNotchMotion.announcementCollapseDuration, accuracy: 0.001)
        XCTAssertEqual(UnifiedNotchMotion(from: .stage(geometry), to: .expanded(geometry), startedAt: 0).curve, .panelSpring)
        XCTAssertEqual(UnifiedNotchMotion(from: .stage(geometry), to: .glance(geometry), startedAt: 0).curve, .spring)
        XCTAssertGreaterThan(NotchPresentation.stage(geometry).cornerRadius, NotchPresentation.glance(geometry).cornerRadius)
    }

    // MARK: The mascot's clock

    private let frames = ["emerge": 24, "idle": 60, "work": 36, "done": 58, "wave": 55, "wait": 48, "fail": 48, "sad": 60]

    func testActsFollowTheEyesMoodAndOnlyRestartForNewMotion() {
        XCTAssertEqual(MascotAct(mood: .done, announcement: nil).entry, "done")
        XCTAssertEqual(MascotAct(mood: .waiting, announcement: nil).loop, "wait")
        XCTAssertEqual(MascotAct(mood: .answering, announcement: nil), .busy)
        XCTAssertEqual(MascotAct(mood: .done, announcement: .hello), .greeting)
        XCTAssertEqual(MascotAct(mood: .failed, announcement: nil).loop, "sad")
        let celebrating = MascotPerformance(.celebrating, start: 10)
        XCTAssertFalse(celebrating.restarts(for: .calm), "a finished leap settles into idle without a cut")
        XCTAssertTrue(celebrating.restarts(for: .busy))
        XCTAssertTrue(MascotPerformance(.calm, start: 0).restarts(for: .asking))
    }

    func testMascotEmergesThenPlaysItsEntranceThenLoops() {
        let fps = 24.0
        let performance = MascotPerformance(.celebrating, start: 100.05)
        func frame(_ time: TimeInterval) -> MascotTimeline.Frame {
            MascotTimeline.frame(performance, appeared: 100, at: time, frames: frames, fps: fps, reducedMotion: false)
        }
        XCTAssertEqual(frame(100), .init(clip: "emerge", index: 0))
        XCTAssertEqual(frame(100.5), .init(clip: "emerge", index: 12))
        // The entrance waits for the emerge to finish rather than being cut short.
        XCTAssertEqual(frame(101.0), .init(clip: "done", index: 0))
        XCTAssertEqual(frame(101.0 + 57.5 / fps), .init(clip: "done", index: 57))
        XCTAssertEqual(frame(101.0 + 58.5 / fps), .init(clip: "idle", index: 0))
        XCTAssertEqual(frame(101.0 + (58 + 60 + 3.5) / fps), .init(clip: "idle", index: 3), "loops wrap")
        XCTAssertEqual(MascotTimeline.frame(performance, appeared: 100, at: 100.5, frames: frames, fps: fps, reducedMotion: true),
                       .init(clip: "idle", index: 0), "reduced motion holds the loop's first pose")
    }

    func testChangesAfterEmergingCrossfadeAndEarlierOnesDoNot() {
        let emerge = 1.0
        let earlier = MascotPerformance(.calm, start: 0)
        let during = MascotPerformance(.busy, start: 100.4)
        XCTAssertNotEqual(earlier, during)
        XCTAssertEqual(MascotTimeline.fade(replaced: true, changed: during.start, appeared: 100, at: 100.45,
                                           emergeLength: emerge, reducedMotion: false), 0)
        let later = MascotPerformance(.busy, start: 105)
        XCTAssertEqual(MascotTimeline.fade(replaced: true, changed: later.start, appeared: 100, at: 105,
                                           emergeLength: emerge, reducedMotion: false), 1)
        XCTAssertEqual(MascotTimeline.fade(replaced: true, changed: later.start, appeared: 100, at: 105 + MascotTimeline.crossfade,
                                           emergeLength: emerge, reducedMotion: false), 0)
        XCTAssertEqual(MascotTimeline.fade(replaced: true, changed: later.start, appeared: 100, at: 105,
                                           emergeLength: emerge, reducedMotion: true), 0)
        XCTAssertEqual(MascotTimeline.fade(replaced: false, changed: later.start, appeared: 100, at: 105,
                                           emergeLength: emerge, reducedMotion: false), 0)
    }

    // MARK: Layout

    func testMascotStandsInTheHeaderOrOnTheStageAndGlidesBetween() {
        let geometry = physical()
        let ground: CGFloat = 0.9
        let header = MascotLayout.headerFigure(geometry, ground: ground)
        let stage = MascotLayout.stageFigure(geometry, ground: ground)
        XCTAssertEqual(header.minY + ground * header.height, geometry.expandedBandHeight - 2, accuracy: 0.001)
        XCTAssertLessThan(header.maxX, 20 + 18 * EyesDrawing.expandedScale + 16 + 10, "beside the header's status")
        XCTAssertEqual(stage.minY + ground * stage.height, geometry.stageFrame.height - 10, accuracy: 0.001)
        XCTAssertLessThanOrEqual(stage.maxX, MascotLayout.stageColumn + 6)
        XCTAssertEqual(MascotLayout.figure(.stage(geometry), geometry: geometry, ground: ground, staging: true), stage)
        XCTAssertEqual(MascotLayout.figure(.expanded(geometry), geometry: geometry, ground: ground, staging: false), header)
        var handover = NotchPresentation.stage(geometry)
        handover.progress = 0.5
        handover.stage = 0.5
        let midway = MascotLayout.figure(handover, geometry: geometry, ground: ground, staging: false)
        XCTAssertEqual(midway.width, (header.width + stage.width) / 2, accuracy: 0.001)
        let scene = MascotLayout.scene(.resting(geometry), geometry: geometry, ground: ground, staging: false, expanded: false)
        XCTAssertEqual(scene.reveal, 0)
        XCTAssertEqual(scene.restCenter, CGPoint(x: geometry.mascotWidth / 2, y: geometry.eyeCenterY(progress: 0)))
    }

    // MARK: Stage content

    @MainActor func testStageContentNamesTheMomentAndAnswersInPlace() {
        var session = CompanionSession(id: "plan", runtimeID: "live", title: "Plan the release", state: .waiting,
                                       messages: [ChatMessage(role: "user", text: "Draft it.")])
        let request = PendingRequest(id: "r", kind: .approval, title: "Permission", detail: "Run swift test",
                                     choices: ["once", "deny"], sessionID: "live")
        let asking = NotchAnnouncement(kind: .needsInput, sessionID: "plan", title: session.title)
        let content = StageContent.make(asking, sessions: [session], requests: [request])
        XCTAssertEqual(content.title, "Plan the release")
        XCTAssertEqual(content.detail, "Wants to run")
        XCTAssertEqual(content.command, "Run swift test", "an approval shows what it runs in its own field")
        XCTAssertEqual(content.meta, "Hermes")
        XCTAssertEqual(content.quickReply?.choices.map(\.value), ["deny", "once"])
        XCTAssertFalse(content.answered)
        XCTAssertFalse(content.acceptsText, "approvals are not typed")
        XCTAssertEqual(content.answerRows, 1)
        session.state = .working
        let answered = StageContent.make(asking, sessions: [session], requests: [])
        XCTAssertTrue(answered.answered)
        XCTAssertNil(answered.quickReply)
        XCTAssertNil(answered.request)
        XCTAssertEqual(answered.answerRows, 1, "the sent confirmation")
        let approval = NotchAnnouncement(kind: .needsInput, sessionID: "plan", title: session.title,
                                         detail: "Run swift test", isApproval: true)
        let sent = StageContent.make(approval, sessions: [session], requests: [])
        XCTAssertEqual(sent.detail, "Wants to run", "an answered approval keeps its label")
        XCTAssertEqual(sent.command, "Run swift test", "and its command stays in the field, not prose")
        XCTAssertEqual(sent.bodyHeight(mascot: false), content.bodyHeight(mascot: false), "the stage does not re-spring as it lands")
        XCTAssertEqual(StageContent.make(NotchAnnouncement(kind: .failed, sessionID: "plan", title: ""), sessions: [session],
                                         requests: []).answerRows, 0, "results carry no buttons")
        let hello = StageContent.make(NotchAnnouncement(kind: .hello, sessionID: AppModel.helloAnnouncementID, title: "Hover"),
                                      sessions: [], requests: [])
        XCTAssertEqual(hello.title, "Hi there", "the eyes alone have no name")
        XCTAssertEqual(StageContent.make(NotchAnnouncement(kind: .hello, sessionID: AppModel.helloAnnouncementID, title: "Hover"),
                                         sessions: [], requests: [], mascot: "Mote").title, "Hi, I’m Mote")
        XCTAssertEqual(StageContent.make(NotchAnnouncement(kind: .finished, sessionID: "gone", title: "Old"), sessions: [],
                                         requests: []).title, "Old")
    }

    @MainActor func testResultsAndFailuresShowTheirSnapshotNotLiveStatus() {
        // A queued send started during the hold: the session is thinking again.
        var session = CompanionSession(id: "plan", runtimeID: "live", title: "Plan the release", state: .working,
                                       messages: [ChatMessage(id: "turn", role: "user", text: "Draft it.")])
        session.runtime = .codex
        let failed = NotchAnnouncement(kind: .failed, sessionID: "plan", title: "Plan the release",
                                       detail: "Rate limit reached. Try again at 14:00.", worked: 134)
        let failure = StageContent.make(failed, sessions: [session], requests: [])
        XCTAssertEqual(failure.detail, "Rate limit reached. Try again at 14:00.")
        XCTAssertNotEqual(SessionDigest.entry(session, requests: []).detail, failure.detail, "live status says Thinking…")
        XCTAssertEqual(failure.meta, "Codex · 2:14")
        XCTAssertNil(failure.changes)
        // A finished turn with changes adds one quiet line; an earlier turn's changes do not count.
        session.state = .finished
        session.changes = [TurnChanges(id: "earlier", workspace: "/tmp", files: [ChangedFile(path: "a.swift", additions: 9, deletions: 1)])]
        let done = NotchAnnouncement(kind: .finished, sessionID: "plan", title: "Plan the release", detail: "Drafted.")
        XCTAssertNil(StageContent.make(done, sessions: [session], requests: []).changes)
        session.changes.append(TurnChanges(id: "turn", workspace: "/tmp", files: [ChangedFile(path: "b.swift", additions: 120, deletions: 8)]))
        let changed = StageContent.make(done, sessions: [session], requests: [])
        XCTAssertEqual(changed.changes?.id, "turn")
        XCTAssertEqual(changed.detail, "Drafted.")
        XCTAssertEqual(changed.meta, "Codex", "no work time without a snapshot")
    }

    @MainActor func testStageHeightFollowsItsContent() {
        let session = CompanionSession(id: "plan", runtimeID: "live", title: "Plan the release", state: .finished,
                                       messages: [ChatMessage(role: "user", text: "Draft it.")])
        func content(_ detail: String, requests: [PendingRequest] = [], kind: NotchAnnouncement.Kind = .finished) -> StageContent {
            var waiting = session
            if kind == .needsInput { waiting.state = .waiting }
            return StageContent.make(NotchAnnouncement(kind: kind, sessionID: "plan", title: session.title, detail: detail),
                                     sessions: [waiting], requests: requests, textWidth: 406)
        }
        let short = content("Drafted.")
        let long = content(String(repeating: "Keyboard focus now follows the reading order. ", count: 12))
        XCTAssertEqual(short.messageLines, 1)
        XCTAssertEqual(long.messageLines, 3, "at most three lines")
        XCTAssertEqual(long.bodyHeight(mascot: false), content(long.detail + long.detail).bodyHeight(mascot: false),
                       "longer text truncates instead of growing the stage")
        // With the eyes a short result drops the empty space; the mascot keeps its room.
        XCTAssertLessThan(short.bodyHeight(mascot: false), 70)
        XCTAssertLessThan(short.bodyHeight(mascot: false), long.bodyHeight(mascot: false))
        XCTAssertEqual(short.bodyHeight(mascot: true), NotchGeometry.mascotStageBodyHeight)
        // Answers sit under the message and grow it a row at a time.
        let pick = PendingRequest(id: "q", kind: .clarification, title: "Question", detail: "Which milestone ships first?",
                                  choices: ["The glance", "The aura"], sessionID: "live", allowsFreeText: false)
        var typed = pick
        typed.allowsFreeText = true
        let one = content("", requests: [pick], kind: .needsInput), two = content("", requests: [typed], kind: .needsInput)
        XCTAssertEqual(one.answerRows, 1)
        XCTAssertEqual(two.answerRows, 2)
        XCTAssertEqual(two.bodyHeight(mascot: false) - one.bodyHeight(mascot: false), StageContent.answerHeight + StageContent.rowSpacing)
        XCTAssertGreaterThan(one.bodyHeight(mascot: false), short.bodyHeight(mascot: false))
        // An approval's message makes room for its command field: two lines at most.
        let approval = PendingRequest(id: "a", kind: .approval, title: "Permission", detail: long.detail, choices: ["once", "deny"], sessionID: "live")
        let approving = content("", requests: [approval], kind: .needsInput)
        XCTAssertEqual(approving.command, SessionDigest.oneLine(long.detail))
        XCTAssertEqual(approving.messageLines, 1)
        XCTAssertEqual(approving.answerRows, 1)
        // The command wraps instead of hiding its middle: three lines at most, and the stage grows to show them.
        XCTAssertEqual(approving.commandLines, 3)
        XCTAssertEqual(approving.commandFieldHeight, StageContent.commandHeight + ceil(2 * StageContent.commandLineHeight))
        XCTAssertEqual(approving.bodyHeight(mascot: false) - one.bodyHeight(mascot: false),
                       StageContent.commandGap + approving.commandFieldHeight, "one line of message, the field, one row of answers")
        let brief = PendingRequest(id: "b", kind: .approval, title: "Permission", detail: "swift test", choices: ["once", "deny"], sessionID: "live")
        let quick = content("", requests: [brief], kind: .needsInput)
        XCTAssertEqual(quick.commandLines, 1)
        XCTAssertEqual(quick.commandFieldHeight, StageContent.commandHeight, "a short command keeps the one-line field")
        let medium = PendingRequest(id: "m", kind: .approval, title: "Permission",
                                    detail: "swift test --filter NotchGlanceTests --parallel --num-workers 4", choices: ["once", "deny"], sessionID: "live")
        XCTAssertEqual(content("", requests: [medium], kind: .needsInput).commandLines, 2)
        XCTAssertEqual(StageContent.breakable("a b"), "a\u{200B} \u{200B}b", "every character boundary may break")
    }

    @MainActor func testQuestionsShowTheirChoicesAndAReplyField() {
        let session = CompanionSession(id: "plan", runtimeID: "live", title: "Plan the release", state: .waiting,
                                       messages: [ChatMessage(role: "user", text: "Draft it.")])
        let asking = NotchAnnouncement(kind: .needsInput, sessionID: "plan", title: session.title)
        // Longer than the glance allows: the stage wraps the choices instead.
        let options = ["Ship the glance first", "Ship the aura first", "Ship both together in one release", "Wait"]
        let pick = PendingRequest(id: "q", kind: .clarification, title: "Claude Code", detail: "Which milestone ships first?",
                                  choices: options, sessionID: "live")
        let content = StageContent.make(asking, sessions: [session], requests: [pick])
        XCTAssertEqual(content.detail, "Which milestone ships first?")
        XCTAssertEqual(content.choiceRows.flatMap { $0 }.map(\.value), options)
        XCTAssertGreaterThan(content.choiceRows.count, 1)
        XCTAssertTrue(content.acceptsText)
        XCTAssertEqual(content.answerRows, content.choiceRows.count + 1)
        for row in content.choiceRows where row.count > 1 {
            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let width = row.reduce(-6) { $0 + 6 + ceil(($1.label as NSString).size(withAttributes: [.font: font]).width) + 18 }
            XCTAssertLessThanOrEqual(width, StageContent.column)
        }
        var open = pick
        open.choices = []
        let typed = StageContent.make(asking, sessions: [session], requests: [open])
        XCTAssertNil(typed.quickReply)
        XCTAssertEqual(typed.answerRows, 1, "an open question is one reply field")
        open.allowsFreeText = false
        XCTAssertEqual(StageContent.make(asking, sessions: [session], requests: [open]).answerRows, 0)
        var several = pick
        several.multiSelect = true
        XCTAssertEqual(StageContent.make(asking, sessions: [session], requests: [several]).answerRows, 0,
                       "choosing several opens the session")
    }

    // MARK: Characters, stage clips and ledges

    /// A throwaway character in a temporary flat bundle, the way `.process`
    /// lays out `<id>.json` and `<id>-<clip>.webp`. PNG data decodes the same.
    private func temporaryCharacter(_ clips: [String: (frames: Int, loops: Bool, ledge: Double?)]) throws -> (MascotLibrary, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mascot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [String: Any] = [:]
        for (name, clip) in clips {
            // Anchors grow over the clip so the emerge rule is visible.
            let anchors = (0..<clip.frames).map { index -> [Double] in
                let y = 0.4 + 0.01 * Double(index)
                let unit = 0.001 * Double(index + 1)
                return [0.5, y, unit, 0, 0, unit, 1]
            }
            var entry: [String: Any] = ["frames": clip.frames, "loops": clip.loops, "columns": 8, "anchors": anchors]
            entry["ledge"] = clip.ledge
            entries[name] = entry
            let columns = min(8, clip.frames), rows = (clip.frames + 7) / 8
            let image = try XCTUnwrap(CGContext(data: nil, width: columns * 4, height: rows * 4, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("tst-\(name).webp"))
        }
        let manifest: [String: Any] = ["size": 4, "fps": 24, "eyeUnit": 0.0145, "ground": 0.9, "clips": entries]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("tst.json"))
        return (MascotLibrary("tst", bundle: try XCTUnwrap(Bundle(url: folder))), folder)
    }

    func testACharacterLoadsItsOwnManifestAndStageVariants() throws {
        let (library, folder) = try temporaryCharacter([
            "emerge": (24, false, nil), "idle": (60, true, nil), "done": (40, false, nil),
            "stage-emerge": (30, false, 0.95), "stage-idle": (48, true, 0.9)])
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(library.isAvailable)
        XCTAssertFalse(MascotLibrary("absent", bundle: try XCTUnwrap(Bundle(url: folder))).isAvailable,
                       "a character without assets falls back to the eyes")
        XCTAssertEqual(library.clips["stage-idle"]?.ledge, 0.9)
        XCTAssertNil(library.clips["idle"]?.ledge)
        // The stage prefers its variants; the header always plays base clips.
        XCTAssertEqual(library.variant("idle", onStage: true), "stage-idle")
        XCTAssertEqual(library.variant("done", onStage: true), "done", "no stage variant rendered")
        XCTAssertEqual(library.variant("idle", onStage: false), "idle")
        XCTAssertEqual(library.frameCounts(onStage: true), ["emerge": 30, "idle": 48, "done": 40])
        XCTAssertEqual(library.emergeLength(onStage: true), 30.0 / 24, accuracy: 0.0001)
        let celebrating = MascotPerformance(.celebrating, start: 0)
        XCTAssertEqual(library.frame(celebrating, appeared: 0, at: 0.5, onStage: true, reducedMotion: false),
                       .init(clip: "stage-emerge", index: 12))
        XCTAssertEqual(library.frame(celebrating, appeared: 0, at: 0.5, onStage: false, reducedMotion: false),
                       .init(clip: "emerge", index: 12))
        XCTAssertEqual(library.frame(celebrating, appeared: 0, at: 30.0 / 24 + 40.5 / 24, onStage: true, reducedMotion: false),
                       .init(clip: "stage-idle", index: 0), "the stage's entrance hands over to the stage loop")
        // Edge lines: a ledge, else the standing line 10 points above the stage's edge.
        XCTAssertEqual(library.edge("stage-idle"), 0.9)
        XCTAssertEqual(library.edge("idle"), 0.9 + 10 / 150, accuracy: 0.0001)
        library.prepare(["stage-idle"], synchronously: true)
        XCTAssertNotNil(library.image(.init(clip: "stage-idle", index: 47)))
    }

    func testEveryEmergeKeepsTheEyesAtItsSettledSize() throws {
        let (library, folder) = try temporaryCharacter(["emerge": (24, false, nil), "idle": (60, true, nil),
                                                        "stage-emerge": (30, false, nil), "wave": (10, false, nil)])
        defer { try? FileManager.default.removeItem(at: folder) }
        for (clip, frames) in [("emerge", 24), ("stage-emerge", 30)] {
            let first = try XCTUnwrap(library.anchor(.init(clip: clip, index: 0)))
            let last = try XCTUnwrap(library.clips[clip]?.anchors.last)
            XCTAssertEqual(first.x, last.x, clip)
            XCTAssertEqual(first.y, last.y, clip)
            XCTAssertEqual(first.center, library.clips[clip]?.anchors.first?.center, "only the centre follows each frame")
            XCTAssertEqual(library.anchor(.init(clip: clip, index: frames + 5))?.center, last.center, "clamped")
        }
        XCTAssertEqual(library.anchor(.init(clip: "wave", index: 0)), library.clips["wave"]?.anchors.first, "other clips are untouched")
    }

    func testEdgeLinesSitOnTheStagesBottomEdgeAndMatchTheStandingPlacement() {
        let geometry = physical()
        let ground: CGFloat = 0.9027
        let standing = ground + MascotLayout.stageStanding / MascotLayout.stageSide
        XCTAssertEqual(MascotLayout.stageFigure(geometry, edge: standing), MascotLayout.stageFigure(geometry, ground: ground))
        let stage = MascotLayout.scene(.stage(geometry), geometry: geometry, ground: ground, staging: true, expanded: false)
        XCTAssertTrue(stage.onStage)
        XCTAssertEqual(stage.figure(edge: standing), stage.figure, "base clips keep today's placement")
        XCTAssertEqual(stage.figure.minY + ground * stage.figure.height, geometry.stageFrame.height - 10, accuracy: 0.001)
        for ledge in [0.8, standing, 0.97] as [CGFloat] {
            let figure = stage.figure(edge: ledge)
            XCTAssertEqual(figure.minY + ledge * figure.height, geometry.stageFrame.height, accuracy: 0.001, "\(ledge)")
            XCTAssertEqual(figure.size, stage.figure.size)
            XCTAssertEqual(stage.eyeLimit(ledge: ledge) ?? 0, geometry.stageFrame.height, accuracy: 0.001,
                           "the eyes clip at the island's edge")
        }
        XCTAssertNil(stage.eyeLimit(ledge: nil))
        // A ledge clip whose ledge equals the standing line is seamless with a base clip.
        XCTAssertEqual(stage.figure(edge: standing).minY, stage.figure.minY, accuracy: 0.0001)
        // The header ignores stage placement; mid-handover it is half applied.
        let header = MascotLayout.scene(.expanded(geometry), geometry: geometry, ground: ground, staging: false, expanded: true)
        XCTAssertFalse(header.onStage)
        XCTAssertEqual(header.figure(edge: 0.8), header.figure)
        var handover = NotchPresentation.stage(geometry)
        handover.progress = 0.5
        handover.stage = 0.5
        let midway = MascotLayout.scene(handover, geometry: geometry, ground: ground, staging: false, expanded: true)
        XCTAssertFalse(midway.onStage, "the panel's clips take over as soon as the session opens")
        XCTAssertEqual(midway.figure(edge: 0.8).minY - midway.figure.minY, 0.5 * (standing - 0.8) * midway.figure.height, accuracy: 0.001)
        let retracting = MascotLayout.scene(handover, geometry: geometry, ground: ground, staging: false, expanded: false)
        XCTAssertTrue(retracting.onStage == (MascotLayout.towardHeader(handover, staging: false) < 0.5))
    }

    func testABoopedBodySquashesThenWobblesBackToRest() {
        let identity = CGSize(width: 1, height: 1)
        XCTAssertEqual(MascotTimeline.wobble(sincePoke: -1, reducedMotion: false), identity)
        XCTAssertEqual(MascotTimeline.wobble(sincePoke: 0.06, reducedMotion: true), identity)
        let squashed = MascotTimeline.wobble(sincePoke: 0.08, reducedMotion: false)
        XCTAssertLessThan(squashed.height, 0.95)
        XCTAssertGreaterThan(squashed.width, 1)
        XCTAssertGreaterThan(MascotTimeline.wobble(sincePoke: 0.2, reducedMotion: false).height, 1, "rebounds taller")
        // It has rung out before the clock stops, so it never snaps back.
        let last = MascotTimeline.wobble(sincePoke: EyeMotion.pokeDuration - 0.001, reducedMotion: false)
        XCTAssertEqual(last.height, 1, accuracy: 0.002)
        XCTAssertEqual(MascotTimeline.wobble(sincePoke: EyeMotion.pokeDuration, reducedMotion: false), identity)
    }

    func testThePointerBoopsTheEyesOrTheMascotsBody() {
        let eyes = PokeZone.eyes(at: CGPoint(x: 29, y: 16), scale: 1)
        XCTAssertTrue(eyes.contains(CGPoint(x: 23, y: 16)), "on an eye")
        XCTAssertFalse(eyes.contains(CGPoint(x: 29, y: 30)))
        XCTAssertTrue(PokeZone.eyes(at: CGPoint(x: 29, y: 16), scale: 1.7).contains(CGPoint(x: 29, y: 30)), "grows with the eyes")
        let figure = CGRect(x: 4, y: 20, width: 150, height: 150)
        let body = PokeZone.body(in: figure, ground: 0.9)
        XCTAssertTrue(body.contains(CGPoint(x: figure.midX, y: figure.minY + 0.56 * figure.height)), "the face")
        XCTAssertTrue(body.contains(CGPoint(x: figure.midX, y: figure.minY + 0.88 * figure.height)), "the feet")
        XCTAssertFalse(body.contains(CGPoint(x: figure.minX + 5, y: figure.minY + 5)), "the frame's empty corner")
        XCTAssertFalse(body.contains(CGPoint(x: figure.midX, y: figure.maxY - 2)), "below the feet")
    }

    func testOnlyTheStageMayOverhangTheIsland() {
        let geometry = physical()
        XCTAssertEqual(MascotLayout.overhangClip(.stage(geometry)), 16)
        XCTAssertEqual(MascotLayout.overhangClip(.expanded(geometry)), 0)
        XCTAssertEqual(MascotLayout.overhangClip(.resting(geometry)), 0)
        XCTAssertEqual(MascotLayout.overhang / MascotLayout.stageSide, 0.107, accuracy: 0.001)
        let scene = MascotLayout.scene(.stage(geometry), geometry: geometry, ground: 0.9, staging: true, expanded: false)
        XCTAssertEqual(scene.size.height, NotchPresentation.stage(geometry).size.height + MascotLayout.overhang,
                       "the canvas reaches below the island for the overhang")
    }

    @MainActor func testMascotCharacterDefaultsToMoteAndPersists() {
        let suite = "notch-mascot-character-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        // A former Pip user: Mascot was saved, no character yet.
        preferences.set(CompanionAppearance.mascot.rawValue, forKey: CompanionAppearance.key)
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: MascotTransport(), preferences: preferences)
        XCTAssertEqual(model.companionAppearance, .mascot)
        XCTAssertEqual(model.mascotCharacter, .mote)
        XCTAssertTrue(model.mascotLibrary === MascotLibrary.library(.mote), "one cached library per character")
        model.mascotCharacter = .soot
        XCTAssertEqual(preferences.string(forKey: MascotCharacter.key), "soot")
        XCTAssertEqual(model.mascotEnabled, MascotLibrary.library(.soot).isAvailable)
        model.shutdown()
        let reopened = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                                client: MascotTransport(), preferences: preferences)
        XCTAssertEqual(reopened.mascotCharacter, .soot)
        XCTAssertEqual(MascotCharacter.allCases.map(\.label), ["Mote", "Fold", "Soot"])
        reopened.shutdown()
    }

    // MARK: Rendered assets

    /// Bundled characters; those not rendered yet are skipped.
    private func bundledCharacters() throws -> [(MascotCharacter, MascotLibrary)] {
        let rendered = MascotCharacter.allCases.map { ($0, MascotLibrary($0.rawValue)) }.filter { $0.1.isAvailable }
        if rendered.isEmpty { throw XCTSkip("No mascot has been rendered into Resources/Mascot yet.") }
        return rendered
    }

    @MainActor func testDecodedSheetsNotifyDrawingsEvenWhenTheirAnimationClockIsPaused() async throws {
        let (library, folder) = try temporaryCharacter(["emerge": (8, false, nil), "idle": (16, true, nil)])
        defer { try? FileManager.default.removeItem(at: folder) }
        let loaded = expectation(description: "Decoded sheet invalidates the static drawing")
        let observation = library.objectWillChange.sink { loaded.fulfill() }
        defer { observation.cancel() }
        library.prepare(["idle"])
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertNotNil(library.image(.init(clip: "idle", index: 0)))
    }

    func testBundledClipsHaveSheetsAndAnAnchorForEveryFrame() throws {
        for (character, library) in try bundledCharacters() {
            let id = character.rawValue
            XCTAssertTrue(Set(library.clips.keys).isSuperset(of: frames.keys), id)
            for name in library.clips.keys {
                let base = name.hasPrefix(MascotLibrary.stagePrefix) ? String(name.dropFirst(MascotLibrary.stagePrefix.count)) : name
                XCTAssertTrue(frames.keys.contains(base), "\(id): \(name) is a known clip or its stage variant")
            }
            XCTAssertGreaterThan(library.frameSize, 200, id)
            XCTAssertTrue((0.8...0.98).contains(library.ground), id)
            for (name, clip) in library.clips {
                XCTAssertEqual(clip.anchors.count, clip.frames, "\(id) \(name)")
                XCTAssertEqual(clip.loops, ["idle", "work", "wait", "sad"].contains(name.replacingOccurrences(of: MascotLibrary.stagePrefix, with: "")),
                               "\(id) \(name)")
                if let ledge = clip.ledge { XCTAssertTrue((0.3...1).contains(ledge), "\(id) \(name) ledge") }
                // A face still hidden below a ledge (climbing or phasing in) may sit outside the frame.
                for anchor in clip.anchors where anchor.facing > 0.2 && anchor.center.y < (clip.ledge ?? .infinity) {
                    XCTAssertTrue((0.1...0.9).contains(anchor.center.x) && (0.1...1).contains(anchor.center.y), "\(id) \(name)")
                }
                let url = try XCTUnwrap(CompanionResources.bundle.url(forResource: "\(id)-\(name)", withExtension: "webp")
                                        ?? CompanionResources.bundle.url(forResource: "\(id)-\(name)", withExtension: "webp",
                                                                         subdirectory: "Mascot"), "\(id) \(name)")
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
                XCTAssertEqual(width, min(clip.columns, clip.frames) * library.frameSize, "\(id) \(name)")
            }
            // Settled poses look at the camera.
            XCTAssertGreaterThan(try XCTUnwrap(library.clips["idle"]?.anchors.first).facing, 0.9, id)
        }
    }
}

@MainActor private final class MascotTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws {}
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
