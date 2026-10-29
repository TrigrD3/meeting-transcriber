import Foundation

/// Result of a meeting export to Notion.
public struct NotionPageResult: Sendable, Equatable {
    public let pageID: String
    public let url: String?

    public init(pageID: String, url: String? = nil) {
        self.pageID = pageID
        self.url = url
    }
}

/// Abstract interface for exporting meeting minutes to Notion.
public protocol NotionExporting: Sendable {
    func exportMeeting(
        title: String,
        date: Date?,
        tags: [String],
        markdown: String,
        transcript: String?
    ) async throws -> NotionPageResult
}
