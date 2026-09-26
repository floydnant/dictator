import Foundation
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        }
    }

    /// Apple shows text while you talk; Parakeet only resolves on release.
    var showsLiveText: Bool { self == .apple }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    var engine: SpeechEngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// Run every engine on each recording and show them side by side, instead of
    /// transcribing with one. Nothing is typed into the focused app in this mode.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Use the on-device LLM for cleanup instead of the deterministic rule pass.
    var smartCleanup: Bool {
        didSet { defaults.set(smartCleanup, forKey: Keys.smartCleanup) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// Mute other processes through Core Audio while a dictation is active. Off by default
    /// because playback continues while it is inaudible.
    var muteMedia: Bool {
        didSet {
            defaults.set(muteMedia, forKey: Keys.muteMedia)
            if muteMedia, pauseMedia { pauseMedia = false }
        }
    }

    /// Pause the active macOS Now Playing session while a dictation is active. This uses
    /// private MediaRemote API through Apple's `osascript`, so it remains experimental.
    var pauseMedia: Bool {
        didSet {
            defaults.set(pauseMedia, forKey: Keys.pauseMediaNowPlaying)
            if pauseMedia {
                if muteMedia { muteMedia = false }
                MediaPause.warmUp()
            }
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let smartCleanup = "smartCleanup"
        static let compareMode = "compareMode"
        static let muteMedia = "muteMedia"
        // Do not reuse the old "pauseMedia" key. Older builds stored the synthetic media
        // key toggle there, and opting those users into private API would be a surprise.
        static let pauseMediaNowPlaying = "pauseMediaNowPlaying"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        smartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        let savedPauseMedia = defaults.object(forKey: Keys.pauseMediaNowPlaying) as? Bool ?? false
        pauseMedia = savedPauseMedia
        muteMedia = savedPauseMedia
            ? false
            : defaults.object(forKey: Keys.muteMedia) as? Bool ?? false
    }
}
