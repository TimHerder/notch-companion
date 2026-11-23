import AppKit
import SwiftUI
import XCTest
@testable import NotchCompanion

/// What keeps the interface smooth: no needless publications of the model, and saves that
/// encode only what changed. The timings of the real panel over a long session, hosted offscreen,
/// are opt-in since they depend on the machine: `NOTCH_RUN_PERF_TESTS=1 swift test --filter TranscriptPerformanceTests`.
final class TranscriptPerformanceTests: XCTestCase {
    @MainActor private final class Transport: RuntimeTransport {
        var onEvent: ((String, [String: Any]) -> Void)?
        var onConnectionChange: ((Bool, String?) -> Void)?
        func connect() async throws {}
        func disconnect() {}
        func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    }

    /// A model on a temporary registry, with preferences under the same name as its folder.
    @MainActor private func fixture() -> (model: AppModel, storage: URL) {
        let name = "NotchCompanionTests.performance.\(UUID().uuidString)"
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathComponent("sessions.json")
        return (AppModel(storageURL: storage, playsSounds: false, client: Transport(), preferences: UserDefaults(suiteName: name)!), storage)
    }

    @MainActor private func cleanUp(_ model: AppModel, _ storage: URL) {
        model.shutdown()
        UserDefaults().removePersistentDomain(forName: storage.deletingLastPathComponent().lastPathComponent)
        try? FileManager.default.removeItem(at: storage.deletingLastPathComponent())
    }

    /// Every publication of the model re-evaluates every view of it, so neither the 60 Hz pointer
    /// samples nor reading a conversation that is already read may publish. The host's refresh of
    /// what the open panel shows is the one deliberate publication, twice a second.
    @MainActor func testPointerSamplesAndIdleVisibilityChecksDoNotPublish() {
        let (model, storage) = fixture()
        defer { cleanUp(model, storage) }
        model.sessions = [CompanionSession(id: "session", state: .finished)]
        model.currentID = "session"
        model.setSessionVisibility(notchVisible: true)
        XCTAssertFalse(model.current!.hasUnreadResult, "Showing the conversation still reads its result.")
        var publications = 0
        let watch = model.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }
        model.pointerOffset = CGSize(width: 2, height: 1)
        model.notchPull = NotchPull(pointer: CGPoint(x: 20, y: 40), depth: 4)
        model.setSessionVisibility(notchVisible: true)
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(model.pointerOffset, CGSize(width: 2, height: 1))
        XCTAssertEqual(model.notchPullState.pull.depth, 4)
        model.refreshVisibleViews()
        XCTAssertEqual(publications, 1)
        model.page = .sessions
        publications = 0
        model.refreshVisibleViews()
        XCTAssertEqual(publications, 1, "Every page of the open panel is refreshed, not only a conversation.")
        model.setSessionVisibility(notchVisible: false)
        model.refreshVisibleViews()
        XCTAssertEqual(publications, 1, "Nothing is refreshed while the panel is closed.")
    }

    /// The transcript does not observe the model, so it must still be drawn again for what it
    /// shows of it, and only for that.
    @MainActor func testTranscriptIsDrawnAgainForWhatItShows() async throws {
        _ = NSApplication.shared
        let (model, storage) = fixture()
        defer { cleanUp(model, storage) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        var session = CompanionSession(id: "shown", state: .finished)
        session.messages = [ChatMessage(id: "u", role: "user", text: "Change it.", createdAt: start, turnID: "u"),
                            ChatMessage(id: "c", role: "assistant", text: "Reading the file first.", createdAt: start.addingTimeInterval(1), turnID: "u"),
                            ChatMessage(id: "a", role: "assistant", text: "Done.", createdAt: start.addingTimeInterval(9), turnID: "u")]
        session.tools = [ToolActivity(id: "t", name: "read_file", detail: "Parser.swift", state: .finished,
                                      startedAt: start.addingTimeInterval(2), finishedAt: start.addingTimeInterval(3), turnID: "u")]
        session.turnEndedAt["u"] = start.addingTimeInterval(10)
        session.turnOutcome["u"] = .finished
        model.sessions = [session]
        model.currentID = session.id
        model.reducedMotion = true
        let hosting = NSHostingView(rootView: ConversationHistoryView(model: model).frame(width: 560, height: 420).background(Color.black))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        func drawn() async throws -> Data {
            for _ in 0..<12 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.tiffRepresentation)
        }
        let folded = try await drawn()
        model.hovering.toggle()
        model.draft = "Typing does not reach the transcript."
        let unrelated = try await drawn()
        XCTAssertEqual(unrelated, folded)
        model.expandedWork.insert("work:shown:u")
        let unfolded = try await drawn()
        XCTAssertNotEqual(unfolded, folded, "Unfolding the turn's work shows it.")
        model.sessions[0].messages.append(ChatMessage(id: "later", role: "assistant", text: "And one more thing.", createdAt: start.addingTimeInterval(20), turnID: "u"))
        let longer = try await drawn()
        XCTAssertNotEqual(longer, unfolded, "A new message appears.")
    }

    /// Nothing publishes when a delivered file is written after its answer: its card asks the disk again.
    @MainActor func testFileCardNoticesItsFileAppearing() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchCompanionTests.performance.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("report.pdf")
        let list = MessageMediaList(media: [MessageMedia(url: file)], open: { _, _ in })
        let hosting = NSHostingView(rootView: list.frame(width: 460, height: 80).background(Color.black))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 460, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        func drawn() async throws -> Data {
            for _ in 0..<12 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.tiffRepresentation)
        }
        let missing = try await drawn()
        try Data("A report".utf8).write(to: file)
        var appeared = missing
        for _ in 0..<20 where appeared == missing { appeared = try await drawn() }
        XCTAssertNotEqual(appeared, missing, "The card offers Open once its file exists.")
    }

    /// The glance's age label has its own 15-second clock, so every step of the label must fall on one.
    func testEveryStepOfAnAgeFallsOnAQuarterMinute() {
        var label = SessionDigest.compactAge(0)
        for second in 1..<400_000 {
            let next = SessionDigest.compactAge(TimeInterval(second))
            if next != label { XCTAssertEqual(second % 15, 0, "\(label) became \(next) at \(second) s") }
            label = next
        }
    }

    /// Scrolling at the end and each delta while reading back write the same value again.
    @MainActor func testNewActivityPublishesOnlyWhenItChanges() async {
        let follow = HistoryScrollCoordinator()
        follow.stopFollowing()
        for _ in 0..<200 where follow.followsLatest { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(follow.followsLatest)
        var publications = 0
        let watch = follow.objectWillChange.sink { publications += 1 }
        defer { watch.cancel() }
        follow.contentChanged()
        follow.contentChanged()
        XCTAssertTrue(follow.hasNewActivity)
        XCTAssertEqual(publications, 1)
    }

    /// A save reuses the encoding of each session that did not change, and the file is still
    /// byte for byte the encoding of them all.
    @MainActor func testSaveWritesTheWholeRegistryWhileEncodingOnlyChangedSessions() throws {
        let (model, storage) = fixture()
        defer { cleanUp(model, storage) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        model.sessions = (0..<3).map { index in
            var session = Self.longSession(turns: 2)
            session.id = "session-\(index)"
            return session
        }
        XCTAssertTrue(model.save())
        XCTAssertEqual(try Data(contentsOf: storage), try encoder.encode(model.sessions))
        model.sessions[1].messages.append(ChatMessage(role: "user", text: "Changed, with \"quotes\" and ünïcödé"))
        model.sessions.remove(at: 2)
        model.sessions.insert(CompanionSession(id: "new"), at: 0)
        XCTAssertTrue(model.save())
        XCTAssertEqual(try Data(contentsOf: storage), try encoder.encode(model.sessions))
        model.sessions = []
        XCTAssertTrue(model.save())
        XCTAssertEqual(try Data(contentsOf: storage), Data("[]".utf8))
    }

    /// The debounced save reaches the disk with nobody waiting for it.
    @MainActor func testDebouncedSaveIsWritten() async throws {
        let (model, storage) = fixture()
        defer { cleanUp(model, storage) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        model.sessions = [Self.longSession(turns: 3)]
        model.scheduleSave()
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: storage.path) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(try Data(contentsOf: storage), try encoder.encode(model.sessions))
    }

    /// A save that waits is written after a slower one asked for before it, never under it:
    /// the registry on disk is the last one asked for.
    func testWritesKeepTheOrderTheyWereAskedIn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchCompanionTests.performance.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sessions.json")
        let writer = RegistryWriter(url: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let long = [Self.longSession(turns: 400)], short = [CompanionSession(id: "short")]
        for _ in 0..<3 {
            writer.writeLater(long) { _ in }
            try writer.write(short)
            XCTAssertEqual(try Data(contentsOf: url), try encoder.encode(short))
            writer.writeLater(short) { _ in }
            try writer.write(long)
            XCTAssertEqual(try Data(contentsOf: url), try encoder.encode(long))
        }
    }

    /// The transcript asks whether a message is blank for every message it holds; the test
    /// that does not copy the text must agree with trimming it to nothing.
    func testBlankMessageTextMatchesTrimming() {
        for text in ["", " ", "\n\t \r\n", "\u{00A0}", "\u{2028}\u{2029}", "\u{3000}", "\u{0085}", "\u{200B}", "\u{FEFF}",
                     "a", "  a  ", "\n# Heading", "\u{1F44D}", " \u{1F600}\n"] {
            XCTAssertEqual(SessionHistory.isVisibleConversation(ChatMessage(role: "assistant", text: text)),
                           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        // Your own rows are searched for an operational envelope only when they open with its bracket.
        let hidden = "[System: The active model for this chat has changed to another]"
        for (text, visible) in [("Plain words", true), ("  [1] a list that opens with a bracket", true), (hidden, false),
                                ("\n \t" + hidden + "\n", false), ("See " + hidden, true), ("\u{301}" + hidden, true)] {
            XCTAssertEqual(SessionHistory.isVisibleConversation(ChatMessage(role: "user", text: text)), visible, text)
        }
    }

    /// The byte search that spares a full search: present bytes are found in native and bridged text alike.
    func testByteSearchFindsWhatAFullSearchWould() {
        XCTAssertTrue("An answer\n\n--- Attached Context ---\n\n".holdsBytes("\n\n--- "))
        XCTAssertTrue((NSString(string: "Größe: MEDIA:/tmp/a.png") as String).holdsBytes("MEDIA:"))
        XCTAssertFalse("An answer -- with dashes".holdsBytes("\n\n--- "))
        XCTAssertFalse("".holdsBytes("!["))
        let delivered = NSString(string: "Größe\nMEDIA:`/tmp/a b.pdf`") as String
        XCTAssertEqual(MessageContent.parse(delivered, fileExists: { _ in false }).media.first?.url.path, "/tmp/a b.pdf")
        XCTAssertEqual(MessageContent.parse("No files here."), MessageContent(text: "No files here.", media: []))
    }

    /// A rule is three or more of one of its symbols and nothing else.
    func testRulesAreStillRecognized() {
        for (line, rule) in [("---", true), (" * * *", true), ("_ _ _ _", true), ("--", false), ("-- -x", false),
                             ("***bold***", false), ("- item", false), ("-*-", false), ("    ---", false)] {
            let blocks = MarkdownDocument.parse("Before\n\n" + line + "\n\nAfter")
            XCTAssertEqual(blocks.contains { if case .rule = $0.content { return true } else { return false } }, rule, line)
        }
    }

    private static let answer = """
    ## Result

    The change touches **three files** and keeps the `public` interface as it was. See [the notes](https://example.com/notes).

    - First the parser reads the header, then each row in turn.
    - Rows that fail validation are *skipped* and counted.
    - The summary lists the count and the first failure.

    ```swift
    func parse(_ text: String) -> [Row] {
        text.split(separator: "\\n").compactMap(Row.init)
    }
    ```

    | File | Added | Removed |
    | --- | ---: | ---: |
    | Parser.swift | 42 | 7 |
    | Row.swift | 12 | 0 |
    """

    /// `turns` finished turns: your message, commentary between six tool calls, then an answer.
    static func longSession(turns: Int) -> CompanionSession {
        var session = CompanionSession()
        session.id = "long"
        session.runtimeID = "live"
        session.title = "Long session"
        session.state = .finished
        for turn in 0..<turns {
            let start = Date(timeIntervalSince1970: 1_000_000 + Double(turn) * 100)
            let id = "u\(turn)"
            session.messages.append(ChatMessage(id: id, role: "user", text: "Please change part \(turn) of the importer.", createdAt: start, turnID: id))
            for step in 0..<3 {
                session.messages.append(ChatMessage(id: "c\(turn)-\(step)", role: "assistant", text: "Reading the files for step \(step) before editing.",
                                                    createdAt: start.addingTimeInterval(Double(step) * 10 + 1), turnID: id))
                for call in 0..<2 {
                    session.tools.append(ToolActivity(id: "t\(turn)-\(step)-\(call)", name: "read_file", detail: "Sources/Importer/Part\(call).swift",
                                                      state: .finished, output: "ok", startedAt: start.addingTimeInterval(Double(step) * 10 + 2 + Double(call)),
                                                      finishedAt: start.addingTimeInterval(Double(step) * 10 + 3 + Double(call)), turnID: id))
                }
            }
            session.messages.append(ChatMessage(id: "a\(turn)", role: "assistant", text: Self.answer, createdAt: start.addingTimeInterval(40), turnID: id))
            session.turnEndedAt[id] = start.addingTimeInterval(41)
            session.turnOutcome[id] = .finished
        }
        return session
    }

    @MainActor private func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000 }

    /// Main-thread CPU milliseconds per tick, with `ticks` ticks at 60 Hz.
    @MainActor private func measure(_ ticks: Int, hosting: NSView, _ tick: (Int) -> Void) -> Double {
        let before = cpu()
        for index in 0..<ticks {
            tick(index)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 / 60))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
        return (cpu() - before) / Double(ticks)
    }

    /// The debounced save of a registry about the size of a heavily used one.
    @MainActor func testLargeRegistrySaveCost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOTCH_RUN_PERF_TESTS"] == "1", "Set NOTCH_RUN_PERF_TESTS=1 to time the save.")
        let (model, storage) = fixture()
        defer { cleanUp(model, storage) }
        model.sessions = (0..<60).map { index in
            var session = Self.longSession(turns: 400)
            session.id = "session-\(index)"
            return session
        }
        let before = cpu()
        let wall = Date()
        XCTAssertTrue(model.save())
        let size = (try FileManager.default.attributesOfItem(atPath: storage.path)[.size] as? Int ?? 0) / 1_000_000
        print("PERF save: \(Int(cpu() - before)) ms main-thread CPU, \(Int(Date().timeIntervalSince(wall) * 1000)) ms wall for \(size) MB")
        model.sessions[7].draft = "A draft"
        let again = cpu()
        let againWall = Date()
        XCTAssertTrue(model.save())
        print("PERF save after one session changed: \(Int(cpu() - again)) ms main-thread CPU, \(Int(Date().timeIntervalSince(againWall) * 1000)) ms wall")
    }

    @MainActor func testLongSessionCosts() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOTCH_RUN_PERF_TESTS"] == "1", "Set NOTCH_RUN_PERF_TESTS=1 to time the transcript.")
        let (model, storage) = fixture()
        defer { cleanUp(model, storage) }
        let session = Self.longSession(turns: 400)
        var other = Self.longSession(turns: 3)
        other.id = "other"
        other.runtimeID = "other-live"
        model.sessions = [session, other]
        model.currentID = session.id
        model.reducedMotion = true
        model.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0,
                                       leftArea: nil, rightArea: nil, indicatorCount: 0)
        model.notchPresentation = .expanded(model.geometry!)
        model.expanded = true

        let buildStart = cpu()
        for _ in 0..<20 { _ = ConversationTimeline.build(session: session) }
        print("PERF timeline build: \(String(format: "%.2f", (cpu() - buildStart) / 20)) ms for \(session.messages.count) messages, \(session.tools.count) tools")

        let size = model.geometry!.expandedFrame.size
        let hosting = NSHostingView(rootView: UnifiedNotchView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))

        var transcript: NSScrollView?
        func find(_ view: NSView) {
            if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > (transcript?.documentView?.frame.height ?? 0) { transcript = scroll }
            view.subviews.forEach(find)
        }
        find(hosting)
        let scroll = try XCTUnwrap(transcript)
        var direction: CGFloat = -1
        model.receive("message.start", payload: ["session_id": "other-live"])
        let cases: [(name: String, tick: (Int) -> Void)] = [
            ("idle", { _ in }),
            ("pointer sample", { model.pointerOffset = CGSize(width: Double($0 % 2), height: 0) }),
            ("frame of the notch moving", { _ in model.notchPresentation = model.notchPresentation }),
            ("delta in another session", { _ in model.receive("message.delta", payload: ["session_id": "other-live", "text": "more words "]) }),
            ("scroll", { _ in
                // 90 points a tick, turning at either end of the history.
                let clip = scroll.contentView
                let limit = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
                if clip.bounds.minY <= 0 { direction = 1 } else if clip.bounds.minY >= limit { direction = -1 }
                clip.scroll(to: NSPoint(x: 0, y: min(limit, max(0, clip.bounds.minY + 90 * direction))))
                scroll.reflectScrolledClipView(clip)
            }),
            ("delta in this session", { model.receive("message.delta", payload: ["session_id": "live", "text": $0 % 12 == 11 ? "words.\n\n" : "more words "]) })
        ]
        // `NOTCH_PERF_SOAK=<case>` repeats one case long enough to profile it with `sample`.
        let soak = ProcessInfo.processInfo.environment["NOTCH_PERF_SOAK"]
        for (name, tick) in cases where soak == nil || soak == name {
            if name == "delta in this session" {
                // A new turn streams its answer through the real event path.
                model.sessions[0].messages.append(ChatMessage(id: "live-user", role: "user", text: "And now?", turnID: "live-user"))
                model.receive("message.start", payload: ["session_id": "live"])
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
            }
            print("PERF \(name): \(String(format: "%.2f", measure(soak == nil ? 240 : 1500, hosting: hosting, tick))) ms/tick")
        }
    }
}
