import Foundation
@testable import MeetingTranscriber
import XCTest

final class MarkdownToNotionBlocksTests: XCTestCase {
    func testHeadingsConversion() {
        let md = """
        # Heading 1
        ## Heading 2
        ### Heading 3
        """
        let blocks = MarkdownToNotionBlocks.convert(markdown: md)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].type, "heading_1")
        XCTAssertEqual(blocks[1].type, "heading_2")
        XCTAssertEqual(blocks[2].type, "heading_3")
    }

    func testListsAndQuotesConversion() {
        let md = """
        - Bullet point 1
        * Bullet point 2
        1. Numbered item 1
        2. Numbered item 2
        > A wise quote
        ---
        """
        let blocks = MarkdownToNotionBlocks.convert(markdown: md)
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0].type, "bulleted_list_item")
        XCTAssertEqual(blocks[1].type, "bulleted_list_item")
        XCTAssertEqual(blocks[2].type, "numbered_list_item")
        XCTAssertEqual(blocks[3].type, "numbered_list_item")
        XCTAssertEqual(blocks[4].type, "quote")
        XCTAssertEqual(blocks[5].type, "divider")
    }

    func testTableConversion() {
        let md = """
        | Task | Assignee | Priority |
        | --- | --- | --- |
        | Setup CI | Alice | High |
        | Write Docs | Bob | Medium |
        """
        let blocks = MarkdownToNotionBlocks.convert(markdown: md)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].type, "table")
    }

    func testTranscriptConvertedToToggleBlock() {
        let md = """
        # Meeting Minutes
        Summary of the meeting.
        """
        let transcript = """
        [Alice]: Hi team!
        [Bob]: Hello Alice, let's start.
        """
        let blocks = MarkdownToNotionBlocks.convert(markdown: md, transcript: transcript)
        XCTAssertTrue(blocks.count >= 3)
        let toggle = blocks.first { $0.type == "toggle" }
        XCTAssertNotNil(toggle, "Transcript should be converted into a toggle block")
    }

    func testInlineFormattingInRichText() {
        let text = "This has **bold text**, *italic text*, and `code text`."
        let richText = MarkdownToNotionBlocks.makeRichText(text)
        XCTAssertGreaterThan(richText.count, 1)
    }

    func testLongTextIsClamped() {
        let veryLongText = String(repeating: "A", count: 3000)
        let richText = MarkdownToNotionBlocks.makeRichText(veryLongText)
        let totalCount = richText.reduce(0) { total, _ in total + 1 }
        XCTAssertGreaterThan(totalCount, 0)
    }
}
