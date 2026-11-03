@testable import MeetingTranscriber
import XCTest

/// The local model's lifecycle under the cloud toggle, at the `EngineController`
/// seam with fake engines: no preload with cloud on, unload on switching on
/// (deferred while a local transcription runs), reload on switching off.
@MainActor
final class EngineControllerCloudModelTests: XCTestCase {
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var settings: AppSettings!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var suiteName: String!
    private let whisperKit = FakeLocalEngine()
    private let parakeet = FakeLocalEngine()

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "EngineControllerCloudModelTests-\(getpid())-\(UUID().uuidString)"
        guard let suite = DefaultsSuite.open(suiteName) else {
            XCTFail("Could not create test UserDefaults suite")
            return
        }
        settings = AppSettings(defaults: suite)
        settings.transcriptionEngine = .whisperKit
    }

    override func tearDown() async throws {
        settings = nil
        DefaultsSuite.remove(suiteName)
        suiteName = nil
        try await super.tearDown()
    }

    private func makeController() -> EngineController {
        EngineController(settings: settings, localEnginesForTesting: (whisperKit: whisperKit, parakeet: parakeet))
    }

    /// Lets the controller's observer tasks run without waiting on a condition.
    private func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }

    func testLaunchPreloadLoadsTheActiveModelWithCloudOff() async {
        let engines = makeController()
        await engines.preloadActiveModel()
        XCTAssertEqual(whisperKit.loads, 1)
        XCTAssertEqual(parakeet.loads, 0)
    }

    func testLaunchWithCloudOnSkipsThePreload() async {
        settings.cloudTranscriptionEnabled = true
        let engines = makeController()
        await engines.preloadActiveModel()
        XCTAssertEqual(whisperKit.loads, 0, "the local model was loaded with cloud on")
    }

    func testSwitchingCloudOnUnloadsTheLocalModels() async {
        whisperKit.modelState = .loaded
        let engines = makeController()
        settings.cloudTranscriptionEnabled = true
        await waitFor(whisperKit.unloads == 1, timeout: regressionCeiling)
        XCTAssertEqual(whisperKit.unloads, 1)
        XCTAssertEqual(parakeet.unloads, 1, "a model loaded before an engine switch stays in memory")
        XCTAssertEqual(whisperKit.modelState, .unloaded)
        withExtendedLifetime(engines) {}
    }

    func testSwitchingCloudOnDuringALocalTranscriptionDefersTheUnloadUntilItEnds() async {
        whisperKit.modelState = .loaded
        whisperKit.transcriptionsInFlight = 1
        let engines = makeController()
        settings.cloudTranscriptionEnabled = true
        await settle()
        XCTAssertEqual(whisperKit.unloads, 0, "the model was released under a running job")

        whisperKit.transcriptionsInFlight = 0
        await waitFor(whisperKit.unloads == 1, timeout: regressionCeiling)
        XCTAssertEqual(whisperKit.unloads, 1)
        XCTAssertEqual(parakeet.unloads, 1)
        withExtendedLifetime(engines) {}
    }

    func testSwitchingCloudOffReloadsTheActiveModel() async {
        settings.cloudTranscriptionEnabled = true
        let engines = makeController()
        settings.cloudTranscriptionEnabled = false
        await waitFor(whisperKit.loads == 1, timeout: regressionCeiling)
        XCTAssertEqual(whisperKit.loads, 1)
        XCTAssertEqual(parakeet.loads, 0, "only the selected engine is reloaded")
        withExtendedLifetime(engines) {}
    }

    func testCloudOnThenOffBeforeTheDeferredUnloadKeepsTheModel() async {
        whisperKit.modelState = .loaded
        whisperKit.transcriptionsInFlight = 1
        let engines = makeController()
        settings.cloudTranscriptionEnabled = true
        await settle()
        settings.cloudTranscriptionEnabled = false
        await settle()

        whisperKit.transcriptionsInFlight = 0
        await settle()
        XCTAssertEqual(whisperKit.unloads, 0, "the unload fired after cloud was switched off again")
        XCTAssertEqual(parakeet.unloads, 0)
        XCTAssertEqual(whisperKit.loads, 0, "the still-loaded model was built a second time")
        withExtendedLifetime(engines) {}
    }
}

/// A local engine that records loads and unloads and whose in-flight count the
/// test sets directly.
@MainActor
@Observable
final class FakeLocalEngine: TranscribingEngine {
    var modelState: EngineModelState = .unloaded
    var downloadProgress: Double = 0
    var transcriptionProgress: Double = 0
    var transcriptionsInFlight = 0
    private(set) var loads = 0
    private(set) var unloads = 0

    func loadModel() {
        loads += 1
        modelState = .loaded
    }

    func unloadModel() {
        unloads += 1
        modelState = .unloaded
    }

    func transcribeSegments(audioPath _: URL) -> [TimestampedSegment] {
        []
    }
}
