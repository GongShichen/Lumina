import AgentRuntime
import Foundation
import LuminaAppCore
import LuminaModelRuntime
import XCTest

#if canImport(CoreML)
import CoreML
#endif

final class Gemma4RealTaskTests: XCTestCase {
    func testOptionalGemma4ReActCurrentTimeTaskUsesRealModelAndTool() async throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_MODEL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_MODEL_BENCHMARKS=1 to run real Gemma4 ReAct task.")
        }
        guard let path = ProcessInfo.processInfo.environment["LUMINA_GEMMA4_STATEFUL_MODEL"], !path.isEmpty else {
            throw XCTSkip("Set LUMINA_GEMMA4_STATEFUL_MODEL to Resources/Models/Gemma4Planner.")
        }

        #if canImport(CoreML)
        let model = try LuminaGemma4StatefulPlannerModel(configuration: .init(
            modelDirectory: URL(fileURLWithPath: path),
            computeUnits: .cpuAndNeuralEngine,
            maxNewTokens: 512,
            expectedContextLength: 12_000,
            outputSafetyMarginTokens: 256
        ))
        let planner = LuminaModelBackedReActPlanner(model: model) { context in
            try Self.prompt(context: context)
        }
        let timeTool = LuminaCurrentTimeTool()
        let runtime = LuminaAgentRuntime(
            tools: [AnyLuminaAgentTool(timeTool)],
            reactPlanner: planner,
            configuration: LuminaAgentRuntimeConfiguration(
                maximumToolCalls: 2,
                maximumReActIterations: 4,
                contextWindowCharacterBudget: 48_000
            )
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "现在几点？请读取本机时间后回答。"))

        XCTAssertTrue(result.toolResults.contains { $0.toolName == "device.current_time" })
        XCTAssertTrue(result.plan.summary.contains("本机时间") || result.plan.summary.contains("时间"))
        XCTAssertNotEqual(result.status.rawValue, LuminaAgentRunStatus.failed.rawValue)
        #else
        throw XCTSkip("CoreML is unavailable on this platform.")
        #endif
    }

    private static func prompt(context: LuminaReActPlannerContext) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let traceJSON = String(decoding: try encoder.encode(context.trace.steps), as: UTF8.self)
        let tools = context.availableTools.map { schema in
            "- \(schema.name): \(schema.description), sideEffect=\(schema.sideEffect.rawValue), input={}"
        }.joined(separator: "\n")

        return """
        You are Lumina, a local-first iOS assistant. Complete the user's task using ReAct.
        Output exactly one JSON object. Do not output markdown fences or prose outside JSON.
        \(LuminaReActSchema.promptContract)

        Rules:
        - If the user asks the current time, you must call device.current_time before final_answer.
        - Correct tool call: {"type":"tool_use","thought":"Need current device time.","tool_name":"device.current_time","parameters":{},"requires_confirmation":false}
        - After device.current_time succeeds, answer from the observation.
        - Use only listed tools.
        - Never claim tool success before the observation.

        User request: \(context.request.text)

        Tools:
        \(tools)

        Recent ReAct steps:
        \(traceJSON.isEmpty ? "none" : traceJSON)

        Return the next JSON object now.
        """
    }
}
