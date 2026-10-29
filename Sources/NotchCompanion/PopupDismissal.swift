import AppKit
import SwiftUI

@MainActor
final class PopupDismissalMonitor: ObservableObject {
    let regions = NSHashTable<NSView>.weakObjects()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var dismiss: (() -> Void)?

    func start(dismiss: @escaping () -> Void) {
        stop()
        self.dismiss = dismiss
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleLocalClick(event) }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPopup() }
        }
    }

    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        dismiss = nil
    }

    func handleLocalClick(_ event: NSEvent) -> NSEvent {
        let inside = regions.allObjects.contains { view in
            guard let window = view.window, window === event.window,
                  !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
        if !inside { dismissPopup() }
        // Dismiss without swallowing the click intended for another control.
        return event
    }

    func dismissPopup() {
        let action = dismiss
        stop()
        action?()
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

/// Track the controls and the offset popup separately, leaving the gap outside.
struct PopupDismissalRegion: NSViewRepresentable {
    let monitor: PopupDismissalMonitor

    func makeCoordinator() -> PopupDismissalMonitor { monitor }

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        monitor.regions.add(view)
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) {}

    static func dismantleNSView(_ view: RegionView, coordinator: PopupDismissalMonitor) {
        coordinator.regions.remove(view)
    }

    final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
