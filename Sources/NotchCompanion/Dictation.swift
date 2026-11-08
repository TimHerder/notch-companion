import AVFoundation
import Speech

/// Speech to text with macOS's own on-device model (SpeechAnalyzer). Audio
/// never leaves the Mac; the language's model downloads once through the
/// system and is shared with other apps.
@MainActor
final class Dictation: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting for the microphone or a model download; the text says which.
        case preparing(String)
        case listening
        /// Stopped; the last words are still being finalized.
        case finishing
    }

    static let languageKey = "notch.dictationLanguage"
    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    @Published private(set) var phase = Phase.idle
    /// The session whose draft receives the words.
    @Published private(set) var sessionID: String?
    /// Words heard but not yet final; shown live, never written to the draft.
    @Published private(set) var volatileText = ""
    @Published var failure: String?
    @Published private(set) var needsMicrophonePermission = false
    /// macOS is asking for Microphone access in its own window.
    @Published private(set) var awaitingPermission = false
    /// Started from the notch, so collapsing the notch stops it.
    private(set) var fromNotch = false

    /// Final text for a session's draft.
    var deliver: ((String, String) -> Void)?
    private var generation = UUID()
    private var engine: AVAudioEngine?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var deviceChange: NSObjectProtocol?

    var isActive: Bool { phase != .idle }

    func start(sessionID: String, language: String?, fromNotch: Bool) {
        guard phase == .idle else { return }
        let generation = UUID()
        self.generation = generation
        self.sessionID = sessionID
        self.fromNotch = fromNotch
        failure = nil
        needsMicrophonePermission = false
        volatileText = ""
        phase = .preparing("Starting microphone…")
        Task { await run(generation, language: language) }
    }

    /// Stops listening and keeps what was said; the remaining words arrive
    /// once the model finalizes them.
    func stop() {
        switch phase {
        case .listening:
            guard let analyzer else { return cancel() }
            phase = .finishing
            stopAudio()
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        case .preparing: cancel()
        case .idle, .finishing: break
        }
    }

    /// Drops anything not yet final.
    func cancel() {
        guard isActive else { return }
        let analyzer = analyzer
        finish(generation)
        Task { await analyzer?.cancelAndFinishNow() }
    }

    private func run(_ generation: UUID, language: String?) async {
        do {
            let allowed = await microphoneAllowed()
            guard self.generation == generation else { return }
            guard allowed else {
                needsMicrophonePermission = true
                throw DictationError("Allow Microphone access for Notch Companion to dictate.")
            }
            let wanted = language.map(Locale.init(identifier:)) ?? Locale.current
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
                throw DictationError("Dictation does not support \(Self.name(of: wanted)). Choose a language in Settings.")
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                guard self.generation == generation else { return }
                phase = .preparing("Downloading the \(Self.name(of: locale)) speech model…")
                try await request.downloadAndInstall()
            }
            guard self.generation == generation, let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                if self.generation == generation { throw DictationError("Dictation could not prepare its speech model.") }
                return
            }
            guard self.generation == generation else { return }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let engine = AVAudioEngine()
            let microphone = engine.inputNode.outputFormat(forBus: 0)
            guard microphone.sampleRate > 0, microphone.channelCount > 0 else { throw DictationError("No microphone is available.") }
            guard let converter = AVAudioConverter(from: microphone, to: format) else { throw DictationError("Dictation cannot read this microphone's audio.") }
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: microphone,
                                        block: Self.tap(converter: converter, format: format, input: input))
            self.analyzer = analyzer
            self.engine = engine
            self.input = input
            // A microphone unplugged or switched stops the engine; keep what was heard and say why.
            deviceChange = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.stop()
                    self.failure = "The microphone changed, so dictation stopped."
                }
            }
            engine.prepare()
            try engine.start()
            try await analyzer.start(inputSequence: stream)
            guard self.generation == generation else { return }
            phase = .listening
            for try await result in transcriber.results {
                guard self.generation == generation else { return }
                let text = String(result.text.characters)
                if result.isFinal {
                    volatileText = ""
                    if let sessionID { deliver?(sessionID, text) }
                } else {
                    volatileText = text
                }
            }
            if self.generation == generation { finish(generation) }
        } catch {
            guard self.generation == generation else { return }
            finish(generation)
            failure = (error as? DictationError)?.message ?? "Dictation stopped: \(error.localizedDescription)"
        }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            awaitingPermission = true
            defer { awaitingPermission = false }
            return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func finish(_ generation: UUID) {
        guard self.generation == generation else { return }
        self.generation = UUID()
        stopAudio()
        analyzer = nil
        phase = .idle
        sessionID = nil
        volatileText = ""
    }

    private func stopAudio() {
        if let deviceChange { NotificationCenter.default.removeObserver(deviceChange) }
        deviceChange = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        input?.finish()
        input = nil
    }

    /// Runs on the audio thread, so it captures nothing main-actor isolated.
    nonisolated static func tap(converter: AVAudioConverter, format: AVAudioFormat,
                                        input: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock {
        // Without priming, every converted buffer starts a little late and the timeline drifts.
        converter.primeMethod = .none
        return { buffer, _ in
            let frames = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up))
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    /// Joins dictated words onto a draft with one space between them.
    nonisolated static func append(_ text: String, to draft: String) -> String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return draft }
        guard let last = draft.last else { return words }
        return draft + (last.isWhitespace ? "" : " ") + words
    }

    /// Every language macOS can transcribe, by name.
    static func languages() async -> [(id: String, name: String)] {
        await SpeechTranscriber.supportedLocales
            .map { (id: $0.identifier(.bcp47), name: name(of: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A language in its own words (Deutsch, English), as language menus show it.
    nonisolated static func name(of locale: Locale) -> String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

private struct DictationError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
