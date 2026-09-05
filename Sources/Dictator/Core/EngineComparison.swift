import AVFoundation
import Foundation

/// One engine's result from a comparison run.
struct ComparisonResult: Sendable {
    let engine: String
    let text: String
    let seconds: Double
}

/// Runs the *same* captured audio through every engine, so a single hold produces a
/// directly comparable set of outputs.
///
/// On macOS 14 the only local engine is Parakeet, so a comparison run is Parakeet against
/// Wispr Flow (filed separately by the caller). Every engine is still driven in batch from
/// the identical buffer, which is the only way to get numbers that mean the same thing.
enum EngineComparison {
    /// - Parameter onResult: called as each engine finishes, so the UI can show results
    ///   incrementally instead of waiting for the whole set.
    static func run(
        chunks: [AudioChunk],
        onResult: @MainActor (ComparisonResult) -> Void = { _ in }
    ) async -> [ComparisonResult] {
        var results: [ComparisonResult] = []
        // Sequential, not concurrent: two engines racing for the ANE and CPU would
        // contaminate each other's timings. So this is not a live race — each engine is
        // timed in isolation and the *measured* durations are what get compared.
        for (name, engine) in [
            ("Parakeet", ParakeetEngine() as any TranscriptionEngine),
        ] {
            let result = await measure(name: name, engine: engine, chunks: chunks)
            results.append(result)
            await onResult(result)
        }
        return results
    }

    private static func measure(
        name: String,
        engine: any TranscriptionEngine,
        chunks: [AudioChunk]
    ) async -> ComparisonResult {
        do {
            let stream = try await engine.start()

            // Clock starts *after* start() returns, deliberately. start() loads models —
            // for Parakeet that's ~470 MB on a cold first run — and whichever engine the
            // menu happens to have selected was already warmed by the live pass. Timing
            // from before start() would report that menu setting as an engine difference.
            let started = Date()

            // Collect on a separate task: the engine may emit its final result during
            // `finish()`, so the consumer has to already be draining.
            let collector = Task { () -> String in
                var latest = ""
                for try await chunk in stream { latest = chunk.text }
                return latest
            }

            for chunk in chunks {
                await engine.feed(chunk)
            }
            await engine.finish()

            // Surface a thrown stream as an error rather than as empty output — an engine
            // that failed and an engine that heard nothing look identical otherwise, which
            // is exactly how the audio-format bug hid.
            let text: String
            do {
                text = try await collector.value
            } catch {
                Log.speech.error("\(name, privacy: .public) stream failed: \(error.localizedDescription)")
                text = "⚠️ \(error.localizedDescription)"
            }

            return ComparisonResult(
                engine: name,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                seconds: Date().timeIntervalSince(started)
            )
        } catch {
            Log.speech.error("\(name, privacy: .public) comparison failed: \(error.localizedDescription)")
            await engine.finish()
            return ComparisonResult(engine: name, text: "⚠️ \(error.localizedDescription)", seconds: 0)
        }
    }
}
