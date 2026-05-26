import LuminaModelRuntime
import XCTest

final class MiniMindOModelBundleInfoTests: XCTestCase {
    func testMiniMindOBundleInfoValidatesTwelveThousandContext() throws {
        let directory = try makeBundle(contextLength: 12_000)

        let info = try LuminaMiniMindOModelBundleInfo.inspect(
            directory: directory,
            expectedContextLength: 12_000
        )

        XCTAssertEqual(info.architecture, "minimind-o")
        XCTAssertEqual(info.contextLength, 12_000)
        XCTAssertEqual(info.hiddenSize, 768)
        XCTAssertEqual(info.numHiddenLayers, 8)
        XCTAssertEqual(info.maximumSupportedOutputTokens(inputTokenCount: 2_000, safetyMargin: 256, configurationCap: 2_048), 2_048)
    }

    func testMiniMindOBundleInfoRejectsWrongContext() throws {
        let directory = try makeBundle(contextLength: 32_768)

        XCTAssertThrowsError(try LuminaMiniMindOModelBundleInfo.inspect(
            directory: directory,
            expectedContextLength: 12_000
        ))
    }

    func testMiniMindOBundleInfoRejectsMissingCoreMLArtifact() throws {
        let directory = try makeBundle(contextLength: 12_000, includeModel: false)

        XCTAssertThrowsError(try LuminaMiniMindOModelBundleInfo.inspect(
            directory: directory,
            expectedContextLength: 12_000
        ))
    }

    private func makeBundle(contextLength: Int, includeModel: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiniMindOModelBundleInfoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("hf_model"), withIntermediateDirectories: true)
        if includeModel {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("model.mlmodelc"), withIntermediateDirectories: true)
        }
        let config: [String: Any] = [
            "architecture": "minimind-o",
            "context_length": contextLength,
            "hidden_size": 768,
            "num_hidden_layers": 8,
            "vocab_size": 6_400
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("model_config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("hf_model/tokenizer.json"))
        return directory
    }
}
