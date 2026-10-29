import XCTest
@testable import NotchCompanion

final class MarkdownDocumentTests: XCTestCase {
    func testParagraphsKeepSoftLineBreaksAndSeparateBlankLines() {
        let blocks = MarkdownDocument.parse("First line\nsecond **line**.\n\nA [link](https://example.com).")
        XCTAssertEqual(blocks.map(\.content), [.paragraph("First line\nsecond **line**."), .paragraph("A [link](https://example.com).")])
    }

    func testHeadingsKeepInlineSyntaxAndStripOnlyClosingMarkers() {
        let blocks = MarkdownDocument.parse("# Main\n\n## **Details** ##\n\n### C#\n\n#hashtag\n\n####### Not a heading")
        XCTAssertEqual(blocks.map(\.content), [.heading(level: 1, text: "Main"), .heading(level: 2, text: "**Details**"), .heading(level: 3, text: "C#"), .paragraph("#hashtag"), .paragraph("####### Not a heading")])
    }

    func testNestedListsRetainTheirHierarchyAndContinuationParagraphs() {
        let blocks = MarkdownDocument.parse("- Parent\n  - Child\n    continued\n  - Another child\n\n  Parent detail.\n- Sibling\n\nAfter list.")
        guard case .list(ordered: false, let items) = blocks.first?.content else { return XCTFail("Expected a list") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].blocks.first?.content, .paragraph("Parent"))
        guard case .list(ordered: false, let children) = items[0].blocks[1].content else { return XCTFail("Expected a nested list") }
        XCTAssertEqual(children.map { $0.blocks.first?.content }, [.paragraph("Child\ncontinued"), .paragraph("Another child")])
        XCTAssertEqual(items[0].blocks.last?.content, .paragraph("Parent detail."))
        XCTAssertEqual(items[1].blocks.first?.content, .paragraph("Sibling"))
        XCTAssertEqual(blocks.last?.content, .paragraph("After list."))
    }

    func testOrderedListNumbersAndNestedUnorderedItemsArePreserved() {
        let blocks = MarkdownDocument.parse("3. Third\n   - Detail\n4. Fourth\n\n10) Tenth\n11) Eleventh")
        guard case .list(ordered: true, let items) = blocks.first?.content else { return XCTFail("Expected an ordered list") }
        XCTAssertEqual(items.map(\.number), [3, 4, 10, 11])
        guard case .list(ordered: false, let nested) = items[0].blocks[1].content else { return XCTFail("Expected a nested detail") }
        XCTAssertEqual(nested.first?.blocks.first?.content, .paragraph("Detail"))
    }

    func testFencedCodeIsLiteralAndPreservesWhitespace() {
        let source = "Before\n\n```swift\n    let message = \"**literal**\"\n\n    // # Not a heading\n```\n\nAfter"
        let blocks = MarkdownDocument.parse(source)
        XCTAssertEqual(blocks.map(\.content), [.paragraph("Before"), .code(language: "swift", text: "    let message = \"**literal**\"\n\n    // # Not a heading"), .paragraph("After")])
    }

    func testStreamingCodeKeepsIdentityWhenClosingFenceArrives() {
        let partial = MarkdownDocument.parse("## Result\n\n```python\nprint('one')")
        let complete = MarkdownDocument.parse("## Result\n\n```python\nprint('one')\nprint('two')\n```\n\nDone.")
        XCTAssertEqual(partial.map(\.id), Array(complete.prefix(2)).map(\.id))
        XCTAssertEqual(partial.last?.content, .code(language: "python", text: "print('one')"))
        XCTAssertEqual(complete[1].content, .code(language: "python", text: "print('one')\nprint('two')"))
    }

    func testFenceRequiresMatchingMarkerAndSufficientLength() {
        let blocks = MarkdownDocument.parse("````markdown\n```swift\nlet x = 1\n```\n~~~\n````")
        XCTAssertEqual(blocks.map(\.content), [.code(language: "markdown", text: "```swift\nlet x = 1\n```\n~~~")])
        XCTAssertEqual(MarkdownDocument.parse("~~~text\n```\n~~~").first?.content, .code(language: "text", text: "```"))
    }

    func testQuoteContainsStructuredBlocks() {
        let blocks = MarkdownDocument.parse("> ## Reminder\n>\n> Keep **drafts**.\n> - Check the result\n> - Send when ready\n\nOutside.")
        guard case .quote(let quoted) = blocks.first?.content else { return XCTFail("Expected a quote") }
        XCTAssertEqual(quoted[0].content, .heading(level: 2, text: "Reminder"))
        XCTAssertEqual(quoted[1].content, .paragraph("Keep **drafts**."))
        guard case .list(ordered: false, let items) = quoted[2].content else { return XCTFail("Expected list inside quote") }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(blocks.last?.content, .paragraph("Outside."))
    }

    func testRulesAndSetextHeadingsAreDistinct() {
        let blocks = MarkdownDocument.parse("Title\n===\n\nSubtitle\n---\n\n---\n\n* * *\n\n___")
        XCTAssertEqual(blocks.map(\.content), [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Subtitle"), .rule, .rule, .rule])
    }

    func testIndentedFenceRemovesOnlyItsOpeningIndent() {
        let blocks = MarkdownDocument.parse("  ```\n  first\n    indented\n second\n  ```")
        XCTAssertEqual(blocks.first?.content, .code(language: nil, text: "first\n  indented\nsecond"))
    }

    func testOrdinaryPunctuationAndEscapesRemainText() {
        let source = "1.5 is a number\n-flag is an argument\n\\# Literal heading\n`inline code` stays inline"
        XCTAssertEqual(MarkdownDocument.parse(source).map(\.content), [.paragraph(source)])
    }

    func testEarlierBlockIdentitiesStayStableAsTextStreams() {
        let initial = MarkdownDocument.parse("A paragraph.\n\n- First\n- Sec")
        let updated = MarkdownDocument.parse("A paragraph.\n\n- First\n- Second\n\nAnother paragraph.")
        XCTAssertEqual(initial.map(\.id), Array(updated.prefix(2)).map(\.id))
        guard case .list(_, let initialItems) = initial[1].content,
              case .list(_, let updatedItems) = updated[1].content else { return XCTFail("Expected lists") }
        XCTAssertEqual(initialItems.map(\.id), updatedItems.map(\.id))
    }

    func testDeeplyNestedQuotesFallBackToLiteralContent() {
        let blocks = MarkdownDocument.parse(String(repeating: "> ", count: 100) + "Retained text")
        func innermost(_ block: MarkdownBlock) -> String? {
            switch block.content {
            case .quote(let children): return children.first.flatMap(innermost)
            case .paragraph(let text): return text
            default: return nil
            }
        }
        XCTAssertTrue(blocks.first.flatMap(innermost)?.hasSuffix("Retained text") == true)
    }

    func testCRLFAndEmptyResponses() {
        XCTAssertEqual(MarkdownDocument.parse("# Title\r\n\r\nText").map(\.content), [.heading(level: 1, text: "Title"), .paragraph("Text")])
        XCTAssertTrue(MarkdownDocument.parse("").isEmpty)
        XCTAssertTrue(MarkdownDocument.parse("  \n\t").isEmpty)
    }
}
