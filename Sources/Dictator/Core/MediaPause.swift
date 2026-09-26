import Foundation

/// Pauses the active macOS Now Playing session for the duration of a dictation.
///
/// Every operation is serialized. A short key hold can end while the helper is still
/// reading the player, and serial execution prevents a late pause from landing after the
/// matching resume. `dictationActive` lets a queued pause abort before it sends anything.
@MainActor
enum MediaPause {
    private static let client = NowPlayingClient()
    private static var chain: Task<Void, Never>?
    private static var dictationActive = false
    private static var owesResume: NowPlayingSession?

    /// Apps whose audio is part of a conversation rather than background media.
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.FaceTime",
        "com.cisco.webexmeetingsapp",
        "com.hnc.Discord",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "us.zoom.xos",
    ]

    static func warmUp() {
        guard Settings.shared.pauseMedia else { return }
        enqueue {
            do {
                _ = try await client.currentSession()
            } catch {
                Log.audio.error("Now Playing warm-up failed · \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func pauseIfPlaying() {
        dictationActive = true
        guard Settings.shared.pauseMedia else { return }

        enqueue {
            guard dictationActive, owesResume == nil else { return }

            do {
                guard let session = try await client.currentSession(),
                      session.playing,
                      !excludedBundleIDs.contains(session.bundleID),
                      dictationActive
                else { return }

                let reply = try await client.send(.pause, to: session)
                guard reply.sent else {
                    if let reason = reply.error {
                        Log.audio.info("media pause skipped · \(reason, privacy: .public)")
                    }
                    return
                }

                if let current = reply.session,
                   current.identity == session.identity,
                   !current.playing {
                    owesResume = session
                    Log.audio.info("paused media · \(session.name, privacy: .public)")
                    return
                }

                // Some players publish the state change after the command returns. Give
                // them a short window, but never queue a resume without seeing the pause.
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let current = try await client.currentSession(),
                          current.identity == session.identity
                    else { return }
                    if !current.playing {
                        owesResume = session
                        Log.audio.info("paused media · \(session.name, privacy: .public)")
                        return
                    }
                }
                Log.audio.info("media did not confirm the pause")
            } catch {
                Log.audio.error("media pause failed · \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resumes only the exact session whose pause Dictator observed.
    ///
    /// This is not gated on the setting. Turning pause off during a dictation must not
    /// strand media in the paused state. If another player owns Now Playing, the obligation
    /// stays around and a later dictation stop retries it.
    static func resumeIfPaused() {
        dictationActive = false
        enqueue {
            guard !dictationActive, let paused = owesResume else { return }

            do {
                guard let current = try await client.currentSession(),
                      current.identity == paused.identity
                else {
                    Log.audio.info("media resume deferred · active player changed")
                    return
                }

                if current.playing {
                    // The user or the player resumed while Dictator was recording.
                    owesResume = nil
                    return
                }

                let reply = try await client.send(.play, to: paused)
                guard reply.sent else {
                    if let reason = reply.error {
                        Log.audio.info("media resume deferred · \(reason, privacy: .public)")
                    }
                    return
                }

                if let current = reply.session,
                   current.identity == paused.identity,
                   current.playing {
                    owesResume = nil
                    Log.audio.info("resumed media · \(paused.name, privacy: .public)")
                    return
                }

                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let current = try await client.currentSession(),
                          current.identity == paused.identity
                    else { return }
                    if current.playing {
                        owesResume = nil
                        Log.audio.info("resumed media · \(paused.name, privacy: .public)")
                        return
                    }
                }
                Log.audio.info("media did not confirm the resume; will retry later")
            } catch {
                Log.audio.error("media resume failed · \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Lets app termination wait for an in-flight pause and its queued resume. The helper
    /// has its own timeout, so shutdown cannot hang forever.
    static func finishPendingWork() async {
        await chain?.value
    }

    private static func enqueue(_ operation: @escaping @Sendable @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }
}
