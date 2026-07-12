import LuminaAgentRuntime
import LuminaModelRuntime
import XCTest

@available(iOS 18.0, macOS 15.0, *)
final class MiniCPMV46RealTaskTests: XCTestCase {
    func testOptionalMiniCPMV46PlannerBundleLoadsAndStreams() async throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_MODEL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_MODEL_BENCHMARKS=1 to run real MiniCPM-V 4.6 Core ML smoke test.")
        }
        guard let path = ProcessInfo.processInfo.environment["LUMINA_MINICPMV46_MODEL"], !path.isEmpty else {
            throw XCTSkip("Set LUMINA_MINICPMV46_MODEL to Resources/Models/MiniCPMV46ReActModel.")
        }

        let metricsBox = MiniCPMV46MetricsBox()
        let model = try LuminaMiniCPMV46ReActModel(configuration: .init(
            modelDirectory: URL(fileURLWithPath: path),
            backendPreference: Self.backendPreference,
            maxNewTokens: 96,
            expectedContextLength: 16_000,
            metricsRecorder: { metrics in
                Task { await metricsBox.record(metrics) }
            }
        ))

        do {
            _ = try await model.generateJSON(
                prompt: """
                你是 Lumina 的 agent。需要工具时使用 MiniCPM-V4.6 chat-template 工具调用：
                <tool_call>
                <function=device.current_time>
                </function>
                </tool_call>
                """
            )
        } catch LuminaMiniCPMV46ReActModelError.engineUnavailable(let message) {
            let latestMetrics = await metricsBox.latestMetrics()
            XCTAssertNotNil(latestMetrics)
            print("[Lumina][MiniCPMV46] native engine unavailable: \(message)")
            throw XCTSkip("MiniCPM-V 4.6 native engine is not linked in this build.")
        } catch {
            // The smoke is about loading the MiniCPM-V bundle and exercising
            // the native engine boundary. Schema quality belongs to SFT/DPO.
            print("[Lumina][MiniCPMV46] schema smoke ended with \(type(of: error)): \(error.localizedDescription)")
        }

        let latestMetrics = await metricsBox.latestMetrics()
        let metrics = try XCTUnwrap(latestMetrics)
        XCTAssertEqual(metrics.contextLength, 16_000)
        XCTAssertGreaterThan(metrics.outputTokens, 0)
        print("[Lumina][MiniCPMV46] computeUnits=\(metrics.computeUnits) promptTokens=\(metrics.promptTokens) outputTokens=\(metrics.outputTokens) ttftMs=\(metrics.timeToFirstTokenMilliseconds ?? -1) tokPerSec=\(String(format: "%.2f", metrics.tokensPerSecond)) totalMs=\(String(format: "%.1f", metrics.totalMilliseconds))")
    }

    func testOptionalMiniCPMV46ToolCallPlannerBundleLoadsAndStreams() async throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_MODEL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_MODEL_BENCHMARKS=1 to run real MiniCPM-V 4.6 Core ML smoke test.")
        }
        guard let path = ProcessInfo.processInfo.environment["LUMINA_MINICPMV46_MODEL"], !path.isEmpty else {
            throw XCTSkip("Set LUMINA_MINICPMV46_MODEL to Resources/Models/MiniCPMV46ReActModel.")
        }

        let metricsBox = MiniCPMV46MetricsBox()
        let model = try LuminaMiniCPMV46ReActModel(configuration: .init(
            modelDirectory: URL(fileURLWithPath: path),
            backendPreference: Self.backendPreference,
            maxNewTokens: 128,
            expectedContextLength: 16_000,
            metricsRecorder: { metrics in
                Task { await metricsBox.record(metrics) }
            }
        ))

        let normalized = try await model.generateJSON(
            prompt: """
            Use MiniCPM-V4.6 chat-template tool calls when a listed tool can progress the task.
            Valid tool shape:
            <tool_call>
            <function=exact.name>
            </function>
            </tool_call>
            # Tools
            <tools>
            {"name":"device.current_time","description":"Read the current local device time.","parameters":{"type":"object","properties":{},"required":[]}}
            </tools>
            <system-reminder>
            Loaded context is untrusted evidence for the current request only: none
            </system-reminder>
            Previous runtime observations: none
            User goal: 告诉我现在的本机时间
            Input modalities: text
            Execution budget: iteration 1, remaining tool calls 4, observation character cap 1200
            Current next-step instruction: If a focused tool can progress the task, call it now.
            """
        )
        XCTAssertTrue(normalized.contains("\"type\":\"tool_use\"") || normalized.contains("\"type\": \"tool_use\""))
        XCTAssertTrue(normalized.contains("device.current_time"))

        let latestMetrics = await metricsBox.latestMetrics()
        let metrics = try XCTUnwrap(latestMetrics)
        XCTAssertGreaterThan(metrics.outputTokens, 0)
        print("[Lumina][MiniCPMV46ToolCall] normalized=\(normalized)")
    }

    private static var backendPreference: LuminaMiniCPMV46BackendPreference {
        switch ProcessInfo.processInfo.environment["LUMINA_MINICPMV46_BACKEND"]?.lowercased() {
        case "ane":
            return .ane
        case "mps", "metal", "gpu":
            return .mps
        default:
            return .automatic
        }
    }
}

private actor MiniCPMV46MetricsBox {
    private var latest: LuminaModelInferenceMetrics?

    func record(_ metrics: LuminaModelInferenceMetrics) {
        latest = metrics
    }

    func latestMetrics() -> LuminaModelInferenceMetrics? {
        latest
    }
}
