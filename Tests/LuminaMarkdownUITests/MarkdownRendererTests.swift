import XCTest
@testable import LuminaMarkdownUI

final class MarkdownRendererTests: XCTestCase {
    func testParserKeepsCommonMarkdownBlocks() {
        let markdown = """
        # 标题

        一段包含 **加粗**、`code` 和 [链接](https://example.com) 的文本。

        > 引用内容

        - [x] 已完成
        - [ ] 待处理

        3. 第三项
        4. 第四项

        ```swift
        let value = 42
        ```

        | 来源 | 置信度 |
        | --- | ---: |
        | Calendar | high |

        ---

        <aside>raw html</aside>
        """

        let document = MarkdownASTParser().parse(markdown)

        XCTAssertTrue(document.blocks.contains { block in
            guard case let .heading(_, level, text) = block else { return false }
            return level == 1 && text == "标题"
        })
        XCTAssertTrue(document.blocks.contains { block in
            guard case let .list(_, .unordered, _, items) = block else { return false }
            return items.map(\.taskState) == [.checked, .unchecked]
        })
        XCTAssertTrue(document.blocks.contains { block in
            guard case let .list(_, .ordered, startIndex, items) = block else { return false }
            return startIndex == 3 && items.count == 2
        })
        XCTAssertTrue(document.blocks.contains { block in
            guard case let .codeBlock(_, language, code) = block else { return false }
            return language == "swift" && code.contains("let value")
        })
        XCTAssertTrue(document.blocks.contains { block in
            guard case let .table(_, table) = block else { return false }
            return table.header == ["来源", "置信度"] && table.rows == [["Calendar", "high"]] && table.alignments.last == .right
        })
        XCTAssertTrue(document.blocks.contains { block in
            guard case .thematicBreak = block else { return false }
            return true
        })
        XCTAssertTrue(document.blocks.contains { block in
            guard case let .htmlBlock(_, rawHTML) = block else { return false }
            return rawHTML.contains("aside")
        })
    }
}
