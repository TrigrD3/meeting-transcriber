import AudioTapLib
@testable import MeetingTranscriber
import XCTest

/// Dictation routing at the controller boundary, without Speech assets or audio hardware.
/// The injected factory represents both a ready on-device asset and an asset
/// still downloading; the published backend must describe what actually runs.
@MainActor
final class LiveTranscriptionDictationStreamingTests: XCTestCase {
    private actor NoopPipeline: LiveCaptionPipeline {
        func ingest(_: LiveAudioBuffer, backlog _: @Sendable () -> TimeInterval) {}
        func reset() {}
        // swiftlint:disable:next async_without_await
        func flush() async {}
    }

    private final class LoadTrackingEngine: StreamingTranscribingEngine {
        var modelState: EngineModelState = .loaded
        var downloadProgress: Double = 1
        var transcriptionProgress: Double = 1
        private(set) var loadModelCount = 0

        func loadModel() {
            loadModelCount += 1
        }

        func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
            []
        }

        func transcribeSamples(_: [Float]) -> String {
            ""
        }
    }

    func testReadyDictationUsesIndependentStreamingPipelines() async {
        let captions = LiveCaptionsState()
        var requestedLanguage: String?
        let factory: LiveTranscriptionController.DictationPipelineFactory = { language, makeSink in
            requestedLanguage = language
            _ = makeSink(.mic)
            _ = makeSink(.app)
            return (NoopPipeline(), NoopPipeline())
        }
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "id",
            dictationAvailable: true,
            dictationSupportsLanguage: { $0 == "id" },
            dictationPipelineFactory: factory,
        )

        await controller.prepare()

        XCTAssertEqual(requestedLanguage, "id")
        XCTAssertEqual(captions.activeBackend, "Dictation · ID")
        await controller.prepareForNextRecording()
        XCTAssertEqual(captions.activeBackend, "Dictation · ID")
    }

    /// A recording that starts before the warm-up resolves must leave the build to
    /// `prepare()`, so the Dictation sessions still replace the fallback.
    func testRecordingBeforePrepareStillBuildsDictation() async {
        let captions = LiveCaptionsState()
        var builds = 0
        let controller = LiveTranscriptionController(
            engine: LoadTrackingEngine(),
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "id",
            dictationAvailable: true,
            dictationSupportsLanguage: { $0 == "id" },
            dictationPipelineFactory: { _, _ in
                builds += 1
                return (NoopPipeline(), NoopPipeline())
            },
        )

        await controller.prepareForNextRecording()
        await controller.prepare()

        XCTAssertEqual(builds, 1)
        XCTAssertEqual(captions.activeBackend, "Dictation · ID")
    }

    func testMissingDictationAssetUsesRetranscribeUntilReady() async {
        let captions = LiveCaptionsState()
        let engine = LoadTrackingEngine()
        var requestedLanguage: String?
        let factory: LiveTranscriptionController.DictationPipelineFactory = { language, _ in
            requestedLanguage = language
            return nil
        }
        let controller = LiveTranscriptionController(
            engine: engine,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "id_ID",
            dictationAvailable: true,
            dictationSupportsLanguage: { $0 == "id_ID" },
            dictationPipelineFactory: factory,
        )

        await controller.prepare()

        XCTAssertEqual(requestedLanguage, "id_ID")
        XCTAssertEqual(engine.loadModelCount, 1)
        XCTAssertEqual(captions.activeBackend, "Re-transcribe · ID_ID")
    }

    /// Before macOS 26 a supported locale must not reach the Dictation factory.
    func testDictationUnavailableNeverBuildsDictation() async {
        let captions = LiveCaptionsState()
        var factoryCalled = false
        let controller = LiveTranscriptionController(
            engine: LoadTrackingEngine(),
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "id",
            dictationAvailable: false,
            dictationSupportsLanguage: { _ in true },
            dictationPipelineFactory: { _, _ in
                factoryCalled = true
                return (NoopPipeline(), NoopPipeline())
            },
        )

        await controller.prepare()

        XCTAssertFalse(factoryCalled)
        XCTAssertEqual(captions.activeBackend, "Re-transcribe · ID")
    }

    /// With no engine to fall back to, the warm-up failure names the Dictation error.
    func testFailedDictationPrepareReportsItsError() async {
        struct PrepareError: LocalizedError {
            var errorDescription: String? {
                "dictation prepare failed"
            }
        }
        let captions = LiveCaptionsState()
        let controller = LiveTranscriptionController(
            engine: nil,
            vad: FluidVAD(threshold: 0.5),
            captions: captions,
            speakerMatcher: FakeLiveSpeakerMatcher(),
            engineLanguage: "id",
            dictationAvailable: true,
            dictationSupportsLanguage: { $0 == "id" },
            dictationPipelineFactory: { _, _ in throw PrepareError() },
        )

        await controller.prepare()

        XCTAssertNil(captions.activeBackend)
        XCTAssertEqual(controller.prepareFailure, "dictation prepare failed")
    }
}
