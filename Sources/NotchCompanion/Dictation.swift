import AVFoundation
import Accelerate
import Combine
import Speech

/// Speech to text on this Mac with the chosen engine: macOS's SpeechAnalyzer
/// (its language models download through the system and are shared with other
/// apps) or Parakeet (see `ParakeetModel`). Audio never leaves the Mac.
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
    /// 15 minutes of 16 kHz audio.
    static let parakeetLimit = 16_000 * 60 * 15
    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    /// Some engine can run here; the dictation button and shortcut need one.
    static var isAvailable: Bool { SpeechTranscriber.isAvailable || ParakeetModel.isSupported }

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
    /// How loud the microphone is, 0 to 1. The listening waveform samples it on
    /// its own clock, so it is not published.
    private(set) var level: CGFloat = 0

    /// Final text for a session's draft.
    var deliver: ((String, String) -> Void)?
    private var generation = UUID()
    private var engine: AVAudioEngine?
    /// Ends the audio stream the engine is reading.
    private var endInput: (() -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var deviceChange: NSObjectProtocol?
    private var parakeetProgress: AnyCancellable?
    private var preview: Task<Void, Never>?

    var isActive: Bool { phase != .idle }

    /// Fixtures render listening without a microphone; `cancel` ends it.
    func setListeningForPreview(volatile: String, level: CGFloat, sessionID: String? = nil) {
        phase = .listening
        volatileText = volatile
        self.level = level
        self.sessionID = sessionID
    }

    /// Returns once the run has ended and its last words were delivered.
    func finished() async {
        for await phase in $phase.values where phase == .idle { return }
    }

    func start(sessionID: String, engine: DictationEngine, language: String?, fromNotch: Bool) {
        guard phase == .idle else { return }
        let generation = UUID()
        self.generation = generation
        self.sessionID = sessionID
        self.fromNotch = fromNotch
        failure = nil
        needsMicrophonePermission = false
        volatileText = ""
        phase = .preparing("Starting microphone…")
        Task { await run(generation, engine: engine, language: language) }
    }

    /// Stops listening and keeps what was said; the remaining words arrive
    /// once the model finalizes them.
    func stop() {
        switch phase {
        case .listening:
            phase = .finishing
            // Parakeet transcribes once its audio stream ends; SpeechAnalyzer finalizes.
            stopAudio()
            if let analyzer { Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() } }
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

    private func run(_ generation: UUID, engine: DictationEngine, language: String?) async {
        // A Parakeet run holds the model from its first moment, the Microphone prompt included.
        if engine == .parakeet { ParakeetModel.shared.acquire() }
        defer { if engine == .parakeet { ParakeetModel.shared.release() } }
        do {
            let allowed = await microphoneAllowed()
            guard self.generation == generation else { return }
            guard allowed else {
                needsMicrophonePermission = true
                throw DictationError("Allow Microphone access for Notch Companion to dictate.")
            }
            switch engine {
            case .system: try await runSystem(generation, language: language)
            case .parakeet: try await runParakeet(generation)
            }
        } catch {
            guard self.generation == generation else { return }
            fail(error)
        }
    }

    /// A failure ends the run and says why. Words heard but not yet final are
    /// delivered first, so what was on screen is not lost with it.
    func fail(_ error: Error) {
        if let sessionID, !volatileText.isEmpty { deliver?(sessionID, volatileText) }
        finish(generation)
        failure = (error as? DictationError)?.message ?? "Dictation stopped: \(error.localizedDescription)"
    }

    private func runSystem(_ generation: UUID, language: String?) async throws {
        guard SpeechTranscriber.isAvailable else { throw DictationError("macOS dictation is not available on this Mac. Choose Parakeet in Settings.") }
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
        self.analyzer = analyzer
        try startMicrophone(format, generation: generation, end: { input.finish() }) { input.yield(AnalyzerInput(buffer: $0)) }
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
    }

    /// Parakeet works on whole clips: it hears everything until Stop, previews
    /// what it has every second and a half, and delivers the full text at the end.
    private func runParakeet(_ generation: UUID) async throws {
        let parakeet = ParakeetModel.shared
        guard ParakeetModel.isSupported else { throw DictationError("Parakeet needs a Mac with Apple silicon.") }
        phase = .preparing(parakeet.status)
        parakeetProgress = parakeet.$state.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generation, case .preparing = self.phase else { return }
                self.phase = .preparing(parakeet.status)
            }
        }
        _ = try await parakeet.recognizer()
        parakeetProgress = nil
        guard self.generation == generation else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let (stream, input) = AsyncStream.makeStream(of: [Float].self)
        try startMicrophone(format, generation: generation, end: { input.finish() }) { buffer in
            guard let channel = buffer.floatChannelData?[0] else { return }
            input.yield(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
        }
        phase = .listening
        var samples: [Float] = []
        var previewed = 0
        for await chunk in stream {
            samples += chunk
            // Raw audio grows about 230 MB an hour; a quarter hour bounds it.
            if samples.count >= Self.parakeetLimit, phase == .listening {
                stop()
                failure = "Parakeet listens up to 15 minutes at a time; what you said is in the draft."
            }
            // shortcut: each preview transcribes the whole clip so far; past a minute only the final pass runs.
            if preview == nil, samples.count - previewed >= 24_000, samples.count <= 16_000 * 60 {
                previewed = samples.count
                let clip = samples
                preview = Task {
                    let text = try? await parakeet.transcribe(clip)
                    guard self.generation == generation else { return }
                    if self.phase == .listening, let text { self.volatileText = text }
                    self.preview = nil
                }
            }
        }
        guard self.generation == generation else { return }
        // Under a quarter second is a tap on the button, not speech.
        let text = samples.count >= 4_000 ? try await parakeet.transcribe(samples) : ""
        guard self.generation == generation else { return }
        volatileText = ""
        if let sessionID { deliver?(sessionID, text) }
        finish(generation)
    }

    /// Taps the default input, converts to the engine's format and hands each buffer on.
    private func startMicrophone(_ format: AVAudioFormat, generation: UUID, end: @escaping () -> Void,
                                 receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let engine = AVAudioEngine()
        let microphone = engine.inputNode.outputFormat(forBus: 0)
        guard microphone.sampleRate > 0, microphone.channelCount > 0 else { throw DictationError("No microphone is available.") }
        guard let converter = AVAudioConverter(from: microphone, to: format) else { throw DictationError("Dictation cannot read this microphone's audio.") }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: microphone,
                                    block: Self.tap(converter: converter, format: format, level: { [weak self] rms in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                // Eased, so the bars swell and settle rather than jump between buffers.
                self.level += (Self.loudness(rms) - self.level) * 0.6
            }
        }, receive: receive))
        self.engine = engine
        endInput = end
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
        parakeetProgress = nil
        preview?.cancel()
        preview = nil
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
        endInput?()
        endInput = nil
        level = 0
    }

    /// Speech at a laptop's microphone sits around -40 to -20 dBFS; -55 is quiet, -15 full.
    nonisolated static func loudness(_ rms: Float) -> CGFloat {
        CGFloat(min(1, max(0, (20 * log10(max(rms, 1e-7)) + 55) / 40)))
    }

    /// Runs on the audio thread, so it captures nothing main-actor isolated.
    /// `level` hears each buffer's RMS as the microphone delivered it.
    nonisolated static func tap(converter: AVAudioConverter, format: AVAudioFormat,
                                level: (@Sendable (Float) -> Void)? = nil,
                                receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        // Without priming, every converted buffer starts a little late and the timeline drifts.
        converter.primeMethod = .none
        return { buffer, _ in
            if let level, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var rms: Float = 0
                vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
                level(rms)
            }
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
            if error == nil, converted.frameLength > 0 { receive(converted) }
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
