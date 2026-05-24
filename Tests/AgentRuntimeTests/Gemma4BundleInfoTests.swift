import Foundation
import LuminaModelRuntime
import XCTest

final class Gemma4BundleInfoTests: XCTestCase {
    func testGemma4BundleInfoValidatesTwelveThousandContextAndOutputBudget() throws {
        let directory = try makeBundle(contextLength: 12_000, ropeLength: 12_000)

        let info = try LuminaGemma4StatefulBundleInfo.inspect(
            directory: directory,
            expectedContextLength: 12_000
        )

        XCTAssertEqual(info.contextLength, 12_000)
        XCTAssertEqual(
            info.maximumSupportedOutputTokens(
                inputTokenCount: 2_000,
                safetyMargin: 256,
                configurationCap: .max
            ),
            9_744
        )
    }

    func testGemma4BundleInfoRejectsOldCoreMLContextShape() throws {
        let directory = try makeBundle(contextLength: 12_000, metadataContextLength: 2_048, ropeLength: 12_000)

        XCTAssertThrowsError(try LuminaGemma4StatefulBundleInfo.inspect(
            directory: directory,
            expectedContextLength: 12_000
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not match"))
            XCTAssertTrue(error.localizedDescription.contains("2048"))
        }
    }

    func testGemma4BundleInfoRejectsShortRopeTables() throws {
        let directory = try makeBundle(contextLength: 12_000, ropeLength: 8_192)

        XCTAssertThrowsError(try LuminaGemma4StatefulBundleInfo.inspect(
            directory: directory,
            expectedContextLength: 12_000
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("RoPE"))
            XCTAssertTrue(error.localizedDescription.contains("8192"))
        }
    }

    private func makeBundle(
        contextLength: Int,
        metadataContextLength: Int? = nil,
        ropeLength: Int
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumina-gemma4-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let config: [String: Any] = [
            "model_name": "gemma4-e2b-swa-ple",
            "architecture": "gemma4",
            "context_length": contextLength,
            "sliding_window": 512
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try configData.write(to: directory.appendingPathComponent("model_config.json"))

        let metadataContextLength = metadataContextLength ?? contextLength
        for chunk in 1...3 {
            let chunkDirectory = directory.appendingPathComponent("chunk_\(chunk).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
            let metadata = [
                [
                    "inputSchema": [
                        [
                            "name": "causal_mask_full",
                            "shape": "[1, 1, 1, \(metadataContextLength)]",
                            "dataType": "Float16"
                        ]
                    ],
                    "stateSchema": [
                        [
                            "name": "kv_cache_full",
                            "shape": "[2, 1, \(metadataContextLength), 512]",
                            "dataType": "Float16"
                        ]
                    ],
                    "functions": [
                        [
                            "name": "prefill_b8",
                            "inputSchema": [
                                [
                                    "name": "causal_mask_full",
                                    "shape": "[1, 1, 8, \(metadataContextLength)]",
                                    "dataType": "Float16"
                                ]
                            ],
                            "outputSchema": [
                                [
                                    "name": "kv14_k",
                                    "shape": "[1, 1, \(metadataContextLength), 512]",
                                    "dataType": "Float16"
                                ]
                            ],
                            "stateSchema": []
                        ]
                    ]
                ]
            ] as [[String: Any]]
            let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
            try metadataData.write(to: chunkDirectory.appendingPathComponent("metadata.json"))
        }

        for name in ["cos_full.npy", "sin_full.npy", "cos_sliding.npy", "sin_sliding.npy"] {
            try makeNpyHeader(firstDimension: ropeLength).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    private func makeNpyHeader(firstDimension: Int) -> Data {
        let magic = Data([0x93]) + Data("NUMPY".utf8)
        let version = Data([0x01, 0x00])
        var header = "{'descr': '<f2', 'fortran_order': False, 'shape': (\(firstDimension), 512), }"
        while (magic.count + version.count + 2 + header.utf8.count + 1) % 16 != 0 {
            header.append(" ")
        }
        header.append("\n")
        var length = UInt16(header.utf8.count).littleEndian
        let lengthData = Data(bytes: &length, count: MemoryLayout<UInt16>.size)
        return magic + version + lengthData + Data(header.utf8)
    }
}
