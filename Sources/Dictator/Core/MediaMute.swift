import CoreAudio
import Foundation

/// Keeps other apps quiet while Dictator records.
///
/// This deliberately does not send the global play/pause key. That key is a toggle owned
/// by whichever app most recently claimed the system media controls, which need not be the
/// app currently making sound. It can start an idle player or pause the wrong one.
///
/// A Core Audio process tap is a better fit. Its mute behavior stops system output without
/// changing any player's state. Destroying the tap restores output, so there is no command
/// to queue, no pause to verify, and no way for Dictator to resume an unrelated player.
@MainActor
enum MediaMute {
    private static var tapID = AudioObjectID(kAudioObjectUnknown)

    /// Mutes every process except Dictator if another process is currently producing audio.
    /// The tap is global, so a second source that starts during dictation is muted too.
    static func muteIfPlaying() {
        guard Settings.shared.muteMedia, tapID == kAudioObjectUnknown else { return }
        guard #available(macOS 14.2, *) else { return }

        let playing = AudioActivity.outputProcesses()
        guard !playing.isEmpty else { return }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Dictator recording mute"
        description.isPrivate = true
        description.muteBehavior = .muted

        // The global tap is exclusive, which means its list contains the processes to leave
        // alone. Newer SDKs can exclude Dictator by bundle ID even when it has not opened an
        // output stream yet. The macOS 14 SDK has no bundle-ID API, so Dictator's own sounds
        // are muted too while the tap is active.
#if compiler(>=6.0)
        if let bundleID = Bundle.main.bundleIdentifier {
            description.bundleIDs = [bundleID]
            description.isProcessRestoreEnabled = true
        }
#endif

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            Log.audio.error("could not mute system audio · Core Audio status \(status, privacy: .public)")
            return
        }

        tapID = newTapID
        let names = playing.map(\.name).joined(separator: ", ")
        Log.audio.info("muted system audio for dictation · \(names, privacy: .public)")
    }

    /// Removes the mute installed by `muteIfPlaying`. Safe to call from every teardown path.
    ///
    /// This is not gated on the setting. If the user turns media muting off during a
    /// dictation, Dictator still has to remove the tap it already created.
    static func restoreIfMuted() {
        guard tapID != kAudioObjectUnknown else { return }
        guard #available(macOS 14.2, *) else { return }

        let oldTapID = tapID
        let status = AudioHardwareDestroyProcessTap(oldTapID)
        if status == noErr {
            tapID = AudioObjectID(kAudioObjectUnknown)
            Log.audio.info("restored system audio")
        } else {
            Log.audio.error("could not restore system audio · Core Audio status \(status, privacy: .public)")
        }
    }
}
