import AppKit
import SwiftUI
import XCTest
@testable import NotchCompanion

/// These exercise the actual NSDraggingDestination implementation with an isolated
/// pasteboard. They do not synthesize input or claim to verify cursor animation.
final class NativeDropTests: XCTestCase {
    @MainActor
    func testReadableRegularFileIsDecodedAndAcceptedAsCopy() async throws {
        let files = try DropFiles()
        defer { files.remove() }
        let sender = DraggingFixture(urls: [files.first])
        defer { sender.releasePasteboard() }
        let view = FileDropHostingView(rootView: EmptyView())
        var presence: [Bool] = []
        view.dragPresenceChanged = { presence.append($0) }

        XCTAssertEqual(view.draggingEntered(sender), .copy)
        XCTAssertEqual(view.draggingUpdated(sender), .copy)
        XCTAssertEqual(sender.numberOfValidItemsForDrop, 1)
        XCTAssertEqual(presence, [true])
        view.draggingExited(sender)
        XCTAssertEqual(presence, [true, false])

        var decoded: [URL] = []
        view.acceptFiles = { decoded = $0; return true }
        XCTAssertTrue(view.performDragOperation(sender))
        XCTAssertEqual(decoded.map(\.standardizedFileURL), [files.first.standardizedFileURL])
        XCTAssertEqual(decoded.first?.lastPathComponent, "brief résumé with spaces.txt")
    }

    @MainActor
    func testDirectoryMissingFileAndRemoteURLAreRejected() async throws {
        let files = try DropFiles()
        defer { files.remove() }
        for url in [files.directory, files.directory.appendingPathComponent("missing.txt"), URL(string: "https://example.com/brief.txt")!] {
            let sender = DraggingFixture(urls: [url])
            defer { sender.releasePasteboard() }
            let view = FileDropHostingView(rootView: EmptyView())
            var acceptedCount = 0
            view.acceptFiles = { _ in acceptedCount += 1; return true }
            XCTAssertEqual(view.draggingEntered(sender), [], url.absoluteString)
            XCTAssertEqual(view.draggingUpdated(sender), [], url.absoluteString)
            XCTAssertFalse(view.prepareForDragOperation(sender), url.absoluteString)
            XCTAssertFalse(view.performDragOperation(sender), url.absoluteString)
            XCTAssertEqual(acceptedCount, 0)
        }
    }

    @MainActor
    func testUnreadableRegularFileIsRejected() async throws {
        let files = try DropFiles()
        defer { files.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: files.first.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.first.path) }
        guard !FileManager.default.isReadableFile(atPath: files.first.path) else {
            throw XCTSkip("This test account can read permission-restricted files.")
        }
        let sender = DraggingFixture(urls: [files.first])
        defer { sender.releasePasteboard() }
        let view = FileDropHostingView(rootView: EmptyView())
        XCTAssertEqual(view.draggingEntered(sender), [])
        XCTAssertFalse(view.prepareForDragOperation(sender))
    }

    @MainActor
    func testNativeDropDeliversOnceShrinksToMouthAndPreservesOriginalFiles() async throws {
        let files = try DropFiles()
        defer { files.remove() }
        let sender = DraggingFixture(urls: [files.first, files.second])
        defer { sender.releasePasteboard() }
        let view = FileDropHostingView(rootView: EmptyView())
        var deliveries: [[URL]] = []
        view.acceptFiles = { deliveries.append($0); return true }
        view.reducesMotion = { false }
        view.mouthPosition = { CGPoint(x: -933, y: 1271) }

        XCTAssertEqual(view.draggingEntered(sender), .copy)
        XCTAssertEqual(sender.numberOfValidItemsForDrop, 2)
        XCTAssertTrue(view.prepareForDragOperation(sender))
        XCTAssertTrue(sender.animatesToDestination)
        XCTAssertTrue(view.performDragOperation(sender))
        view.draggingEnded(sender)

        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries[0].map(\.standardizedFileURL), [files.first, files.second].map(\.standardizedFileURL))
        XCTAssertEqual(sender.enumerationCount, 1)
        XCTAssertTrue(sender.enumeratedInScreenCoordinates)
        XCTAssertEqual(sender.enumeratedFileURLsOnly, true)
        XCTAssertEqual(sender.items.map(\.draggingFrame), Array(repeating: CGRect(x: -935, y: 1269, width: 4, height: 4), count: 2))
        XCTAssertEqual(try Data(contentsOf: files.first), Data("First file stays here.".utf8))
        XCTAssertEqual(try Data(contentsOf: files.second), Data("Second file stays here.".utf8))
    }

    @MainActor
    func testReducedMotionDisablesNativeDragAnimationAndLeavesDragFramesUnchanged() async throws {
        let files = try DropFiles()
        defer { files.remove() }
        let sender = DraggingFixture(urls: [files.first])
        defer { sender.releasePasteboard() }
        sender.animatesToDestination = true
        let initialFrames = sender.items.map(\.draggingFrame)
        let view = FileDropHostingView(rootView: EmptyView())
        var deliveries = 0
        view.acceptFiles = { _ in deliveries += 1; return true }
        view.reducesMotion = { true }
        view.mouthPosition = { CGPoint(x: 960, y: 1062) }

        XCTAssertEqual(view.draggingEntered(sender), .copy)
        XCTAssertTrue(view.prepareForDragOperation(sender))
        XCTAssertFalse(sender.animatesToDestination)
        XCTAssertTrue(view.performDragOperation(sender))
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(sender.enumerationCount, 0)
        XCTAssertEqual(sender.items.map(\.draggingFrame), initialFrames)
        XCTAssertEqual(try Data(contentsOf: files.first), Data("First file stays here.".utf8))
    }

    @MainActor
    func testRejectedCornerCanBecomeValidDuringDragWithoutReenteringWindow() async throws {
        let files = try DropFiles()
        defer { files.remove() }
        let sender = DraggingFixture(urls: [files.first])
        defer { sender.releasePasteboard() }
        let presentation = expandedPresentation()
        let view = FileDropHostingView(rootView: EmptyView())
        view.frame = CGRect(origin: .zero, size: presentation.size)
        view.acceptsDropPoint = presentation.contains
        var presence: [Bool] = []
        var deliveries = 0
        view.dragPresenceChanged = { presence.append($0) }
        view.acceptFiles = { _ in deliveries += 1; return true }

        sender.draggingLocation = windowPoint(CGPoint(x: 1, y: 543), in: view)
        XCTAssertEqual(view.draggingEntered(sender), [])
        XCTAssertEqual(sender.numberOfValidItemsForDrop, 0)
        XCTAssertTrue(presence.isEmpty)
        XCTAssertFalse(view.prepareForDragOperation(sender))
        XCTAssertFalse(view.performDragOperation(sender))
        XCTAssertEqual(deliveries, 0)

        sender.draggingLocation = windowPoint(CGPoint(x: 280, y: 120), in: view)
        XCTAssertEqual(view.draggingUpdated(sender), .copy)
        XCTAssertEqual(view.draggingUpdated(sender), .copy)
        XCTAssertEqual(sender.numberOfValidItemsForDrop, 1)
        XCTAssertEqual(presence, [true], "Entering the visible shape must trigger passive opening exactly once.")

        sender.draggingLocation = windowPoint(CGPoint(x: 559, y: 543), in: view)
        XCTAssertEqual(view.draggingUpdated(sender), [])
        XCTAssertEqual(presence, [true, false])
        sender.draggingLocation = windowPoint(CGPoint(x: 280, y: 120), in: view)
        XCTAssertEqual(view.draggingUpdated(sender), .copy)
        XCTAssertEqual(presence, [true, false, true])
        XCTAssertTrue(view.prepareForDragOperation(sender))
        XCTAssertTrue(view.performDragOperation(sender))
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(try Data(contentsOf: files.first), Data("First file stays here.".utf8))
    }

    @MainActor
    func testNativeHitTestingConvertsToTheSameTopLeftRoundedShape() async {
        let presentation = expandedPresentation()
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 700))
        let view = FileDropHostingView(rootView: Color.black)
        view.frame = CGRect(x: 37, y: 53, width: 560, height: 544)
        parent.addSubview(view)
        // Current AppKit hosting views need a window before native hit testing.
        let window = NSWindow(contentRect: parent.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = parent
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        var observed: [CGPoint] = []
        view.acceptsHitPoint = { point in observed.append(point); return presentation.contains(point) }

        let corner = localPoint(CGPoint(x: 1, y: 543), in: view)
        XCTAssertNil(view.hitTest(view.convert(corner, to: parent)))
        XCTAssertEqual(observed.last, CGPoint(x: 1, y: 543))

        let center = localPoint(CGPoint(x: 280, y: 120), in: view)
        XCTAssertNotNil(view.hitTest(view.convert(center, to: parent)))
        XCTAssertEqual(observed.last, CGPoint(x: 280, y: 120))
    }

    @MainActor
    func testInsetTargetsKeepPreviewAcrossDimmedBackgroundAndDeliverChosenHalfOnce() async throws {
        let files = try DropFiles()
        defer { files.remove() }
        let sender = DraggingFixture(urls: [files.first])
        defer { sender.releasePasteboard() }
        let presentation = expandedPresentation()
        let layout = FileDropLayout(size: presentation.size, headerHeight: presentation.bandHeight)
        let view = FileDropHostingView(rootView: EmptyView())
        view.frame = CGRect(origin: .zero, size: presentation.size)
        view.acceptsDragPoint = presentation.contains
        var selected: FileDropDestination?
        var presence: [Bool] = []
        var delivered: [FileDropDestination] = []
        view.dragPresenceChanged = { presence.append($0) }
        view.dragLocationChanged = { point, _ in
            selected = point.flatMap { layout.destination(at: $0, hasCurrentSession: true) }
        }
        view.acceptsDropPoint = { _ in selected != nil }
        view.acceptFiles = { _ in
            guard let selected else { return false }
            delivered.append(selected)
            return true
        }
        sender.draggingLocation = windowPoint(CGPoint(x: 44, y: 32), in: view)
        XCTAssertEqual(view.draggingEntered(sender), [])
        XCTAssertEqual(presence, [true], "The dimmed header keeps the chooser open but does not accept a drop.")
        XCTAssertNil(selected)
        XCTAssertFalse(view.prepareForDragOperation(sender))
        let first = layout.frame(for: .currentSession)
        sender.draggingLocation = windowPoint(CGPoint(x: first.midX, y: first.maxY - 1), in: view)
        XCTAssertEqual(view.draggingUpdated(sender), .copy)
        XCTAssertEqual(selected, .currentSession)
        sender.draggingLocation = windowPoint(CGPoint(x: 4, y: first.midY), in: view)
        XCTAssertEqual(view.draggingUpdated(sender), [])
        XCTAssertNil(selected)
        XCTAssertEqual(presence, [true], "Crossing a dimmed margin must keep the preview open.")
        sender.draggingLocation = windowPoint(CGPoint(x: first.maxX, y: first.midY), in: view)
        XCTAssertEqual(view.draggingUpdated(sender), .copy)
        XCTAssertEqual(selected, .newSession)
        XCTAssertEqual(presence, [true], "Crossing the divider must not close or reset the chooser.")
        let second = layout.frame(for: .newSession)
        sender.draggingLocation = windowPoint(CGPoint(x: second.maxX - 1, y: second.minY + 1), in: view)
        XCTAssertEqual(view.draggingUpdated(sender), [], "The tray's rounded corner is not a drop target.")
        sender.draggingLocation = windowPoint(CGPoint(x: second.midX, y: second.midY), in: view)
        // The drop itself refreshes the final location even without draggingUpdated.
        XCTAssertTrue(view.prepareForDragOperation(sender))
        XCTAssertEqual(selected, .newSession)
        XCTAssertTrue(view.performDragOperation(sender))
        XCTAssertFalse(view.performDragOperation(sender))
        view.draggingEnded(sender)
        XCTAssertEqual(delivered, [.newSession])
        XCTAssertNil(selected)
        XCTAssertEqual(presence, [true, false])
    }

    @MainActor
    func testCancelledDragClearsChoiceAndFailedDeliveryDoesNotAnimate() async throws {
        let files = try DropFiles()
        defer { files.remove() }
        let sender = DraggingFixture(urls: [files.first])
        defer { sender.releasePasteboard() }
        let view = FileDropHostingView(rootView: EmptyView())
        var point: CGPoint?
        view.dragLocationChanged = { point = $0; _ = $1 }
        view.acceptFiles = { _ in false }
        view.mouthPosition = { .zero }
        XCTAssertEqual(view.draggingEntered(sender), .copy)
        XCTAssertNotNil(point)
        view.draggingExited(sender)
        XCTAssertNil(point)
        XCTAssertEqual(view.draggingEntered(sender), .copy)
        XCTAssertFalse(view.performDragOperation(sender))
        XCTAssertEqual(sender.enumerationCount, 0)
        view.draggingEnded(sender)
        XCTAssertNil(point)
    }

    @MainActor
    private func expandedPresentation() -> NotchPresentation {
        .expanded(NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                topInset: 0, leftArea: nil, rightArea: nil))
    }

    @MainActor
    private func localPoint(_ topLeft: CGPoint, in view: NSView) -> CGPoint {
        CGPoint(x: view.bounds.minX + topLeft.x,
                y: view.isFlipped ? view.bounds.minY + topLeft.y : view.bounds.maxY - topLeft.y)
    }

    @MainActor
    private func windowPoint(_ topLeft: CGPoint, in view: NSView) -> CGPoint {
        view.convert(localPoint(topLeft, in: view), to: nil)
    }
}

private struct DropFiles {
    let directory: URL
    let first: URL
    let second: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-native-drop-\(UUID().uuidString)", isDirectory: true)
        first = directory.appendingPathComponent("brief résumé with spaces.txt")
        second = directory.appendingPathComponent("second.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("First file stays here.".utf8).write(to: first)
        try Data("Second file stays here.".utf8).write(to: second)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
private final class DraggingFixture: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let items: [NSDraggingItem]
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggingLocation = NSPoint.zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    private(set) var enumerationCount = 0
    private(set) var enumeratedInScreenCoordinates = false
    private(set) var enumeratedFileURLsOnly: Bool?

    init(urls: [URL]) {
        items = urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(CGRect(x: 120, y: 80, width: 40, height: 30), contents: NSImage(size: NSSize(width: 40, height: 30)))
            return item
        }
        super.init()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    func releasePasteboard() { draggingPasteboard.releaseGlobally() }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        enumerationCount += 1
        enumeratedInScreenCoordinates = view == nil
        enumeratedFileURLsOnly = searchOptions[.urlReadingFileURLsOnly] as? Bool
        var stop = ObjCBool(false)
        for (index, item) in items.enumerated() {
            block(item, index, &stop)
            if stop.boolValue { break }
        }
    }
}
