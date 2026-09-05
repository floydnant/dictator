import Foundation

/// Cleanup via Apple's on-device LLM — unavailable on macOS 14.
///
/// The real implementation is built on `FoundationModels`, which ships with macOS 26. This
/// build targets macOS 14, so the type survives only as a shim: it reports itself
/// unavailable (which greys out the "Smart cleanup" toggle) and, if it is ever constructed
/// anyway, falls back to the deterministic rule pass rather than dropping the utterance.
struct FoundationModelFormatter: TextFormatter {
    private let fallback = RuleBasedFormatter()

    static var isAvailable: Bool { false }

    static var unavailableReason: String? {
        "Smart cleanup needs Apple Intelligence, which requires macOS 26."
    }

    func format(_ raw: String) async -> String {
        await fallback.format(raw)
    }
}
