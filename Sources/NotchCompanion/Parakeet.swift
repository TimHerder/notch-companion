import FluidAudio
import Foundation

/// Which recognizer turns speech into text.
enum DictationEngine: String, CaseIterable, Identifiable {
    /// macOS's own SpeechTranscriber; the system manages its language models.
    case system
    /// NVIDIA's Parakeet TDT 0.6B v3 through FluidAudio, downloaded on request.
    case parakeet

    static let key = "notch.dictationEngine"
    var id: String { rawValue }
    var label: String { self == .system ? "macOS" : "Parakeet" }
}

/// Parakeet V3 (CC BY 4.0) lives in the app's support folder once the user
/// chooses it, and runs on the Neural Engine. Audio never leaves the Mac; only
/// the model comes from Hugging Face.
@MainActor
final class ParakeetModel: ObservableObject {
    enum State: Equatable {
        case missing
        case downloading(Double)
        /// Compiling for the Neural Engine or loading into memory.
        case preparing
        case ready
        case failed(String)
    }

    static let shared = ParakeetModel()
    /// FluidAudio's int8 encoder, decoder, joint network and vocabulary.
    static let downloadSize = "about 480 MB"
    /// Parakeet needs Apple silicon's Neural Engine.
    static var isSupported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    @Published private(set) var state = State.missing
    /// Everything Parakeet stores; deleting the model removes this folder.
    let folder: URL
    private var manager: AsrManager?
    private var work: Task<AsrManager?, Error>?
    private var unload: Task<Void, Never>?
    /// Dictation runs using the model; Delete waits for them, whatever engine is chosen now.
    @Published private(set) var users = 0
    /// Delete is tearing the model down; nothing may load or fetch it meanwhile.
    @Published private(set) var deleting = false
    /// The loaded model holds several hundred MB; an always-running app gives it back when idle.
    static let idleUnload: Duration = .seconds(300)

    init(folder: URL = AppPaths.support.appendingPathComponent("Speech Models", isDirectory: true)) {
        self.folder = folder
        state = isDownloaded ? .ready : .missing
    }

    /// FluidAudio keeps the model beside this path, in a folder named after its repository.
    private var directory: URL { folder.appendingPathComponent("parakeet", isDirectory: true) }
    var isDownloaded: Bool { AsrModels.modelsExist(at: directory, version: .v3) }
    var isBusy: Bool { work != nil }
    var inUse: Bool { users > 0 || work != nil || deleting }

    var status: String {
        switch state {
        case .missing: "Not downloaded"
        case .downloading(let fraction): "Downloading Parakeet… \(Int((fraction * 100).rounded()))%"
        case .preparing: "Preparing Parakeet…"
        case .ready: "Downloaded"
        case .failed(let message): message
        }
    }

    /// Downloads without loading, from Settings.
    func download() {
        guard work == nil, !deleting, !isDownloaded else { return }
        run(load: false)
    }

    /// Try again after a failure: fetch what is missing, or load what is there.
    func retry() {
        guard work == nil, !deleting else { return }
        if isDownloaded { Task { _ = try? await recognizer() } } else { run(load: false) }
    }

    /// The loaded recognizer, downloading first if the model is missing.
    func recognizer() async throws -> AsrManager {
        guard !deleting else { throw ParakeetDeleting() }
        unload?.cancel()
        unload = nil
        if let manager { return manager }
        // A download from Settings finishes first; then this loads what it fetched.
        if let work { _ = try? await work.value }
        if let manager { return manager }
        guard let manager = try await (work ?? run(load: true)).value else { return try await recognizer() }
        return manager
    }

    /// A dictation run starts using the model.
    func acquire() {
        users += 1
        unload?.cancel()
        unload = nil
    }

    /// A dictation run finished: free the loaded model unless it is used again soon.
    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        unload?.cancel()
        unload = Task {
            try? await Task.sleep(for: Self.idleUnload)
            guard !Task.isCancelled, work == nil, users == 0, let manager else { return }
            self.manager = nil
            await manager.cleanup()
        }
    }

    /// Frees the memory and removes the downloaded files; refused while in use.
    func delete() async {
        guard !inUse else { return }
        deleting = true
        defer { deleting = false }
        // Taken away before the cleanup awaits, so no dictation can pick it up half torn down.
        let loaded = manager
        manager = nil
        unload?.cancel()
        unload = nil
        await loaded?.cleanup()
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            state = .missing
        } catch {
            state = .failed("Could not delete Parakeet: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func run(load: Bool) -> Task<AsrManager?, Error> {
        let directory = directory
        state = isDownloaded ? .preparing : .downloading(0)
        let progress: ProgressHandler = { [weak self] update in
            Task { @MainActor in self?.report(update) }
        }
        // Main-actor bookkeeping around FluidAudio's own (nonisolated) download and load.
        let task = Task<AsrManager?, Error> { @MainActor in
            defer { work = nil }
            do {
                var loaded: AsrManager?
                if load {
                    let models = try await AsrModels.downloadAndLoad(to: directory, version: .v3, progressHandler: progress)
                    let manager = AsrManager(config: .default)
                    try await manager.loadModels(models)
                    loaded = manager
                    self.manager = manager
                } else {
                    try await AsrModels.download(to: directory, version: .v3, progressHandler: progress)
                }
                state = isDownloaded ? .ready : .missing
                return loaded
            } catch {
                state = .failed("Parakeet could not be \(isDownloaded ? "loaded" : "downloaded"): \(error.localizedDescription)")
                throw error
            }
        }
        work = task
        return task
    }

    private func report(_ update: DownloadProgress) {
        guard work != nil else { return }
        state = Self.state(for: update)
    }

    /// FluidAudio weighs the download as the first half of its progress, and
    /// reports models already on disk as a download with no files.
    nonisolated static func state(for update: DownloadProgress) -> State {
        switch update.phase {
        case .listing: .downloading(0)
        case .downloading(_, let files) where files == 0: .preparing
        case .downloading: .downloading(min(1, update.fractionCompleted * 2))
        case .compiling: .preparing
        }
    }

    /// Transcribes 16 kHz mono samples; clips under Parakeet's one-second minimum are padded with silence.
    func transcribe(_ samples: [Float]) async throws -> String {
        let manager = try await recognizer()
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        let audio = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state).text
    }
}

private struct ParakeetDeleting: LocalizedError {
    var errorDescription: String? { "Parakeet is being deleted. Choose Download in Settings to use it again." }
}
