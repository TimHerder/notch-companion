import AVFoundation
import Combine
import Foundation

/// Resolve shipped resources relative to the app, not the developer's checkout.
enum CompanionResources {
    static let bundle: Bundle = {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent("NotchCompanion_NotchCompanion.bundle")) {
            return packaged
        }
        if let executable = Bundle.main.executableURL,
           let adjacent = Bundle(url: executable.deletingLastPathComponent()
            .appendingPathComponent("NotchCompanion_NotchCompanion.bundle")) {
            return adjacent
        }
        #if DEBUG
        return Bundle.module
        #else
        fatalError("Notch Companion resources are missing. Reinstall the complete app bundle.")
        #endif
    }()
}

/// Short, original interaction cues. No cue loops and background activity is silent.
@MainActor
final class SoundPlayer: ObservableObject {
    enum Cue: String, CaseIterable {
        case expand, collapse, attach, send, complete, attention, failure
    }

    static let shared = SoundPlayer()

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "sound.enabled")
            if !enabled { stopAll() }
        }
    }

    @Published var volume: Float {
        didSet {
            let normalized = volume.isFinite ? min(1, max(0, volume)) : 0.28
            if volume != normalized { volume = normalized }
            defaults.set(normalized, forKey: "sound.volume")
            for playback in active { playback.player.volume = normalized }
        }
    }

    private struct Playback {
        let id = UUID()
        let cue: Cue
        let player: AVAudioPlayer
    }

    private let defaults: UserDefaults
    private var data: [Cue: Data] = [:]
    private var active: [Playback] = []
    private var lastPlayed: [Cue: TimeInterval] = [:]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.object(forKey: "sound.enabled") as? Bool ?? true
        let storedVolume = (defaults.object(forKey: "sound.volume") as? NSNumber)?.floatValue ?? 0.28
        self.volume = storedVolume.isFinite ? min(1, max(0, storedVolume)) : 0.28
        for cue in Cue.allCases {
            if let url = CompanionResources.bundle.url(forResource: cue.rawValue, withExtension: "wav")
                ?? CompanionResources.bundle.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "Sounds"),
               let cueData = try? Data(contentsOf: url) {
                data[cue] = cueData
            }
        }
    }

    func play(_ cue: Cue) {
        guard enabled, volume > 0, let cueData = data[cue] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Prevent duplicate stream events or a burst of interactions becoming a chorus.
        let minimumInterval: TimeInterval = switch cue {
        case .attention: 4
        case .failure: 2
        case .complete: 0.65
        default: 0.08
        }
        guard now - (lastPlayed[cue] ?? -10) >= minimumInterval else { return }
        lastPlayed[cue] = now
        active.removeAll { !$0.player.isPlaying }

        if cue == .expand || cue == .collapse {
            for item in active.filter({ $0.cue == .expand || $0.cue == .collapse }) { fadeOut(item) }
        }
        while active.count >= 3 {
            fadeOut(active[0])
        }
        guard let player = try? AVAudioPlayer(data: cueData) else { return }
        player.volume = volume
        player.numberOfLoops = 0
        player.prepareToPlay()
        let playback = Playback(cue: cue, player: player)
        active.append(playback)
        player.play()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(player.duration + 0.05))
            self?.active.removeAll { $0.id == playback.id }
        }
    }

    private func stopAll() {
        for item in active { fadeOut(item) }
    }

    private func fadeOut(_ playback: Playback) {
        active.removeAll { $0.id == playback.id }
        playback.player.setVolume(0, fadeDuration: 0.025)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            playback.player.stop()
        }
    }
}
