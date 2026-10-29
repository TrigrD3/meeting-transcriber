import Foundation

// MARK: - Notion Database Models

struct NotionDatabaseCreateRequest: Encodable {
    struct Parent: Encodable {
        let type: String = "page_id"
        let pageId: String

        enum CodingKeys: String, CodingKey {
            case type
            case pageId = "page_id"
        }
    }

    struct TitleContent: Encodable {
        let type: String = "text"
        let text: TextContent
    }

    struct TextContent: Encodable {
        let content: String
    }

    struct Properties: Encodable {
        struct EmptySchema: Encodable {}
        struct MultiSelectOption: Encodable {
            let name: String
            let color: String?
        }
        struct MultiSelectSchema: Encodable {
            let options: [MultiSelectOption]?
        }

        let title: [String: EmptySchema] = ["title": EmptySchema()]
        let tags: [String: MultiSelectSchema] = ["multi_select": MultiSelectSchema(options: nil)]
        let date: [String: EmptySchema] = ["date": EmptySchema()]
        let createdTime: [String: EmptySchema] = ["created_time": EmptySchema()]
        let lastEditedTime: [String: EmptySchema] = ["last_edited_time": EmptySchema()]

        enum CodingKeys: String, CodingKey {
            case title = "Title"
            case tags = "Tags"
            case date = "Date"
            case createdTime = "Created time"
            case lastEditedTime = "Last edited time"
        }
    }

    let parent: Parent
    let title: [TitleContent]
    let properties: Properties
}

struct NotionDatabaseResponse: Decodable {
    struct TitleItem: Decodable {
        let plainText: String?
        enum CodingKeys: String, CodingKey {
            case plainText = "plain_text"
        }
    }

    struct PropertyInfo: Decodable {
        let id: String
        let name: String?
        let type: String
    }

    let id: String
    let title: [TitleItem]?
    let properties: [String: PropertyInfo]?
    let url: String?
}

// MARK: - Notion Page Models

struct NotionPageCreateRequest: Encodable {
    struct Parent: Encodable {
        let databaseId: String
        enum CodingKeys: String, CodingKey {
            case databaseId = "database_id"
        }
    }

    struct Icon: Encodable {
        let type: String = "emoji"
        let emoji: String
    }

    let parent: Parent
    let icon: Icon?
    let properties: [String: NotionPropertyValue]
    let children: [NotionBlock]
}

enum NotionPropertyValue: Encodable {
    case title(String)
    case date(Date)
    case multiSelect([String])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .title(let text):
            let dict: [String: [[String: AnyEncodable]]] = [
                "title": [
                    [
                        "type": AnyEncodable("text"),
                        "text": AnyEncodable(["content": AnyEncodable(String(text.prefix(2000)))]),
                    ],
                ],
            ]
            try container.encode(dict)
        case .date(let date):
            let formatter = ISO8601DateFormatter()
            let dict: [String: [String: String]] = [
                "date": ["start": formatter.string(from: date)],
            ]
            try container.encode(dict)
        case .multiSelect(let tags):
            let selectArray = tags.map { ["name": String($0.prefix(100))] }
            let dict: [String: [[String: String]]] = [
                "multi_select": selectArray,
            ]
            try container.encode(dict)
        }
    }
}

struct NotionPageResponse: Decodable {
    let id: String
    let url: String?
}

struct NotionAPIError: Decodable, LocalizedError {
    let status: Int?
    let code: String?
    let message: String?

    var errorDescription: String? {
        message ?? code ?? "Notion API error (\(status ?? 0))"
    }
}

// MARK: - Notion Block Models

struct NotionBlock: Encodable {
    let object: String = "block"
    let type: String
    let content: [String: AnyEncodable]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(object, forKey: DynamicKey(stringValue: "object")!)
        try container.encode(type, forKey: DynamicKey(stringValue: "type")!)
        try container.encode(content, forKey: DynamicKey(stringValue: type)!)
    }
}

struct NotionBlockAppendRequest: Encodable {
    let children: [NotionBlock]
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

struct AnyEncodable: Encodable {
    private let encodeFunc: (any Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeFunc = { try value.encode(to: $0) }
    }

    func encode(to encoder: any Encoder) throws {
        try encodeFunc(encoder)
    }
}
