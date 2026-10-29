import AppKit
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
