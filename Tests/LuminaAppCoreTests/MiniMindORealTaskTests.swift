import AgentRuntime
import CoreML
import LuminaModelRuntime
import XCTest

@available(iOS 18.0, macOS 15.0, *)
final class MiniMindORealTaskTests: XCTestCase {
    func testOptionalMiniMindOPlannerBundleLoadsAndStreams() async throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_MODEL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_MODEL_BENCHMARKS=1 to run real MiniMind-o Core ML smoke test.")
        }
        guard let path = ProcessInfo.processInfo.environment["LUMINA_MINIMINDO_MODEL"], !path.isEmpty else {
            throw XCTSkip("Set LUMINA_MINIMINDO_MODEL to Resources/Models/MiniMindOReActModel.")
        }

        let metricsBox = MiniMindOMetricsBox()
        let model = try LuminaMiniMindOReActModel(configuration: .init(
            modelDirectory: URL(fileURLWithPath: path),
            computeUnits: .cpuAndGPU,
            maxNewTokens: 96,
            expectedContextLength: 12_000,
            metricsRecorder: { metrics in
                Task { await metricsBox.record(metrics) }
            }
        ))

        do {
            _ = try await model.generateJSON(
                prompt: """
                你是 Lumina 的 ReAct agent。只输出一个 JSON 对象：
                {"type":"tool_use","tool_name":"device.current_time","parameters":{}}
                """
            )
        } catch {
            // The smoke is about loading the converted bundle and exercising
            // the streaming decode path. Schema quality belongs to SFT/DPO.
            print("[Lumina][MiniMindO] schema smoke ended with \(type(of: error)): \(error.localizedDescription)")
        }

        let latestMetrics = await metricsBox.latestMetrics()
        let metrics = try XCTUnwrap(latestMetrics)
        XCTAssertEqual(metrics.contextLength, 12_000)
        XCTAssertGreaterThan(metrics.outputTokens, 0)
        print("[Lumina][MiniMindO] computeUnits=\(metrics.computeUnits) promptTokens=\(metrics.promptTokens) outputTokens=\(metrics.outputTokens) ttftMs=\(metrics.timeToFirstTokenMilliseconds ?? -1) tokPerSec=\(String(format: "%.2f", metrics.tokensPerSecond)) totalMs=\(String(format: "%.1f", metrics.totalMilliseconds))")
    }
}

private actor MiniMindOMetricsBox {
    private var latest: LuminaModelInferenceMetrics?

    func record(_ metrics: LuminaModelInferenceMetrics) {
        latest = metrics
    }

    func latestMetrics() -> LuminaModelInferenceMetrics? {
        latest
    }
}
