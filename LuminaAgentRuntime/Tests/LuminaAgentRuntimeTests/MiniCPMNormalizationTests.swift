import XCTest
@testable import LuminaAgentRuntimeApple

final class MiniCPMNormalizationTests: XCTestCase {
    func testPrefilledThinkingContinuationDoesNotLeakIntoFinalAnswer() throws {
        // Reproduces the on-device reminder completion: the opening token was in the generation prefix.
        let reasoning = "The reminder for \"吃早餐提醒\" has been successfully created for tomorrow at 8:00 AM. Goal achieved."
        let answer = "完成，明天早上八点提醒我吃早餐已设置。"
        let step = try normalize("\(reasoning)\n</think>\n\n\(answer)")

        XCTAssertEqual(step["type"] as? String, "result")
        XCTAssertEqual(step["thinking"] as? String, reasoning)
        XCTAssertEqual(step["content"] as? String, answer)
        XCTAssertEqual(step["completed"] as? Bool, true)
    }

    func testPrefilledThinkingContinuationKeepsToolCallAndItsArguments() throws {
        let step = try normalize("""
        Read the current time before creating the reminder.
        </think>
        <tool_call><function=device.current_time></function></tool_call>
        """)

        XCTAssertEqual(step["type"] as? String, "tool_use")
        XCTAssertEqual(step["thinking"] as? String, "Read the current time before creating the reminder.")
        XCTAssertEqual(step["tool_name"] as? String, "device.current_time")
        XCTAssertEqual((step["parameters"] as? [String: Any])?.count, 0)
        XCTAssertNil(step["content"])
    }

    func testContinuationWithOnlyReasoningRequiresFollowup() throws {
        let reasoning = "The requested time needs adjustment based on device time."
        let step = try normalize("\(reasoning)\n</think>")

        XCTAssertEqual(step["type"] as? String, "reasoning")
        XCTAssertEqual(step["thinking"] as? String, reasoning)
        XCTAssertEqual(step["requires_followup"] as? Bool, true)
        XCTAssertNil(step["content"])
    }

    func testStandaloneClosingTagAcceptsCRLFAndTransportWhitespace() throws {
        let step = try normalize("Reasoning.\r\n  </think>  \r\n\r\nActual answer.<|im_end|>")

        XCTAssertEqual(step["thinking"] as? String, "Reasoning.")
        XCTAssertEqual(step["content"] as? String, "Actual answer.")
    }

    func testInlineClosingTagExamplesRemainOrdinaryMarkdown() throws {
        for answer in [
            "Use `</think>` to end the block.",
            "The literal tag </think> is part of this example.",
            "The literal tag is \"</think>\".",
            "Escape the marker as &lt;/think&gt;."
        ] {
            XCTAssertEqual(try normalize(answer)["content"] as? String, answer)
        }
    }

    func testFencedClosingTagExamplesRemainOrdinaryMarkdown() throws {
        for fence in ["```", "~~~~"] {
            let answer = "Example:\n\(fence)xml\n</think>\n\(fence)\nThis is a literal tag."
            let step = try normalize(answer)

            XCTAssertEqual(step["type"] as? String, "result")
            XCTAssertEqual(step["content"] as? String, answer)
            XCTAssertEqual(step["thinking"] as? String, "final answer")
        }
    }

    func testIndentedCodeClosingTagRemainsOrdinaryMarkdown() throws {
        let answer = "Example:\n\n    </think>\n\nLiteral indented code."
        XCTAssertEqual(try normalize(answer)["content"] as? String, answer)
    }

    func testClosingTagInsideFenceDoesNotMaskActualTransportEndAfterFence() throws {
        let reasoning = "Check the literal marker:\n```xml\n</think>\n```\nThe operation succeeded."
        let step = try normalize("\(reasoning)\n</think>\n完成。")

        XCTAssertEqual(step["thinking"] as? String, reasoning)
        XCTAssertEqual(step["content"] as? String, "完成。")
    }

    func testCompleteThinkBlockContinuesToNormalize() throws {
        let step = try normalize("<think>Validated the observation.</think>完成。")

        XCTAssertEqual(step["thinking"] as? String, "Validated the observation.")
        XCTAssertEqual(step["content"] as? String, "完成。")
    }

    func testTrustedCanonicalAdapterDoesNotStripLiteralClosingTags() throws {
        let answer = "An example:\n</think>\nThis remains literal provider content."
        let json = try JSONSerialization.data(withJSONObject: ["type": "result", "content": answer])
        let normalized = try XCTUnwrap(LuminaReActTransport.validateCanonicalRuntimeStep(from: String(decoding: json, as: UTF8.self)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(normalized.utf8)) as? [String: Any])

        XCTAssertEqual(object["content"] as? String, answer)
    }

    private func normalize(_ text: String, file: StaticString = #filePath,
                           line: UInt = #line) throws -> [String: Any] {
        let normalized = try XCTUnwrap(LuminaReActTransport.normalizeMiniCPMV46ToolCalls(from: text), file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(normalized.utf8)) as? [String: Any], file: file, line: line)
    }
}
