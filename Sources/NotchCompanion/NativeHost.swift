import AppKit
import Carbon
import SwiftUI

/// One native window and one presentation clock own the complete notch shape.
@MainActor
final class NativeHost: NSObject, NSMenuDelegate, NSWindowDelegate {
    private let model: AppModel
    private let notchPanel = CompanionPanel(canTakeFocus: false)
    private var fullWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var pointerTimer: Timer?
    private var eventMonitors: [Any] = []
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var hotKeys: CompanionHotKeys?
    private var isStopped = false
    private var trackingMenus = Set<ObjectIdentifier>()
    private var interaction = NotchInteraction()
    private var dragSources = Set<String>()
    private var dragExitTask: Task<Void, Never>?
    private var receivingUntil: TimeInterval = 0
    private var lastPointerSample: TimeInterval?
    private var touchingCompanion = false
    private var lastPoke: TimeInterval = -100
    private var frameTimer: Timer?
    private var frameAnimation: UnifiedNotchMotion?
    private var wantsComposerFocus = false
    private var lastVisibilitySample: TimeInterval?
    /// Decorative edge light behind the notch; click-through, never the body.
    private let auraPanel = NotchAuraPanel()
    private let auraState = NotchAuraState()
    private var auraEndsAt: TimeInterval = 0
    private var shownAnnouncementID: UUID?
    private var announcementEndsAt: TimeInterval = 0
    private var panelToastEndsAt: TimeInterval = 0
    private var announcing = false
    /// Popup updates present announcements on a stage instead of the shoulder.
    private var staging = false
    private var stageEndsAt: TimeInterval = 0
    /// The eyes doze after this long without work, announcements or a nearby pointer.
    static let dozeDelay: TimeInterval = 150
    private var lastEngagement: TimeInterval = 0
    private var bootWakeAt: TimeInterval = 0
    /// Until then the resting island holds the launch's hello drop.
    private var launchHoldsUntil: TimeInterval = 0
    private var swipe = NotchSwipe()
    /// The island is squeezed under a held click on its band.
    private var pressing = false
    /// A failure announcement shakes the island on top of whatever motion runs.
    private var shakeStartedAt: TimeInterval = -100
    private var lastDropTarget: FileDropDestination?
    /// The window reaches this far below the body while a stage mascot may
    /// overhang it. Nothing there takes clicks, hover or swipes.
    private var windowOverhang: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        super.init()
        model.togglePanel = { [weak self] in self?.toggle() }
        model.dismissPanel = { [weak self] in self?.hide() }
        model.activatePanel = { [weak self] in self?.show() }
        model.requestOpenPanel = { [weak self] in self?.show() }
        model.openFullSession = { [weak self] in self?.showFullSession() }
        model.dismissStage = { [weak self] in self?.setStaging(false) }
        // The panel never activates the app; without this the pointing-hand
        // and I-beam cursors over its controls are ignored.
        HoverCursor.allowInBackground()
        configurePanel()
        configureMenu()
        updateAccessibilityPreferences()
        updateGeometry()
        installObservation()
        hotKeys = CompanionHotKeys()
        model.shortcutsChanged = { [weak self] in self?.applyShortcuts() }
        applyShortcuts()
        notchPanel.orderFrontRegardless()
        playLaunch()
    }

    /// Registers the chosen shortcuts, none while Settings records a new one.
    private func applyShortcuts() {
        guard let hotKeys, !isStopped else { return }
        var unavailable = Set<ShortcutAction>()
        for action in ShortcutAction.allCases {
            let shortcut = model.recordingShortcut ? nil : model.shortcut(for: action)
            let registered = hotKeys.register(action.hotKeyID, shortcut) { [weak self] in self?.perform(action) }
            if !registered { unavailable.insert(action) }
        }
        if !model.recordingShortcut { model.unavailableShortcuts = unavailable }
        let open = model.openShortcut.flatMap { unavailable.contains(.openPanel) ? nil : $0 }
        statusItem?.button?.toolTip = open.map { "Notch Companion · \($0.spoken)" } ?? "Notch Companion · click to open"
    }

    private func perform(_ action: ShortcutAction) {
        switch action {
        case .openPanel: toggle()
        case .dictate:
            guard !hasPresentedSheet, trackingMenus.isEmpty else { return }
            model.dictateNewSession()
        }
    }

    /// A drop pops out of the top edge (or the camera) with the eyes in its
    /// middle, they blink awake, and it settles into the resting band; a first
    /// launch then opens the welcome.
    private func playLaunch() {
        let now = ProcessInfo.processInfo.systemUptime
        lastEngagement = now
        guard let geometry = model.geometry, !model.reducedMotion, !model.expanded, !model.glancing else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.model.welcomeIfFirstLaunch() }
            return
        }
        let seed = NotchPresentation.launchSeed(geometry)
        bootWakeAt = now + 0.9
        launchHoldsUntil = now + 1.65
        model.drowsy = true
        applyPresentation(seed)
        run(UnifiedNotchMotion(from: seed, to: .hello(geometry), startedAt: now + 0.15, curve: .liquid))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.movePanel(animated: true, curve: self.target == .resting ? .liquid : nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.model.welcomeIfFirstLaunch() }
    }

    private func configurePanel() {
        let content = FileDropHostingView(rootView: UnifiedNotchView(model: model))
        content.sizingOptions = []
        content.originX = NotchPresentation.flareMargin
        content.acceptsDragPoint = { [weak model] point in model?.notchPresentation.contains(point) ?? false }
        content.acceptsDropPoint = { [weak model] point in model?.fileDropDestination(at: point) != nil }
        content.acceptsHitPoint = { [weak model] point in model?.notchPresentation.contains(point) ?? false }
        configureDrop(content)
        notchPanel.contentView = content
        notchPanel.hasShadow = false
        notchPanel.title = "Notch Companion"
        notchPanel.delegate = self
        notchPanel.setAccessibilityLabel("Notch Companion")
        let aura = NSHostingView(rootView: NotchAuraView(state: auraState))
        aura.sizingOptions = []
        auraPanel.contentView = aura
    }

    private func configureDrop<Content: View>(_ view: FileDropHostingView<Content>, expandsOnDrop: Bool = true) {
        let sourceID = UUID().uuidString
        if expandsOnDrop {
            view.dragLocationChanged = { [weak self] point, fileCount in
                guard let self else { return }
                if let point, !self.interaction.suppressedUntilTriggerExit {
                    self.model.updateFileDrop(at: point, fileCount: fileCount)
                    // A detent as the file crosses from one destination to the other.
                    let destination = self.model.fileDropChoice?.destination
                    if destination != self.lastDropTarget, destination != nil { Haptics.perform(.alignment) }
                    self.lastDropTarget = destination
                } else {
                    self.model.endFileDrop()
                    self.lastDropTarget = nil
                }
            }
        }
        view.dragPresenceChanged = { [weak self] active in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if active {
                self.dragExitTask?.cancel()
                self.dragSources.insert(sourceID)
                self.model.receivingFile = true
            } else {
                self.dragSources.remove(sourceID)
                self.dragExitTask?.cancel()
                self.dragExitTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(110))
                    guard !Task.isCancelled, let self, self.dragSources.isEmpty,
                          ProcessInfo.processInfo.systemUptime >= self.receivingUntil else { return }
                    self.model.receivingFile = false
                }
            }
            if expandsOnDrop, let action = self.interaction.dragChanged(source: sourceID, active: active, now: now) {
                self.apply(action, playSound: false)
            } else if expandsOnDrop, active, self.model.glancing, !self.model.expanded {
                // Files need the full surface's destinations, not the glance.
                self.present(activate: false, playSound: false, focusComposer: false)
            }
        }
        view.acceptFiles = { [weak self] urls in
            guard let self else { return false }
            let accepted = expandsOnDrop ? self.model.acceptFileDrop(urls) : self.model.addAttachments(urls, showPanel: false)
            guard accepted else { return false }
            self.receivingUntil = ProcessInfo.processInfo.systemUptime + 0.65
            if expandsOnDrop { self.show() }
            return true
        }
        // A file dropped on the notch glides into its composer's attach button;
        // the full window's own composer is where it was dropped.
        if expandsOnDrop {
            view.landingFrame = { [weak self] in
                guard let self, let button = self.model.attachLandingFrame else { return nil }
                let frame = self.model.notchPresentation.frame
                return CGRect(x: frame.minX + button.minX, y: frame.maxY - button.maxY,
                              width: button.width, height: button.height).insetBy(dx: 6, dy: 6)
            }
        }
        view.reducesMotion = { [weak self] in self?.model.reducedMotion ?? false }
    }

    private func installObservation() {
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.updateGeometry()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in
            self?.updateGeometry()
            self?.notchPanel.orderFrontRegardless()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.model.setSessionVisibility(notchVisible: false, fullSessionVisible: false)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.refreshSessionVisibility()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
            self?.updateAccessibilityPreferences()
        }
        for (name, beginning) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                MainActor.assumeIsolated {
                    if beginning { self?.trackingMenus.insert(ObjectIdentifier(menu)) }
                    else { self?.trackingMenus.remove(ObjectIdentifier(menu)) }
                }
            }
            notificationTokens.append((NotificationCenter.default, token))
        }
        let timer = Timer(timeInterval: PointerGazeMotion.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        timer.tolerance = 0.001
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleSwipe(event) ?? false }
            return consumed ? nil : event
        }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.expanded || self.model.glancing, !self.hasPresentedSheet,
                      self.trackingMenus.isEmpty else { return }
                self.hide()
            }
        }) { eventMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown], handler: { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .leftMouseUp {
                    self.releasePress()
                    return false
                }
                guard !self.hasPresentedSheet, self.trackingMenus.isEmpty else { return false }
                // Settings is recording a shortcut and takes every key, Escape included.
                if event.type == .keyDown && self.model.recordingShortcut { return false }
                if let action = ShortcutAction.allCases.first(where: { self.model.shortcut(for: $0)?.matches(event) == true }) {
                    if !event.isARepeat { self.perform(action) }
                    return true
                }
                if event.type == .keyDown {
                    if self.model.expanded, event.keyCode == 53, event.window === self.notchPanel {
                        self.hide()
                        return true
                    }
                } else if event.window === self.notchPanel {
                    let distanceFromTop = self.notchPanel.frame.height - event.locationInWindow.y
                    let point = CGPoint(x: event.locationInWindow.x - NotchPresentation.flareMargin, y: distanceFromTop)
                    guard self.model.notchPresentation.contains(point) else { return false }
                    if self.model.notchPresentation.contentIsInteractive {
                        // Pin and make the clicked control key without redirecting
                        // to the composer. This includes header controls in the
                        // band; a tap on the eyes also focuses via activatePanel.
                        self.apply(self.interaction.activate(), playSound: false, focusComposer: false)
                    } else if event.type == .leftMouseDown, !self.model.expanded,
                              point.y <= self.model.notchPresentation.bandHeight {
                        self.press()
                    }
                } else if self.model.expanded || self.model.glancing {
                    self.hide()
                }
                return false
            }
            return consumed ? nil : event
        }) { eventMonitors.append(monitor) }
    }

    private var hasPresentedSheet: Bool {
        notchPanel.attachedSheet != nil || fullWindow?.attachedSheet != nil || NSApp.modalWindow != nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        notificationTokens.append((center, token))
    }

    private func updateAccessibilityPreferences() {
        model.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if model.reducedMotion, frameAnimation != nil { movePanel(animated: false) }
    }

    private func updateGeometry(animated: Bool = false) {
        guard let screen = NSScreen.screens.first(where: {
            $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil
        }) ?? NSScreen.screens.first else { return }
        let previous = model.geometry
        let inputs = restingInputs()
        var geometry = NotchGeometry(screen: screen.frame, topInset: screen.safeAreaInsets.top,
                                     leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
                                     indicatorCount: inputs.indicators)
        geometry.liveContentWidth = inputs.liveWidth
        geometry.liveSessionIDs = inputs.liveSessions
        geometry.glanceRows = model.glanceEntries.count
        geometry.glanceActionRows = model.glanceEntries.filter { $0.quickReply != nil }.count
        geometry.announcing = announcing
        if let announcement = model.announcement { geometry.announcementWidth = announcement.labelWidth }
        geometry.stageBodyHeight = model.stageBodyHeight
        guard previous != geometry else { return }
        model.geometry = geometry
        // Only retarget when the presented tier's own bounds change.
        let unchanged: Bool
        switch target {
        case .expanded: unchanged = previous?.expandedFrame == geometry.expandedFrame
        case .glance: unchanged = previous?.glanceFrame == geometry.glanceFrame
        case .resting: unchanged = previous?.collapsedFrame == geometry.collapsedFrame
            && previous?.announcing == geometry.announcing
        case .stage: unchanged = previous?.stageFrame == geometry.stageFrame
        }
        if unchanged, previous != nil { return }
        movePanel(animated: animated || frameAnimation != nil)
    }

    /// What shapes the resting band besides the screen: its dots and the live
    /// activity, which takes its session's dot and steps aside for announcements.
    private struct RestingInputs: Equatable {
        var indicators: Int
        var liveWidth: CGFloat
        var liveSessions: [String]

        init(indicators: Int, liveWidth: CGFloat, liveSessions: [String]) {
            self.indicators = indicators
            self.liveWidth = liveWidth
            self.liveSessions = liveSessions
        }

        init(_ geometry: NotchGeometry) {
            self.init(indicators: geometry.indicatorCount, liveWidth: geometry.liveContentWidth,
                      liveSessions: geometry.liveSessionIDs)
        }
    }

    private func restingInputs() -> RestingInputs {
        let indicators = model.sessionIndicators
        guard !announcing, let live = model.liveActivity else {
            return RestingInputs(indicators: indicators.count, liveWidth: 0, liveSessions: [])
        }
        let folded = indicators.filter { live.sessionIDs.contains($0.id) }.count
        return RestingInputs(indicators: indicators.count - folded,
                             liveWidth: live.contentWidth, liveSessions: live.sessionIDs)
    }

    private enum Target { case resting, glance, stage, expanded }
    private var target: Target { model.expanded ? .expanded : model.glancing ? .glance : staging ? .stage : .resting }

    /// Pressing the resting band or the glance's band squeezes the island a
    /// few points toward its centre, like pressing the Dynamic Island.
    private func press() {
        guard !model.reducedMotion, !model.expanded, model.geometry != nil, !pressing else { return }
        pressing = true
        let now = ProcessInfo.processInfo.systemUptime
        let current = frameAnimation?.presentation(at: now) ?? model.notchPresentation
        run(UnifiedNotchMotion(from: current, to: current.pressed, startedAt: now,
                               duration: UnifiedNotchMotion.pressDuration, curve: .easeOut))
    }

    /// Release springs the island back, unless the click already opened the
    /// panel, which then springs open from the squeezed shape.
    private func releasePress() {
        guard pressing else { return }
        pressing = false
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isStopped, !self.model.expanded else { return }
            self.movePanel(animated: true, curve: .spring)
        }
    }

    private func movePanel(animated: Bool, curve: UnifiedNotchMotion.Curve? = nil) {
        guard let geometry = model.geometry else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let current = frameAnimation?.presentation(at: now) ?? model.notchPresentation
        frameTimer?.invalidate()
        frameTimer = nil
        frameAnimation = nil
        let destination: NotchPresentation
        switch target {
        case .expanded: destination = .expanded(geometry)
        case .glance: destination = .glance(geometry)
        case .stage: destination = .stage(geometry)
        case .resting: destination = now < launchHoldsUntil ? .hello(geometry) : .resting(geometry)
        }
        pressing = false
        guard animated, !model.reducedMotion, !notchPanel.frame.isEmpty,
              current != destination else {
            applyPresentation(destination)
            holdForShake()
            focusComposerIfReady()
            return
        }
        run(UnifiedNotchMotion(from: current, to: destination, startedAt: now, curve: curve))
    }

    private func run(_ motion: UnifiedNotchMotion) {
        frameTimer?.invalidate()
        frameAnimation = motion
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrameAnimation() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
        advanceFrameAnimation()
    }

    private func advanceFrameAnimation() {
        guard let animation = frameAnimation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        applyPresentation(animation.presentation(at: now))
        if animation.isComplete(at: now), now >= shakeStartedAt + UnifiedNotchMotion.shakeDuration {
            frameTimer?.invalidate()
            frameTimer = nil
            frameAnimation = nil
            focusComposerIfReady()
        }
    }

    private func applyPresentation(_ presentation: NotchPresentation) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            withTransaction(transaction) {
                model.notchPresentation = presentation
                // The shake moves only the windows; geometry and hit testing stay put.
                let shake = UnifiedNotchMotion.shakeOffset(ProcessInfo.processInfo.systemUptime - shakeStartedAt)
                let frame = presentation.frame.offsetBy(dx: shake, dy: 0)
                // The window's side margins hold the flares; the body stays centred in it.
                // Its top stays fixed, so every top-anchored conversion is unchanged.
                // Below, it leaves room for a stage overhang and the resting pointer pull.
                windowOverhang = max(model.mascotEnabled && presentation.stage > 0 ? MascotLayout.overhang : 0,
                                     NotchPull.reach + 1)
                var window = frame.insetBy(dx: -NotchPresentation.flareMargin, dy: 0)
                window.origin.y -= windowOverhang
                window.size.height += windowOverhang
                notchPanel.setFrame(window, display: false, animate: false)
                if auraState.effect != nil {
                    auraState.presentation = presentation
                    auraPanel.setFrame(NotchAuraPanel.frame(around: frame), display: false, animate: false)
                }
                let needsShadow = presentation.progress > 0.01 || presentation.peek > 0.01 || presentation.stage > 0.01
                if notchPanel.hasShadow != needsShadow { notchPanel.hasShadow = needsShadow }
                notchPanel.contentView?.needsLayout = true
                notchPanel.contentView?.layoutSubtreeIfNeeded()
            }
        }
        if model.expanded && presentation.progress == 1 {
            refreshSessionVisibility()
        } else {
            model.setSessionVisibility(notchVisible: false)
        }
    }

    private func refreshSessionVisibility() {
        lastVisibilitySample = ProcessInfo.processInfo.systemUptime
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let desktopVisible = session?["CGSSessionScreenIsLocked"] as? Bool != true
            && session?[kCGSessionOnConsoleKey as String] as? Bool != false
        model.setSessionVisibility(notchVisible: desktopVisible && model.expanded && model.notchPresentation.progress == 1,
                                   fullSessionVisible: desktopVisible && fullWindow?.isKeyWindow == true
                                     && fullWindow?.isVisible == true)
    }

    private func mascotCenter() -> CGPoint {
        let presentation = model.notchPresentation
        guard let geometry = model.geometry else { return .zero }
        let rest = presentation.restingEyeCenter(geometry)
        if model.mascotEnabled {
            // The eyes travel onto the mascot's face, a little above its middle.
            let reveal = max(presentation.progress, presentation.stage)
            let figure = MascotLayout.figure(presentation, geometry: geometry, ground: model.mascotLibrary.ground,
                                             staging: staging)
            let visor = CGPoint(x: figure.midX, y: figure.minY + 0.56 * figure.height)
            return CGPoint(x: presentation.frame.minX + rest.x + (visor.x - rest.x) * reveal,
                           y: presentation.frame.maxY - (rest.y + (visor.y - rest.y) * reveal))
        }
        let expandedX = NotchGeometry.expandedEyeX
        return CGPoint(x: presentation.frame.minX + rest.x + (expandedX - rest.x) * presentation.progress,
                       y: presentation.frame.maxY - (rest.y + geometry.eyeCenterY(progress: presentation.progress)
                                                     - geometry.eyeCenterY(progress: 0)))
    }

    /// The visible eyes, or once the mascot is mostly out, its body; local coordinates.
    private func pokeZone(eyesAt center: CGPoint) -> PokeZone? {
        guard let geometry = model.geometry else { return nil }
        let presentation = model.notchPresentation
        let eyes = CGPoint(x: center.x - presentation.frame.minX, y: presentation.frame.maxY - center.y)
        guard model.mascotEnabled else {
            let expansion = presentation.progress + 0.15 * presentation.peek + 0.43 * presentation.hello
            return .eyes(at: eyes, scale: 1 + (EyesDrawing.expandedScale - 1) * expansion)
        }
        let library = model.mascotLibrary
        let scene = MascotLayout.scene(presentation, geometry: geometry, ground: library.ground,
                                       staging: staging, expanded: model.expanded)
        guard scene.reveal >= 0.5 else { return .eyes(at: eyes, scale: scene.restScale) }
        return .body(in: scene.figure(edge: library.edge(library.variant("idle", onStage: scene.onStage))),
                     ground: library.ground)
    }

    private func updatePointer() {
        guard !isStopped, model.geometry != nil else { return }
        if let geometry = model.geometry, RestingInputs(geometry) != restingInputs() {
            // Dots and the live activity reshape the band on the island spring.
            updateGeometry(animated: true)
        } else if model.glancing, model.geometry?.glanceRows != model.glanceEntries.count
                    || model.geometry?.glanceActionRows != model.glanceEntries.filter({ $0.quickReply != nil }).count {
            // A session starting, finishing or being answered reshapes the open glance.
            updateGeometry(animated: true)
        } else if model.geometry?.stageBodyHeight != model.stageBodyHeight {
            // A question's answers, its next question or a late change summary reshape the stage.
            updateGeometry(animated: true)
        }
        let now = ProcessInfo.processInfo.systemUptime
        updateAnnouncement(now: now)
        if auraState.effect != nil, now >= auraEndsAt { stopAura() }
        guard let geometry = model.geometry else { return }
        // Check desktop visibility separately from 60 Hz gaze; the lock screen
        // must not turn a background completion into a checked conversation.
        if now - (lastVisibilitySample ?? 0) >= 0.5 { refreshSessionVisibility() }
        let location = NSEvent.mouseLocation
        let center = mascotCenter()
        let presentation = model.notchPresentation
        let header = CGRect(x: presentation.frame.minX, y: presentation.frame.maxY - presentation.bandHeight,
                            width: presentation.frame.width, height: presentation.bandHeight)
        let nearPointer = header.insetBy(dx: -140, dy: -140).contains(location)
        if model.hovering != nearPointer { model.hovering = nearPointer }
        // Touching the visible eyes or mascot boops them, once per touch. A body
        // hanging on the island's edge is hidden below the silhouette's overhang.
        let local = CGPoint(x: location.x - presentation.frame.minX, y: presentation.frame.maxY - location.y)
        let touching = local.y <= presentation.size.height + MascotLayout.overhangClip(presentation)
            && pokeZone(eyesAt: center)?.contains(local) == true
        if touching, !touchingCompanion, !model.receivingFile, now - lastPoke >= EyeMotion.pokeDuration {
            lastPoke = now
            model.pokeEvent += 1
        }
        touchingCompanion = touching
        updateDrowsiness(now: now)
        // While the band names a session, the eyes look over at the label.
        let lookingAtLabel = announcing && !model.expanded && !model.glancing && presentation.announce > 0.3
        let target = lookingAtLabel
            ? (model.reducedMotion ? .zero : CGSize(width: 3, height: 0.6))
            : PointerGazeMotion.target(at: location, mascotCenter: center, screen: geometry.screen,
                                       reducedMotion: model.reducedMotion)
        let elapsed = now - (lastPointerSample ?? now - PointerGazeMotion.sampleInterval)
        lastPointerSample = now
        let offset = PointerGazeMotion.step(from: model.pointerOffset, toward: target,
                                           elapsed: elapsed, reducedMotion: model.reducedMotion)
        if model.pointerOffset != offset {
            model.pointerOffset = offset
        }
        let pulling = model.pointerPull && !model.expanded && !model.glancing && !staging
        let pull = model.reducedMotion ? NotchPull()
            : model.notchPull.stepped(toward: pulling ? local : nil, size: presentation.size, elapsed: elapsed)
        if model.notchPull != pull { model.notchPull = pull }
        if !dragSources.isEmpty && !model.receivingFile { model.receivingFile = true }
        let trigger = geometry.collapsedFrame.insetBy(dx: -3, dy: -2)
        var body = notchPanel.frame
        body.origin.y += windowOverhang
        body.size.height -= windowOverhang
        let region = body.insetBy(dx: NotchPresentation.flareMargin - 7, dy: -5)
        let editing = notchPanel.isKeyWindow && (notchPanel.firstResponder as? NSTextView)?.isEditable == true
        // Collapsing a tier holds the hover state; a widening band does not.
        let isContracting = frameAnimation.map { $0.to.progress < $0.from.progress || $0.to.peek < $0.from.peek } ?? false
        // Hovering the stage, or typing an answer into it, holds it open rather than
        // swapping it for the glance; once its time is up, hovering away retracts it.
        if staging, region.contains(location) || editing { stageEndsAt = max(stageEndsAt, now + interaction.leaveDelay) }
        if let action = interaction.update(now: now, insideTrigger: trigger.contains(location),
                                           insideRegion: region.contains(location),
                                           protected: hasPresentedSheet || !trackingMenus.isEmpty || editing || isContracting
                                            || staging,
                                           openOnHover: model.openOnHover) {
            // Hover opening and closing play cues; drag entry remains silent.
            apply(action, playSound: !interaction.hasActiveDrag)
        }
        focusComposerIfReady()
    }

    /// Work, questions, announcements, a nearby pointer or an open notch keep
    /// the eyes awake; otherwise they doze off after a quiet spell.
    private func updateDrowsiness(now: TimeInterval) {
        let mood = CompanionMood.resolve(overall: model.overallState, current: model.current)
        let engaged = model.hovering || model.expanded || model.glancing || announcing || staging || model.announcement != nil
            || !mood.canDoze || model.receivingFile || !dragSources.isEmpty
        if engaged { lastEngagement = now }
        let drowsy = now < bootWakeAt || now - lastEngagement >= Self.dozeDelay
        if model.drowsy != drowsy { model.drowsy = drowsy }
    }

    /// Two-finger swipes on a trackpad: down over the band or glance opens the
    /// panel, up over the glance or the open panel's header closes it. The
    /// transcript keeps ordinary scrolling.
    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard event.window === notchPanel, model.swipeGestures, event.hasPreciseScrollingDeltas,
              !hasPresentedSheet, trackingMenus.isEmpty, !isStopped else { return false }
        let local = CGPoint(x: event.locationInWindow.x - NotchPresentation.flareMargin,
                            y: notchPanel.frame.height - event.locationInWindow.y)
        let presentation = model.notchPresentation
        guard presentation.contains(local) else { return false }
        let overHeader = local.y <= presentation.bandHeight
        guard !model.expanded || overHeader else { return false }
        let action = swipe.update(began: event.phase == .began || event.phase == .mayBegin,
                                  ended: event.phase == .ended || event.phase == .cancelled,
                                  momentum: event.momentumPhase != [], deltaY: event.scrollingDeltaY,
                                  inverted: event.isDirectionInvertedFromDevice,
                                  tier: model.expanded ? .expanded : model.glancing || staging ? .glance : .resting)
        switch action {
        case .open:
            Haptics.perform(.alignment)
            show()
        case .close:
            Haptics.perform(.alignment)
            // Swiping a stage up sends the mascot back into the notch.
            if staging && !model.expanded && !model.glancing { setStaging(false) } else { hide() }
        case nil: break
        }
        return true
    }

    func toggle() {
        guard !hasPresentedSheet, trackingMenus.isEmpty else { return }
        // The shortcut promotes a glance to the full panel rather than closing it.
        if model.glancing && !model.expanded { show(); return }
        apply(interaction.toggle(), playSound: true)
    }

    func show() { apply(interaction.activate(), playSound: true) }

    private func apply(_ action: NotchInteraction.Action, playSound: Bool, focusComposer: Bool = true) {
        switch action {
        case .showPassively:
            if model.hoverPreview == .glance, !interaction.hasActiveDrag { presentGlance() }
            else { present(activate: false, playSound: playSound, focusComposer: false) }
        case .activate: present(activate: true, playSound: playSound, focusComposer: focusComposer)
        case .close: closePresentation(playSound: playSound)
        }
    }

    private func present(activate: Bool, playSound: Bool, focusComposer: Bool) {
        guard !isStopped else { return }
        let wasExpanded = model.expanded
        if !wasExpanded { model.recordSnapShotSource() }
        notchPanel.allowsKeyboardFocus = activate
        notchPanel.orderFrontRegardless()
        if activate { notchPanel.makeKeyAndOrderFront(nil) }
        if !wasExpanded {
            if playSound { SoundPlayer.shared.play(.expand) }
            model.glancing = false
            model.expanded = true
            movePanel(animated: true)
        }
        if activate && !focusComposer { wantsComposerFocus = false }
        guard activate, focusComposer else { return }
        wantsComposerFocus = true
        focusComposerIfReady()
    }

    private func focusComposerIfReady() {
        // The panel spring may still be settling its last points of overshoot;
        // the content is fully revealed once progress reaches 1.
        guard wantsComposerFocus, frameAnimation == nil || model.notchPresentation.progress >= 1, model.expanded,
              model.fileDropChoice == nil,
              model.notchPresentation.contentIsInteractive, interaction.mode == .intentional,
              notchPanel.isKeyWindow, !hasPresentedSheet, trackingMenus.isEmpty else { return }
        wantsComposerFocus = false
        model.composerFocusRequest += 1
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.expanded, self.interaction.mode == .intentional,
                  self.model.notchPresentation.contentIsInteractive, self.notchPanel.isKeyWindow,
                  let textInput = self.firstEditableInput(in: self.notchPanel.contentView) else { return }
            self.notchPanel.makeFirstResponder(textInput)
        }
    }

    /// The hover glance: a small, silent island of recent sessions. It never
    /// takes focus or acknowledges results; a click promotes it to the panel.
    func presentGlance() {
        guard !isStopped, !model.expanded, !model.glancing else { return }
        notchPanel.allowsKeyboardFocus = false
        notchPanel.orderFrontRegardless()
        model.glancing = true
        // A light detent under the finger as the island opens beneath the pointer.
        Haptics.perform(.levelChange)
        updateGeometry(animated: true)
        movePanel(animated: true)
    }

    func hide(playSound: Bool = true) { apply(interaction.dismiss(), playSound: playSound) }

    private func closePresentation(playSound: Bool) {
        if model.glancing && !model.expanded {
            model.glancing = false
            HoverCursor.reset()
            model.endFileDrop()
            movePanel(animated: true)
            return
        }
        guard model.expanded else { return }
        if playSound { SoundPlayer.shared.play(.collapse) }
        // The microphone never keeps listening behind a closed notch.
        if model.dictation.fromNotch { model.dictation.stop() }
        wantsComposerFocus = false
        HoverCursor.reset()
        model.endFileDrop()
        model.expanded = false
        model.setSessionVisibility(notchVisible: false)
        notchPanel.resignKey()
        notchPanel.allowsKeyboardFocus = false
        notchPanel.makeFirstResponder(nil)
        // The same visible window contracts back to its resting bounds. There is
        // no second window to hide and no independent content animation to wait for.
        movePanel(animated: true)
    }

    private func firstEditableInput(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.isEnabled { return field }
        if let field = view as? NSTextView, field.isEditable { return field }
        for child in view.subviews {
            if let input = firstEditableInput(in: child) { return input }
        }
        return nil
    }

    func showFullSession() {
        hide(playSound: false)
        if fullWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Notch Companion"
            // The sidebar and panel run up under the traffic lights, with no title strip.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.tabbingMode = .disallowed
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentMinSize = NSSize(width: 780, height: 550)
            window.isReleasedWhenClosed = false
            window.delegate = self
            let content = FileDropHostingView(rootView: FullSessionView(model: model).panelThemed())
            configureDrop(content, expandsOnDrop: false)
            window.contentView = content
            window.center()
            window.setFrameAutosaveName("FullSessionWindow")
            fullWindow = window
        }
        fullWindow?.title = "Notch Companion"
        NSApp.activate(ignoringOtherApps: true)
        fullWindow?.makeKeyAndOrderFront(nil)
        refreshSessionVisibility()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if notification.object as? NSWindow === fullWindow {
            refreshSessionVisibility()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if notification.object as? NSWindow === fullWindow {
            model.setSessionVisibility(fullSessionVisible: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === fullWindow {
            model.setSessionVisibility(fullSessionVisible: false)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === notchPanel { hide(); return false }
        return true
    }

    private func configureMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "eyes", accessibilityDescription: "Notch Companion")
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "NC" }
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("Open Notch Companion", action: #selector(openFromMenu)))
        menu.addItem(menuItem("New Session", action: #selector(newSessionFromMenu)))
        menu.addItem(menuItem("Open Full Session", action: #selector(fullSessionFromMenu)))
        menu.addItem(.separator())
        let status = NSMenuItem(title: "Connecting to runtimes…", action: nil, keyEquivalent: "")
        status.tag = 100
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(menuItem("Reconnect runtimes", action: #selector(reconnectFromMenu)))
        let cancelDeferred = menuItem("Cancel pending operation", action: #selector(cancelDeferredFromMenu))
        cancelDeferred.tag = 102
        cancelDeferred.isHidden = true
        menu.addItem(cancelDeferred)
        menu.addItem(.separator())
        let soundItem = menuItem("Sound Effects", action: #selector(toggleSoundsFromMenu))
        soundItem.tag = 101
        menu.addItem(soundItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Notch Companion", action: #selector(quitFromMenu), key: "q"))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 100)?.title = model.deferredOperation?.waitingMessage
            ?? model.connectionMessage
        menu.item(withTag: 101)?.state = SoundPlayer.shared.enabled ? .on : .off
        menu.item(withTag: 102)?.isHidden = model.deferredOperation == nil
        menu.item(withTag: 102)?.title = "Cancel pending \(model.deferredOperation?.title.lowercased() ?? "operation")"
        let shortcut = model.unavailableShortcuts.contains(.openPanel) ? nil : model.openShortcut
        menu.items.first?.title = "Open Notch Companion" + (shortcut.map { "   \($0.display)" } ?? "")
    }

    @objc private func openFromMenu() { show() }
    @objc private func fullSessionFromMenu() { showFullSession() }
    @objc private func newSessionFromMenu() { Task { @MainActor in await model.newSession(showPanel: false); show() } }
    @objc private func reconnectFromMenu() { Task { await model.reconnect() } }
    @objc private func cancelDeferredFromMenu() { model.cancelDeferredOperation() }
    @objc private func toggleSoundsFromMenu() { SoundPlayer.shared.enabled.toggle() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    // MARK: Announcements and aura

    /// A finished, failed, or waiting session widens the resting band to name
    /// it for a few seconds and lights the edge. The open panel shows a toast
    /// instead, and only for a session other than the one being read.
    private func updateAnnouncement(now: TimeInterval) {
        if let announcement = model.announcement, announcement.id != shownAnnouncementID {
            shownAnnouncementID = announcement.id
            announcementEndsAt = now + announcement.kind.bannerDuration
            if !model.statusEffects || (model.expanded && model.isReading(announcement.sessionID)) {
                model.clearAnnouncement(announcement.id)
                return
            }
            speak(announcement)
            if model.expanded {
                // Inside the open panel, a small toast names another session's result.
                model.panelToast = announcement
                panelToastEndsAt = announcementEndsAt
                model.clearAnnouncement(announcement.id)
                return
            }
            startAura(announcement.kind)
            if model.updateStyle == .popup {
                // An open glance already lists the session; only its edge lights.
                if !model.glancing {
                    stageEndsAt = now + announcement.kind.stageDuration
                    setStaging(true)
                }
            } else if announcing {
                // A replacement during the hold re-measures the band for its own label.
                updateGeometry(animated: true)
            } else {
                setAnnouncing(true)
            }
            if announcement.kind == .failed { shake() }
        }
        if announcing, now >= announcementEndsAt || model.expanded || model.announcement == nil {
            setAnnouncing(false)
        }
        if staging, let announcement = model.announcement, announcement.kind == .needsInput,
           model.sessions.first(where: { $0.id == announcement.sessionID }).map({ CollapsedStatus.resolve(session: $0) != .waiting }) == true {
            // Answered from the stage (or elsewhere): a moment to see it land, then retract.
            stageEndsAt = min(stageEndsAt, now + 1.6)
        }
        if staging, now >= stageEndsAt || model.expanded || model.glancing || model.announcement == nil {
            setStaging(false)
        }
        if !announcing, !staging, let announcement = model.announcement, announcement.id == shownAnnouncementID,
           model.notchPresentation.announce == 0, model.notchPresentation.stage == 0, frameAnimation == nil {
            model.clearAnnouncement(announcement.id)
        }
        if let toast = model.panelToast,
           now >= panelToastEndsAt || !model.expanded || model.isReading(toast.sessionID) {
            model.panelToast = nil
        }
    }

    /// VoiceOver hears what the band or toast shows.
    private func speak(_ announcement: NotchAnnouncement) {
        NSAccessibility.post(element: notchPanel, notification: .announcementRequested, userInfo: [
            .announcement: announcement.spoken,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }

    private func setAnnouncing(_ on: Bool) {
        guard announcing != on else { return }
        announcing = on
        updateGeometry(animated: true)
    }

    private func setStaging(_ on: Bool) {
        guard staging != on, !isStopped else { return }
        let before = target
        staging = on
        model.staging = on
        if on {
            // A click into a question's reply field can take the keyboard; the stage never takes it by itself.
            notchPanel.allowsKeyboardFocus = true
            notchPanel.orderFrontRegardless()
        } else if !model.expanded {
            notchPanel.makeFirstResponder(nil)
            notchPanel.resignKey()
            notchPanel.allowsKeyboardFocus = false
        }
        if target != before { movePanel(animated: true) }
    }

    private func startAura(_ kind: NotchAnnouncement.Kind) {
        guard model.statusEffects, !isStopped else { return }
        let effect = NotchAuraEffect(kind: kind, startedAt: Date().timeIntervalSinceReferenceDate,
                                     reducedMotion: model.reducedMotion)
        auraState.presentation = model.notchPresentation
        auraState.effect = effect
        auraEndsAt = ProcessInfo.processInfo.systemUptime + effect.duration
        auraPanel.setFrame(NotchAuraPanel.frame(around: model.notchPresentation.frame), display: false, animate: false)
        auraPanel.order(.below, relativeTo: notchPanel.windowNumber)
    }

    private func shake() {
        guard !model.reducedMotion, !isStopped else { return }
        shakeStartedAt = ProcessInfo.processInfo.systemUptime
        // Ride the band's own spring when one runs; otherwise tick for the shake alone.
        if frameAnimation == nil { holdForShake() }
    }

    /// Keeps the windows ticking until a running shake dies away.
    private func holdForShake() {
        let now = ProcessInfo.processInfo.systemUptime
        let end = shakeStartedAt + UnifiedNotchMotion.shakeDuration
        guard now < end, !isStopped else { return }
        run(UnifiedNotchMotion(from: model.notchPresentation, to: model.notchPresentation, startedAt: now, duration: end - now))
    }

    private func stopAura() {
        auraState.effect = nil
        auraPanel.orderOut(nil)
    }

    func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        model.setSessionVisibility(notchVisible: false, fullSessionVisible: false)
        dragExitTask?.cancel()
        pointerTimer?.invalidate()
        frameTimer?.invalidate()
        frameTimer = nil
        frameAnimation = nil
        for token in eventMonitors { NSEvent.removeMonitor(token) }
        eventMonitors.removeAll()
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens.removeAll()
        hotKeys?.unregisterAll()
        hotKeys = nil
        notchPanel.orderOut(nil)
        auraPanel.orderOut(nil)
        auraState.effect = nil
        fullWindow?.orderOut(nil)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
}

extension NSWindow.Level {
    /// The notch panel is at status-bar level; system panels it opens go above.
    static let aboveNotch = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
}

extension NSWindow {
    /// `runModal` orders a panel in at the modal-panel level, under the notch,
    /// and a remote open panel appears a moment later. Keep it above the notch
    /// until the caller invalidates the timer when its modal session ends.
    @MainActor func keepAboveNotch() -> Timer {
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, self.isVisible, self.level != .aboveNotch { self.level = .aboveNotch }
            }
        }
        // Common modes include the modal panel mode.
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

extension NSAlert {
    /// Run modally above the notch. A modal window suppresses its outside-click dismissal.
    @MainActor func runAboveNotch() -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let raising = window.keepAboveNotch()
        defer { raising.invalidate() }
        return runModal()
    }
}

@MainActor
final class CompanionPanel: NSPanel {
    var allowsKeyboardFocus: Bool
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    init(canTakeFocus: Bool) {
        self.allowsKeyboardFocus = canTakeFocus
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        // isFloatingPanel resets the level to .floating, below the menu bar,
        // which would take clicks in the top band. Set the level after it.
        isFloatingPanel = true
        level = .statusBar
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .canJoinAllApplications]
        animationBehavior = .none
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A hosting view participates as a drag destination without covering SwiftUI controls.
@MainActor
final class FileDropHostingView<Content: View>: NSHostingView<Content> {
    var dragPresenceChanged: ((Bool) -> Void)?
    var dragLocationChanged: ((CGPoint?, Int) -> Void)?
    var acceptFiles: (([URL]) -> Bool)?
    /// Where an accepted file's drag image lands, in screen coordinates; nil
    /// lets it vanish where it was dropped.
    var landingFrame: (() -> CGRect?)?
    var reducesMotion: (() -> Bool)?
    /// Optional shape restrictions in local top-left coordinates. Other hosting
    /// surfaces, including the ordinary full-session window, remain unrestricted.
    var acceptsDropPoint: ((CGPoint) -> Bool)?
    /// The whole silhouette keeps the chooser open; only its two targets accept
    /// a drop. Crossing the dimmed surround must not look like leaving the app.
    var acceptsDragPoint: ((CGPoint) -> Bool)?
    var acceptsHitPoint: ((CGPoint) -> Bool)?
    /// Where those local coordinates begin, for a body inset in its window.
    var originX: CGFloat = 0
    private var hasAcceptedDrop = false
    private var dragIsInsideAcceptedRegion = false

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let acceptsHitPoint {
            let local = convert(point, from: superview)
            guard acceptsHitPoint(topLeftPoint(local)) else { return nil }
        }
        return super.hitTest(point)
    }

    private func topLeftPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x - bounds.minX - originX, y: isFlipped ? local.y - bounds.minY : bounds.maxY - local.y)
    }

    private func acceptsLocation(_ sender: NSDraggingInfo) -> Bool {
        guard let acceptsDropPoint else { return true }
        return acceptsDropPoint(topLeftPoint(convert(sender.draggingLocation, from: nil)))
    }

    private func updateDragPresence(_ active: Bool) {
        guard active != dragIsInsideAcceptedRegion else { return }
        dragIsInsideAcceptedRegion = active
        dragPresenceChanged?(active)
    }

    private func updateDragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = topLeftPoint(convert(sender.draggingLocation, from: nil))
        let inside = (acceptsDragPoint ?? acceptsDropPoint)?(point) ?? true
        let files = inside ? acceptableFiles(sender) : []
        // Publish the chooser before opening the panel so a hidden conversation
        // cannot be acknowledged as read while the file choices are on screen.
        dragLocationChanged?(files.isEmpty ? nil : point, files.count)
        updateDragPresence(!files.isEmpty)
        let accepts = !files.isEmpty && acceptsLocation(sender)
        sender.numberOfValidItemsForDrop = accepts ? files.count : 0
        return accepts ? .copy : []
    }

    private func acceptableFiles(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return FileAttachmentValidation.readableFiles(urls)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasAcceptedDrop = false
        return updateDragOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // AppKit can enter a transparent corner and then move into the shape
        // without a second draggingEntered callback. Promote on this transition.
        updateDragOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragLocationChanged?(nil, 0)
        updateDragPresence(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !hasAcceptedDrop, updateDragOperation(sender) == .copy else { return false }
        sender.animatesToDestination = !(reducesMotion?() ?? false) && landingFrame?() != nil
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !hasAcceptedDrop, updateDragOperation(sender) == .copy else { return false }
        let files = acceptableFiles(sender)
        guard !files.isEmpty, let acceptFiles, acceptFiles(files) else { return false }
        hasAcceptedDrop = true
        if !(reducesMotion?() ?? false), let landing = landingFrame?() {
            sender.enumerateDraggingItems(options: [], for: nil, classes: [NSURL.self],
                                          searchOptions: [.urlReadingFileURLsOnly: true]) { item, _, _ in
                item.draggingFrame = landing
            }
        }
        dragLocationChanged?(nil, 0)
        updateDragPresence(false)
        return true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragLocationChanged?(nil, 0)
        updateDragPresence(false)
    }
}
