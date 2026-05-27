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
                你是 Lumina 的 ReAct agent。只输出一个 JSON 对象：
                {"type":"tool_use","tool_name":"device.current_time","parameters":{}}
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
