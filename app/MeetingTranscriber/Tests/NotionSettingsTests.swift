import Foundation
@testable import MeetingTranscriber
import XCTest

final class NotionSettingsTests: XCTestCase {
    func testNotionSettingsPersistence() {
        let suite = "test.notion.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let notionKeyAccount = "notionKey.\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: suite)
            KeychainHelper.delete(key: notionKeyAccount)
        }

        let settings = AppSettings(
            defaults: defaults,
            notionAPIKeyAccount: notionKeyAccount
        )

        XCTAssertFalse(settings.notionExportEnabled)
        XCTAssertTrue(settings.notionSkipLocalMarkdownOnSuccess)
        XCTAssertEqual(settings.notionDatabaseID, "")
        XCTAssertEqual(settings.notionAPIKey, "")

        // Mutate settings
        settings.notionExportEnabled = true
        settings.notionSkipLocalMarkdownOnSuccess = false
        settings.notionDatabaseID = "c83b8b171234456789abcdef01234567"
        settings.notionAPIKey = "ntn_mock_secret_token"

        // Verify values
        XCTAssertTrue(settings.notionExportEnabled)
        XCTAssertFalse(settings.notionSkipLocalMarkdownOnSuccess)
        XCTAssertEqual(settings.notionDatabaseID, "c83b8b171234456789abcdef01234567")
        XCTAssertEqual(settings.notionAPIKey, "ntn_mock_secret_token")

        // Reload fresh settings instance with same suite
        let reloaded = AppSettings(
            defaults: defaults,
            notionAPIKeyAccount: notionKeyAccount
        )
        XCTAssertTrue(reloaded.notionExportEnabled)
        XCTAssertFalse(reloaded.notionSkipLocalMarkdownOnSuccess)
        XCTAssertEqual(reloaded.notionDatabaseID, "c83b8b171234456789abcdef01234567")
        XCTAssertEqual(reloaded.notionAPIKey, "ntn_mock_secret_token")
    }
}
