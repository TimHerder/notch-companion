import AppKit
import AVFoundation
import Carbon
import FluidAudio
import Speech
import SwiftUI
import XCTest
@testable import NotchCompanion

@MainActor private final class ShortcutTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    var sent: [String] = []
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        if method == "prompt.submit", let text = params["text"] as? String { sent.append(text) }
        return method == "session.create" ? ["session_id": "live", "stored_session_id": "saved", "messages": []] : [:]
    }
}

private final class HeardLevel: @unchecked Sendable { var rms: Float = 0 }

@MainActor final class ShortcutDictationTests: XCTestCase {
    private func key(_ code: Int, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: UInt16(code))!
    }

    func testRecordedShortcutsNeedAModifierThatDoesNotTypeText() {
        let open = KeyShortcut(event: key(kVK_Space, " ", [.control, .option]))
        XCTAssertEqual(open, .openPanelDefault)
        XCTAssertEqual(open?.display, "⌃⌥Space")
        XCTAssertEqual(open?.spoken, "Control–Option–Space")
        XCTAssertEqual(KeyShortcut(event: key(kVK_ANSI_K, "k", [.shift, .command]))?.display, "⇧⌘K")
        XCTAssertEqual(KeyShortcut(event: key(kVK_F5, "", []))?.display, "F5", "A function key stands alone")
        XCTAssertNil(KeyShortcut(event: key(kVK_ANSI_A, "a", [])), "A bare letter would take over typing")
        XCTAssertNil(KeyShortcut(event: key(kVK_ANSI_A, "A", [.shift])), "Shift alone types capitals")

        XCTAssertTrue(KeyShortcut.openPanelDefault.matches(key(kVK_Space, " ", [.control, .option])))
        XCTAssertFalse(KeyShortcut.openPanelDefault.matches(key(kVK_Space, " ", [.control, .option, .shift])))
        XCTAssertFalse(KeyShortcut.openPanelDefault.matches(key(kVK_ANSI_V, "v", [.control, .option])))
    }

    func testRecorderCancelsClearsRefusesAndNeverDuplicatesTheOtherAction() {
        var current: [ShortcutAction: KeyShortcut] = [.openPanel: .openPanelDefault, .dictate: .dictateDefault, .ask: .askDefault]
        let decide = { (event: NSEvent) in ShortcutRecording.decide(event, for: .dictate, current: { current[$0] }) }
        XCTAssertEqual(decide(key(kVK_Escape, "\u{1b}", [])), .cancel)
        XCTAssertEqual(decide(key(kVK_Delete, "\u{7f}", [])), .clear)
        XCTAssertEqual(decide(key(kVK_ForwardDelete, "", [])), .clear)
        XCTAssertEqual(decide(key(kVK_ANSI_A, "a", [])), .refuse("Add ⌃, ⌥ or ⌘"))
        XCTAssertEqual(decide(key(kVK_Space, " ", [.control, .option])), .refuse("Used by Open the notch"))
        XCTAssertEqual(decide(key(kVK_ANSI_A, "a", [.control, .option])), .refuse("Used by Hold to ask"))
        XCTAssertEqual(decide(key(kVK_ANSI_D, "d", [.control, .option])),
                       .set(KeyShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey), key: "D")))
        // Another layout labels the same key differently; it is still the same combination.
        current[.openPanel] = KeyShortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(controlKey | optionKey), key: "Z")
        XCTAssertEqual(decide(key(kVK_ANSI_Y, "y", [.control, .option])), .refuse("Used by Open the notch"))
        current[.openPanel] = nil
        XCTAssertEqual(decide(key(kVK_Space, " ", [.control, .option])), .set(.openPanelDefault), "A shortcut turned off frees its keys")
    }

    func testShortcutsPersistAndAClearedOneStaysOff() {
        let suite = "notch-shortcuts-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let open = { AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                              client: ShortcutTransport(), preferences: preferences) }
        let model = open()
        XCTAssertEqual(model.openShortcut, .openPanelDefault)
        XCTAssertEqual(model.dictateShortcut, .dictateDefault)
        XCTAssertEqual(model.askShortcut, .askDefault)
        XCTAssertEqual(Set(ShortcutAction.allCases.map(\.hotKeyID)).count, 3, "Each action registers under its own hot key")
        XCTAssertTrue(model.showDictation)
        XCTAssertNil(model.dictationLanguage, "Dictation follows the system language until one is chosen")
        XCTAssertEqual(model.dictationEngine, .system, "macOS dictation is the default; Parakeet is opt-in")

        let custom = KeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), key: "K")
        model.setShortcut(custom, for: .openPanel)
        model.setShortcut(nil, for: .dictate)
        let hold = KeyShortcut(keyCode: UInt32(kVK_F6), modifiers: 0, key: "F6")
        model.setShortcut(hold, for: .ask)
        model.dictationLanguage = "en-US"
        model.dictationEngine = .parakeet
        model.shutdown()

        let reopened = open()
        XCTAssertEqual(reopened.openShortcut, custom)
        XCTAssertNil(reopened.dictateShortcut, "Turning a shortcut off must not bring the default back")
        XCTAssertEqual(reopened.askShortcut, hold)
        XCTAssertEqual(reopened.dictationLanguage, "en-US")
        XCTAssertEqual(reopened.dictationEngine, .parakeet)
        reopened.shutdown()
    }

    func testParakeetStartsMissingAndDeleteRemovesOnlyItsFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Speech Models")
        let parakeet = ParakeetModel(folder: folder)
        XCTAssertEqual(parakeet.state, .missing)
        XCTAssertEqual(parakeet.status, "Not downloaded")
        XCTAssertFalse(parakeet.isDownloaded)

        // A partial download leaves files that are not a usable model; Delete clears them.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("parakeet-tdt-0.6b-v3"), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: folder.appendingPathComponent("parakeet-tdt-0.6b-v3/Encoder.mlmodelc.partial"))
        let sibling = root.appendingPathComponent("sessions.json")
        try Data("[]".utf8).write(to: sibling)
        XCTAssertFalse(ParakeetModel(folder: folder).isDownloaded)
        await parakeet.delete()
        XCTAssertEqual(parakeet.state, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path), "Only the model folder goes")

        // A dictation using the model keeps Delete from removing it, whatever engine is chosen meanwhile.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        parakeet.acquire()
        XCTAssertTrue(parakeet.inUse)
        await parakeet.delete()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        parakeet.release()
        XCTAssertFalse(parakeet.inUse)
        await parakeet.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testParakeetProgressReadsAsAFullDownloadAndCachedModelsAsPreparing() {
        let state = { ParakeetModel.state(for: DownloadProgress(fractionCompleted: $0, phase: $1)) }
        XCTAssertEqual(state(0, .listing), .downloading(0))
        XCTAssertEqual(state(0.21, .downloading(completedFiles: 1, totalFiles: 5)), .downloading(0.42))
        XCTAssertEqual(state(0.5, .downloading(completedFiles: 5, totalFiles: 5)), .downloading(1))
        XCTAssertEqual(state(0.5, .downloading(completedFiles: 0, totalFiles: 0)), .preparing, "Already on disk")
        XCTAssertEqual(state(0.7, .compiling(modelName: "Encoder")), .preparing)
    }

    /// The real editor coordinator bound to a session draft, as the composer wires it.
    private func composer(_ model: AppModel, _ id: String) -> (NativeComposerEditor.Coordinator, ComposerTextView) {
        let focus = FocusState<Bool>()
        var parent = NativeComposerEditor(text: Binding(get: { model.draft }, set: { model.draft = $0 }), focused: focus.projectedValue,
                                          height: .constant(22), accessibilityLabel: "", accessibilityHint: "", onSubmit: {})
        parent.onComposingChanged = { model.setComposing($0, in: id) }
        let coordinator = parent.makeCoordinator()
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.delegate = coordinator
        editor.onMarkedTextChanged = { coordinator.reportComposing() }
        coordinator.editor = editor
        editor.string = model.draft
        coordinator.synced = model.draft
        editor.setSelectedRange(NSRange(location: (model.draft as NSString).length, length: 0))
        return (coordinator, editor)
    }

    private func compose(_ editor: ComposerTextView) {
        editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
    }

    private func commit(_ editor: ComposerTextView) {
        editor.insertText("仮", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
    }

    func testDictationWaitsForAnInputMethodAndADeliberateReplacementWins() async throws {
        let suite = "notch-ime-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: ShortcutTransport(), preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        await model.newSession(showPanel: false)
        let id = try XCTUnwrap(model.currentID)

        // Final words during a composition wait for its commit, then join after it.
        model.draft = "Hello"
        var (coordinator, editor) = composer(model, id)
        compose(editor)
        model.receiveDictation("final words", into: id)
        coordinator.sync(to: model.draft)
        XCTAssertTrue(editor.hasMarkedText(), "The composition stays open")
        commit(editor)
        coordinator.sync(to: model.draft)
        XCTAssertEqual(model.draft, "Hello仮 final words")
        XCTAssertEqual(editor.string, "Hello仮 final words")

        // Send empties the draft mid-composition: the composition goes, sent text stays sent,
        // and words finalized afterwards start the new draft.
        model.draft = "Hello"
        (coordinator, editor) = composer(model, id)
        compose(editor)
        model.draft = ""
        coordinator.sync(to: model.draft)
        XCTAssertFalse(editor.hasMarkedText())
        model.receiveDictation("final words", into: id)
        coordinator.sync(to: model.draft)
        XCTAssertEqual(model.draft, "final words")
        XCTAssertEqual(editor.string, "final words")

        // A queued message's Edit replaces a composition in an empty composer; typing goes after it.
        model.draft = ""
        (coordinator, editor) = composer(model, id)
        compose(editor)
        model.draft = "Queued message"
        coordinator.sync(to: model.draft)
        XCTAssertEqual(editor.string, "Queued message")
        XCTAssertEqual(editor.selectedRange().location, ("Queued message" as NSString).length)
        editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(model.draft, "Queued message!")
    }

    func testSendWaitsForWordsHeldByAnInputMethod() async throws {
        let suite = "notch-held-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: ShortcutTransport(), preferences: preferences)
        defer { model.shutdown(); preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        await model.newSession(showPanel: false)
        let id = try XCTUnwrap(model.currentID)
        model.draft = "Regarding the crash:"

        // Dictation finalizes while a composition is open: its words wait, and so does Send.
        model.setComposing(true, in: id)
        model.receiveDictation("it happens on launch", into: id)
        var delivered = false
        let waiting = Task { await model.dictationDelivered(to: id); delivered = true }
        await Task.yield(); await Task.yield()
        XCTAssertFalse(delivered)
        XCTAssertEqual(model.draft, "Regarding the crash:")

        model.setComposing(false, in: id)
        await waiting.value
        XCTAssertTrue(delivered)
        XCTAssertEqual(model.draft, "Regarding the crash: it happens on launch")
        // Nothing held: it returns at once.
        await model.dictationDelivered(to: id)
    }

    /// A model whose default harness is set up (or not), with one session already used.
    private func askModel(ready: Bool) async -> (AppModel, ShortcutTransport, () -> Void) {
        let suite = "notch-ask-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        if ready {
            preferences.set([RuntimeKind.hermes.rawValue: RuntimeRoute.defaultProfile(.hermes, defaults: preferences)],
                            forKey: "runtime.configuredProfiles")
        }
        let transport = ShortcutTransport()
        let model = AppModel(storageURL: folder.appendingPathComponent("sessions.json"), playsSounds: false,
                             client: transport, preferences: preferences)
        model.sessions[0].messages = [ChatMessage(role: "user", text: "Earlier work")]
        await model.connect()
        return (model, transport, {
            model.shutdown()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    func testHoldToAskSendsTheHeardWordsAsANewSessionAndLeavesThePanelClosed() async throws {
        let (model, transport, cleanUp) = await askModel(ready: true)
        defer { cleanUp() }
        var opened = 0
        model.activatePanel = { opened += 1 }
        model.requestOpenPanel = { opened += 1 }
        let earlier = model.sessions[0].id

        // A tap on the shortcut hears nothing: no session, no panel.
        await model.sendQuickAsk("  \n", failed: false)
        XCTAssertEqual(model.sessions.count, 1)

        await model.sendQuickAsk(" What changed in the last release? ", failed: false)
        XCTAssertEqual(transport.sent, ["What changed in the last release?"])
        XCTAssertEqual(model.sessions.count, 2)
        let session = try XCTUnwrap(model.current)
        XCTAssertNotEqual(session.id, earlier, "The question never joins the session that was open")
        XCTAssertEqual(session.runtime, model.defaultRuntime)
        XCTAssertEqual(session.workspacePath ?? model.workspacePath, model.workspacePath, "A new session's default folder")
        XCTAssertEqual(session.title, "What changed in the last release?")
        XCTAssertEqual(session.messages.map(\.text), ["What changed in the last release?"])
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(opened, 0, "The notch stays closed; the session runs in the background")
    }

    func testHoldToAskKeepsWordsItCannotSendInADraftAndOpensIt() async throws {
        let (model, transport, cleanUp) = await askModel(ready: true)
        defer { cleanUp() }
        var opened = 0
        model.activatePanel = { opened += 1 }

        // A run that failed may have lost words: review them beside the failure.
        await model.sendQuickAsk("Half a question", failed: true)
        XCTAssertEqual(model.draft, "Half a question")
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(opened, 1)
        // A failure before any word (no microphone access) opens one reused draft that says why.
        await model.sendQuickAsk("", failed: true)
        await model.sendQuickAsk("", failed: true)
        XCTAssertEqual(model.sessions.count, 3)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(opened, 3)
        XCTAssertTrue(transport.sent.isEmpty)

        // No harness is set up yet: the words wait in the draft where setup is offered.
        let (fresh, freshTransport, cleanUpFresh) = await askModel(ready: false)
        defer { cleanUpFresh() }
        fresh.activatePanel = { opened += 1 }
        await fresh.sendQuickAsk("Hello there", failed: false)
        XCTAssertEqual(fresh.draft, "Hello there")
        XCTAssertEqual(opened, 4)
        XCTAssertTrue(freshTransport.sent.isEmpty)
    }

    func testListeningIslandGrowsWithTheWordsAndStopsAtSixLines() {
        var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
                                     leftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                     rightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32), indicatorCount: 1)
        let line = AskIsland.lineHeight
        XCTAssertEqual(AskIsland.bodyHeight("Listening…"), 6 + line + 14)
        let sentence = "Compare both options and tell me which one ships sooner. "
        let few = AskIsland.lines(String(repeating: sentence, count: 3))
        XCTAssertTrue((2...5).contains(few), "\(few)")
        XCTAssertEqual(AskIsland.bodyHeight(String(repeating: sentence, count: 3)), 6 + CGFloat(few) * line + 14)
        XCTAssertEqual(AskIsland.bodyHeight(String(repeating: sentence, count: 40)), 6 + 6 * line + 14, "A long prompt stops growing")

        geometry.askBodyHeight = AskIsland.bodyHeight("Listening…")
        let frame = geometry.askFrame
        XCTAssertEqual(frame.height, geometry.bandHeight + 6 + line + 14)
        XCTAssertEqual(frame.maxY, geometry.screen.maxY)
        XCTAssertEqual(frame.minX, geometry.glanceFrame.minX)
        XCTAssertEqual(frame.width, geometry.glanceFrame.width)
        XCTAssertTrue(frame.contains(geometry.collapsedFrame))

        // It opens and grows on the island spring and closes on the quick ease-out, like the glance.
        let ask = NotchPresentation.ask(geometry)
        XCTAssertEqual(ask.peek, 1)
        XCTAssertEqual(ask.progress, 0)
        XCTAssertEqual(UnifiedNotchMotion(from: .resting(geometry), to: ask, startedAt: 0).curve, .spring)
        var taller = geometry
        taller.askBodyHeight = AskIsland.bodyHeight(String(repeating: sentence, count: 3))
        let grow = UnifiedNotchMotion(from: ask, to: .ask(taller), startedAt: 0)
        XCTAssertEqual(grow.curve, .spring)
        XCTAssertEqual(grow.presentation(at: 0.2).frame.maxY, geometry.screen.maxY, "It grows downward from the screen edge")
        XCTAssertEqual(grow.presentation(at: 10).frame, taller.askFrame)
        let close = UnifiedNotchMotion(from: ask, to: .resting(geometry), startedAt: 0)
        XCTAssertEqual(close.curve, .easeOut)
        XCTAssertEqual(close.duration, UnifiedNotchMotion.collapseDuration)
    }

    func testListeningIslandShowsFinalizedWordsThenThoseStillBeingHeard() async {
        let (model, _, cleanUp) = await askModel(ready: true)
        defer { cleanUp() }
        XCTAssertEqual(model.askBodyHeight, 0, "No island, no height")
        model.setAskingForPreview("")
        XCTAssertEqual(model.askText, "")
        XCTAssertEqual(model.askHint, "Listening…")
        XCTAssertEqual(model.askBodyHeight, AskIsland.bodyHeight("Listening…"))
        model.dictation.setListeningForPreview(volatile: "tomorrow morning", level: 0.5)
        model.quickAsk = "What is the weather"
        XCTAssertEqual(model.askText, "What is the weather tomorrow morning")
        // Released: the island keeps its words while it closes, and nothing is sent by a quit.
        model.dictation.cancel()
        model.setAskingForPreview(nil)
        XCTAssertFalse(model.asking)
        XCTAssertEqual(model.askText, "What is the weather")
    }

    func testMicrophoneLevelFollowsTheBufferAsDelivered() throws {
        XCTAssertEqual(Dictation.loudness(0), 0)
        XCTAssertEqual(Dictation.loudness(1), 1)
        XCTAssertLessThan(Dictation.loudness(0.01), Dictation.loudness(0.1))
        XCTAssertGreaterThan(Dictation.loudness(0.01), 0, "Quiet speech still moves the bars")

        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: format, to: format))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        for index in 0..<1_600 { buffer.floatChannelData![0][index] = index % 2 == 0 ? 0.5 : -0.5 }
        let heard = HeardLevel()
        let tap = Dictation.tap(converter: converter, format: format, level: { heard.rms = $0 }) { _ in }
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
        XCTAssertEqual(heard.rms, 0.5, accuracy: 0.001)
    }

    func testDictatedWordsJoinTheDraftWithOneSpace() {
        XCTAssertEqual(Dictation.append(" Hello there.", to: ""), "Hello there.")
        XCTAssertEqual(Dictation.append("Second part.", to: "First part."), "First part. Second part.")
        XCTAssertEqual(Dictation.append("Next line", to: "List:\n"), "List:\nNext line")
        XCTAssertEqual(Dictation.append("  \n", to: "Unchanged"), "Unchanged")
    }

    /// Speech synthesized at 22.05 kHz goes through the microphone's converter
    /// tap into the on-device model. Downloads the English model on first run.
    func testMicrophoneTapTranscribesOnDevice() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_DICTATION_TEST"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_DICTATION_TEST=1 to run macOS's on-device transcriber (may download its English model).")
        }
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: clip) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", clip.path, "Open the settings page and check the microphone."]
        try say.run(); say.waitUntilExit()

        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let format = try XCTUnwrap(best)
        let file = try AVAudioFile(forReading: clip)
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: format))
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let tap = Dictation.tap(converter: converter, format: format) { input.yield(AnalyzerInput(buffer: $0)) }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal { text = Dictation.append(String(result.text.characters), to: text) }
            return text
        }
        try await analyzer.start(inputSequence: stream)
        while file.framePosition < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer, frameCount: 4096)
            tap(buffer, AVAudioTime(sampleTime: file.framePosition, atRate: file.processingFormat.sampleRate))
        }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collected.value.lowercased()
        XCTAssertTrue(text.contains("settings") && text.contains("microphone"), text)
    }

    /// Parakeet downloads into a reusable test cache (about 480 MB on first run),
    /// then English and German speech, synthesized at 22.05 kHz, goes through the
    /// microphone's converter tap at 16 kHz into it with no language chosen.
    func testParakeetDownloadsAndTranscribesWithoutAChosenLanguage() async throws {
        guard ProcessInfo.processInfo.environment["NOTCH_RUN_PARAKEET_TEST"] == "1" else {
            throw XCTSkip("Set NOTCH_RUN_PARAKEET_TEST=1 to download Parakeet (about 480 MB, cached) and transcribe with it.")
        }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchCompanionTests/Speech Models", isDirectory: true)
        let parakeet = ParakeetModel(folder: folder)
        _ = try await parakeet.recognizer()
        XCTAssertEqual(parakeet.state, .ready)
        XCTAssertTrue(parakeet.isDownloaded)
        let bytes = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        print("Parakeet folder: \(bytes / 1_000_000) MB")
        XCTAssertTrue((400_000_000...560_000_000).contains(bytes), "Settings promises about 480 MB; found \(bytes / 1_000_000) MB")

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        for (voice, sentence, expected) in [("Samantha", "Refactor the login handler and add unit tests.", ["login", "handler"]),
                                            ("Anna", "Bitte prüfe die Datenbank und schreibe einen Bericht.", ["datenbank", "bericht"])] {
            let clip = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: clip) }
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", clip.path, sentence]
            try say.run(); say.waitUntilExit()
            let file = try AVAudioFile(forReading: clip)
            let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: format))
            let (stream, input) = AsyncStream.makeStream(of: [Float].self)
            let tap = Dictation.tap(converter: converter, format: format) { buffer in
                input.yield(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
            }
            while file.framePosition < file.length {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
                try file.read(into: buffer, frameCount: 4096)
                tap(buffer, AVAudioTime(sampleTime: file.framePosition, atRate: file.processingFormat.sampleRate))
            }
            input.finish()
            var samples: [Float] = []
            for await chunk in stream { samples += chunk }
            let text = try await parakeet.transcribe(samples)
            print("Parakeet (\(voice)): \(text)")
            XCTAssertTrue(expected.allSatisfy(text.lowercased().contains), text)
        }
        // A tap on the button (under a second) is padded rather than refused.
        _ = try await parakeet.transcribe([Float](repeating: 0, count: 4_000))
    }
}
