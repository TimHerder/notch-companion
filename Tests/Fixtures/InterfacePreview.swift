import SwiftUI
import AppKit
import ImageIO

@MainActor private final class PreviewTransport: HermesTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws {}
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
    func disconnect() {}
}

@main enum InterfacePreview {
    /// Check the production window's backing and live body changes without a runtime.
    @MainActor static func fullBodySmoke() throws {
        NSApp.setActivationPolicy(.accessory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("notch-body-\(UUID().uuidString)")
        let suite = "notch-body-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: temporary)
            preferences.removePersistentDomain(forName: suite)
        }
        preferences.set(true, forKey: AppModel.welcomeKey)
        let model = AppModel(storageURL: temporary.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: PreviewTransport(), preferences: preferences)
        let host = NativeHost(model: model)
        defer { host.shutdown(); model.shutdown() }
        host.showFullSession()
        guard let window = NSApp.windows.first(where: { $0.title == "Notch Companion" && !($0 is NSPanel) }),
              let content = window.contentView else { throw AppError("Full-session window missing") }
        guard !window.isOpaque, window.backgroundColor?.alphaComponent == 0, window.titlebarAppearsTransparent else {
            throw AppError("Full-session window backing hides its body material")
        }
        func backdrops(in view: NSView) -> [NSVisualEffectView] {
            let own = (view as? NSVisualEffectView).map { [$0] } ?? []
            return own + view.subviews.flatMap { backdrops(in: $0) }
        }
        // Return to Black to check that changing an already-open window removes blur.
        for style in [NotchBodyStyle.black, .glass, .smoked, .black] {
            UserDefaults.standard.register(defaults: [NotchBodyStyle.key: style.rawValue])
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
            content.layoutSubtreeIfNeeded()
            let materials = backdrops(in: content).filter { $0.material == .hudWindow && $0.blendingMode == .behindWindow }
            guard materials.count == (style == .black ? 0 : 1), materials.allSatisfy({ $0.state == .active }) else {
                throw AppError("Full-session \(style.rawValue): unexpected backdrop \(materials.count)")
            }
            print("PASS full-session \(style.rawValue): live material, clear backing, transparent title bar")
        }
    }

    /// Exercise the actual panel and its menu/outside-click tracking without
    /// connecting an agent or reading/writing the user's conversation registry.
    @MainActor static func previewRuntimeDropdown() throws {
        NSApp.setActivationPolicy(.accessory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("notch-dropdown-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suite = "notch-ui-fixture-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(Dictionary(uniqueKeysWithValues: [RuntimeKind.hermes, .codex, .pi].map {
            ($0.rawValue, RuntimeRoute.defaultProfile($0, defaults: preferences))
        }), forKey: "runtime.configuredProfiles")
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(storageURL: temporary.appendingPathComponent("sessions.json"), playsSounds: false, client: PreviewTransport(),
                             preferences: preferences)
        model.sessions[0].runtime = .hermes
        model.sessions[0].title = "Runtime dropdown preview"
        model.draft = "A draft retained while switching agents."
        model.connection = true
        model.connectionMessage = "Preview only — no runtime connection"
        let host = NativeHost(model: model)
        defer { host.shutdown(); model.shutdown() }
        // This fixture owns no agent work. Bound its lifetime even if a manual
        // review disconnects before closing it.
        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
            NSApp.stop(nil)
        }
        defer { timer.invalidate() }
        host.show()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
    }

    /// Drive the real host and windows (mock transport, temporary storage,
    /// sounds off) through an announcement, a glance, and promotion, checking
    /// actual window-server frames and stacking. Prints one line per check.
    @MainActor static func islandSmoke() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        NSApp.setActivationPolicy(.accessory)
        SoundPlayer.shared.enabled = false
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("notch-island-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suite = "notch-island-smoke-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(storageURL: temporary.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: PreviewTransport(), preferences: preferences)
        model.sessions[0].title = "Island smoke"
        model.statusEffects = true
        model.hoverPreview = .glance
        // Compact eyes below; the other layout/appearance pairs run at the end.
        model.updateStyle = .compact
        model.companionAppearance = .eyes
        // The first-run welcome has its own unit test; keep this sequence deterministic.
        preferences.set(true, forKey: AppModel.welcomeKey)
        let host = NativeHost(model: model)
        defer { host.shutdown(); model.shutdown() }
        let launchFrame = NSApp.windows.first(where: { $0 is CompanionPanel })?.frame ?? .zero
        let launchDrowsy = model.drowsy
        var failures = 0
        var panelFrame: () -> CGRect = { .zero }
        func check(_ ok: Bool, _ label: String) {
            print("\(ok ? "PASS" : "FAIL")  \(label)\(ok ? "" : " — panel \(panelFrame()), presentation \(model.notchPresentation.frame)")")
            if !ok { failures += 1 }
        }
        func pump(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        // The window server snaps a half-point origin to whole points.
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
        }
        /// Front-to-back order of this process's on-screen windows.
        func stacking() -> [Int] {
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
                .compactMap { $0[kCGWindowNumber as String] as? Int }
        }
        pump(0.9)
        guard let panel = NSApp.windows.first(where: { $0 is CompanionPanel }),
              let aura = NSApp.windows.first(where: { $0 is NotchAuraPanel }), let geometry = model.geometry else {
            throw AppError("Island smoke could not find its windows.")
        }
        panelFrame = { panel.frame }
        print("display: \(geometry.hasHardware ? "physical notch" : "no notch") \(geometry.screen.size), band \(geometry.bandHeight)")
        let resting = geometry.collapsedFrame
        if !model.reducedMotion {
            let seed = geometry.hasHardware ? geometry.hardware : CGRect(x: resting.midX - 50, y: resting.minY, width: 100, height: resting.height)
            check(close(launchFrame, seed) && launchDrowsy, "launch starts from the camera with closed eyes \(launchFrame.size)")
        }
        check(close(panel.frame, resting), "resting panel matches the resting band \(resting)")
        check(!model.drowsy, "the eyes are awake after the launch unfurl")
        check(!aura.isVisible, "aura window is ordered out at rest")

        model.setAnnouncementForPreview(NotchAnnouncement(kind: .finished, sessionID: model.sessions[0].id, title: "Island smoke"))
        pump(0.3)
        let order = stacking()
        check(aura.isVisible && aura.ignoresMouseEvents, "aura is on screen and click-through while playing")
        if let front = order.firstIndex(of: panel.windowNumber), let back = order.firstIndex(of: aura.windowNumber) {
            check(front < back, "aura is stacked directly behind the notch panel (\(front) < \(back))")
        } else { check(false, "window server lists both windows") }
        check(close(aura.frame, NotchAuraPanel.frame(around: panel.frame)), "aura frame wraps the live panel frame")
        pump(0.4)
        let announced = panel.frame
        check(abs(announced.height - resting.height) < 0.5 && abs(announced.maxY - resting.maxY) < 0.5,
              "announcement keeps the band's exact height and top edge")
        check(announced.width > resting.width + 60, "announcement widens the band (\(Int(resting.width)) → \(Int(announced.width)))")
        if geometry.hasHardware { check(abs(announced.minX - panel.frame.minX) <= 1 && abs(announced.minX - resting.minX) <= 1, "camera-side edge stays fixed") }
        pump(2.0)
        check(!aura.isVisible, "aura orders out after its effect")
        pump(2.6)
        check(close(panel.frame, resting), "band retracts to the resting frame")
        check(model.announcement == nil, "announcement clears after retracting")

        if !model.reducedMotion {
            // A failure shakes the windows (not the geometry), then lands exactly.
            model.setAnnouncementForPreview(NotchAnnouncement(kind: .failed, sessionID: model.sessions[0].id, title: "Island smoke"))
            var swing: CGFloat = 0
            var auraFollows = true
            for _ in 0..<25 {
                pump(0.02)
                swing = max(swing, abs(panel.frame.minX - model.notchPresentation.frame.minX))
                if aura.isVisible { auraFollows = auraFollows && close(aura.frame, NotchAuraPanel.frame(around: panel.frame)) }
            }
            check(swing >= 2, "a failure shakes the island (\(Int(swing)) pt)")
            check(auraFollows, "the aura shakes with the island")
            pump(0.4)
            check(close(panel.frame, model.notchPresentation.frame), "the shake settles on the announced band")
            pump(5.6)
            check(close(panel.frame, resting) && model.announcement == nil, "the failure band retracts to rest")
        }

        model.sessions[0].state = .finished
        model.sessions[0].messages = [ChatMessage(role: "assistant", text: "Smoke result")]
        pump(0.2)
        host.presentGlance()
        pump(0.7)
        check(model.glancing && !model.expanded, "glance is the presented tier")
        check(close(panel.frame, model.geometry!.glanceFrame), "panel matches the glance frame \(model.geometry!.glanceFrame.size)")
        check(!panel.isKeyWindow, "glance takes no keyboard focus")
        check(model.glanceEntries.first?.unread == true && model.unreadResultCount == 1, "glance shows the result without reading it")
        host.show()
        pump(0.7)
        check(model.expanded && !model.glancing, "click/shortcut promotes the glance to the full panel")
        check(close(panel.frame, model.geometry!.expandedFrame), "panel matches the expanded frame")
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        if locked {
            check(model.unreadResultCount == 1, "a locked desktop keeps the result unread (screen is locked)")
        } else {
            check(model.unreadResultCount == 0, "the full panel's conversation acknowledges the result")
        }
        model.sessions.append(CompanionSession(id: "other", title: "Background task", state: .finished))
        model.setAnnouncementForPreview(NotchAnnouncement(kind: .finished, sessionID: "other", title: "Background task"))
        pump(0.2)
        check(model.panelToast?.sessionID == "other" && !aura.isVisible && close(panel.frame, model.geometry!.expandedFrame),
              "another session's result shows an in-panel toast, without aura or band")
        model.setAnnouncementForPreview(NotchAnnouncement(kind: .finished, sessionID: model.sessions[0].id, title: "Island smoke"))
        pump(0.2)
        check(model.announcement == nil && model.panelToast?.sessionID == "other",
              "the conversation being read is not announced; the earlier toast stays")
        pump(4.3)
        check(model.panelToast == nil, "the toast leaves after its time")

        // A draft's folder picker opens above the open panel and leaves it open.
        model.sessions.insert(CompanionSession(id: "draft", title: "New session"), at: 0)
        model.selectSession("draft")
        pump(0.2)
        var pickerModal = false
        var pickerLayer: Int?
        var notchLayer: Int?
        let probe = Timer(timeInterval: 0.8, repeats: false) { _ in
            MainActor.assumeIsolated {
                let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                func layer(_ number: Int) -> Int? {
                    info.first { ($0[kCGWindowNumber as String] as? Int) == number }?[kCGWindowLayer as String] as? Int
                }
                if let picker = NSApp.modalWindow { pickerModal = picker is NSOpenPanel; pickerLayer = layer(picker.windowNumber) }
                notchLayer = layer(panel.windowNumber)
                NSApp.abortModal()
            }
        }
        RunLoop.main.add(probe, forMode: .common)
        check(model.canChooseCurrentWorkspace, "a draft offers its own folder choice")
        model.chooseSessionWorkspace()
        check(pickerModal, "the folder picker runs modally from the panel")
        check((pickerLayer ?? 0) > (notchLayer ?? .max), "the folder picker is above the notch (layer \(pickerLayer ?? -1) > \(notchLayer ?? -1))")
        check(model.expanded && close(panel.frame, model.geometry!.expandedFrame), "the panel stays open while choosing a folder")
        check(model.current?.workspacePath == nil, "cancelling the picker keeps the draft's folder")
        host.hide()
        pump(0.6)
        check(!model.expanded && !model.glancing && close(panel.frame, model.geometry!.collapsedFrame), "hide returns to rest")

        // A held click squeezes the band about its centre; the click then
        // springs the panel open from the squeezed shape.
        if !model.reducedMotion {
            let before = panel.frame
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: before.width / 2, y: before.height / 2),
                                   modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = mouse(.leftMouseDown) { NSApp.sendEvent(down) }
            pump(0.16)
            let squeezed = panel.frame
            check(squeezed.width < before.width - 4 && abs(squeezed.midX - before.midX) <= 1 && abs(squeezed.maxY - before.maxY) < 0.5
                  && abs(squeezed.height - before.height) < 0.5,
                  "a held click squeezes the band about its centre (\(Int(before.width)) → \(Int(squeezed.width)))")
            if let up = mouse(.leftMouseUp) { NSApp.sendEvent(up) }
            pump(0.7)
            check(model.expanded && close(panel.frame, model.geometry!.expandedFrame),
                  "releasing the click opens the panel from the squeezed band")
            host.hide()
            pump(0.6)
            check(close(panel.frame, model.geometry!.collapsedFrame), "the band is back at rest")
        }

        // A working session opens the live shoulder on the camera side; its
        // dot folds into it, and finishing retracts it.
        let plainRest = panel.frame
        var worker = CompanionSession(id: "worker", runtimeID: "live-worker", title: "Live work", state: .working,
                                      messages: [ChatMessage(role: "user", text: "Run the tests",
                                                             createdAt: Date().addingTimeInterval(-75))],
                                      tools: [ToolActivity(id: "t", name: "terminal", detail: "swift test")])
        worker.updatedAt = Date()
        model.sessions.append(worker)
        pump(0.7)
        check(model.geometry?.showsLiveActivity == true && model.geometry?.liveSessionIDs == ["worker"],
              "a working session becomes the live activity")
        check(close(panel.frame, model.geometry!.collapsedFrame) && panel.frame.width > plainRest.width + 30,
              "the live shoulder widens the band (\(Int(plainRest.width)) → \(Int(panel.frame.width)))")
        check(abs(panel.frame.height - plainRest.height) < 0.5 && abs(panel.frame.maxY - plainRest.maxY) < 0.5,
              "the live band keeps the notch's exact height and top edge")
        if geometry.hasHardware { check(abs(panel.frame.minX - plainRest.minX) <= 1, "the eyes' side stays fixed") }
        check(!model.restingIndicators.contains { $0.id == "worker" }, "the live session's dot folds into the live activity")
        model.sessions[model.sessions.firstIndex { $0.id == "worker" }!].state = .interrupted
        pump(0.7)
        check(model.geometry?.showsLiveActivity == false && close(panel.frame, model.geometry!.collapsedFrame),
              "the live shoulder retracts when the work stops")

        model.companionAppearance = .mascot
        // The first rendered mascot; with none rendered yet, Mascot shows the eyes.
        if let rendered = MascotCharacter.allCases.first(where: { MascotLibrary.library($0).isAvailable }) {
            model.mascotCharacter = rendered
            check(model.mascotEnabled, "\(rendered.label)'s assets are bundled")
        } else {
            print("SKIP  no mascot is rendered yet; Mascot falls back to the eyes")
        }
        model.setAnnouncementForPreview(NotchAnnouncement(kind: .finished, sessionID: model.sessions[0].id, title: "Island smoke"))
        pump(0.7)
        check(!model.staging && model.notchPresentation.announce > 0.99 && close(panel.frame, model.geometry!.collapsedFrame),
              "compact updates still widen only the shoulder with Mascot selected")
        model.setAnnouncementForPreview(nil)
        pump(0.6)

        model.updateStyle = .popup
        for appearance in CompanionAppearance.allCases {
            model.companionAppearance = appearance
            let rest = panel.frame
            model.setAnnouncementForPreview(NotchAnnouncement(kind: .finished, sessionID: model.sessions[0].id, title: "Island smoke"))
            pump(0.7)
            // A mascot's window reaches below the body for its overhang.
            var stageWindow = model.geometry!.stageFrame
            if model.mascotEnabled {
                stageWindow.origin.y -= MascotLayout.overhang
                stageWindow.size.height += MascotLayout.overhang
            }
            check(model.staging && close(panel.frame, stageWindow),
                  "a result opens the popup with \(appearance.label) \(stageWindow.size)")
            check(abs(panel.frame.maxY - rest.maxY) < 0.5, "the stage hangs from the screen's top edge")
            check(aura.isVisible && !panel.isKeyWindow, "the stage lights its edge and takes no focus")
            if let shot = ProcessInfo.processInfo.environment["NOTCH_STAGE_SHOT"] {
                // The real window, mid-act, for visual review (needs screen recording access).
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l\(panel.windowNumber)", shot]
                try? process.run()
                process.waitUntilExit()
            }
            pump(UnifiedNotchMotion.announcementCollapseDuration + NotchAnnouncement.Kind.finished.stageDuration)
            check(!model.staging && close(panel.frame, model.geometry!.collapsedFrame) && model.announcement == nil,
                  "the stage retracts to rest after its hold")
            // A question answered elsewhere lands, then the stage retracts early.
            model.sessions[0].state = .waiting
            model.setAnnouncementForPreview(NotchAnnouncement(kind: .needsInput, sessionID: model.sessions[0].id, title: "Island smoke"))
            pump(0.7)
            check(model.staging, "a question opens the stage")
            model.sessions[0].state = .working
            pump(2.2)
            check(!model.staging, "an answered question retracts the stage early")
            model.sessions[0].state = .finished
            pump(0.6)
            // Clicking the stage opens its session in the panel.
            model.setAnnouncementForPreview(NotchAnnouncement(kind: .finished, sessionID: model.sessions[0].id, title: "Island smoke"))
            pump(0.7)
            model.openAnnouncedSession()
            pump(0.8)
            check(model.expanded && !model.staging && close(panel.frame, model.geometry!.expandedFrame),
                  "clicking the stage opens the session in the panel")
            host.hide()
            pump(0.6)
            check(close(panel.frame, model.geometry!.collapsedFrame), "the panel closes back to rest")
        }
        print(failures == 0 ? "island smoke: all checks passed" : "island smoke: \(failures) failed")
        if failures > 0 { throw AppError("Island smoke failed \(failures) checks.") }
    }

    /// A small generated chart, so media fixtures need no checked-in images.
    @MainActor static func sampleChart() throws -> Data {
        let image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
            NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.2, blue: 0.18, alpha: 1),
                       ending: NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.09, alpha: 1))?.draw(in: rect, angle: 90)
            for (index, value) in [0.35, 0.55, 0.42, 0.7, 0.62, 0.85, 0.78].enumerated() {
                NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.66, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 50 + CGFloat(index) * 80, y: 40, width: 46, height: 280 * value), xRadius: 6, yRadius: 6).fill()
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw AppError("The sample chart could not be drawn.")
        }
        return png
    }

    static func samplePDF() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        if let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) {
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        }
        return data as Data
    }

    @MainActor static func renderChanges(output: URL, temporary: URL, preferences: UserDefaults) throws {
        let patch = """
        diff --git a/Sources/Companion.swift b/Sources/Companion.swift
        --- a/Sources/Companion.swift
        +++ b/Sources/Companion.swift
        @@ -1,3 +1,4 @@
         func greet() {
        -    print("Hello")
        +    print("Welcome back")
        +    showChanges()
         }
        """
        var summary = TurnChanges(id: "turn", workspace: "/tmp/Project", baseRevision: "a1b2c3d4", source: .agent,
            files: UnifiedDiff.files(patch) + [ChangedFile(path: "Tests/CompanionTests.swift", kind: "Added", additions: 12),
                ChangedFile(path: "Resources/companion.png", additions: nil, deletions: nil, patch: "Binary files differ")])
        for expanded in [false, true] {
            try render(ChangeSummaryView(summary: summary, editorName: "VS Code", open: { _ in }, chooseEditor: { _ in },
                onInspect: {}, showsFiles: expanded, selectedPath: expanded ? summary.files[0].path : nil)
                .padding(16).frame(width: 540, height: expanded ? 520 : 80, alignment: .top)
                .background(CompanionStyle.background).environment(\.colorScheme, .dark),
                size: NSSize(width: 540, height: expanded ? 520 : 80), name: expanded ? "changes-diff" : "changes-collapsed", output: output)
        }
        summary.source = .workspace
        try render(ChangeSummaryView(summary: summary, editorName: "VS Code", open: { _ in }, chooseEditor: { _ in }, onInspect: {}, showsFiles: true)
            .padding(16).frame(width: 380, height: 350, alignment: .top).background(CompanionStyle.background).environment(\.colorScheme, .dark),
            size: NSSize(width: 380, height: 350), name: "changes-workspace-small", output: output)
        // A parent turn with a shared child (its file in the parent's capture too) and a worktree child.
        let tests = ChangedFile(path: "Tests/CompanionTests.swift", kind: "Added", additions: 12)
        var delegated = TurnChanges(id: "turn", workspace: "/tmp/Project", baseRevision: "a1b2c3d4", files: UnifiedDiff.files(patch) + [tests], capturedAt: Date())
        delegated.delegated = [
            TurnChanges(id: "child", workspace: "/tmp/Project", files: [tests], capturedAt: Date(), label: "Write the welcome tests · Claude Code"),
            TurnChanges(id: "child-2", workspace: "/tmp/Worktrees/Project-1a2b/streaming", files: UnifiedDiff.files(patch.replacingOccurrences(of: "Welcome back", with: "Hi again"))
                + [ChangedFile(path: "Sources/Stream.swift", kind: "Added", additions: 48)], capturedAt: Date(), label: "Try a streaming greeting · Codex · worktree")]
        try render(ChangeSummaryView(summary: delegated, editorName: "VS Code", open: { _ in }, chooseEditor: { _ in }, onInspect: {},
            showsFiles: true, selectedPath: "child-2\u{0}Sources/Companion.swift")
            .padding(16).frame(width: 540, height: 640, alignment: .top).background(CompanionStyle.background).environment(\.colorScheme, .dark),
            size: NSSize(width: 540, height: 640), name: "changes-delegated", output: output)
        summary.source = .agent
        let model = AppModel(storageURL: temporary.appendingPathComponent("changes.json"), playsSounds: false, client: PreviewTransport(), preferences: preferences)
        defer { model.shutdown() }
        model.sessions[0].runtime = .codex
        model.sessions[0].title = "Add a welcome message"
        model.sessions[0].workspacePath = summary.workspace
        model.sessions[0].messages = [ChatMessage(id: "turn", role: "user", text: "Add a welcome message.", turnID: "turn"),
            ChatMessage(role: "assistant", text: "Added the welcome message and its tests.", turnID: "turn")]
        model.sessions[0].state = .finished
        model.sessions[0].changes = [summary]
        model.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0, leftArea: nil, rightArea: nil)
        model.notchPresentation = .expanded(model.geometry!)
        model.expanded = true
        model.reducedMotion = true
        try render(UnifiedNotchView(model: model), size: model.geometry!.expandedFrame.size, name: "changes-compact", output: output)
        try render(FullSessionView(model: model), size: NSSize(width: 900, height: 660), name: "changes-full", output: output)
    }

    /// A Claude parent with a native subagent and an app-owned Codex child, the
    /// child's own conversation, and the parent's Delegation result row.
    @MainActor static func renderDelegation(output: URL, temporary: URL, preferences: UserDefaults) throws {
        let model = AppModel(storageURL: temporary.appendingPathComponent("delegation.json"), playsSounds: false, client: PreviewTransport(), preferences: preferences)
        defer { model.shutdown() }
        let ask = ChatMessage(id: "turn", role: "user", text: "Ship the parser fix, and have Codex review it.", turnID: "turn")
        let result = ChatMessage(id: "wake", role: "user", text: """
        Delegated task "Review the parser fix" (taskId 3f2a9c1e-6b0d-4a51-9e2f-8c7d1b4a0e65, sessionId child, Codex, review) completed.

        Two findings: the empty-input branch skips the error, and `parse(_:)` lacks a test for trailing commas.
        """, turnID: "wake", kind: ChatMessage.delegationResult)
        var parent = CompanionSession(id: "parent", runtimeID: "live-parent", title: "Parser fix", state: .working,
            messages: [ask, ChatMessage(role: "assistant", text: "Fixed the parser and asked Codex for a review.", turnID: "turn"),
                       ChatMessage(id: "notice", role: "user", text: "Delegated task \"Review the parser fix\" (taskId 3f2a9c1e…, sessionId child) asks:\n\n- Should trailing commas be accepted? (Yes / No)\n\nRead it with pending_request_read and answer with pending_request_respond. If you cannot answer it, ask the user.", turnID: "notice", kind: ChatMessage.delegationNotice),
                       ChatMessage(role: "assistant", text: "Answered: yes, trailing commas are accepted.", turnID: "notice"), result,
                       ChatMessage(role: "assistant", text: "Addressing both findings now.", turnID: "wake")],
            workspacePath: "/tmp/Parser")
        parent.runtime = .claude
        parent.parentTurnComplete = false
        parent.tools = [ToolActivity(id: "delegate", name: "mcp__notch__delegate_task", detail: "Review the parser fix", state: .finished, turnID: "turn")]
        var child = CompanionSession(id: "child", title: "Review the parser fix", state: .finished,
            messages: [ChatMessage(id: "task", role: "user", text: "Act as the review sub-agent for this task.\n\nReview the parser fix in Sources/Parser.swift.", turnID: "task"),
                       ChatMessage(role: "assistant", text: "Two findings: the empty-input branch skips the error, and `parse(_:)` lacks a test for trailing commas.", turnID: "task")],
            workspacePath: "/tmp/Parser")
        child.runtime = .codex
        child.parentSessionID = "parent"
        child.delegation = DelegationRecord(taskID: "3f2a9c1e", role: "review", wokenCompletionID: "done", wakeMessageID: "wake")
        child.completionID = "done"
        parent.agents = [ChildAgent(id: "native", title: "Explore test fixtures", state: .finished, turnID: "turn"),
                         ChildAgent(id: "delegation:3f2a9c1e", title: child.title, state: .finished, turnID: "turn", sessionID: "child", runtime: .codex, role: "review"),
                         ChildAgent(id: "delegation:7c1d", title: "Benchmark the tokenizer", state: .working, turnID: "wake", sessionID: "child-2", runtime: .pi, role: "test")]
        var running = CompanionSession(id: "child-2", title: "Benchmark the tokenizer", state: .working, messages: [], workspacePath: "/tmp/Parser")
        running.runtime = .pi
        running.parentSessionID = "parent"
        running.delegation = DelegationRecord(taskID: "7c1d", role: "test")
        model.sessions = [parent, child, running]
        model.currentID = "parent"
        model.connection = true
        model.reducedMotion = true
        model.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0,
                                       leftArea: nil, rightArea: nil, indicatorCount: model.sessionIndicators.count)
        model.notchPresentation = .expanded(model.geometry!)
        model.expanded = true
        let compact = model.geometry!.expandedFrame.size
        let full = NSSize(width: 900, height: 660)
        model.page = .team
        try render(UnifiedNotchView(model: model), size: compact, name: "delegation-team", output: output)
        try render(FullSessionView(model: model, tab: "Team"), size: full, name: "delegation-team-full", output: output)
        model.page = .session

        try render(UnifiedNotchView(model: model), size: compact, name: "delegation-result", output: output)
        try render(FullSessionView(model: model), size: full, name: "delegation-result-full", output: output)
        model.openDelegatedSession("child")
        try render(UnifiedNotchView(model: model), size: compact, name: "delegation-child", output: output)
        model.selectSession("parent")
        model.delegationWaits = ["parent": 1]
        try render(UnifiedNotchView(model: model), size: compact, name: "delegation-waiting", output: output)
    }

    @MainActor static func render<V: View>(_ content: V, size: NSSize, name: String, output: URL,
                                           settle: TimeInterval = 0.35) throws {
        // `--only a,b` renders just the fixtures whose names start with one of these prefixes.
        if let index = CommandLine.arguments.firstIndex(of: "--only"), index + 1 < CommandLine.arguments.count,
           !CommandLine.arguments[index + 1].split(separator: ",").contains(where: { name.hasPrefix($0) }) { return }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: settle))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "InterfacePreview", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "InterfacePreview", code: 2)
        }
        try data.write(to: output.appendingPathComponent("\(name).png"))
        print("\(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
        window.close()
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        // `--theme tahoe` renders the expanded panel in that design (default Refined).
        // Registered rather than set, so the fixture never persists a preference.
        if let index = CommandLine.arguments.firstIndex(of: "--theme"), index + 1 < CommandLine.arguments.count {
            guard let theme = PanelTheme(rawValue: CommandLine.arguments[index + 1]) else {
                fatalError("Unknown theme \(CommandLine.arguments[index + 1]); use \(PanelTheme.allCases.map(\.rawValue))")
            }
            UserDefaults.standard.register(defaults: [PanelTheme.key: theme.rawValue])
            PanelTheme.current = theme
        }
        if CommandLine.arguments.contains("--interactive-runtime") {
            try previewRuntimeDropdown()
            return
        }
        if CommandLine.arguments.contains("--island-smoke") {
            try islandSmoke()
            return
        }
        if CommandLine.arguments.contains("--full-body-smoke") {
            try fullBodySmoke()
            return
        }
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("notch-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suite = "notch-ui-fixture-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(Dictionary(uniqueKeysWithValues: [RuntimeKind.hermes, .codex, .pi].map {
            ($0.rawValue, RuntimeRoute.defaultProfile($0, defaults: preferences))
        }), forKey: "runtime.configuredProfiles")
        defer { preferences.removePersistentDomain(forName: suite) }
        UserDefaults.standard.register(defaults: [NotchBodyStyle.key: NotchBodyStyle.black.rawValue])
        preferences.register(defaults: [NotchUpdateStyle.key: NotchUpdateStyle.compact.rawValue,
                                        CompanionAppearance.key: CompanionAppearance.eyes.rawValue])
        if CommandLine.arguments.contains("--island-only") {
            try renderIsland(output: output, temporary: temporary, preferences: preferences)
            return
        }
        if CommandLine.arguments.contains("--changes-only") {
            try renderChanges(output: output, temporary: temporary, preferences: preferences)
            return
        }
        if CommandLine.arguments.contains("--delegation-only") {
            try renderDelegation(output: output, temporary: temporary, preferences: preferences)
            return
        }
        let model = AppModel(storageURL: temporary.appendingPathComponent("sessions.json"), playsSounds: false, client: PreviewTransport(), preferences: preferences)
        defer { model.shutdown() }
        let user = ChatMessage(id: "turn", role: "user", text: "Review the plan and suggest next steps.", turnID: "turn")
        let response = ChatMessage(role: "assistant", text: """
        ## Ready for review
        The conversation now supports **structured results** and selectable code.

        - Keep the current notch dimensions.
        - Review the implementation with a longer real-world prompt.
          - Check keyboard shortcuts and saved drafts.

        ```swift
        let message = "A deliberately long line to check horizontal scrolling without widening the conversation surface or clipping the copy action."
        print(message)
        ```
        """, turnID: "turn")
        model.sessions = [
            CompanionSession(id: "review", runtimeID: "live-review", title: "Website accessibility review", state: .finished,
                             messages: [user, response], draft: "Summarize the changes.\nInclude keyboard navigation.\nKeep it concise.\nThen list the remaining checks.\nPreserve this fifth line too.", workspacePath: "/tmp/Website"),
            CompanionSession(id: "running", title: "Compare the implementation options", state: .working),
            CompanionSession(id: "question", title: "Plan the next release", state: .waiting),
            CompanionSession(id: "failure", title: "Review delegated work", state: .failed),
            CompanionSession(id: "archive", title: "Last week’s notes", state: .finished, isArchived: true),
            // Read and idle for three days: listed under Archived without a flag.
            CompanionSession(id: "dormant", title: "Welcome email for testers", state: .finished,
                             messages: [ChatMessage(role: "user", text: "Draft a welcome email for new testers."),
                                        ChatMessage(role: "assistant", text: "Here is a short draft for review.")],
                             updatedAt: Date().addingTimeInterval(-3 * 86_400), workspacePath: "/tmp/Website",
                             completionID: "dormant-result", acknowledgedCompletionID: "dormant-result")
        ]
        model.sessions[1].runtime = .codex
        model.sessions[3].isLegacyPrivate = true
        model.currentID = "review"
        model.workspacePath = "/tmp/New Projects"
        let sampleChoice = RuntimeModelChoice(model: "fixture-model", provider: "fixture-provider")
        let sampleCatalog = RuntimeModelCatalog(defaultModel: sampleChoice, models: [
            RuntimeModelOption(choice: sampleChoice, title: "Fixture Model", reasoningEfforts: ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"], defaultReasoningEffort: "medium"),
            RuntimeModelOption(choice: RuntimeModelChoice(model: "fixture-long-context-model", provider: "fixture-provider"), title: "Fixture Long Context Model")])
        for runtime in RuntimeKind.allCases {
            for cwd in [model.workspacePath, "/tmp/Website"] {
                model.modelCatalogs[ModelCatalogKey(route: RuntimeRoute(runtime: runtime), cwd: cwd)] = sampleCatalog
            }
        }
        model.connection = true
        model.connectionMessage = "Hermes connected"
        model.reducedMotion = true
        model.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0,
                                       leftArea: nil, rightArea: nil, indicatorCount: model.sessionIndicators.count)
        model.notchPresentation = .expanded(model.geometry!)
        model.expanded = true
        // Whole expanded notch, header included. Glass cannot render offscreen,
        // so fixtures use the black body; the setting itself is not persisted.
        UserDefaults.standard.register(defaults: [NotchBodyStyle.key: NotchBodyStyle.black.rawValue])
        let compact = model.geometry!.expandedFrame.size
        let full = NSSize(width: 900, height: 660)
        model.page = .session
        if CommandLine.arguments.contains("--settings-only") {
            for width: CGFloat in [560, 252] {
                try render(SettingsContent(model: model, inNotch: true).padding(20)
                    .frame(width: width, height: 3200, alignment: .top)
                    .background(CompanionStyle.background).foregroundStyle(CompanionStyle.text)
                    .environment(\.colorScheme, .dark),
                    size: NSSize(width: width, height: 3200), name: "settings-version-\(Int(width))", output: output)
            }
            return
        }
        if CommandLine.arguments.contains("--busy-composer-only") {
            model.sessions[0].runtime = .codex
            model.sessions[0].runtimeID = "preview"
            model.sessions[0].parentTurnComplete = false
            model.sessions[0].state = .working
            model.draft = ""
            try render(UnifiedNotchView(model: model), size: compact, name: "busy-steer-empty", output: output)
            model.sessions[0].runtime = .claude
            var claudeCapabilities = RuntimeKind.claude.capabilities
            claudeCapabilities.steering = true
            model.sessions[0].runtimeInfo = RuntimeSessionInfo(capabilities: claudeCapabilities)
            try render(UnifiedNotchView(model: model), size: compact, name: "busy-steer-claude", output: output)
            model.sessions[0].runtime = .codex
            model.sessions[0].runtimeInfo = nil
            model.draft = "Keep the existing design and focus on the keyboard behavior."
            model.sessions[0].queuedSends = [QueuedSend(id: "preview-queue", text: "When finished, summarize the changes.", attachments: [])]
            try render(UnifiedNotchView(model: model), size: compact, name: "busy-steer-queued", output: output)
            try render(FullSessionView(model: model), size: full, name: "busy-steer-full", output: output)
            model.sessions[0].runtime = .deepseek
            model.draft = ""
            try render(UnifiedNotchView(model: model), size: compact, name: "busy-queue-only", output: output)
            return
        }
        if CommandLine.arguments.contains("--full-body-only") {
            for style in NotchBodyStyle.allCases {
                UserDefaults.standard.register(defaults: [NotchBodyStyle.key: style.rawValue])
                try render(FullSessionView(model: model), size: full, name: "full-body-\(style.rawValue)", output: output)
                try render(FullSessionView(model: model, utility: .settings), size: full, name: "full-body-\(style.rawValue)-settings", output: output)
            }
            return
        }
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-conversation", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-conversation", output: output)
        // A wide window keeps the transcript and composer at a reading width.
        try render(FullSessionView(model: model), size: NSSize(width: 1440, height: 900), name: "full-conversation-wide", output: output)
        try render(FullSessionView(model: model, tab: "Activity"), size: full, name: "full-activity", output: output)
        try render(FullSessionView(model: model, tab: "Team"), size: full, name: "full-team-empty", output: output)
        let sending = AppModel(storageURL: temporary.appendingPathComponent("sending.json"), playsSounds: false,
                               client: PreviewTransport(), preferences: preferences)
        defer { sending.shutdown() }
        sending.sessions = [model.sessions[0]]
        sending.currentID = sending.sessions[0].id
        sending.geometry = model.geometry
        sending.notchPresentation = model.notchPresentation
        sending.expanded = true
        sending.reducedMotion = true
        sending.connection = true
        let stagedMessage = ChatMessage(id: "sending", role: "user", text: sending.draft, turnID: "sending")
        sending.sessions[0].stagedSubmission = StagedSubmission(message: stagedMessage, draft: sending.draft, attachments: [])
        sending.sessions[0].draft = ""
        sending.submitting = true
        try render(UnifiedNotchView(model: sending), size: compact, name: "compact-sending", output: output)
        try render(FullSessionView(model: sending), size: full, name: "full-sending", output: output)
        // Synthetic metadata in actual native views; never claims live provider usage.
        model.showModelPicker = true
        model.showContextUsage = true
        model.sessions[0].runtimeInfo = RuntimeSessionInfo(model: "fixture-model", provider: "fixture-provider",
            context: RuntimeContextUsage(used: 42000, limit: 200000, estimated: true))
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-model-context", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-model-context", output: output)
        try render(ModelControlsView(model: model, choosingModel: true).padding(20)
            .frame(width: 560, height: 350, alignment: .bottomTrailing).background(CompanionStyle.background)
            .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
            size: NSSize(width: 560, height: 350), name: "model-chooser", output: output)
        for (name, query) in [("filtered", "long-context"), ("empty", "missing-model")] {
            try render(ModelControlsView(model: model, choosingModel: true, search: query).padding(20)
                .frame(width: 560, height: 350, alignment: .bottomTrailing).background(CompanionStyle.background)
                .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
                size: NSSize(width: 560, height: 350), name: "model-chooser-\(name)", output: output)
        }
        model.sessions[0].modelOverride = sampleCatalog.models[1].choice
        try render(ModelControlsView(model: model, choosingModel: true).padding(20)
            .frame(width: 560, height: 350, alignment: .bottomTrailing).background(CompanionStyle.background)
            .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
            size: NSSize(width: 560, height: 350), name: "model-chooser-no-effort", output: output)
        model.sessions[0].modelOverride = nil
        model.sessions[0].state = .working
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-busy-draft", output: output)
        // A working turn's tool calls: older ones fold away, the latest three stay live.
        let (toolMessages, savedTools) = (model.sessions[0].messages, model.sessions[0].tools)
        let toolStart = Date().addingTimeInterval(-40)
        model.sessions[0].messages = [ChatMessage(id: "tools-turn", role: "user", text: "Run the tests and fix what fails.", turnID: "tools-turn")]
        model.sessions[0].tools = [
            ToolActivity(id: "read", name: "read_file", detail: "Sources/NotchCompanion/Views.swift", state: .finished,
                         startedAt: toolStart, finishedAt: toolStart.addingTimeInterval(0.4), turnID: "tools-turn"),
            ToolActivity(id: "grep", name: "grep", detail: "CompanionStyle", state: .finished,
                         startedAt: toolStart.addingTimeInterval(1), finishedAt: toolStart.addingTimeInterval(1.2), turnID: "tools-turn"),
            ToolActivity(id: "build", name: "terminal", detail: "swift build --product NotchCompanion", state: .finished,
                         startedAt: toolStart.addingTimeInterval(2), finishedAt: toolStart.addingTimeInterval(26), turnID: "tools-turn"),
            ToolActivity(id: "edit", name: "edit_file", detail: "Sources/NotchCompanion/NotchControls.swift", state: .failed,
                         startedAt: toolStart.addingTimeInterval(27), finishedAt: toolStart.addingTimeInterval(27.3), turnID: "tools-turn"),
            ToolActivity(id: "test", name: "terminal", detail: "swift test --filter NotchControlsTests", state: .working,
                         startedAt: toolStart.addingTimeInterval(30), turnID: "tools-turn")]
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-tool-log", output: output)
        (model.sessions[0].messages, model.sessions[0].tools) = (toolMessages, savedTools)
        model.sessions[0].state = .finished
        try render(ModelControlsView(model: model, showingContext: true).padding(20)
            .frame(width: 560, height: 170, alignment: .bottom).background(CompanionStyle.background)
            .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
            size: NSSize(width: 560, height: 170), name: "context-details", output: output)
        model.showModelPicker = false
        let contextSamples: [(String, RuntimeContextUsage?)] = [
            ("example", RuntimeContextUsage(used: 20000, limit: 828000)),
            ("empty", RuntimeContextUsage(used: 0, limit: 200000)),
            ("half", RuntimeContextUsage(used: 100000, limit: 200000)),
            ("full", RuntimeContextUsage(used: 200000, limit: 200000)),
            ("over-limit", RuntimeContextUsage(used: 220000, limit: 200000)),
            ("unknown-window", RuntimeContextUsage(used: 42000)),
            ("unavailable", nil)
        ]
        for (name, usage) in contextSamples {
            model.sessions[0].runtimeInfo?.context = usage
            let closed = NSHostingView(rootView: ModelControlsView(model: model).frame(width: 220))
            let opened = NSHostingView(rootView: ModelControlsView(model: model, showingContext: true).frame(width: 220))
            guard closed.fittingSize.height > 0, closed.fittingSize == opened.fittingSize else {
                throw AppError("Context details changed the control row size for \(name).")
            }
            try render(ModelControlsView(model: model).padding(10)
                .frame(width: 220, height: 44).background(CompanionStyle.background)
                .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
                size: NSSize(width: 220, height: 44), name: "context-gauge-\(name)", output: output)
            try render(ModelControlsView(model: model, showingContext: true).padding(20)
                .frame(width: 260, height: 170, alignment: .bottom).background(CompanionStyle.background)
                .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
                size: NSSize(width: 260, height: 170), name: "context-details-\(name)", output: output)
        }
        try render(ModelControlsView(model: model, showingContext: true).padding(20)
            .frame(width: 260, height: 200, alignment: .bottom).background(CompanionStyle.background)
            .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
            size: NSSize(width: 260, height: 200), name: "context-details-unavailable", output: output)
        model.showModelPicker = true
        model.sessions[0].runtimeInfo?.context = RuntimeContextUsage(used: 42000, limit: 200000, estimated: true)
        model.sessions[0].modelOverride = RuntimeModelChoice(model: "fixture-long-context-model", provider: "fixture-provider")
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-model-pending", output: output)
        model.sessions[0].modelOverride = nil
        // Permission modes on a mapped harness, and Full access's header marker.
        let fixtureRuntime = model.sessions[0].runtime
        model.showPermissionModes = true
        model.sessions[0].runtime = .codex
        model.sessions[0].permissionMode = .autoEdit
        try render(ModelControlsView(model: model, choosingPermissions: true).padding(20)
            .frame(width: 560, height: 300, alignment: .bottomTrailing).background(CompanionStyle.background)
            .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
            size: NSSize(width: 560, height: 300), name: "permission-modes", output: output)
        model.sessions[0].permissionMode = .fullAccess
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-full-access", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-full-access", output: output)
        model.sessions[0].permissionMode = nil
        model.sessions[0].runtime = fixtureRuntime
        model.showPermissionModes = false
        // Usage: synthetic limits and token reports in the actual page; never live account data.
        model.showUsage = true
        model.receive("runtime.rateLimits", payload: ["runtime": "codex", "limits": [
            RuntimeRateLimit(name: "5-hour", usedPercent: 42, resetsAt: Date().addingTimeInterval(7_200)),
            RuntimeRateLimit(name: "Weekly", usedPercent: 81, resetsAt: Date().addingTimeInterval(4 * 86_400))]])
        model.receive("runtime.rateLimits", payload: ["runtime": "claude", "limits": [
            RuntimeRateLimit(name: "5-hour", resetsAt: Date().addingTimeInterval(3_600), reached: true),
            RuntimeRateLimit(name: "Weekly", usedPercent: 63)]])
        let unreported = model.sessions.map(\.turnTokens)
        for index in model.sessions.indices where index % 2 == 0 {
            for message in model.sessions[index].messages where message.role == "user" {
                model.sessions[index].turnTokens[message.turnID ?? message.id] = 18_400 * (index + 1)
            }
        }
        model.page = .usage
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-usage", output: output)
        try render(UsageView(model: model).padding(.horizontal, 20).frame(width: 560, height: 760)
            .background(CompanionStyle.background).foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
            size: NSSize(width: 560, height: 760), name: "usage-page", output: output)
        model.page = .sessions
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-sessions-usage", output: output)
        model.page = .session
        model.showContextUsage = true
        for runtime in [RuntimeKind.codex, .claude] {
            model.sessions[0].runtime = runtime
            try render(ModelControlsView(model: model, showingContext: true).padding(20)
                .frame(width: 560, height: 260, alignment: .bottom).background(CompanionStyle.background)
                .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
                size: NSSize(width: 560, height: 260), name: "context-details-limits-\(runtime.rawValue)", output: output)
        }
        model.sessions[0].runtime = fixtureRuntime
        model.page = .session
        for index in model.sessions.indices { model.sessions[index].turnTokens = unreported[index] }
        model.showUsage = false
        // SnapShot's composer button and the Screen Recording hint; no real capture.
        model.showSnapShot = true
        model.snapShotSource = SnapShotSource(processID: 1, appName: "Safari", windowID: 1, title: "Release notes")
        model.snapShotNeedsPermission = true
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-snapshot", output: output)
        model.snapShotNeedsPermission = false
        model.snapShotSource = nil
        model.showSnapShot = false
        model.showModelPicker = false
        model.showContextUsage = false
        let external = model.geometry!
        // MacBook-style camera; a dashed outline marks pixels that do not exist.
        let notched = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
                                    leftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                    rightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
        model.geometry = notched
        model.notchPresentation = .expanded(notched)
        let camera = notched.hardware
        try render(UnifiedNotchView(model: model).overlay(alignment: .topLeading) {
            UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: camera.width, height: camera.height)
                .offset(x: camera.minX - notched.expandedBandFrame.minX)
        }, size: notched.expandedFrame.size, name: "compact-physical-notch", output: output)
        model.geometry = external
        model.notchPresentation = .expanded(external)
        model.eating = true
        model.updateFileDrop(at: CGPoint(x: -1, y: 32), fileCount: 2)
        try render(UnifiedNotchView(model: model), size: compact, name: "file-drop-choices", output: output)
        let dropLayout = FileDropLayout(size: compact, headerHeight: model.geometry!.expandedBandHeight)
        for destination in FileDropDestination.allCases {
            let frame = dropLayout.frame(for: destination)
            model.updateFileDrop(at: CGPoint(x: frame.midX, y: frame.midY), fileCount: 2)
            try render(UnifiedNotchView(model: model), size: compact,
                       name: destination == .currentSession ? "file-drop-current" : "file-drop-new", output: output)
        }
        let normalGeometry = model.geometry!
        model.geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 360, height: 360), topInset: 0,
                                       leftArea: nil, rightArea: nil)
        model.notchPresentation = .expanded(model.geometry!)
        model.sessions[0].title = "A longer project name that needs to wrap clearly inside the current session target"
        model.updateFileDrop(at: CGPoint(x: 84, y: 120), fileCount: 1)
        try render(UnifiedNotchView(model: model), size: model.notchPresentation.size, name: "file-drop-small", output: output)
        model.geometry = normalGeometry
        model.notchPresentation = .expanded(normalGeometry)
        model.sessions[0].title = "Website accessibility review"
        model.endFileDrop()
        model.sessions[0].isArchived = true
        model.updateFileDrop(at: CGPoint(x: 44, y: 32), fileCount: 1)
        try render(UnifiedNotchView(model: model), size: compact, name: "file-drop-no-current", output: output)
        model.sessions[0].isArchived = false
        model.endFileDrop()
        model.eating = false
        model.page = .sessions
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-sessions", output: output)
        let unreadSessions = model.sessions
        // Projects: sessions group under their working folders.
        for (index, folder) in ["/Users/me/Developer/notch-companion", "/Users/me/Developer/website"].enumerated()
            where index < model.sessions.count { model.sessions[index].workspacePath = folder }
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-projects", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-projects", output: output)
        model.sessions = unreadSessions
        model.setSessionVisibility(notchVisible: true)
        model.selectSession("failure")
        model.page = .sessions
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-failure-read", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-failure-read", output: output)
        model.setSessionVisibility(notchVisible: false)
        model.sessions = unreadSessions
        model.currentID = "review"
        // Inline row actions; the legacy row has all three, which stack in the sidebar.
        model.sessionActionsID = "failure"
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-session-actions", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-session-actions", output: output)
        model.sessionActionsID = nil
        // A search covers archived sessions too and marks them.
        model.sessionSearch = "review"
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-sessions-filtered", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-sessions-filtered", output: output)
        model.sessionSearch = ""
        model.sessionFilter = .archived
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-sessions-archived", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-sessions-archived", output: output)
        model.sessionFilter = .all
        // Nothing active: the default list says so and links to Archived.
        let caughtUp = AppModel(storageURL: temporary.appendingPathComponent("caught-up.json"), playsSounds: false,
                                client: PreviewTransport(), preferences: preferences)
        defer { caughtUp.shutdown() }
        caughtUp.sessions = model.sessions.filter { ["archive", "dormant"].contains($0.id) }
        caughtUp.currentID = "archive"
        (caughtUp.geometry, caughtUp.notchPresentation) = (model.geometry, model.notchPresentation)
        (caughtUp.expanded, caughtUp.reducedMotion, caughtUp.connection, caughtUp.page) = (true, true, true, .sessions)
        try render(UnifiedNotchView(model: caughtUp), size: compact, name: "compact-sessions-caught-up", output: output)
        model.sessionSearch = "A longer session search with no matching results"
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-sessions-search", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-sessions-search", output: output)
        model.sessionSearch = ""
        model.page = .runtimeChooser(defaultSelection: true)
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-runtime-chooser", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-runtime-chooser", output: output)
        // The agent step lists the harnesses installed on the rendering Mac.
        for step in 0..<WelcomeView.steps {
            model.page = .welcome(step: step)
            // The look step's mascot sheets decode off the main thread; give them time under load.
            try render(UnifiedNotchView(model: model), size: compact, name: "compact-welcome-\(step)", output: output,
                       settle: step == 1 ? 2.5 : 0.35)
        }
        // The look step with a mascot chosen: its tile lit, and it in the header.
        let (appearance, character) = (model.companionAppearance, model.mascotCharacter)
        model.companionAppearance = .mascot
        model.mascotCharacter = .soot
        model.mascotLibrary.prepare(["idle", MascotTimeline.emerge], synchronously: true)
        model.page = .welcome(step: 1)
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-welcome-1-mascot", output: output)
        (model.companionAppearance, model.mascotCharacter) = (appearance, character)
        model.page = .settings
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-settings", output: output)
        for width: CGFloat in [560, 252] {
            try render(SettingsContent(model: model, inNotch: true).padding(20)
                .frame(width: width, height: 900, alignment: .top)
                .background(CompanionStyle.background).foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
                size: NSSize(width: width, height: 900), name: "settings-appearance-\(Int(width))", output: output)
        }
        try render(VStack(alignment: .leading, spacing: 16) {
            ForEach([RuntimeKind.hermes, .codex]) { runtime in
                Text(runtime.title).padding(.leading, 12)
                RuntimeDefaultModelView(model: model, runtime: runtime)
            }
        }.padding(18).frame(width: 252, height: 380, alignment: .top)
            .background(CompanionStyle.background).foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
            size: NSSize(width: 252, height: 380), name: "runtime-default-models", output: output)
        // Settings and Usage open in the full-session window's main pane.
        try render(FullSessionView(model: model, utility: .settings), size: full, name: "full-settings", output: output)
        model.showUsage = true
        try render(FullSessionView(model: model, utility: .usage), size: full, name: "full-usage", output: output)
        model.showUsage = false
        model.connection = false
        model.connectionMessage = "Connects when you send a message."
        for runtime in RuntimeKind.allCases {
            model.page = .runtimeSetup(runtime)
            try render(UnifiedNotchView(model: model), size: compact, name: "compact-setup-\(runtime.rawValue)", output: output)
        }
        try render(FullSessionView(model: model), size: full, name: "full-runtime-setup", output: output)
        model.connection = false
        model.connectionMessage = "This Hermes authentication method is not supported by the companion yet. Choose an API-key provider or an externally managed local endpoint with hermes model, or use Hermes directly."
        model.page = .runtimeSetup(.hermes)
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-setup-unavailable", output: output)
        model.connection = true
        model.connectionMessage = "Hermes connected"
        let originalSessions = model.sessions
        model.sessions.append(CompanionSession(id: "runtime-draft", title: "New session", workspacePath: "/tmp/Website"))
        model.currentID = "runtime-draft"
        model.page = .session
        model.sessions[model.sessions.count - 1].runtime = .claude
        model.projectTrustSessionID = "runtime-draft"
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-project-trust", output: output)
        model.projectTrustSessionID = nil
        model.sessions[model.sessions.count - 1].runtime = .hermes
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-runtime-draft", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-runtime-draft", output: output)
        try render(VStack {
            Spacer()
            HStack { SessionRuntimeControl(model: model, session: model.current!, choosingRuntime: true); Spacer() }
        }.padding(20).frame(width: 560, height: 300)
            .background(CompanionStyle.background).foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
            size: NSSize(width: 560, height: 300), name: "ready-harness-dropdown", output: output)
        let emptySuite = "notch-empty-harness-\(UUID().uuidString)"
        let emptyPreferences = UserDefaults(suiteName: emptySuite)!
        let emptyModel = AppModel(storageURL: temporary.appendingPathComponent("empty-sessions.json"), playsSounds: false,
                                  client: PreviewTransport(), preferences: emptyPreferences)
        defer { emptyModel.shutdown(); emptyPreferences.removePersistentDomain(forName: emptySuite) }
        emptyModel.expanded = true
        emptyModel.notchPresentation = model.notchPresentation
        emptyModel.geometry = model.geometry
        emptyModel.draft = "Keep this draft while setting up a harness."
        try render(UnifiedNotchView(model: emptyModel), size: compact, name: "compact-no-harness", output: output)
        try render(FullSessionView(model: emptyModel), size: full, name: "full-no-harness", output: output)
        model.sessions[model.sessions.count - 1].runtime = .codex
        model.connectionMessage = "Codex connected"
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-codex-draft", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-codex-draft", output: output)
        model.sessions[model.sessions.count - 1].pendingSubmission = PendingSubmission(
            id: "pending-fixture", draft: "Review the plan", userTurnCount: 1, attachmentIDs: [])
        model.sessions[model.sessions.count - 1].runtime = .claude
        model.sessions[model.sessions.count - 1].state = .interrupted
        model.sessions[model.sessions.count - 1].title = "Older Claude session"
        model.errorMessage = "Claude Code has no exact delivery receipt or complete native history for this send check. The saved send remains protected from retry; inspect the exact session in the native runtime."
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-pending-send", output: output)
        model.setSessionVisibility(notchVisible: true)
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-pending-send-read", output: output)
        model.page = .sessions
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-pending-send-read-list", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-pending-send-read", output: output)
        model.setSessionVisibility(notchVisible: false)
        model.page = .session
        model.errorMessage = nil
        model.sessions = originalSessions
        model.currentID = "review"
        model.sessions[0].runtime = .codex
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-codex-conversation", output: output)
        try render(FullSessionView(model: model), size: full, name: "full-codex-conversation", output: output)
        model.sessions[0].runtime = .hermes
        model.sessions[0].isLegacyPrivate = true
        model.connectionMessage = "Legacy Hermes connected"
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-legacy-conversation", output: output)
        model.sessions[0].isLegacyPrivate = false
        model.connectionMessage = "Hermes connected"
        model.page = .session
        model.sessions[0].state = .waiting
        model.requests = [
            PendingRequest(id: "q1", kind: .clarification, title: "Hermes has a question", detail: "Which parts should be included in the next review?", choices: ["Keyboard and focus behavior", "Long conversations and code blocks", "Multiple sessions and delegated work"], sessionID: "live-review", questionID: "q1", requestID: "batch", multiSelect: true),
            PendingRequest(id: "q2", kind: .clarification, title: "Hermes has a question", detail: "How detailed should the report be?", choices: ["A short summary", "Detailed findings"], sessionID: "live-review", questionID: "q2", requestID: "batch")
        ]
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-question", output: output)
        model.sessions[0].runtime = .codex
        model.connectionMessage = "Codex connected"
        model.requests = [PendingRequest(id: "codex-choice", kind: .clarification, title: "Codex has a question",
            detail: "Which change should I implement first?", choices: ["Keyboard navigation", "Search"],
            sessionID: "live-review", allowsFreeText: false)]
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-codex-choice", output: output)
        model.requests = [PendingRequest(id: "codex-approval", kind: .approval, title: "Codex needs permission",
            detail: "Run the project’s test command in the selected working folder?", choices: ["once", "session", "deny", "cancel"],
            sessionID: "live-review")]
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-codex-approval", output: output)
        model.sessions[0].runtime = .claude
        model.connectionMessage = "Claude Code connected"
        model.requests = [PendingRequest(id: "claude-question", kind: .clarification, title: "Claude Code · Accent",
            detail: "Which accent should the composer use?", choices: ["Sage", "Amber"], sessionID: "live-review",
            choiceDetails: ["Sage": "Matches the current primary actions", "Amber": "Stands out, but competes with questions"])]
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-claude-question-details", output: output)
        model.requests.removeAll()
        // Files an agent delivered, and Codex's non-blocking question card.
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let chart = temporary.appendingPathComponent("weekly chart.png")
        let report = temporary.appendingPathComponent("release-report.pdf")
        try sampleChart().write(to: chart)
        try samplePDF().write(to: report)
        let savedMessages = model.sessions[0].messages
        model.sessions[0].runtime = .codex
        model.connectionMessage = "Codex connected"
        model.sessions[0].state = .finished
        model.sessions[0].messages = [
            ChatMessage(id: "turn", role: "user", text: "Chart last week and write the report.", turnID: "turn"),
            ChatMessage(role: "assistant", text: "Here are the chart and the report.\n\nMEDIA:\(chart.path)\nMEDIA:\(report.path)", turnID: "turn")
        ]
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-agent-media", output: output)
        model.sessions[0].messages = savedMessages
        let asked = [AsyncQuestion(title: "Which channel should get the release first?", options: ["Beta testers", "Everyone"]),
                     AsyncQuestion(title: "Anything to mention in the notes?")]
        for (name, status) in [("open", AsyncQuestionCard.Status.open(canReply: true, hint: "Sent as your next message.")),
                               ("busy", .open(canReply: false, hint: "Reply when Codex finishes this turn.")), ("answered", .answered)] {
            try render(AsyncQuestionCard(questions: asked, asker: "Codex", status: status) { _ in true }
                .padding(20).frame(width: 520, height: status == .answered ? 190 : 330, alignment: .top)
                .background(Color.black).foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
                size: NSSize(width: 520, height: status == .answered ? 190 : 330), name: "async-question-\(name)", output: output)
        }
        model.sessions[0].runtime = .hermes
        model.connectionMessage = "Hermes connected"
        model.sessions[0].state = .failed
        model.sessions[0].agents = [ChildAgent(id: "failed-child", title: "Check keyboard navigation", state: .failed,
                                             text: "The task could not finish.\n\nTry again after reconnecting the test device.", turnID: "turn")]
        try render(UnifiedNotchView(model: model), size: compact, name: "compact-failure", output: output)
        let moods: [(CompanionMood, String)] = [(.ready, "Ready"), (.thinking, "Thinking"), (.working, "Working"),
                                                (.answering, "Answering"), (.waiting, "Needs you"), (.done, "Done"), (.failed, "Failed"),
                                                (.sleeping, "Dozing")]
        let sheet = VStack(alignment: .leading, spacing: 10) {
            ForEach([0.0, 1.0], id: \.self) { expansion in
                HStack(spacing: 10) {
                    ForEach(moods, id: \.1) { mood, label in
                        VStack(spacing: 4) {
                            EyesDrawing(expansion: expansion, mood: mood, previousMood: mood, sinceMood: 0.6, sinceGlance: 100,
                                        sinceChomp: 100, time: 0, feeding: 0, pointer: .zero, blink: 0, reducedMotion: false)
                                .frame(width: 76, height: 64).background(Color.black, in: RoundedRectangle(cornerRadius: 10))
                            Text(label).font(.system(size: 10)).foregroundStyle(.white)
                        }
                    }
                }
            }
        }.padding(12).background(Color(white: 0.15)).fixedSize()
        try render(sheet.scaleEffect(2, anchor: .topLeading).frame(width: 1420, height: 400, alignment: .topLeading),
                   size: NSSize(width: 1420, height: 400), name: "eyes-expressions", output: output)
        // Timed moments on the eyes' own clock: nodding off, waking with a start, finishing sparkles.
        let moments: [(mood: CompanionMood, previous: CompanionMood, times: [TimeInterval], label: String)] = [
            (.sleeping, .ready, [0.3, 0.55, 0.8, 1.45, 1.9, 2.4], "Nodding off"),
            (.ready, .sleeping, [0.02, 0.08, 0.16, 0.3, 0.45, 0.7], "Waking"),
            (.done, .working, [0.1, 0.2, 0.35, 0.5, 0.7, 0.95], "Done")]
        let motionSheet = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(moments.enumerated()), id: \.offset) { _, moment in
                HStack(spacing: 10) {
                    Text(moment.label).font(.system(size: 10)).foregroundStyle(.white).frame(width: 64, alignment: .leading)
                    ForEach(moment.times, id: \.self) { since in
                        VStack(spacing: 4) {
                            EyesDrawing(expansion: 0, mood: moment.mood, previousMood: moment.previous, sinceMood: since,
                                        sinceGlance: 100, sinceChomp: 100, time: 0, feeding: 0, pointer: .zero, blink: 0,
                                        reducedMotion: false)
                                .frame(width: 76, height: 64).background(Color.black, in: RoundedRectangle(cornerRadius: 10))
                            Text(String(format: "%.2f s", since)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Text("Booped").font(.system(size: 10)).foregroundStyle(.white).frame(width: 64, alignment: .leading)
                ForEach([0.04, 0.1, 0.18, 0.3, 0.45, 0.7] as [TimeInterval], id: \.self) { since in
                    VStack(spacing: 4) {
                        EyesDrawing(expansion: 0, mood: .ready, previousMood: .ready, sinceMood: 100, sinceGlance: 100,
                                    sinceChomp: 100, time: 0, feeding: 0, pointer: .zero, blink: 0, reducedMotion: false,
                                    sincePoke: since)
                            .frame(width: 76, height: 64).background(Color.black, in: RoundedRectangle(cornerRadius: 10))
                        Text(String(format: "%.2f s", since)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white)
                    }
                }
            }
            HStack(spacing: 14) {
                Text("Writing").font(.system(size: 10)).foregroundStyle(.white).frame(width: 64, alignment: .leading)
                LiveActivityGlyph(kind: .working, symbol: LiveActivity.writingSymbol, written: 12, reducedMotion: false, size: 32)
                LiveActivityGlyph(kind: .working, symbol: "terminal.fill", reducedMotion: false, size: 32)
            }.padding(8).background(Color.black, in: RoundedRectangle(cornerRadius: 10))
        }.padding(12).background(Color(white: 0.15)).fixedSize()
        try render(motionSheet.scaleEffect(2, anchor: .topLeading).frame(width: 1240, height: 880, alignment: .topLeading),
                   size: NSSize(width: 1240, height: 880), name: "eyes-motion", output: output)
        try render(MarkdownContentView(text: response.text).padding(20).frame(width: 560).background(Color.black)
            .foregroundStyle(CompanionStyle.text).environment(\.colorScheme, .dark),
            size: NSSize(width: 560, height: 420), name: "markdown-blocks", output: output)
        try renderIsland(output: output, temporary: temporary, preferences: preferences)
        try renderDelegation(output: output, temporary: temporary, preferences: preferences)
    }

    @MainActor static func image<V: View>(_ content: V, size: NSSize) throws -> NSImage {
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "InterfacePreview", code: 3)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.close()
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Tile still frames into one contact sheet.
    @MainActor static func writeSheet(_ frames: [NSImage], columns: Int, cell: NSSize, name: String, output: URL) throws {
        let rows = (frames.count + columns - 1) / columns
        let size = NSSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        let sheet = NSImage(size: size)
        sheet.lockFocus()
        for (index, frame) in frames.enumerated() {
            let column = index % columns
            let row = index / columns
            frame.draw(in: NSRect(x: CGFloat(column) * cell.width, y: size.height - CGFloat(row + 1) * cell.height,
                                  width: cell.width, height: cell.height))
        }
        sheet.unlockFocus()
        guard let tiff = sheet.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "InterfacePreview", code: 4)
        }
        try data.write(to: output.appendingPathComponent("\(name).png"))
        print("\(name): \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }

    /// A desktop backdrop with a menu bar, so island tiers read in context.
    @MainActor static func desktop<Content: View>(width: CGFloat, height: CGFloat, band: CGFloat,
                                                 @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.56), Color(red: 0.72, green: 0.62, blue: 0.58)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: band)
            HStack {
                Text("  Finder   File   Edit   View").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("Mon 9:41  ").font(.system(size: 12, weight: .medium))
            }.foregroundStyle(.white.opacity(0.9)).frame(height: band)
            content()
        }
        .frame(width: width, height: height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// Glance, announcement, and aura fixtures with their own model and storage.
    @MainActor static func renderIsland(output: URL, temporary: URL, preferences: UserDefaults) throws {
        let model = AppModel(storageURL: temporary.appendingPathComponent("island-sessions.json"), playsSounds: false,
                             client: PreviewTransport(), preferences: preferences)
        defer { model.shutdown() }
        let now = Date()
        var waiting = CompanionSession(id: "plan", runtimeID: "live-plan", title: "Plan the next release", state: .waiting,
                                       messages: [ChatMessage(role: "user", text: "Draft the release plan.")])
        waiting.updatedAt = now.addingTimeInterval(-40)
        var working = CompanionSession(id: "compare", runtimeID: "live-compare", title: "Compare the implementation options",
                                       state: .working,
                                       messages: [ChatMessage(role: "user", text: "Compare both options.", createdAt: now.addingTimeInterval(-84))],
                                       tools: [ToolActivity(id: "t1", name: "terminal", detail: "swift test --filter NotchGlanceTests")])
        working.runtime = .codex
        working.updatedAt = now.addingTimeInterval(-3)
        var finished = CompanionSession(id: "review", title: "Website accessibility review", state: .finished,
                                        messages: [ChatMessage(role: "user", text: "Review the plan."),
                                                   ChatMessage(role: "assistant", text: "## Ready for review\nKeyboard focus now follows the reading order, and every control has a visible label.")])
        finished.updatedAt = now.addingTimeInterval(-240)
        var read = CompanionSession(id: "sounds", title: "Refine the sound palette", state: .finished,
                                    messages: [ChatMessage(role: "assistant", text: "Regenerated all seven cues with balanced loudness.")])
        read.runtime = .claude
        read.updatedAt = now.addingTimeInterval(-7_200)
        read.acknowledgeResult()
        model.sessions = [finished, working, waiting, read]
        model.currentID = "review"
        model.requests = [PendingRequest(id: "q", kind: .clarification, title: "Hermes has a question",
                                         detail: "Which milestone should ship first: the glance or the aura?",
                                         choices: [], sessionID: "live-plan")]
        model.reducedMotion = true
        let external = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1920, height: 1080), topInset: 0,
                                     leftArea: nil, rightArea: nil, indicatorCount: model.sessionIndicators.count)
        let notched = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
                                    leftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                    rightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                    indicatorCount: model.sessionIndicators.count)
        let sceneWidth: CGFloat = 760
        func scene(_ geometry: NotchGeometry, _ presentation: NotchPresentation, height: CGFloat,
                   aura: (NotchAnnouncement.Kind, AuraSample)? = nil) -> some View {
            // Centre the physical camera (or the simulated band) in the scene.
            let originX = sceneWidth / 2 - (geometry.hasHardware ? geometry.hardware.midX : geometry.screen.midX)
            let frame = presentation.frame
            let x = frame.minX + originX
            return desktop(width: sceneWidth, height: height, band: geometry.bandHeight) {
                ZStack(alignment: .topLeading) {
                    if geometry.hasHardware {
                        UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8).fill(.black)
                            .frame(width: geometry.hardware.width, height: geometry.hardware.height)
                            .offset(x: geometry.hardware.minX + originX)
                    }
                    if let aura {
                        NotchAuraView.drawing(kind: aura.0, sample: aura.1, notch: frame.size,
                                              cornerRadius: presentation.cornerRadius, margin: NotchAuraPanel.margin)
                            .frame(width: frame.width + 2 * NotchAuraPanel.margin, height: frame.height + NotchAuraPanel.margin)
                            .offset(x: x - NotchAuraPanel.margin)
                    }
                    UnifiedNotchView(model: model)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: x)
                }
                .frame(width: sceneWidth, height: height, alignment: .topLeading)
            }
        }
        for (name, base) in [("external", external), ("physical", notched)] {
            var geometry = base
            geometry.glanceRows = model.glanceEntries.count
            model.geometry = geometry
            model.glancing = true
            model.notchPresentation = .glance(geometry)
            try render(scene(geometry, model.notchPresentation, height: 240), size: NSSize(width: sceneWidth, height: 240),
                       name: "island-glance-\(name)", output: output)
            model.glancing = false
            model.notchPresentation = .resting(geometry)
            try render(scene(geometry, model.notchPresentation, height: 90), size: NSSize(width: sceneWidth, height: 90),
                       name: "island-resting-\(name)", output: output)
            for kind in NotchAnnouncement.Kind.allCases {
                let session = kind == .finished ? finished : kind == .failed ? working : waiting
                let announcement = kind == .hello
                    ? NotchAnnouncement(kind: .hello, sessionID: AppModel.helloAnnouncementID, title: "Hover here to begin")
                    : NotchAnnouncement(kind: kind, sessionID: session.id, title: session.title)
                model.setAnnouncementForPreview(announcement)
                geometry.announcing = true
                geometry.announcementWidth = announcement.labelWidth
                model.geometry = geometry
                model.notchPresentation = .resting(geometry)
                let sample = NotchAuraTimeline.sample(kind, elapsed: kind == .finished || kind == .hello ? 0.9 : kind == .failed ? 0.3 : 0.55,
                                                      reducedMotion: false)
                try render(scene(geometry, model.notchPresentation, height: 90, aura: (kind, sample)),
                           size: NSSize(width: sceneWidth, height: 90),
                           name: "island-announce-\(kind)-\(name)", output: output)
                geometry.announcing = false
            }
            model.setAnnouncementForPreview(nil)
            model.geometry = geometry
        }
        // Live activity: a glyph per busy session in the right shoulder (their
        // dots fold in), including one waiting for an answer.
        func live(_ base: NotchGeometry) -> NotchGeometry {
            var geometry = base
            let activity = model.liveActivity
            let indicators = model.sessionIndicators
            geometry.indicatorCount = indicators.filter { !(activity?.sessionIDs.contains($0.id) ?? false) }.count
            geometry.liveContentWidth = activity?.contentWidth ?? 0
            geometry.liveSessionIDs = activity?.sessionIDs ?? []
            return geometry
        }
        let allSessions = model.sessions
        let allRequests = model.requests
        for (variant, keep) in [("working", ["compare", "review", "sounds"]), ("waiting", ["plan", "compare", "sounds"]),
                                ("solo", ["compare", "sounds"])] {
            model.sessions = allSessions.filter { keep.contains($0.id) }
            model.requests = keep.contains("plan") ? allRequests : []
            for (name, base) in [("external", external), ("physical", notched)] where variant != "solo" || name == "physical" {
                let geometry = live(base)
                model.geometry = geometry
                model.notchPresentation = .resting(geometry)
                try render(scene(geometry, model.notchPresentation, height: 90), size: NSSize(width: sceneWidth, height: 90),
                           name: "island-live-\(variant)-\(name)", output: output)
            }
        }
        model.sessions = allSessions
        model.requests = allRequests
        // Interactive glance: an approval answered in place, and a running row.
        model.requests = [PendingRequest(id: "approve", kind: .approval, title: "Hermes needs permission",
                                         detail: "Run swift test --filter NotchGlanceTests", choices: ["once", "session", "deny"],
                                         sessionID: "live-plan")]
        for (name, base) in [("physical", notched)] {
            var geometry = live(base)
            geometry.glanceRows = model.glanceEntries.count
            geometry.glanceActionRows = model.glanceEntries.filter { $0.quickReply != nil }.count
            model.geometry = geometry
            model.glancing = true
            model.notchPresentation = .glance(geometry)
            try render(scene(geometry, model.notchPresentation, height: 270), size: NSSize(width: sceneWidth, height: 270),
                       name: "island-glance-interactive-\(name)", output: output)
            model.glancing = false
        }
        model.requests = [PendingRequest(id: "pick", kind: .clarification, title: "Hermes has a question",
                                         detail: "Which milestone should ship first?", choices: ["The glance", "The aura", "Both"],
                                         sessionID: "live-plan")]
        var choiceGeometry = live(external)
        choiceGeometry.glanceRows = model.glanceEntries.count
        choiceGeometry.glanceActionRows = model.glanceEntries.filter { $0.quickReply != nil }.count
        model.geometry = choiceGeometry
        model.glancing = true
        model.notchPresentation = .glance(choiceGeometry)
        try render(scene(choiceGeometry, model.notchPresentation, height: 270), size: NSSize(width: sceneWidth, height: 270),
                   name: "island-glance-choices-external", output: output)
        model.glancing = false
        model.requests = allRequests
        // A filmstrip of the completion aura around the plain resting band.
        model.geometry = notched
        model.notchPresentation = .resting(notched)
        let times: [TimeInterval] = [0.18, 0.4, 0.62, 0.8, 1.05, 1.5]
        let strip = VStack(spacing: 0) {
            ForEach(times, id: \.self) { time in
                ZStack(alignment: .topTrailing) {
                    scene(notched, model.notchPresentation, height: 86,
                          aura: (.finished, NotchAuraTimeline.sample(.finished, elapsed: time, reducedMotion: false)))
                    Text(String(format: "t = %.2f s", time)).font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white).padding(.top, 60).padding(.trailing, 14)
                }
            }
        }
        try render(strip, size: NSSize(width: sceneWidth, height: 86 * CGFloat(times.count)),
                   name: "island-aura-finished-filmstrip", output: output)
        // Morph filmstrips on the one clock: resting → glance (spring), then
        // glance → full panel (ease-out), sampled at fixed times.
        var morphGeometry = notched
        morphGeometry.glanceRows = model.glanceEntries.count
        model.geometry = morphGeometry
        let opening = UnifiedNotchMotion(from: .resting(morphGeometry), to: .glance(morphGeometry), startedAt: 0)
        let promoting = UnifiedNotchMotion(from: .glance(morphGeometry), to: .expanded(morphGeometry), startedAt: 0)
        let liveGeometry = live(notched)
        let liveOpening = UnifiedNotchMotion(from: .resting(notched), to: .resting(liveGeometry), startedAt: 0)
        let popping = UnifiedNotchMotion(from: .launchSeed(morphGeometry), to: .hello(morphGeometry), startedAt: 0, curve: .liquid)
        let settling = UnifiedNotchMotion(from: .hello(morphGeometry), to: .resting(morphGeometry), startedAt: 0, curve: .liquid)
        for (name, motion, samples, height) in [("launch-pop", popping, [0.1, 0.2, 0.3, 0.4, 0.55, 1.4], CGFloat(100)),
                                                ("launch-settle", settling, [0.1, 0.2, 0.3, 0.4, 0.55, 1.4], CGFloat(100)),("glance-open", opening, [0.04, 0.08, 0.14, 0.22, 0.32, 0.46], CGFloat(250)),
                                                ("glance-promote", promoting, [0.04, 0.09, 0.14, 0.2, 0.28, 0.5], CGFloat(250)),
                                                ("live-open", liveOpening, [0.03, 0.07, 0.11, 0.16, 0.24, 0.46], CGFloat(60))] {
            let morphHeight = height
            // Show the materialize blur and stagger the real motion produces.
            model.reducedMotion = false
            defer { model.reducedMotion = true }
            model.glancing = name == "glance-open"
            model.expanded = name == "glance-promote"
            model.geometry = name == "live-open" ? liveGeometry : morphGeometry
            var frames: [NSImage] = []
            for time in samples {
                model.notchPresentation = motion.presentation(at: time)
                let view = scene(name == "live-open" ? liveGeometry : morphGeometry, model.notchPresentation, height: morphHeight)
                    .overlay(alignment: .bottomTrailing) {
                        Text(String(format: "t = %.2f s", time)).font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white).padding(10)
                    }
                frames.append(try image(view, size: NSSize(width: sceneWidth, height: morphHeight)))
            }
            try writeSheet(frames, columns: 2, cell: NSSize(width: sceneWidth, height: morphHeight),
                           name: "island-morph-\(name)", output: output)
        }
        // The resting contour leaning toward the pointer, settled at each position.
        model.glancing = false
        model.expanded = false
        model.geometry = notched
        model.notchPresentation = .resting(notched)
        let restSize = model.notchPresentation.size
        var pullFrames: [NSImage] = []
        for (label, x, y) in [("Far", restSize.width - 30, CGFloat(110)), ("Near", restSize.width - 20, 70),
                              ("Closest", restSize.width + 4, 44), ("Left", CGFloat(-28), 46),
                              ("Below", restSize.width / 2, 52), ("Lower right", restSize.width + 18, 54)] as [(String, CGFloat, CGFloat)] {
            var pull = NotchPull()
            for _ in 0..<120 { pull = pull.stepped(toward: CGPoint(x: x, y: y), size: restSize, elapsed: 1.0 / 60) }
            model.notchPull = pull
            let originX = sceneWidth / 2 - notched.hardware.midX
            let view = scene(notched, model.notchPresentation, height: 130)
                .overlay(alignment: .topLeading) {
                    Image(systemName: "cursorarrow").font(.system(size: 18)).foregroundStyle(.white)
                        .shadow(radius: 1).offset(x: model.notchPresentation.frame.minX + originX + x - 4, y: y - 3)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).padding(10)
                }
            pullFrames.append(try image(view, size: NSSize(width: sceneWidth, height: 130)))
        }
        model.notchPull = NotchPull()
        try writeSheet(pullFrames, columns: 2, cell: NSSize(width: sceneWidth, height: 130),
                       name: "island-pointer-pull", output: output)
        // The working rim light at fixed lap positions on the open island.
        let panel = external.expandedFrame.size
        let laps: [CGFloat] = [0.1, 0.3, 0.55, 0.8, 1.0]
        let rim = HStack(spacing: 16) {
            ForEach(laps, id: \.self) { head in
                ZStack(alignment: .bottomTrailing) {
                    Color.black
                    WorkingRimLight.light(head: head, cornerRadius: 22,
                                          fade: UnifiedNotchView.edgeFade(band: external.bandHeight, height: panel.height))
                    Text(String(format: "lap %.2f", head)).font(.system(size: 18, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white).padding(24)
                }
                .frame(width: panel.width, height: panel.height)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22))
            }
        }.padding(16).background(Color(red: 0.36, green: 0.42, blue: 0.56))
        let rimSize = NSSize(width: (panel.width + 16) * CGFloat(laps.count) + 16, height: panel.height + 32)
        try render(rim.frame(width: rimSize.width, height: rimSize.height), size: rimSize, name: "island-working-rim", output: output)
        // Another session's result while the panel is open on this one.
        model.glancing = false
        model.expanded = true
        model.geometry = external
        model.notchPresentation = .expanded(external)
        model.page = .session
        model.currentID = "review"
        model.panelToast = NotchAnnouncement(kind: .finished, sessionID: "compare", title: "Compare the implementation options")
        try render(UnifiedNotchView(model: model), size: external.expandedFrame.size, name: "island-panel-toast", output: output)
        model.panelToast = nil
        model.expanded = false
        // Empty glance: nothing has run yet.
        model.sessions = [CompanionSession(id: "fresh", title: "New session")]
        model.requests = []
        var quiet = external
        quiet.indicatorCount = 0
        quiet.glanceRows = model.glanceEntries.count
        model.geometry = quiet
        model.glancing = true
        model.notchPresentation = .glance(quiet)
        try render(scene(quiet, model.notchPresentation, height: 150), size: NSSize(width: sceneWidth, height: 150),
                   name: "island-glance-empty", output: output)
        model.glancing = false
        try renderMascot(model: model, sessions: allSessions, requests: allRequests, external: external, notched: notched,
                         scene: {
                             // Compact appearances trim the sheets; load each endpoint before its offscreen capture.
                             model.mascotLibrary.prepare(Array(model.mascotLibrary.clips.keys), synchronously: true)
                             try render(scene($0, $1, height: $2, aura: $3), size: NSSize(width: sceneWidth, height: $2),
                                        name: $4, output: output)
                         },
                         output: output)
    }

    /// Each rendered mascot (characters without assets are skipped): the stage
    /// for each moment, the open panel's header, and every clip with the live
    /// eyes on the face (checks the anchors), stage clips on their island edge.
    @MainActor static func renderMascot(model: AppModel, sessions: [CompanionSession], requests: [PendingRequest],
                                        external: NotchGeometry, notched: NotchGeometry,
                                        scene: (NotchGeometry, NotchPresentation, CGFloat, (NotchAnnouncement.Kind, AuraSample)?, String) throws -> Void,
                                        output: URL) throws {
        let characters = MascotCharacter.allCases.filter { MascotLibrary.library($0).isAvailable }
        let skipped = MascotCharacter.allCases.filter { !characters.contains($0) }
        if !skipped.isEmpty { print("Skipping mascots without rendered assets: \(skipped.map(\.label).joined(separator: ", "))") }
        for character in characters {
            let library = MascotLibrary.library(character)
            library.maxDecodedSheets = library.clips.count
            library.prepare(Array(library.clips.keys), synchronously: true)
        }
        let style = model.updateStyle
        let appearance = model.companionAppearance
        let character = model.mascotCharacter
        model.updateStyle = .popup
        defer { model.updateStyle = style; model.companionAppearance = appearance; model.mascotCharacter = character }
        model.sessions = sessions
        model.requests = requests
        let approval = PendingRequest(id: "approve", kind: .approval, title: "Hermes needs permission",
                                      detail: "Run swift test --filter NotchGlanceTests", choices: ["once", "session", "deny"],
                                      sessionID: "live-plan")
        let choice = PendingRequest(id: "pick", kind: .clarification, title: "Claude Code", detail: "Which milestone should ship first?",
                                    choices: ["The glance", "The aura", "Both together in one release"], sessionID: "live-plan")
        // The eyes once, then each rendered mascot.
        let looks: [(CompanionAppearance, MascotCharacter?)] = [(.eyes, nil)] + characters.map { (.mascot, $0) }
        func suffix(_ look: (CompanionAppearance, MascotCharacter?)) -> String { look.1.map { "-\($0.rawValue)" } ?? "-eyes" }
        for (name, base) in [("physical", notched), ("external", external)] {
            for look in looks {
                model.companionAppearance = look.0
                if let mascot = look.1 { model.mascotCharacter = mascot }
                for (variant, kind, session) in [("finished", NotchAnnouncement.Kind.finished, "review"), ("failed", .failed, "compare"),
                                                 ("question", .needsInput, "plan"), ("choice", .needsInput, "plan"),
                                                 ("approval", .needsInput, "plan"), ("hello", .hello, "")]
                    where name == "physical" || variant == "finished" {
                    model.requests = variant == "approval" ? [approval] : variant == "choice" ? [choice] : requests
                    let title = sessions.first { $0.id == session }?.title ?? "Hover here to begin"
                    model.setAnnouncementForPreview(NotchAnnouncement(kind: kind, sessionID: kind == .hello ? AppModel.helloAnnouncementID : session,
                                                                      title: title))
                    model.staging = true
                    var geometry = base
                    geometry.stageAnswerRows = model.stageAnswerRows
                    model.geometry = geometry
                    model.notchPresentation = .stage(geometry)
                    let sample = NotchAuraTimeline.sample(kind, elapsed: kind == .failed ? 0.3 : 0.9, reducedMotion: false)
                    try scene(geometry, model.notchPresentation, max(200, geometry.stageFrame.height + 30), (kind, sample),
                              "island-stage-\(variant)-\(name)\(suffix(look))")
                }
                model.updateStyle = .compact
                model.staging = false
                let announcement = NotchAnnouncement(kind: .finished, sessionID: "review", title: "Website accessibility review")
                model.setAnnouncementForPreview(announcement)
                var geometry = base
                geometry.announcing = true
                geometry.announcementWidth = announcement.labelWidth
                model.geometry = geometry
                model.notchPresentation = .resting(geometry)
                let sample = NotchAuraTimeline.sample(.finished, elapsed: 0.9, reducedMotion: false)
                try scene(geometry, model.notchPresentation, 90, (.finished, sample), "island-compact\(suffix(look))-\(name)")
                model.updateStyle = .popup
            }
        }
        model.staging = false
        model.setAnnouncementForPreview(nil)
        model.requests = requests
        // The open panel: the mascot stands in the header's left column.
        model.expanded = true
        model.geometry = notched
        model.notchPresentation = .expanded(notched)
        model.page = .session
        model.currentID = "review"
        for look in looks {
            model.companionAppearance = look.0
            if let mascot = look.1 { model.mascotCharacter = mascot }
            // The full panel's character is independent of the update layout too.
            model.updateStyle = .compact
            try scene(notched, model.notchPresentation, notched.expandedFrame.height + 20, nil,
                      "island-panel\(suffix(look))-physical")
        }
        model.expanded = false
        for character in characters {
            let library = MascotLibrary.library(character)
            // Selecting another character above trimmed this one's sheets.
            library.prepare(Array(library.clips.keys), synchronously: true)
            try renderMascotClips(library: library, name: "mascot-clips-\(character.rawValue)", output: output)
            try renderMascotMotion(library: library, geometry: notched, id: character.rawValue, output: output)
            try renderMascotBoop(library: library, id: character.rawValue, output: output)
        }
    }

    /// One cell of a clip on a stretch of stage: the island above its bottom edge
    /// (black), the 16-point overhang band below it (grey, clipped at its end),
    /// and stage clips placed by their edge line with the eyes clipped above it.
    @MainActor static func mascotCell(library: MascotLibrary, side: CGFloat, frame: MascotTimeline.Frame, eyes: EyesDrawing,
                                      spotlight: Color? = nil, wobble: CGSize = CGSize(width: 1, height: 1)) -> some View {
        let standing = library.ground + MascotLayout.stageStanding / MascotLayout.stageSide
        let edge = standing * side
        let overhang = MascotLayout.overhang * side / MascotLayout.stageSide
        let scene = MascotScene(size: CGSize(width: side, height: edge + overhang), restCenter: .zero, restScale: 1,
                                figure: CGRect(x: 0, y: 0, width: side, height: side), reveal: 1, closing: false,
                                spotlight: spotlight, spotlightAmount: spotlight == nil ? 0 : 1, ground: library.ground,
                                stageWeight: 1, onStage: true)
        return ZStack(alignment: .top) {
            Color(white: 0.3)
            Color.black.frame(height: edge)
            MascotDrawing(scene: scene, eyes: eyes, frame: frame, fading: nil, library: library, wobble: wobble)
        }
        .frame(width: side, height: edge + overhang)
        .clipped()
    }

    /// Every clip, base then stage variants, sampled across its length.
    @MainActor static func renderMascotClips(library: MascotLibrary, name: String, output: URL) throws {
        let moods: [String: CompanionMood] = ["emerge": .ready, "idle": .ready, "work": .working, "done": .done,
                                              "wave": .waiting, "wait": .waiting, "fail": .failed, "sad": .failed]
        let order = ["emerge", "idle", "work", "done", "wave", "wait", "fail", "sad"]
        let clips = (order + order.map { MascotLibrary.stagePrefix + $0 }).filter { library.clips[$0] != nil }
        let side: CGFloat = 120
        let cellHeight = (library.ground + MascotLayout.stageStanding / MascotLayout.stageSide) * side
            + MascotLayout.overhang * side / MascotLayout.stageSide
        let columns = 8
        let sheet = VStack(alignment: .leading, spacing: 6) {
            ForEach(clips, id: \.self) { clip in
                HStack(spacing: 4) {
                    let ledge = library.clips[clip]?.ledge
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clip).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        if let ledge { Text(String(format: "ledge %.3f", ledge)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)) }
                    }
                    .frame(width: 84, alignment: .leading)
                    let count = library.clips[clip]?.frames ?? 1
                    let mood = moods[clip.replacingOccurrences(of: MascotLibrary.stagePrefix, with: "")] ?? .ready
                    ForEach(0..<columns, id: \.self) { column in
                        let index = column * (count - 1) / (columns - 1)
                        mascotCell(library: library, side: side, frame: .init(clip: clip, index: index), eyes: previewEyes(mood, time: 0))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .bottomTrailing) {
                                Text("\(index)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.6)).padding(3)
                            }
                    }
                }
            }
        }.padding(10).background(Color(white: 0.15)).fixedSize()
        let size = NSSize(width: 10 * 2 + 84 + 4 + CGFloat(columns) * (side + 4),
                          height: 10 * 2 + CGFloat(clips.count) * (cellHeight + 6))
        try render(sheet.frame(width: size.width, height: size.height, alignment: .topLeading), size: size, name: name, output: output)
    }

    /// A boop on the header's and the stage's idle pose: the jelly wobble and the eyes' reaction.
    @MainActor static func renderMascotBoop(library: MascotLibrary, id: String, output: URL) throws {
        let times: [TimeInterval] = [0, 0.04, 0.08, 0.14, 0.2, 0.26, 0.34, 0.45, 0.6, 0.85]
        let side: CGFloat = 120
        let clips = ["idle", library.variant("idle", onStage: true)]
        let sheet = VStack(alignment: .leading, spacing: 6) {
            ForEach(clips, id: \.self) { clip in
                HStack(spacing: 4) {
                    ForEach(times, id: \.self) { time in
                        mascotCell(library: library, side: side, frame: .init(clip: clip, index: 0),
                                   eyes: EyesDrawing(expansion: 0, mood: .ready, previousMood: .ready, sinceMood: 100,
                                                     sinceGlance: 100, sinceChomp: 100, time: 0, feeding: 0, pointer: .zero,
                                                     blink: 0, reducedMotion: false, sincePoke: time),
                                   wobble: MascotTimeline.wobble(sincePoke: time, reducedMotion: false))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(alignment: .bottomTrailing) {
                                Text(String(format: "%.2f", time)).font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.6)).padding(3)
                            }
                    }
                }
            }
        }.padding(10).background(Color(white: 0.15)).fixedSize()
        let cellHeight = (library.ground + MascotLayout.stageStanding / MascotLayout.stageSide) * side
            + MascotLayout.overhang * side / MascotLayout.stageSide
        let size = NSSize(width: 20 + CGFloat(times.count) * (side + 4), height: 20 + 2 * (cellHeight + 6))
        try render(sheet.frame(width: size.width, height: size.height, alignment: .topLeading), size: size,
                   name: "mascot-boop-\(id)", output: output)
    }

    @MainActor static func previewEyes(_ mood: CompanionMood, previous: CompanionMood? = nil, since: TimeInterval = 0.6,
                                       time: TimeInterval, pointer: CGSize = .zero, blink: CGFloat = 0) -> EyesDrawing {
        EyesDrawing(expansion: 0, mood: mood, previousMood: previous ?? mood, sinceMood: since, sinceGlance: 100, sinceChomp: 100,
                    time: time, feeding: 0, pointer: pointer, blink: blink, reducedMotion: false)
    }

    /// The mascot in motion through the real drawing code at fixed times: the
    /// eyes travelling onto the face as the stage springs open (stage clips,
    /// overhang allowed), and an animated reel of every act on the stage at
    /// 24 fps. Not a recording of the live window.
    @MainActor static func renderMascotMotion(library: MascotLibrary, geometry: NotchGeometry, id: String, output: URL) throws {
        let emergeLength = library.emergeLength(onStage: true)
        let opening = UnifiedNotchMotion(from: .resting(geometry), to: .stage(geometry), startedAt: 0)
        let emergenceTimes: [TimeInterval] = (1...6).map { 0.3 + (emergeLength - 0.3) * Double($0) / 6 }
        let times: [TimeInterval] = [0, 0.06, 0.12, 0.2, 0.3] + emergenceTimes + [emergeLength + 0.6]
        let stage = geometry.stageFrame
        let rowHeight = stage.height + MascotLayout.overhang + 8
        let strip = VStack(spacing: 6) {
            ForEach(times, id: \.self) { time in
                let presentation = opening.presentation(at: time)
                let scene = MascotLayout.scene(presentation, geometry: geometry, ground: library.ground, staging: true,
                                               expanded: false, spotlight: NotchAnnouncement.Kind.finished.color)
                let frame = library.frame(MascotPerformance(.celebrating, start: 0), appeared: 0, at: time, onStage: true,
                                          reducedMotion: false)
                let silhouette = UnevenRoundedRectangle(bottomLeadingRadius: presentation.cornerRadius,
                                                        bottomTrailingRadius: presentation.cornerRadius)
                ZStack(alignment: .topLeading) {
                    silhouette.fill(.black)
                        .frame(width: presentation.frame.width, height: presentation.frame.height)
                    MascotDrawing(scene: scene, eyes: previewEyes(.done, previous: .ready, since: time, time: time),
                                  frame: frame, fading: nil, library: library)
                        .frame(width: scene.size.width, height: scene.size.height)
                        .clipShape(silhouette.path(in: CGRect(x: 0, y: 0, width: presentation.frame.width,
                                                              height: presentation.frame.height + MascotLayout.overhangClip(presentation))))
                }
                .offset(x: presentation.frame.minX - stage.minX)
                .frame(width: stage.width + 40, height: rowHeight, alignment: .topLeading)
                .overlay(alignment: .topTrailing) {
                    Text(String(format: "%.2f s · %@ %d", time, frame.clip, frame.index)).font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
        }.padding(10).background(Color(red: 0.36, green: 0.42, blue: 0.56)).fixedSize()
        let stripSize = NSSize(width: stage.width + 60, height: CGFloat(times.count) * (rowHeight + 6) + 20)
        try render(strip.frame(width: stripSize.width, height: stripSize.height, alignment: .topLeading), size: stripSize,
                   name: "mascot-stage-reveal-\(id)", output: output)

        // The reel: each act's entrance, then a little of its loop, as the stage plays them.
        func seconds(_ clip: String, _ fallback: TimeInterval) -> TimeInterval {
            library.frameCounts[library.variant(clip, onStage: true)].map { Double($0) / library.fps } ?? fallback
        }
        let program: [(clip: String, mood: CompanionMood, seconds: TimeInterval, tint: Color?)] = [
            ("emerge", .ready, emergeLength, nil), ("idle", .ready, 1.25, nil),
            ("done", .done, seconds("done", 2.4), NotchAnnouncement.Kind.finished.color), ("idle", .ready, 0.5, nil),
            ("work", .working, 3.0, nil), ("wave", .waiting, seconds("wave", 2.3), IslandStyle.amber),
            ("wait", .waiting, 2.0, IslandStyle.amber),
            ("fail", .failed, seconds("fail", 2.0), NotchAnnouncement.Kind.failed.color), ("sad", .failed, 1.25, NotchAnnouncement.Kind.failed.color)]
        let side: CGFloat = 180
        let cellHeight = (library.ground + MascotLayout.stageStanding / MascotLayout.stageSide) * side
            + MascotLayout.overhang * side / MascotLayout.stageSide
        let url = output.appendingPathComponent("mascot-reel-\(id).gif")
        let total = program.reduce(0) { $0 + Int(($1.seconds * library.fps).rounded()) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, total, nil) else {
            throw AppError("Could not create the mascot reel.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var clock: TimeInterval = 0
        var previous = CompanionMood.ready
        for act in program {
            let count = Int((act.seconds * library.fps).rounded())
            let clip = library.variant(act.clip, onStage: true)
            for index in 0..<count {
                let local = Double(index) / library.fps
                let time = clock + local
                let frames = library.clips[clip]?.frames ?? 1
                let eyes = previewEyes(act.mood, previous: previous, since: local, time: time,
                                       pointer: CGSize(width: 2.4 * sin(time * 0.9), height: 0.8 * sin(time * 0.55)),
                                       blink: CGFloat(MascotMotion.blinkAmount(at: time + 6)))
                let view = mascotCell(library: library, side: side, frame: .init(clip: clip, index: index % frames), eyes: eyes,
                                      spotlight: act.tint)
                if let image = try self.image(view, size: NSSize(width: side, height: cellHeight))
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary:
                                                                    [kCGImagePropertyGIFDelayTime: 1 / library.fps]] as CFDictionary)
                }
            }
            clock += Double(count) / library.fps
            previous = act.mood
        }
        guard CGImageDestinationFinalize(destination) else { throw AppError("Could not write the mascot reel.") }
    }
}
