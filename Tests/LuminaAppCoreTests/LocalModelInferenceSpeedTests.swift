import LuminaAgentClient
import Foundation
import LuminaModelRuntime
import XCTest

#if canImport(CoreML)
import CoreML
#endif

final class LocalModelInferenceSpeedTests: XCTestCase {
    func testBGEEmbeddingInferenceSpeedSmoke() async throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_MODEL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_MODEL_BENCHMARKS=1 to run local model speed smoke tests.")
        }
        #if canImport(CoreML)
        let modelURL = Self.embeddingModelURL()
        let tokenizerURL = Self.embeddingTokenizerURL(modelURL: modelURL)
        let provider = try LuminaBGECoreMLEmbeddingProvider(configuration: .init(
            modelURL: modelURL,
            tokenizerURL: tokenizerURL,
            computeUnits: Self.modelComputeUnits
        ))

        _ = try await provider.embed("本地端侧记忆检索预热")
        var elapsed: [Double] = []
        for text in ["今天的会议摘要", "帮我检索本地记忆", "端侧 RAG embedding benchmark"] {
            let start = ContinuousClock.now
            let vector = try await provider.embed(text)
            elapsed.append(Self.milliseconds(since: start))
            XCTAssertEqual(vector.count, 512)
        }

        let average = elapsed.reduce(0, +) / Double(elapsed.count)
        print("[Lumina][ModelSpeed] BGE embedding computeUnits=\(Self.computeUnitsLabel(Self.modelComputeUnits)) avgMs=\(String(format: "%.1f", average)) samples=\(elapsed.map { String(format: "%.1f", $0) })")
        XCTAssertLessThan(average, Self.strictPerformance ? 500 : 5_000)
        #else
        throw XCTSkip("CoreML is unavailable on this platform.")
        #endif
    }

    func testMiniCPMV46InferenceSpeedSmoke() async throws {
        guard ProcessInfo.processInfo.environment["LUMINA_RUN_MODEL_BENCHMARKS"] == "1" else {
            throw XCTSkip("Set LUMINA_RUN_MODEL_BENCHMARKS=1 to run local model speed smoke tests.")
        }
        let metricsBox = ModelMetricsBox()
        let model = try LuminaMiniCPMV46ReActModel(configuration: .init(
            modelDirectory: Self.miniCPMV46ModelURL(),
            backendPreference: Self.miniCPMV46BackendPreference,
            maxNewTokens: 96,
            expectedContextLength: 16_000,
            outputSafetyMarginTokens: 256,
            metricsRecorder: { metrics in
                metricsBox.record(metrics)
            }
        ))

        do {
            _ = try await model.generateJSON(
                prompt: Self.miniCPMV46SpeedPrompt,
                maxOutputTokens: 96
            )
        } catch LuminaMiniCPMV46ReActModelError.engineUnavailable(let message) {
            let metrics = try XCTUnwrap(metricsBox.latest, "MiniCPM-V 4.6 native engine should emit metadata before reporting unavailability.")
            print("[Lumina][ModelSpeed] MiniCPM-V 4.6 native engine unavailable: \(message); metadata=\(metrics)")
            throw XCTSkip("MiniCPM-V 4.6 native engine is not linked in this build.")
        } catch {
            let metrics = try XCTUnwrap(metricsBox.latest, "MiniCPM-V 4.6 should emit inference metrics even if schema validation rejects model text.")
            print("[Lumina][ModelSpeed] MiniCPM-V 4.6 schema smoke ended with \(type(of: error)); metrics remain valid for speed: \(metrics)")
        }

        let metrics = try XCTUnwrap(metricsBox.latest)
        print("[Lumina][ModelSpeed] MiniCPM-V 4.6 computeUnits=\(metrics.computeUnits) promptTokens=\(metrics.promptTokens) outputTokens=\(metrics.outputTokens) ttftMs=\(metrics.timeToFirstTokenMilliseconds ?? -1) tokPerSec=\(String(format: "%.2f", metrics.tokensPerSecond)) totalMs=\(String(format: "%.1f", metrics.totalMilliseconds))")
        XCTAssertEqual(metrics.contextLength, 16_000)
        XCTAssertGreaterThan(metrics.promptTokens, 0)
        XCTAssertGreaterThan(metrics.totalMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(metrics.outputTokens, 0)
    }

    #if canImport(CoreML)
    private static var modelComputeUnits: MLComputeUnits {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return .cpuAndGPU
        #else
        return .cpuAndNeuralEngine
        #endif
    }

    private static func computeUnitsLabel(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "CPU"
        case .cpuAndGPU: return "CPU+GPU/MPS"
        case .cpuAndNeuralEngine: return "CPU+ANE"
        case .all: return "CPU+GPU/MPS+ANE"
        @unknown default: return String(describing: units)
        }
    }
    #endif

    private static var miniCPMV46SpeedPrompt: String {
        """
        You are Lumina. Output exactly one standard ReAct JSON object.
        \(LuminaReActSchema.promptContract)

        User request: 现在几点？

        Available tools:
        - device.current_time: read the current local device time. parameters={}

        Return the next JSON object now. If a tool is needed, use tool_use.
        """
    }

    private static func embeddingModelURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["LUMINA_EMBEDDING_MODEL"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return repositoryRoot()
            .appendingPathComponent("Resources/Models/BGETextEmbedding.mlmodelc")
    }

    private static func embeddingTokenizerURL(modelURL: URL) -> URL {
        if let path = ProcessInfo.processInfo.environment["LUMINA_EMBEDDING_TOKENIZER"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return modelURL
            .deletingLastPathComponent()
            .appendingPathComponent("BGETextEmbedding-tokenizer.json")
    }

    private static func miniCPMV46ModelURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["LUMINA_MINICPMV46_MODEL"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return repositoryRoot()
            .appendingPathComponent("Resources/Models/MiniCPMV46ReActModel")
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var miniCPMV46BackendPreference: LuminaMiniCPMV46BackendPreference {
        switch ProcessInfo.processInfo.environment["LUMINA_MINICPMV46_BACKEND"]?.lowercased() {
        case "ane":
            return .ane
        case "mps", "metal", "gpu":
            return .mps
        default:
            return .automatic
        }
    }

    private static var strictPerformance: Bool {
        ProcessInfo.processInfo.environment["LUMINA_STRICT_PERF"] == "1"
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}

private final class ModelMetricsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LuminaModelInferenceMetrics?

    var latest: LuminaModelInferenceMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ metrics: LuminaModelInferenceMetrics) {
        lock.lock()
        stored = metrics
        lock.unlock()
    }
}
