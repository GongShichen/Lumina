import LuminaModelRuntime
import XCTest

final class MiniCPMV46ModelBundleInfoTests: XCTestCase {
    func testMiniCPMV46BundleInfoValidatesSixteenThousandContext() throws {
        let directory = try makeBundle(contextLength: 16_000)

        let info = try LuminaMiniCPMV46ModelBundleInfo.inspect(
            directory: directory,
            expectedContextLength: 16_000
        )

        XCTAssertEqual(info.architecture, "minicpm-v-4_6")
        XCTAssertEqual(info.contextLength, 16_000)
        XCTAssertEqual(info.quantization, "F16")
        XCTAssertEqual(info.modelURL.lastPathComponent, "model.gguf")
        XCTAssertEqual(info.projectorURL?.lastPathComponent, "mmproj-model-f16.gguf")
        XCTAssertEqual(info.maximumSupportedOutputTokens(inputTokenCount: 2_000, safetyMargin: 256, configurationCap: 2_048), 2_048)
    }

    func testMiniCPMV46BundleInfoRejectsWrongContext() throws {
        let directory = try makeBundle(contextLength: 32_768)

        XCTAssertThrowsError(try LuminaMiniCPMV46ModelBundleInfo.inspect(
            directory: directory,
            expectedContextLength: 16_000
        ))
    }

    func testMiniCPMV46BundleInfoRejectsMissingGGUFArtifact() throws {
        let directory = try makeBundle(contextLength: 16_000, includeModel: false)

        XCTAssertThrowsError(try LuminaMiniCPMV46ModelBundleInfo.inspect(
            directory: directory,
            expectedContextLength: 16_000
        ))
    }

    func testMiniCPMV46NativeCapabilitiesExposeKVCacheAndOperatorPlan() throws {
        let json = try XCTUnwrap(LuminaMiniCPMV46ReActModel.nativeCapabilitiesJSON())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["engine"] as? String, "LuminaModelRuntimeCore")
        XCTAssertEqual(object["model"] as? String, "MiniCPM-V 4.6")
        XCTAssertEqual(object["contextLength"] as? Int, 16_000)
        XCTAssertGreaterThan(object["kvCacheBytes"] as? Int ?? 0, 0)
        XCTAssertNotNil(object["mpsReady"] as? Bool)
        XCTAssertNotNil(object["aneReady"] as? Bool)
        let optimizations = try XCTUnwrap(object["optimizations"] as? [String])
        XCTAssertTrue(optimizations.contains("miniCPM-v-specific-kv-cache-shape"))
        XCTAssertTrue(optimizations.contains("paged-kv-cache-plan"))
        XCTAssertTrue(optimizations.contains("fused-rmsnorm-plan"))
        XCTAssertTrue(optimizations.contains("fused-rotary-embedding-plan"))
        XCTAssertTrue(optimizations.contains("fused-qkv-gemm-plan"))
    }

    func testMiniCPMV46ModelUsesNativeEngineBoundaryInsteadOfExternalProcess() async throws {
        let directory = try makeBundle(contextLength: 16_000)
        let metricsBox = MiniCPMV46MetricsBox()
        let model = try LuminaMiniCPMV46ReActModel(configuration: .init(
            modelDirectory: directory,
            maxNewTokens: 64,
            expectedContextLength: 16_000,
            metricsRecorder: { metrics in
                Task { await metricsBox.record(metrics) }
            }
        ))

        do {
            _ = try await model.generateJSON(
                prompt: """
                You are Lumina. Return {"type":"result","answer":"ok"}.
                """
            )
            XCTFail("The synthetic GGUF test bundle should fail inside the native MiniCPM-V engine.")
        } catch LuminaMiniCPMV46ReActModelError.engineUnavailable(let message) {
            XCTAssertFalse(message.contains("external process"))
        }

        let metrics = await metricsBox.latestMetrics()
        XCTAssertEqual(metrics?.modelName, "MiniCPM-V 4.6")
        XCTAssertEqual(metrics?.contextLength, 16_000)
        XCTAssertGreaterThan(metrics?.promptTokens ?? 0, 0)
    }

    private func makeBundle(contextLength: Int, includeModel: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniCPMV46ModelBundleInfoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if includeModel {
            try Data("gguf".utf8).write(to: directory.appendingPathComponent("model.gguf"))
            try Data("mmproj".utf8).write(to: directory.appendingPathComponent("mmproj-model-f16.gguf"))
        }
        let config: [String: Any] = [
            "architecture": "minicpm-v-4_6",
            "context_length": contextLength,
            "quantization": "F16",
            "text_model": "model.gguf",
            "vision_projector": "mmproj-model-f16.gguf",
            "source_repo": "openbmb/MiniCPM-V-4_6-gguf"
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("model_config.json"))
        return directory
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
