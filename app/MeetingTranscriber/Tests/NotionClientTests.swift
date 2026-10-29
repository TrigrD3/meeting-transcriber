import Foundation
@testable import MeetingTranscriber
import XCTest

final class NotionClientTests: XCTestCase {
    func testExtractIDFromRawUUID() {
        let rawUUID = "c83b8b17-1234-4567-89ab-cdef01234567"
        let expected = "c83b8b171234456789abcdef01234567"
        XCTAssertEqual(NotionClient.extractID(from: rawUUID), expected)
    }

    func testExtractIDFromContinuousHex() {
        let hex = "c83b8b171234456789abcdef01234567"
        XCTAssertEqual(NotionClient.extractID(from: hex), hex.lowercased())
    }

    func testExtractIDFromNotionPageURL() {
        let url = "https://www.notion.so/myworkspace/Meeting-Transcriber-c83b8b171234456789abcdef01234567"
        let expected = "c83b8b171234456789abcdef01234567"
        XCTAssertEqual(NotionClient.extractID(from: url), expected)
    }

    func testExtractIDFromURLWithQueryParams() {
        let url = "https://www.notion.so/myworkspace/Meeting-Transcriber-c83b8b171234456789abcdef01234567?v=987654321&p=123"
        let expected = "c83b8b171234456789abcdef01234567"
        XCTAssertEqual(NotionClient.extractID(from: url), expected)
    }

    func testExtractIDFromInvalidString() {
        XCTAssertNil(NotionClient.extractID(from: "not-a-valid-id"))
        XCTAssertNil(NotionClient.extractID(from: ""))
    }

    func testExtractSpeakerTags() {
        let transcript = """
        [Alice]: Welcome everyone.
        [Bob]: Thanks Alice.
        [Remote]: Hey there.
        [Charlie-Dev]: Let's start.
        """
        let tags = PipelineQueue.extractSpeakerTags(from: transcript)
        XCTAssertTrue(tags.contains("Alice"))
        XCTAssertTrue(tags.contains("Bob"))
        XCTAssertTrue(tags.contains("Charlie-Dev"))
        XCTAssertTrue(tags.contains("Meeting"))
        XCTAssertFalse(tags.contains("Remote"), "Remote routing tag should be excluded")
    }
}
