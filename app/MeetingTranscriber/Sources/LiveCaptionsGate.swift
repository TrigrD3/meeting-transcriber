import Foundation

/// Pure decision logic for whether live captions run, and which per-channel
/// streaming backend they use. Shared single source of truth between
/// `AppState.shouldShowLiveCaptions` (overlay-window visibility),
/// `LiveTranscriptionCoordinator` (whether to build + arm the controller), and
/// `LiveTranscriptionController` (which pipeline each channel gets) so all three
/// agree. Pure + value-typed → unit-testable as a truth table without
/// constructing the actors.
///
/// **Master toggle (`liveEnabled`) still gates the pipeline** — off means no
/// captions, regardless of the other inputs. `overlayEnabled` only gates the
/// overlay window (`overlayVisible`); it is not a strategy input.
///
/// **The backend follows the active engine's EXPLICITLY configured language**
/// (not auto-detect): trained non-English languages → Nemotron, English → Parakeet
/// EOU streaming. Both streaming sessions drive their FluidAudio models directly
/// and never touch the active `TranscribingEngine`, so they are available even
/// for engines without the re-transcribe hook. Languages outside
/// `LiveCaptionLanguages` that on-device Apple Dictation supports (macOS 26+)
/// use a Dictation session. Auto-detect (nil language) and every other language
/// use the engine-driven `.reTranscribe` fallback when supported, otherwise
/// captions are off.
enum LiveCaptionsGate {
    /// Which per-channel pipeline strategy to build, or none.
    enum Strategy: Equatable {
        /// Low-latency streaming session via Nemotron multilingual (an explicitly
        /// configured, trained non-English language). FluidAudio auto-selects the Latin or
        /// full multilingual model variant from the language. Engine-independent.
        case nemotronStreaming
        /// On-device Apple Dictation session (macOS 26+) for a language Nemotron
        /// was not trained on. Engine-independent.
        case dictationStreaming
        /// Low-latency English streaming session (Parakeet EOU). Engine-independent.
        case englishStreaming
        /// VAD + re-transcribe via the active engine.
        case reTranscribe
        /// Captions are off — build nothing.
        case none // swiftlint:disable:this discouraged_none_name

        /// The name shown for a streaming session of this strategy, or nil when it streams nothing.
        var streamingBackendName: String? {
            switch self {
            case .nemotronStreaming: "Nemotron"
            case .englishStreaming: "Parakeet EOU"
            case .dictationStreaming: "Dictation"
            case .reTranscribe, .none: nil
            }
        }
    }

    /// Resolve the active strategy from the gate inputs.
    ///
    /// English routes to the English-optimized EOU path; table-covered non-English
    /// languages route to Nemotron multilingual, then Dictation when the runtime
    /// reports the locale as supported. Auto-detect (nil) and unsupported explicit
    /// languages fall back to engine-driven re-transcription when available.
    /// Dictation support is injected so selection stays synchronous and testable;
    /// asset readiness is checked when the pipeline is built.
    ///
    /// - Parameters:
    ///   - liveEnabled: master live-captions toggle.
    ///   - engineLanguage: the active engine's explicitly configured language
    ///     (ISO 639-1, e.g. `de`/`en`), or `nil` for auto-detect.
    ///   - engineSupportsLive: whether the active engine implements the
    ///     in-memory `transcribeSamples` re-transcribe hook.
    ///   - dictationAvailable: whether the OS has `DictationTranscriber` (macOS 26+).
    ///   - dictationSupportsLanguage: runtime on-device Dictation locale lookup.
    static func strategy(
        liveEnabled: Bool,
        engineLanguage: String?,
        engineSupportsLive: Bool,
        dictationAvailable: Bool = systemSupportsDictation,
        dictationSupportsLanguage: (String) -> Bool = { _ in false },
    ) -> Strategy {
        guard liveEnabled else { return .none }
        guard let engineLanguage else { return engineSupportsLive ? .reTranscribe : .none }
        if let tag = LiveCaptionLanguages.canonicalTag(for: engineLanguage) {
            return tag.hasPrefix("en-") ? .englishStreaming : .nemotronStreaming
        }
        if dictationAvailable, dictationSupportsLanguage(engineLanguage) { return .dictationStreaming }
        return engineSupportsLive ? .reTranscribe : .none
    }

    static var systemSupportsDictation: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Whether `language` would need the runtime Dictation locale list to route.
    static func needsDictationLookup(_ language: String) -> Bool {
        systemSupportsDictation && LiveCaptionLanguages.canonicalTag(for: language) == nil
    }

    /// Whether live captions are available at all (any non-`none` strategy).
    /// Drives the coordinator's eligibility gate. Overlay-window visibility is
    /// `overlayVisible`, which ANDs this with recording + the overlay toggle.
    static func captionsAvailable(
        liveEnabled: Bool,
        engineLanguage: String?,
        engineSupportsLive: Bool,
        dictationSupportsLanguage: (String) -> Bool = { _ in false },
    ) -> Bool {
        strategy(
            liveEnabled: liveEnabled,
            engineLanguage: engineLanguage,
            engineSupportsLive: engineSupportsLive,
            dictationSupportsLanguage: dictationSupportsLanguage,
        ) != .none
    }

    /// Whether the click-through caption bar should be on screen. Calls
    /// `captionsAvailable` (pipeline gate unchanged), then ANDs recording and
    /// the overlay toggle. `overlayEnabled` is UI-only: it never feeds
    /// `strategy` / coordinator arming.
    static func overlayVisible(
        liveEnabled: Bool,
        engineLanguage: String?,
        engineSupportsLive: Bool,
        isRecording: Bool,
        overlayEnabled: Bool,
        dictationSupportsLanguage: (String) -> Bool = { _ in false },
    ) -> Bool {
        captionsAvailable(
            liveEnabled: liveEnabled,
            engineLanguage: engineLanguage,
            engineSupportsLive: engineSupportsLive,
            dictationSupportsLanguage: dictationSupportsLanguage,
        ) && isRecording && overlayEnabled
    }
}
