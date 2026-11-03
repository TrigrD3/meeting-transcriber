import Foundation
import Observation

// MARK: - EngineController

/// Owns the transcription-engine concern: the engine instances
/// (`WhisperKitEngine`, `ParakeetEngine`),
/// the active-engine selection, and keeping each engine's model / language /
/// vocabulary in line with `AppSettings` (both an up-front sync at construction
/// and a self-rearming reactive observer for runtime changes).
///
/// Extracted from `AppState` as the final concern-specific controller in the
/// god-class split. Unlike the other controllers it is fully self-contained — it
/// needs only `settings`, so it does its up-front sync + arms its observer in its
/// own `init` (no post-init `activate` wiring). `AppState` exposes it as
/// `engines` and the pipeline / live-transcription coordinators read
/// `engines.activeTranscriptionEngine`; the watch-start path calls
/// `engines.syncEngineSettings()` for its belt-and-suspenders up-front sync.
///
/// Not `@Observable` — its stored engine references are `let`s and consumers
/// observe the engine instances themselves (each is `@Observable`), so the
/// controller exposes no observable state of its own. It still uses
/// `withObservationTracking` internally to watch the settings keys, which works
/// regardless of this type's annotation (same as `LiveTranscriptionCoordinator`).
@MainActor
final class EngineController {
    let whisperKit: WhisperKitEngine
    let parakeetEngine: ParakeetEngine
    /// The Settings row for WhisperKit models earlier builds left in
    /// `Documents`, built once here rather than on every Settings body pass.
    let legacyWhisperModels: LegacyWhisperModelsState?

    private let settings: AppSettings

    /// Shared serial warm-up queue. The launch model preload runs through it so
    /// it doesn't compile concurrently with the live-caption models (the
    /// simultaneous ANE / CoreML-compiler peak that starves the system on a
    /// meeting join). Defaulted so tests get an isolated queue.
    private let warmupQueue: ModelWarmupQueue

    // Dependency-default factories keep `init`'s body-type-check under the 300 ms
    // budget — an inline `@Observable` engine constructor forces the type-checker
    // to re-solve that engine's own init constraints at this call site (the same
    // reason AppState uses factory helpers for its defaults).

    private static func makeWhisperKit() -> WhisperKitEngine {
        WhisperKitEngine()
    }

    private static func makeParakeet() -> ParakeetEngine {
        ParakeetEngine()
    }

    /// Nil in the App Store build, which leaves the row out. Its `Documents` is
    /// the container's own, which iCloud does not sync, and that sync was the
    /// reason for the row; worse, a sandboxed `trashItem` moves container items
    /// into the container's private Trash, so nothing would be freed and
    /// Finder's Trash would never show them.
    private static func makeLegacyWhisperModels(settings: AppSettings) -> LegacyWhisperModelsState? {
        #if APPSTORE
            nil
        #else
            LegacyWhisperModelsState(settings: settings)
        #endif
    }

    /// The engines `activeTranscriptionEngine` and the cloud-toggle model
    /// lifecycle act on. The two instances above, unless a test injects fakes.
    private let localWhisperKit: any TranscribingEngine
    private let localParakeet: any TranscribingEngine

    /// Cloud was switched on and the local models are still to be released,
    /// once no local transcription is running. Cleared by switching cloud off.
    private var unloadPending = false
    private var waitingForIdleEngines = false
    private var cloudEnabled: Bool

    init(
        settings: AppSettings,
        warmupQueue: ModelWarmupQueue = ModelWarmupQueue(),
        localEnginesForTesting: (whisperKit: any TranscribingEngine, parakeet: any TranscribingEngine)? = nil,
    ) {
        self.settings = settings
        self.warmupQueue = warmupQueue
        self.whisperKit = Self.makeWhisperKit()
        self.parakeetEngine = Self.makeParakeet()
        self.localWhisperKit = localEnginesForTesting?.whisperKit ?? whisperKit
        self.localParakeet = localEnginesForTesting?.parakeet ?? parakeetEngine
        self.legacyWhisperModels = Self.makeLegacyWhisperModels(settings: settings)
        self.cloudEnabled = settings.cloudTranscriptionEnabled

        // Bring engines in line with the current settings up front so the first
        // transcription doesn't run against stale defaults, then start observing
        // for runtime changes.
        syncEngineSettings()
        observeEngineSettings()
        observeCloudSetting()
    }

    /// The active transcription engine based on the current settings.
    var activeTranscriptionEngine: any TranscribingEngine {
        switch settings.transcriptionEngine {
        case .parakeet:
            localParakeet

        case .whisperKit:
            localWhisperKit
        }
    }

    /// Pre-load the active engine's model (applying its settings-derived config
    /// first) so the first transcription doesn't pay the cold-load cost. Called
    /// from the menu-bar `.task` at launch. Skipped while cloud transcription is
    /// on, so the local model takes no memory.
    func preloadActiveModel() async {
        // Push settings into the active engine through the one canonical sync
        // (idempotent — it already ran at init), then load it. Routing the
        // variant/language writes through `syncEngineSettings` keeps a single
        // settings→engine path instead of re-inlining a whisperKit-only subset.
        syncEngineSettings()
        // Serialize against the live-caption model warm-up so the two big CoreML
        // loads don't compile at once. `run` awaits the load, so the caller still
        // returns only after the model is loaded. Cloud is read inside the slot:
        // a reload queued behind a warm-up must not load after cloud went back on.
        await warmupQueue.run { [self] in
            guard !settings.cloudTranscriptionEnabled else { return }
            let engine = activeTranscriptionEngine
            // A loaded model would be built a second time by `loadModel`.
            guard engine.modelState != .loaded else { return }
            await engine.loadModel()
        }
    }

    /// Cloud on releases the local models, once no local transcription is
    /// running; cloud off reloads the active one as the launch preload does.
    private func cloudSettingChanged(enabled: Bool) {
        if enabled {
            unloadPending = true
            unloadLocalModelsWhenIdle()
        } else {
            unloadPending = false
            Task { await preloadActiveModel() }
        }
    }

    /// The signal is each engine's `transcriptionsInFlight`, counted around
    /// `transcribeSegments`, which every pipeline job goes through, whichever
    /// queue or target resolved the engine.
    private func unloadLocalModelsWhenIdle() {
        guard unloadPending else { return }
        let engines = [localWhisperKit, localParakeet]
        guard engines.allSatisfy({ $0.transcriptionsInFlight == 0 }) else {
            guard !waitingForIdleEngines else { return }
            waitingForIdleEngines = true
            withObservationTracking {
                for engine in engines {
                    _ = engine.transcriptionsInFlight
                }
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.waitingForIdleEngines = false
                    self.unloadLocalModelsWhenIdle()
                }
            }
            return
        }
        unloadPending = false
        for engine in engines {
            engine.unloadModel()
        }
    }

    /// Push current model / language / vocabulary settings into the active
    /// engine. Idempotent — each branch only writes when the value actually
    /// differs, so unchanged settings don't churn the engine's `@Observable`
    /// watchers (`applyModelVariant` self-guards the same way).
    func syncEngineSettings() {
        switch settings.transcriptionEngine {
        case .whisperKit:
            let model = settings.whisperKitModelSelection
            whisperKit.applyModelVariant(model.variant, origin: model.origin)
            let next = settings.whisperLanguageOrNil
            if whisperKit.language != next { whisperKit.language = next }
            let nextVocab = settings.customVocabularyPath
            if whisperKit.customVocabularyPath != nextVocab { whisperKit.customVocabularyPath = nextVocab }
            let nextBookmark = settings.customVocabularyBookmark
            if whisperKit.customVocabularyBookmark != nextBookmark { whisperKit.customVocabularyBookmark = nextBookmark }
            let nextVocabularyPromptEnabled = settings.customVocabularyEnabled
            if whisperKit.vocabularyPromptEnabled != nextVocabularyPromptEnabled {
                whisperKit.vocabularyPromptEnabled = nextVocabularyPromptEnabled
            }

        case .parakeet:
            let vocabularyOn = settings.customVocabularyEnabled
            let nextVocab = vocabularyOn ? settings.customVocabularyPath : ""
            if parakeetEngine.customVocabularyPath != nextVocab { parakeetEngine.customVocabularyPath = nextVocab }
            let nextBookmark = vocabularyOn ? settings.customVocabularyBookmark : nil
            if parakeetEngine.customVocabularyBookmark != nextBookmark { parakeetEngine.customVocabularyBookmark = nextBookmark }
            let nextLang = settings.parakeetLanguageOrNil
            if parakeetEngine.language != nextLang { parakeetEngine.language = nextLang }
        }
    }

    /// Acts only on a change of the cloud toggle; same re-arming pattern as below.
    private func observeCloudSetting() {
        withObservationTracking {
            _ = settings.cloudTranscriptionEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let enabled = self.settings.cloudTranscriptionEnabled
                if enabled != self.cloudEnabled {
                    self.cloudEnabled = enabled
                    self.cloudSettingChanged(enabled: enabled)
                }
                self.observeCloudSetting()
            }
        }
    }

    /// `withObservationTracking` is one-shot — re-arm after each fire so the
    /// controller reacts to every settings change, not just the first one.
    /// Same self-re-arming pattern the other concern controllers use.
    private func observeEngineSettings() {
        withObservationTracking {
            _ = settings.transcriptionEngine
            _ = settings.whisperKitModel
            _ = settings.whisperKitCustomModelEnabled
            _ = settings.whisperKitCustomRepo
            _ = settings.whisperKitCustomVariant
            _ = settings.whisperKitCustomModelFolderPath
            _ = settings.whisperKitCustomModelFolderBookmark
            _ = settings.whisperLanguage
            _ = settings.customVocabularyPath
            _ = settings.customVocabularyBookmark
            _ = settings.customVocabularyEnabled
            _ = settings.parakeetLanguage
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncEngineSettings()
                self.observeEngineSettings()
            }
        }
    }
}
