import AppKit
import AVFoundation
import Carbon
import Speech
import XCTest
@testable import NotchCompanion

@MainActor private final class ShortcutTransport: RuntimeTransport {
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool, String?) -> Void)?
    func connect() async throws { onConnectionChange?(true, nil) }
    func disconnect() { onConnectionChange?(false, nil) }
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] { [:] }
}

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
        XCTAssertTrue(model.showDictation)
        XCTAssertNil(model.dictationLanguage, "Dictation follows the system language until one is chosen")

        let custom = KeyShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), key: "K")
        model.setShortcut(custom, for: .openPanel)
        model.setShortcut(nil, for: .dictate)
        model.dictationLanguage = "en-US"
        model.shutdown()

        let reopened = open()
        XCTAssertEqual(reopened.openShortcut, custom)
        XCTAssertNil(reopened.dictateShortcut, "Turning a shortcut off must not bring the default back")
        XCTAssertEqual(reopened.dictationLanguage, "en-US")
        reopened.shutdown()
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
        let tap = Dictation.tap(converter: converter, format: format, input: input)
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
}
