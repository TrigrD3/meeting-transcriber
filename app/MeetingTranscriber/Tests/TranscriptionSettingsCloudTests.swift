@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// One wiring test per cloud-transcription control in Settings → Transcribe,
/// plus the consent alert's two buttons.
@MainActor
final class TranscriptionSettingsCloudTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keyAccount: String!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "TranscriptionSettingsCloudTests-\(getpid())-\(UUID().uuidString)"
        defaults = try XCTUnwrap(DefaultsSuite.open(suiteName))
        // Never the production account: see `AppSettings.apiKeyAccount`.
        keyAccount = "TranscriptionSettingsCloudTests-key-\(getpid())-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        KeychainHelper.delete(key: keyAccount)
        DefaultsSuite.remove(suiteName)
        defaults = nil
        suiteName = nil
        keyAccount = nil
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, cloudTranscriptionAPIKeyAccount: keyAccount)
    }

    private func makeView(_ settings: AppSettings) -> TranscriptionSettingsView {
        TranscriptionSettingsView(
            settings: settings,
            whisperKitEngine: WhisperKitEngine(),
            parakeetEngine: ParakeetEngine(),
        )
    }

    private func tapToggle(in view: TranscriptionSettingsView) throws {
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionToggle)
            .find(ViewType.Toggle.self)
            .tap()
    }

    // MARK: - Placement

    func testCloudControlsHaveTheirOwnSectionAndRecordOnlyDisablesIt() throws {
        let settings = makeSettings()
        settings.recordOnly = true
        let body = try makeView(settings).inspect()
        let cloud = try body.find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionSection)
        XCTAssertNoThrow(try cloud.find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionToggle))
        XCTAssertTrue(cloud.isDisabled())
        let local = try body.find(viewWithAccessibilityIdentifier: A11yID.transcriptionSection)
        XCTAssertThrowsError(try local.find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionToggle))
    }

    // MARK: - Toggle and consent alert

    func testFirstEnableAsksAndCancelLeavesCloudOff() throws {
        let settings = makeSettings()
        let view = makeView(settings)

        try tapToggle(in: view)
        XCTAssertFalse(settings.cloudTranscriptionEnabled, "nothing may switch on before the user confirms")
        let alert = try view.inspect().find(ViewType.Alert.self)
        try alert.actions().find(button: "Cancel").tap()

        XCTAssertFalse(settings.cloudTranscriptionEnabled)
        XCTAssertFalse(settings.cloudTranscriptionConsented)
        XCTAssertThrowsError(try view.inspect().find(ViewType.Alert.self), "the alert must close on Cancel")
    }

    func testConfirmSwitchesCloudOnAndIsRemembered() throws {
        let settings = makeSettings()
        let view = makeView(settings)

        try tapToggle(in: view)
        try view.inspect().find(ViewType.Alert.self).actions().find(button: "Send to Cloud").tap()

        XCTAssertTrue(settings.cloudTranscriptionEnabled)
        XCTAssertTrue(settings.cloudTranscriptionConsented)
        XCTAssertTrue(makeSettings().cloudTranscriptionConsented, "the confirmation must persist")

        try tapToggle(in: view)
        XCTAssertFalse(settings.cloudTranscriptionEnabled)
        try tapToggle(in: view)
        XCTAssertTrue(settings.cloudTranscriptionEnabled, "a later enable must not ask again")
        XCTAssertThrowsError(try view.inspect().find(ViewType.Alert.self))
    }

    // MARK: - Fields and host note

    func testHostNoteNamesTheConfiguredHostOnlyWhileCloudIsOn() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionBaseURL = "https://transcribe.example.com/v1"

        XCTAssertThrowsError(
            try makeView(settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionHostNote),
        )

        settings.cloudTranscriptionEnabled = true
        let note = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionHostNote)
            .text()
            .string()
        XCTAssertTrue(note.contains("transcribe.example.com"), note)
    }

    func testBaseURLFieldWritesBack() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true

        try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionBaseURLField)
            .find(ViewType.TextField.self)
            .setInput("https://other.example.com/v1")

        XCTAssertEqual(settings.cloudTranscriptionBaseURL, "https://other.example.com/v1")
    }

    func testModelFieldWritesBack() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        XCTAssertEqual(settings.cloudTranscriptionModel, "whisper-1", "default model")

        try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionModelField)
            .find(ViewType.TextField.self)
            .setInput("whisper-large-v3")

        XCTAssertEqual(settings.cloudTranscriptionModel, "whisper-large-v3")
    }

    func testAPIKeyFieldWritesToTheKeychainNotUserDefaults() throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true

        try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionAPIKeyField)
            .find(ViewType.SecureField.self)
            .setInput("sk-cloud")

        XCTAssertEqual(KeychainHelper.read(key: keyAccount), "sk-cloud")
        let stored = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(stored.contains("sk-cloud"), "the key must never reach UserDefaults")
    }

    // MARK: - Live captions note

    func testLiveCaptionsNoteShowsOnlyWhenCloudTurnsCaptionsOff() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .parakeet
        settings.parakeetLanguage = ""
        settings.liveTranscriptionEnabled = true
        XCTAssertThrowsError(
            try makeView(settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsCloudOffNote),
            "no note while cloud is off",
        )

        settings.cloudTranscriptionEnabled = true
        let section = try makeView(settings).inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveTranscriptionSection)
        let note = try section.find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsCloudOffNote).text().string()
        XCTAssertEqual(note, "Live captions are off for this language while cloud transcription is on.")

        settings.parakeetLanguage = "en"
        XCTAssertThrowsError(
            try makeView(settings).inspect().find(viewWithAccessibilityIdentifier: A11yID.liveCaptionsCloudOffNote),
            "English captions stream without the local engine, so no note",
        )
    }

    // MARK: - Test Connection

    func testTestConnectionButtonRunsTheTestAndShowsItsResult() async throws {
        let settings = makeSettings()
        settings.cloudTranscriptionEnabled = true
        settings.cloudTranscriptionBaseURL = "https://cloud.test/v1"
        MockURLProtocol.handler = { request in
            // swiftlint:disable:next force_unwrapping
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.handler = nil }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let test = CloudConnectionTest(session: URLSession(configuration: sessionConfig))
        let controls = CloudTranscriptionControls(settings: settings, consent: CloudTranscriptionConsent(), connectionTest: test)

        try controls.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionTestButton)
            .find(ViewType.Button.self)
            .tap()
        XCTAssertTrue(test.isRunning, "the button must start the test and show it running")
        await test.task?.value

        XCTAssertEqual(test.result, .authFailed(status: 401))
        let status = try controls.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.cloudTranscriptionTestStatus)
            .find(ViewType.Text.self)
            .string()
        XCTAssertEqual(status, CloudConnectionTestResult.authFailed(status: 401).message)
    }

    // MARK: - Configuration

    func testConfigurationCarriesTheEngineLanguageAndVocabularyTerms() throws {
        let settings = makeSettings()
        settings.transcriptionEngine = .whisperKit
        settings.whisperLanguage = "id"
        let vocabulary = FileManager.default.temporaryDirectory.appendingPathComponent("vocab_\(UUID().uuidString).txt")
        try "Dexa\nProf Raymond\n".write(to: vocabulary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vocabulary) }
        settings.setCustomVocabularyPath(vocabulary.path)

        let config = settings.cloudTranscriptionConfiguration
        XCTAssertEqual(config.language, "id")
        XCTAssertEqual(config.vocabularyTerms, ["Dexa", "Prof Raymond"])

        settings.whisperLanguage = ""
        settings.clearCustomVocabularyFile()
        XCTAssertNil(settings.cloudTranscriptionConfiguration.language)
        XCTAssertEqual(settings.cloudTranscriptionConfiguration.vocabularyTerms, [])
    }
}
