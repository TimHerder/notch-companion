import AppKit
import SwiftUI
import XCTest
@testable import NotchCompanion

@MainActor final class PopupDismissalTests: XCTestCase {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func click(_ point: NSPoint, in window: NSWindow, type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                          clickCount: 1, pressure: 1)!
    }

    func testPopupAndToggleStayOpenWhileGapAndOtherWindowsDismissWithoutConsumingClick() {
        let host = window(), other = window()
        defer { host.close(); other.close() }
        let controls = NSView(frame: NSRect(x: 300, y: 20, width: 160, height: 22))
        let popup = NSView(frame: NSRect(x: 110, y: 50, width: 350, height: 250))
        host.contentView!.addSubview(controls)
        host.contentView!.addSubview(popup)
        let monitor = PopupDismissalMonitor()
        monitor.regions.add(controls)
        monitor.regions.add(popup)
        var dismissals = 0
        monitor.start { dismissals += 1 }
        defer { monitor.stop() }

        for point in [NSPoint(x: 320, y: 30), NSPoint(x: 120, y: 290)] {
            let event = click(point, in: host)
            XCTAssertTrue(monitor.handleLocalClick(event) === event)
            XCTAssertEqual(dismissals, 0, "The toggle and popup content must handle their own clicks")
        }
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            monitor.start { dismissals += 1 }
            let before = dismissals
            let event = click(NSPoint(x: 320, y: 46), in: host, type: type)
            XCTAssertTrue(monitor.handleLocalClick(event) === event)
            XCTAssertEqual(dismissals, before + 1, "The gap between the toggle and popup is outside")
        }
        monitor.start { dismissals += 1 }
        let event = click(NSPoint(x: 120, y: 290), in: other)
        XCTAssertTrue(monitor.handleLocalClick(event) === event)
        XCTAssertEqual(dismissals, 4, "Matching coordinates in another window are outside")
    }

    func testGlobalDismissalAndTeardownAreOneShotAndCanReopen() {
        _ = NSApplication.shared
        let monitor = PopupDismissalMonitor()
        var dismissals = 0
        monitor.start { dismissals += 1 }
        monitor.dismissPopup()
        monitor.dismissPopup()
        XCTAssertEqual(dismissals, 1)
        monitor.start { dismissals += 1 }
        monitor.stop()
        monitor.dismissPopup()
        XCTAssertEqual(dismissals, 1)
        monitor.start { dismissals += 1 }
        monitor.dismissPopup()
        XCTAssertEqual(dismissals, 2)
    }

    func testActualModelContextAndRuntimeOverlaysDismissThroughAppKitEventMonitor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notch-popup-\(UUID().uuidString)")
        let suite = "notch-popup-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: PopupTransport(), preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        model.showModelPicker = true
        model.showContextUsage = true
        model.expanded = true
        await model.connectRuntime(.hermes)
        let session = try XCTUnwrap(model.current)
        XCTAssertTrue(model.readyRuntimes.contains(.hermes))
        let overlays = [
            AnyView(ModelControlsView(model: model, choosingModel: true)),
            AnyView(ModelControlsView(model: model, showingContext: true)),
            AnyView(SessionRuntimeControl(model: model, session: session, choosingRuntime: true))
        ]
        for overlay in overlays {
            let host = window()
            defer { host.close() }
            let hosting = NSHostingView(rootView: overlay
                .padding(20).frame(width: 560, height: 400, alignment: .bottomTrailing))
            host.contentView = hosting
            settle(hosting)
            // Each toggle control and the popup has its own native hit region.
            let open = regions(in: hosting).count
            XCTAssertGreaterThanOrEqual(open, 2, "Both the toggle and popup need native hit regions")
            let popup = try XCTUnwrap(regions(in: hosting).max(by: { $0.bounds.height < $1.bounds.height }))
            XCTAssertGreaterThan(popup.bounds.height, 22)
            XCTAssertNil(popup.hitTest(NSPoint(x: 1, y: 1)), "Tracking must not intercept popup controls")
            let inside = popup.convert(NSPoint(x: 5, y: 5), to: nil)
            NSApp.sendEvent(click(inside, in: host))
            NSApp.sendEvent(click(inside, in: host, type: .leftMouseUp))
            settle(hosting)
            XCTAssertEqual(regions(in: hosting).count, open, "The offset popup must recognize clicks inside itself")
            NSApp.sendEvent(click(NSPoint(x: 5, y: 390), in: host))
            settle(hosting)
            XCTAssertEqual(regions(in: hosting).count, open - 1, "An outside click must remove the actual popup")
        }
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        view.layoutSubtreeIfNeeded()
    }

    private func regions(in view: NSView) -> [PopupDismissalRegion.RegionView] {
        (view as? PopupDismissalRegion.RegionView).map { [$0] } ?? view.subviews.flatMap { regions(in: $0) }
    }
}

@MainActor private final class PopupTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws {}
    func disconnect() {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}
