import Foundation

struct NowPlayingSession: Codable, Equatable, Sendable {
    let identity: String
    let bundleID: String
    let name: String
    let title: String
    let playing: Bool
}

/// Reads and controls the active macOS Now Playing session through Apple's `osascript`.
///
/// MediaRemote is private API. Since macOS 15.4, a normal third-party process cannot read
/// it. `osascript` is an Apple platform binary and still has access. Keeping the private API
/// call in that short-lived process also means Dictator never links the framework itself.
struct NowPlayingClient: Sendable {
    enum Command: String, Sendable {
        case pause
        case play

        var mediaRemoteValue: Int {
            switch self {
            case .play: 0
            case .pause: 1
            }
        }
    }

    struct Reply: Codable, Sendable {
        let sent: Bool
        let session: NowPlayingSession?
        let error: String?
    }

    enum ClientError: LocalizedError {
        case launch(String)
        case failed(Int32, String)
        case invalidReply(String)
        case reported(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .launch(let message): "could not start the Now Playing helper: \(message)"
            case .failed(let status, let message): "Now Playing helper failed with status \(status): \(message)"
            case .invalidReply(let reply): "Now Playing helper returned invalid data: \(reply)"
            case .reported(let message): "Now Playing helper reported: \(message)"
            case .timedOut: "Now Playing helper timed out"
            }
        }
    }

    func currentSession() async throws -> NowPlayingSession? {
        let reply = try await run(action: "query", expectedIdentity: "", commandValue: -1)
        if let error = reply.error { throw ClientError.reported(error) }
        return reply.session
    }

    func send(_ command: Command, to session: NowPlayingSession) async throws -> Reply {
        try await run(
            action: "command",
            expectedIdentity: session.identity,
            commandValue: command.mediaRemoteValue
        )
    }

    private func run(
        action: String,
        expectedIdentity: String,
        commandValue: Int
    ) async throws -> Reply {
        try await Task.detached(priority: .userInitiated) {
            try Self.runSynchronously(
                action: action,
                expectedIdentity: expectedIdentity,
                commandValue: commandValue
            )
        }.value
    }

    private static func runSynchronously(
        action: String,
        expectedIdentity: String,
        commandValue: Int
    ) throws -> Reply {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-l", "JavaScript", "-e", script, "--",
            action, expectedIdentity, String(commandValue),
        ]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw ClientError.launch(error.localizedDescription)
        }

        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw ClientError.timedOut
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let outputText = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw ClientError.failed(process.terminationStatus, errorText)
        }
        guard let data = outputText.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else {
            throw ClientError.invalidReply(outputText)
        }
        return reply
    }

    /// `MRNowPlayingController` sends explicit play and pause commands. This script checks
    /// the session identity and state again inside the helper process before sending one.
    /// That closes the race between Dictator reading a player and another player becoming
    /// active.
    private static let script = #"""
    ObjC.import("Foundation");

    function unwrap(value) {
        if (!value) return "";
        try {
            const result = ObjC.unwrap(value);
            return result === undefined || result === null ? "" : String(result);
        } catch (_) {
            return "";
        }
    }

    function loadMediaRemote() {
        const framework = $.NSBundle.bundleWithPath(
            "/System/Library/PrivateFrameworks/MediaRemote.framework"
        );
        if (!framework || !framework.load) throw new Error("MediaRemote did not load");
    }

    function currentSession() {
        const request = $.NSClassFromString("MRNowPlayingRequest");
        const path = request.localNowPlayingPlayerPath;
        if (!path) return null;

        const bundleID = unwrap(path.client.bundleIdentifier);
        const name = unwrap(path.client.displayName);
        const clientID = unwrap(path.client.identifier);
        const playerID = unwrap(path.player.identifier);
        if (!bundleID && !name && !clientID && !playerID) return null;

        const item = request.localNowPlayingItem;
        const info = item ? item.nowPlayingInfo : null;
        const title = info
            ? unwrap(info.valueForKey("kMRMediaRemoteNowPlayingInfoTitle"))
            : "";
        const identity = [bundleID, clientID, playerID].join("|");

        return {
            identity: identity,
            bundleID: bundleID,
            name: name,
            title: title,
            playing: Boolean(request.localIsPlaying),
        };
    }

    function result(sent, session, error) {
        return JSON.stringify({ sent: sent, session: session, error: error || null });
    }

    function run(arguments) {
        try {
            loadMediaRemote();
            const action = arguments[0] || "query";
            const expectedIdentity = arguments[1] || "";
            const command = Number(arguments[2]);
            const before = currentSession();

            if (action === "query") return result(false, before, null);
            if (!before || before.identity !== expectedIdentity) {
                return result(false, before, "active player changed");
            }
            if (command === 1 && !before.playing) {
                return result(false, before, "player is not playing");
            }
            if (command === 0 && before.playing) {
                return result(false, before, "player is already playing");
            }

            const controllerClass = $.NSClassFromString("MRNowPlayingController");
            const controller = controllerClass.localRouteController;
            const options = $.NSDictionary.alloc.init;
            controller.sendCommandOptionsCompletion(command, options, null);
            delay(0.12);
            return result(true, currentSession(), null);
        } catch (error) {
            return result(false, null, String(error));
        }
    }
    """#
}
