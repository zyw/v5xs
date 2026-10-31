import XCTest
@testable import MonitorCore

final class ReleaseNotesMarkdownTests: XCTestCase {
    func testReleaseNotesRetainBlockStructureAndInlineFormatting() {
        let markdown = """
        # v5xs 0.1.4

        > Release date: 2026-10-30

        ## Changes

        - **Localized uninstaller** with [details](https://example.com)
        - Faster search

        1. Download
        2. Restart

        ```swift
        let build = 6
        ```
        """
        let blocks = ReleaseNotesMarkdown.parse(markdown)

        XCTAssertEqual(blocks.map(\.kind), [
            .heading(1), .quote, .heading(2), .bullet(depth: 0), .bullet(depth: 0),
            .number(1, depth: 0), .number(2, depth: 0), .code
        ])
        XCTAssertEqual(String(blocks[0].content.characters), "v5xs 0.1.4")
        XCTAssertEqual(String(blocks[3].content.characters), "Localized uninstaller with details")
        XCTAssertTrue(blocks[3].content.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(blocks[3].content.runs.contains {
            $0.link == URL(string: "https://example.com")
        })
        XCTAssertEqual(String(blocks[7].content.characters), "let build = 6\n")
    }

    func testSeparatesParagraphsAndRuleWithoutShowingMarkdownMarkers() {
        let blocks = ReleaseNotesMarkdown.parse("First paragraph\n\n---\n\nSecond paragraph")

        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .rule, .paragraph])
        XCTAssertEqual(blocks.map { String($0.content.characters) },
                       ["First paragraph", "⸻", "Second paragraph"])
    }

    func testNestedListUsesItsOwnMarkerAndIndentation() {
        let blocks = ReleaseNotesMarkdown.parse("1. Parent\n   - Child\n   - Another\n2. Next")

        XCTAssertEqual(blocks.map(\.kind), [
            .number(1, depth: 0), .bullet(depth: 1), .bullet(depth: 1), .number(2, depth: 0)
        ])
    }
}
