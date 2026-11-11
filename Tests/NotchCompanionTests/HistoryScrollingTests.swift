import AppKit
import SwiftUI
import XCTest
@testable import NotchCompanion

final class HistoryScrollingTests: XCTestCase {
    @MainActor private func settle() async {
        try? await Task.sleep(for: .milliseconds(65))
    }

    @MainActor private func installDriver(_ follow: HistoryScrollCoordinator, scroll: NSScrollView) {
        // The real view supplies ScrollViewProxy.scrollTo. This test driver
        // executes the same requested movement against an isolated native view.
        follow.installScrollAction {
            guard let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let y = document.isFlipped ? max(0, document.bounds.maxY - clip.bounds.height) : document.bounds.minY
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        follow.attach(scroll)
    }

    @MainActor func testReadingEarlierMessagesDoesNotJumpOnNewActivity() async {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedHistoryDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.documentView = document
        let follow = HistoryScrollCoordinator()
        defer { follow.detach() }
        installDriver(follow, scroll: scroll)
        await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 800, accuracy: 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        XCTAssertFalse(follow.followsLatest)
        document.setFrameSize(NSSize(width: 300, height: 1400))
        follow.contentChanged()
        await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 400, accuracy: 1)
        XCTAssertTrue(follow.hasNewActivity)
        follow.jumpToLatest()
        await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 1200, accuracy: 1)
        XCTAssertTrue(follow.followsLatest)
        XCTAssertFalse(follow.hasNewActivity)
    }

    @MainActor func testCurrentReaderFollowsAppendedOutput() async {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedHistoryDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        scroll.documentView = document
        let follow = HistoryScrollCoordinator()
        defer { follow.detach() }
        installDriver(follow, scroll: scroll)
        await settle()
        XCTAssertTrue(follow.followsLatest)
        document.setFrameSize(NSSize(width: 300, height: 1100))
        follow.contentChanged()
        await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, 900, accuracy: 1)
        XCTAssertTrue(follow.followsLatest)
    }

    @MainActor func testInspectingCollapsedToolsSuspendsFollowing() async {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedHistoryDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        scroll.documentView = document
        let follow = HistoryScrollCoordinator()
        defer { follow.detach() }
        installDriver(follow, scroll: scroll)
        await settle()
        follow.stopFollowing()
        document.setFrameSize(NSSize(width: 300, height: 1500))
        await settle()
        XCTAssertFalse(follow.followsLatest)
        XCTAssertEqual(scroll.contentView.bounds.minY, 500, accuracy: 1)
        follow.resetForSession()
        await settle()
        XCTAssertTrue(follow.followsLatest)
        XCTAssertEqual(scroll.contentView.bounds.minY, 1300, accuracy: 1)
    }

    @MainActor func testToolGroupRelayoutCannotResumeFollowingOnItsOwn() async {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedHistoryDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.documentView = document
        let follow = HistoryScrollCoordinator()
        defer { follow.detach() }
        installDriver(follow, scroll: scroll)
        await settle()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        XCTAssertFalse(follow.followsLatest)
        document.setFrameSize(NSSize(width: 300, height: 500))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        XCTAssertFalse(follow.followsLatest)
        document.setFrameSize(NSSize(width: 300, height: 1200))
        follow.contentChanged()
        await settle()
        XCTAssertFalse(follow.followsLatest)
        XCTAssertTrue(follow.hasNewActivity)
    }

    @MainActor func testUserScrollCancelsFollowQueuedByLazyHistoryRemeasurement() async {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedHistoryDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        scroll.documentView = document
        let follow = HistoryScrollCoordinator()
        defer { follow.detach() }
        installDriver(follow, scroll: scroll)
        await settle()
        // Real LazyVStack history can grow its estimate in the same run-loop
        // pass as the reader moves upward. That must not snap back to the end.
        document.setFrameSize(NSSize(width: 300, height: 1400))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle()
        XCTAssertFalse(follow.followsLatest)
        XCTAssertEqual(scroll.contentView.bounds.minY, 400, accuracy: 1)
    }
}

private final class FlippedHistoryDocument: NSView {
    override var isFlipped: Bool { true }
}

private struct HistoryHost: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group { if model.page == .session { ConversationHistoryView(model: model) } else { Color.clear } }
            .frame(width: 560, height: 420).background(Color.black)
    }
}

extension HistoryScrollingTests {
    /// Finished turns with many tool calls each: unfolded, every turn's work is taller than the view.
    fileprivate static func toolHeavySession(_ id: String) -> CompanionSession {
        var session = CompanionSession(id: id)
        let start = Date(timeIntervalSinceNow: -100_000)
        for turn in 0..<40 {
            let at = start.addingTimeInterval(Double(turn) * 600)
            session.messages.append(ChatMessage(id: "\(id)-u\(turn)", role: "user", text: "Question \(turn)", createdAt: at, turnID: "\(id)-u\(turn)"))
            for tool in 0..<25 {
                session.tools.append(ToolActivity(id: "\(id)-t\(turn)-\(tool)", name: "Bash", detail: "command \(tool)", state: .finished,
                                                  startedAt: at.addingTimeInterval(Double(tool)), finishedAt: at.addingTimeInterval(Double(tool) + 1), turnID: "\(id)-u\(turn)"))
            }
            session.messages.append(ChatMessage(id: "\(id)-a\(turn)", role: "assistant", text: String(repeating: "Answer \(turn) with several words of text. ", count: 30),
                                                createdAt: at.addingTimeInterval(60), turnID: "\(id)-u\(turn)"))
        }
        session.state = .finished
        return session
    }

    @MainActor func testUnfoldedToolHeavyTranscriptShowsItsEndAfterLeavingAndReturning() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: folder) }
        var short = CompanionSession(id: "short")
        short.messages = [ChatMessage(role: "user", text: "Hi"), ChatMessage(role: "assistant", text: "Hello there")]
        short.state = .finished
        let long = Self.toolHeavySession("long")
        model.sessions = [long, short]
        model.expandedWork = Set(ConversationTimeline.build(session: long).compactMap { if case .work(let work) = $0 { work.id } else { nil } })
        model.currentID = "long"; model.page = .session
        let hosting = NSHostingView(rootView: HistoryHost(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        func findScroll(_ view: NSView) -> NSScrollView? { (view as? NSScrollView) ?? view.subviews.lazy.compactMap(findScroll).first }
        /// Rows are drawn (not the bare black panel) and the view rests at the transcript's end.
        func expectEnd(_ message: String) async throws {
            for _ in 0..<12 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            var lit = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) where (bitmap.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.25 { lit += 1 }
            }
            XCTAssertGreaterThan(lit, 50, message)
            let scroll = try XCTUnwrap(findScroll(hosting))
            // The tail anchor sits above the transcript's bottom padding.
            XCTAssertEqual(scroll.contentView.bounds.maxY, scroll.documentView?.bounds.maxY ?? 0, accuracy: 20, message)
        }
        try await expectEnd("A long transcript opens at its end")
        model.page = .team
        try await Task.sleep(for: .milliseconds(100))
        model.page = .session
        try await expectEnd("Returning from another page shows the transcript")
        model.currentID = "short"
        try await Task.sleep(for: .milliseconds(200))
        model.currentID = "long"
        try await expectEnd("Returning from another session shows the transcript")
    }
}
