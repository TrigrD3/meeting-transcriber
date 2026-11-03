@testable import MeetingTranscriber
import XCTest

/// `unloadModel` on the two local engines, without real models: the load is
/// parked on a gate, so an unload can be placed inside it deterministically.
@MainActor
final class LocalEngineUnloadTests: XCTestCase {
    // MARK: - WhisperKit

    private func makeWhisperKit(gate: MainActorGate? = nil) async throws -> (WhisperKitEngine, WhisperKitLoadRecorder, URL) {
        let engine = WhisperKitEngine()
        engine.modelVariant = "openai_whisper-small"
        let local = try makeTempDirectory(prefix: "wk-unload")
        let recorder = try await installRecordingSource(
            on: engine,
            local: local,
            download: .failure(URLError(.networkConnectionLost)),
            pipe: .success(makeIdlePipe()),
            // swiftlint:disable:next trailing_closure
            onPipe: { _ in await gate?.wait() },
        )
        return (engine, recorder, local)
    }

    func testWhisperKitUnloadReleasesTheModelAndTheNextLoadBuildsItAgain() async throws {
        let (engine, recorder, _) = try await makeWhisperKit()
        await engine.loadModel()
        XCTAssertEqual(engine.modelState, .loaded)

        engine.unloadModel()
        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertFalse(engine.pipeInstalled)

        try await engine.loadModel(untilCancelled: true)
        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertEqual(recorder.pipeVariants.count, 2)
    }

    /// A preload is what the unload exists to stop: it must not count the
    /// discarded pass as superseded and build the model again.
    func testWhisperKitUnloadDuringAPreloadDiscardsItWithoutARetry() async throws {
        let gate = MainActorGate()
        let (engine, recorder, _) = try await makeWhisperKit(gate: gate)
        let preload = Task { @MainActor in
            await engine.loadModel()
            return true
        }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        engine.unloadModel()
        gate.open()
        let returned = await value(of: preload)

        XCTAssertNotNil(returned)
        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertFalse(engine.pipeInstalled, "the discarded load was installed")
        XCTAssertEqual(recorder.pipeVariants.count, 1, "the preload loaded again after the unload")
    }

    func testWhisperKitTranscriptionWaitingOnADiscardedLoadLoadsAgain() async throws {
        let gate = MainActorGate()
        let (engine, recorder, _) = try await makeWhisperKit(gate: gate)
        let transcription = Task { @MainActor in
            await outcome { try await engine.loadModel(untilCancelled: true) }
        }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        engine.unloadModel()
        gate.open()
        let result = await value(of: transcription)

        XCTAssertEqual(result, "returned")
        XCTAssertEqual(engine.modelState, .loaded)
        XCTAssertEqual(recorder.pipeVariants.count, 2)
    }

    func testWhisperKitCountsATranscriptionInFlight() async throws {
        let gate = MainActorGate()
        let (engine, _, local) = try await makeWhisperKit(gate: gate)
        let job = Task { @MainActor in
            await outcome { _ = try await engine.transcribeSegments(audioPath: local.appendingPathComponent("a.wav")) }
        }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        XCTAssertEqual(engine.transcriptionsInFlight, 1)

        job.cancel()
        _ = await value(of: job)
        XCTAssertEqual(engine.transcriptionsInFlight, 0)
        gate.open()
    }

    // MARK: - Parakeet

    private var parakeetLoads = 0

    private func makeParakeet(gate: MainActorGate) -> ParakeetEngine {
        let engine = ParakeetEngine()
        engine.installModelLoadForTesting { [self] in
            parakeetLoads += 1
            await gate.wait()
        }
        return engine
    }

    func testParakeetUnloadDuringAPreloadDiscardsItWithoutARetry() async {
        let gate = MainActorGate()
        let engine = makeParakeet(gate: gate)
        let preload = Task { @MainActor in
            await engine.loadModel()
            return true
        }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        engine.unloadModel()
        gate.open()
        let returned = await value(of: preload)

        XCTAssertNotNil(returned)
        XCTAssertEqual(engine.modelState, .unloaded)
        XCTAssertEqual(parakeetLoads, 1, "the preload loaded again after the unload")
    }

    /// The fake load installs no manager, so the job still ends with
    /// `modelNotLoaded`; what is pinned is that it loaded a second time.
    func testParakeetTranscriptionWaitingOnADiscardedLoadLoadsAgain() async {
        let gate = MainActorGate()
        let engine = makeParakeet(gate: gate)
        let job = Task { @MainActor in
            await outcome { _ = try await engine.transcribeSegments(audioPath: URL(fileURLWithPath: "/dev/null")) }
        }
        await waitFor(gate.hasWaiter, timeout: regressionCeiling)
        XCTAssertEqual(engine.transcriptionsInFlight, 1)
        engine.unloadModel()
        gate.open()
        _ = await value(of: job)

        XCTAssertEqual(parakeetLoads, 2)
        XCTAssertEqual(engine.transcriptionsInFlight, 0)
    }
}
