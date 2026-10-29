import Foundation
import os.log

private let logger = Logger(subsystem: "com.meetingtranscriber", category: "NotionClient")

/// Native async Notion API client for creating databases and exporting meeting notes.
public actor NotionClient: NotionExporting {
    public static let notionAPIVersion = "2022-06-28"
    private static let baseURL = URL(string: "https://api.notion.com/v1")!

    private let apiKey: String
    private let configuredDatabaseID: String?
    private let session: URLSession

    public init(apiKey: String, databaseID: String? = nil, session: URLSession? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.configuredDatabaseID = databaseID.flatMap { NotionClient.extractID(from: $0) }
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - ID Parser

    /// Extracts a 32-hex character Notion ID from a raw UUID or Notion page/database URL.
    public static func extractID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Remove query parameters and anchors
        let withoutQuery = trimmed.components(separatedBy: "?").first ?? trimmed
        let path = withoutQuery.components(separatedBy: "#").first ?? withoutQuery

        // 1. Standard UUID format: 8-4-4-4-12
        let uuidPattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        if let uuidRegex = try? NSRegularExpression(pattern: uuidPattern),
           let match = uuidRegex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           let range = Range(match.range, in: path) {
            return String(path[range]).replacingOccurrences(of: "-", with: "").lowercased()
        }

        // 2. Continuous 32-hex characters
        let hexPattern = #"[0-9a-fA-F]{32}"#
        if let hexRegex = try? NSRegularExpression(pattern: hexPattern),
           let match = hexRegex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
           let range = Range(match.range, in: path) {
            return String(path[range]).lowercased()
        }

        return nil
    }

    // MARK: - Database Management

    /// Validates database accessibility and returns its display title.
    public func validateDatabase(id: String) async throws -> String {
        guard let cleanID = Self.extractID(from: id) else {
            throw NotionClientError.invalidID("Invalid Database ID or URL")
        }

        let url = Self.baseURL.appendingPathComponent("databases/\(cleanID)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)

        let decoded = try JSONDecoder().decode(NotionDatabaseResponse.self, from: data)
        let title = decoded.title?.compactMap { $0.plainText }.joined() ?? ""
        return title.isEmpty ? "Untitled Database" : title
    }

    /// Creates a new "Meeting Transcriber" database under the specified parent page.
    public func createDatabase(parentPageID: String, title: String = "Meeting Transcriber") async throws -> String {
        guard let cleanParentID = Self.extractID(from: parentPageID) else {
            throw NotionClientError.invalidID("Invalid Parent Page ID or URL")
        }

        let url = Self.baseURL.appendingPathComponent("databases")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request)

        let payload = NotionDatabaseCreateRequest(
            parent: .init(pageId: cleanParentID),
            title: [.init(text: .init(content: title))],
            properties: .init()
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)

        let decoded = try JSONDecoder().decode(NotionDatabaseResponse.self, from: data)
        return decoded.id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: - NotionExporting

    public func exportMeeting(
        title: String,
        date: Date?,
        tags: [String],
        markdown: String,
        transcript: String?
    ) async throws -> NotionPageResult {
        guard let databaseID = configuredDatabaseID else {
            throw NotionClientError.missingDatabaseID
        }

        // 1. Inspect database schema for property matching
        let schemaUrl = Self.baseURL.appendingPathComponent("databases/\(databaseID)")
        var schemaReq = URLRequest(url: schemaUrl)
        schemaReq.httpMethod = "GET"
        applyHeaders(to: &schemaReq)

        let (schemaData, schemaResp) = try await session.data(for: schemaReq)
        try validateResponse(schemaResp, data: schemaData)

        let dbInfo = try JSONDecoder().decode(NotionDatabaseResponse.self, from: schemaData)
        let props = dbInfo.properties ?? [:]

        // Identify properties dynamically
        var titlePropName = "Title"
        var hasDateProp = false
        var hasTagsProp = false

        for (propName, info) in props {
            if info.type == "title" {
                titlePropName = propName
            } else if info.type == "date" && propName.lowercased() == "date" {
                hasDateProp = true
            } else if info.type == "multi_select" && propName.lowercased() == "tags" {
                hasTagsProp = true
            }
        }

        // 2. Prepare properties
        var properties: [String: NotionPropertyValue] = [
            titlePropName: .title(title),
        ]
        if let date, hasDateProp {
            properties["Date"] = .date(date)
        }
        if hasTagsProp && !tags.isEmpty {
            properties["Tags"] = .multiSelect(tags)
        }

        // 3. Convert markdown to Notion blocks
        let allBlocks = MarkdownToNotionBlocks.convert(markdown: markdown, transcript: transcript)
        let firstBatch = Array(allBlocks.prefix(100))
        let remainingBlocks = Array(allBlocks.dropFirst(100))

        // 4. Create the page
        let pageUrl = Self.baseURL.appendingPathComponent("pages")
        var pageReq = URLRequest(url: pageUrl)
        pageReq.httpMethod = "POST"
        applyHeaders(to: &pageReq)

        let createPayload = NotionPageCreateRequest(
            parent: .init(databaseId: databaseID),
            icon: .init(emoji: "🎙️"),
            properties: properties,
            children: firstBatch
        )
        pageReq.httpBody = try JSONEncoder().encode(createPayload)

        let (pageData, pageResp) = try await session.data(for: pageReq)
        try validateResponse(pageResp, data: pageData)

        let pageResult = try JSONDecoder().decode(NotionPageResponse.self, from: pageData)

        // 5. Append overflow blocks in batches of 100 if any
        if !remainingBlocks.isEmpty {
            var chunkStart = 0
            while chunkStart < remainingBlocks.count {
                let chunkEnd = min(chunkStart + 100, remainingBlocks.count)
                let batch = Array(remainingBlocks[chunkStart..<chunkEnd])

                let appendUrl = Self.baseURL.appendingPathComponent("blocks/\(pageResult.id)/children")
                var appendReq = URLRequest(url: appendUrl)
                appendReq.httpMethod = "PATCH"
                applyHeaders(to: &appendReq)

                let appendPayload = NotionBlockAppendRequest(children: batch)
                appendReq.httpBody = try JSONEncoder().encode(appendPayload)

                let (appendData, appendResp) = try await session.data(for: appendReq)
                try validateResponse(appendResp, data: appendData)

                chunkStart += 100
            }
        }

        return NotionPageResult(pageID: pageResult.id, url: pageResult.url)
    }

    // MARK: - Private Helpers

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.notionAPIVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NotionClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(NotionAPIError.self, from: data) {
                throw apiError
            }
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NotionClientError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }
}

public enum NotionClientError: LocalizedError, Equatable {
    case invalidID(String)
    case missingDatabaseID
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidID(let msg):
            return msg
        case .missingDatabaseID:
            return "No Notion Database ID configured."
        case .invalidResponse:
            return "Invalid response received from Notion."
        case .httpError(let code, let msg):
            return "Notion error (HTTP \(code)): \(msg)"
        }
    }
}
