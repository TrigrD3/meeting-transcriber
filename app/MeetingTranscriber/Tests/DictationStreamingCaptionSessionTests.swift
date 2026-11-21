@testable import MeetingTranscriber
import OSLog
import Speech
import XCTest

/// Runs the real Speech session, so it skips where the Indonesian Dictation assets aren't installed.
final class DictationStreamingCaptionSessionTests: XCTestCase {
    /// A channel that never received audio (No Microphone) is torn down on stop;
    /// that teardown must not be logged as a results error.
    func testFlushWithoutAudioLogsNoResultsError() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("DictationTranscriber needs macOS 26") }
        let locale = Locale(identifier: "id_ID")
        let label = "test-\(UUID().uuidString.prefix(8))"
        let start = Date()
        let session = DictationStreamingCaptionSession(locale: locale, channelLabel: label) { _ in }
        do { try await session.prepare() } catch { throw XCTSkip("id_ID Dictation unavailable: \(error)") }
        await session.flush()

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let errors = try store.getEntries(at: store.position(date: start))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.category == "DictationCaptions" && $0.composedMessage.contains("[\(label)] results error") }
        XCTAssertEqual(errors.map(\.composedMessage), [])
    }

    func testLongFinalSplitsIntoLinesWithTheAudioOnTheFirst() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("DictationTranscriber needs macOS 26") }
        let words = (1 ... 30).map { "w\($0)" }
        let events = DictationStreamingCaptionSession.finalEvents(words.joined(separator: " "), audio: [0.1, 0.2])
        XCTAssertEqual(events.map(Self.describe), ["final:14:2", "final:14:0", "final:2:0"])
    }

    func testShortFinalStaysOneLine() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("DictationTranscriber needs macOS 26") }
        let events = DictationStreamingCaptionSession.finalEvents("selamat pagi semua", audio: [0.1])
        XCTAssertEqual(events.map(Self.describe), ["final:3:1"])
    }

    /// An empty final ends the utterance, so the standing hypothesis must be cleared.
    func testEmptyFinalClearsTheHypothesis() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("DictationTranscriber needs macOS 26") }
        XCTAssertEqual(DictationStreamingCaptionSession.finalEvents("", audio: []).map(Self.describe), ["partial:"])
    }

    /// `final:<words>:<audio samples>` or `partial:<text>`.
    private static func describe(_ event: StreamingTranscriber.Event) -> String {
        switch event {
        case let .partial(text): "partial:\(text)"
        case let .finalized(text, audio): "final:\(text.split(separator: " ").count):\(audio.count)"
        }
    }
}
