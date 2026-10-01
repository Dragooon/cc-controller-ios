import Darwin
import Foundation
import XCTest
@testable import CCKit

final class MarkdownDocumentTests: XCTestCase {
    func testBuildsTheExpectedGFMBlockTree() {
        let document = MarkdownDocument(parsing: """
        ## Heading

        A **bold**, *italic*, `code` and [link](https://example.com).

        - one
          - two
            - three

        3. three
        4. four

        ```swift
        let value = 1
        ```

        > quoted
        > - item

        ---

        | A | B | C |
        |---|---|---|
        | 1 | 2 | 3 |
        | 4 | 5 | 6 |
        """)

        XCTAssertEqual(document.blocks.count, 8)
        guard document.blocks.count == 8 else { return }

        assertHeading(document.blocks[0], level: 2, text: "Heading")
        assertParagraph(document.blocks[1], text: "A bold, italic, code and link.")
        assertInlineFormatting(in: document.blocks[1])
        assertNestedList(document.blocks[2])
        assertNumberedList(document.blocks[3])
        assertCode(document.blocks[4], language: "swift", text: "let value = 1\n")
        assertQuote(document.blocks[5])
        assertRule(document.blocks[6])
        assertTable(document.blocks[7])
    }

    func testPlainTextIsOneParagraph() {
        let document = MarkdownDocument(parsing: "Hello, world.")
        XCTAssertEqual(document.blocks.count, 1)
        assertParagraph(document.blocks[0], text: "Hello, world.")
    }

    func testUnterminatedCodeFenceKeepsCodeLiteral() {
        let document = MarkdownDocument(parsing: """
        ```swift
        # not a heading
        **not bold**
        """)

        XCTAssertEqual(document.blocks.count, 1)
        assertCode(document.blocks[0], language: "swift", text: "# not a heading\n**not bold**\n")
    }

    func testEmojiAndCJKRoundTrip() {
        let text = "## 你好 🌏\n\nこんにちは、世界。"
        let document = MarkdownDocument(parsing: text)

        XCTAssertEqual(document.blocks.compactMap(blockText).joined(separator: "\n"), "你好 🌏\nこんにちは、世界。")
    }

    func testVeryLongReplyParsesWithinFiftyMilliseconds() {
        let text = (1...2_000).map { "Line \($0) with plain text." }.joined(separator: "\n\n")
        _ = MarkdownDocument(parsing: text)

        var bestCPUTime = UInt64.max
        var document: MarkdownDocument?
        for _ in 0..<5 {
            let start = threadCPUTime()
            let parsed = MarkdownDocument(parsing: text)
            let elapsed = threadCPUTime() - start
            bestCPUTime = min(bestCPUTime, elapsed)
            document = parsed
        }

        guard let document else { return XCTFail("Expected a parsed document") }
        XCTAssertEqual(document.blocks.count, 2_000)
        XCTAssertLessThan(bestCPUTime, 50_000_000)
    }

    private func threadCPUTime() -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    private func assertHeading(_ block: MarkdownBlock, level: Int, text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .heading(let actualLevel, let actualText) = block else {
            return XCTFail("Expected heading", file: file, line: line)
        }
        XCTAssertEqual(actualLevel, level, file: file, line: line)
        XCTAssertEqual(String(actualText.characters), text, file: file, line: line)
    }

    private func assertParagraph(_ block: MarkdownBlock, text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .paragraph(let actualText) = block else {
            return XCTFail("Expected paragraph", file: file, line: line)
        }
        XCTAssertEqual(String(actualText.characters), text, file: file, line: line)
    }

    private func assertNestedList(_ block: MarkdownBlock, file: StaticString = #filePath, line: UInt = #line) {
        guard case .list(let ordered, let items) = block else {
            return XCTFail("Expected unordered list", file: file, line: line)
        }
        XCTAssertFalse(ordered, file: file, line: line)
        XCTAssertEqual(items.count, 1, file: file, line: line)
        XCTAssertEqual(items.first.map { String($0.text.characters) }, "one", file: file, line: line)
        guard let first = items.first, first.blocks.count == 1 else { return XCTFail("Expected nested list", file: file, line: line) }
        guard case .list(_, let secondItems) = first.blocks[0] else { return XCTFail("Expected second list", file: file, line: line) }
        XCTAssertEqual(secondItems.count, 1, file: file, line: line)
        XCTAssertEqual(String(secondItems[0].text.characters), "two", file: file, line: line)
        guard secondItems[0].blocks.count == 1, case .list(_, let thirdItems) = secondItems[0].blocks[0] else { return XCTFail("Expected third list", file: file, line: line) }
        XCTAssertEqual(thirdItems.count, 1, file: file, line: line)
        XCTAssertEqual(String(thirdItems[0].text.characters), "three", file: file, line: line)
    }

    private func assertNumberedList(_ block: MarkdownBlock, file: StaticString = #filePath, line: UInt = #line) {
        guard case .list(let ordered, let items) = block else { return XCTFail("Expected ordered list", file: file, line: line) }
        XCTAssertTrue(ordered, file: file, line: line)
        XCTAssertEqual(items.map(\.ordinal), [3, 4], file: file, line: line)
        XCTAssertEqual(items.map { String($0.text.characters) }, ["three", "four"], file: file, line: line)
    }

    private func assertCode(_ block: MarkdownBlock, language: String?, text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .code(let actualLanguage, let actualText) = block else { return XCTFail("Expected code", file: file, line: line) }
        XCTAssertEqual(actualLanguage, language, file: file, line: line)
        XCTAssertEqual(actualText, text, file: file, line: line)
    }

    private func assertQuote(_ block: MarkdownBlock, file: StaticString = #filePath, line: UInt = #line) {
        guard case .quote(let blocks) = block else { return XCTFail("Expected quote", file: file, line: line) }
        XCTAssertEqual(blocks.count, 2, file: file, line: line)
        assertParagraph(blocks[0], text: "quoted", file: file, line: line)
        guard case .list(let ordered, let items) = blocks[1] else { return XCTFail("Expected quoted list", file: file, line: line) }
        XCTAssertFalse(ordered, file: file, line: line)
        XCTAssertEqual(items.count, 1, file: file, line: line)
        XCTAssertEqual(items.first.map { String($0.text.characters) }, "item", file: file, line: line)
    }

    private func assertRule(_ block: MarkdownBlock, file: StaticString = #filePath, line: UInt = #line) {
        guard case .rule = block else { return XCTFail("Expected rule", file: file, line: line) }
    }

    private func assertTable(_ block: MarkdownBlock, file: StaticString = #filePath, line: UInt = #line) {
        guard case .table(let header, let rows) = block else { return XCTFail("Expected table", file: file, line: line) }
        XCTAssertEqual(header.map { String($0.characters) }, ["A", "B", "C"], file: file, line: line)
        XCTAssertEqual(rows.map { $0.map { String($0.characters) } }, [["1", "2", "3"], ["4", "5", "6"]], file: file, line: line)
    }

    private func assertInlineFormatting(in block: MarkdownBlock, file: StaticString = #filePath, line: UInt = #line) {
        guard case .paragraph(let text) = block else { return XCTFail("Expected paragraph", file: file, line: line) }
        let runs = text.runs.map { (String(text[$0.range].characters), $0.inlinePresentationIntent != nil, $0.link != nil) }
        XCTAssertTrue(runs.contains { $0.0 == "bold" && $0.1 }, file: file, line: line)
        XCTAssertTrue(runs.contains { $0.0 == "italic" && $0.1 }, file: file, line: line)
        XCTAssertTrue(runs.contains { $0.0 == "code" && $0.1 }, file: file, line: line)
        XCTAssertTrue(runs.contains { $0.0 == "link" && $0.2 }, file: file, line: line)
    }

    private func blockText(_ block: MarkdownBlock) -> String? {
        switch block {
        case .heading(_, let text), .paragraph(let text): return String(text.characters)
        case .code(_, let text): return text
        default: return nil
        }
    }
}
