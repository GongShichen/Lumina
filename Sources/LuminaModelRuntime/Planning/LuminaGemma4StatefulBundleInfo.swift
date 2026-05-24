import Foundation

public struct LuminaGemma4StatefulBundleInfo: Equatable, Sendable {
    public struct ValidationError: LocalizedError, Equatable {
        public var message: String

        public var errorDescription: String? {
            message
        }
    }

    public var directory: URL
    public var contextLength: Int
    public var metadataContextLengths: [String: Int]
    public var ropeLengths: [String: Int]

    public var shortestRopeLength: Int {
        ropeLengths.values.min() ?? 0
    }

    public func maximumSupportedOutputTokens(
        inputTokenCount: Int,
        safetyMargin: Int,
        configurationCap: Int
    ) -> Int {
        let remaining = max(0, contextLength - inputTokenCount - safetyMargin)
        return min(configurationCap, remaining)
    }

    public static func inspect(
        directory: URL,
        expectedContextLength: Int? = nil
    ) throws -> LuminaGemma4StatefulBundleInfo {
        let configURL = directory.appendingPathComponent("model_config.json")
        let configData = try Data(contentsOf: configURL)
        guard let configObject = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let contextLength = configObject["context_length"] as? Int else {
            throw ValidationError(message: "Gemma4 model_config.json is missing integer context_length.")
        }

        if let expectedContextLength, contextLength != expectedContextLength {
            throw ValidationError(
                message: "Gemma4 context_length is \(contextLength), expected \(expectedContextLength). Rebuild the Core ML bundle instead of editing only app code."
            )
        }

        let metadataLengths = try metadataContextLengths(in: directory)
        let mismatches = metadataLengths.filter { $0.value != contextLength }
        if !mismatches.isEmpty {
            let details = mismatches
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            throw ValidationError(
                message: "Gemma4 Core ML metadata context does not match model_config.json (\(contextLength)): \(details)."
            )
        }

        let ropeLengths = try ropeLengths(in: directory)
        let shortRopes = ropeLengths.filter { $0.value < contextLength }
        if !shortRopes.isEmpty {
            let details = shortRopes
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            throw ValidationError(
                message: "Gemma4 RoPE tables are shorter than context_length \(contextLength): \(details)."
            )
        }

        return LuminaGemma4StatefulBundleInfo(
            directory: directory,
            contextLength: contextLength,
            metadataContextLengths: metadataLengths,
            ropeLengths: ropeLengths
        )
    }

    private static func metadataContextLengths(in directory: URL) throws -> [String: Int] {
        let chunkNames = ["chunk_1.mlmodelc", "chunk_2.mlmodelc", "chunk_3.mlmodelc"]
        var lengths: [String: Int] = [:]

        for chunkName in chunkNames {
            let metadataURL = directory
                .appendingPathComponent(chunkName)
                .appendingPathComponent("metadata.json")
            let data = try Data(contentsOf: metadataURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let metadata = root.first else {
                throw ValidationError(message: "\(chunkName)/metadata.json has an unexpected format.")
            }
            collectContextLengths(from: metadata, prefix: chunkName, into: &lengths)
        }

        return lengths
    }

    private static func collectContextLengths(
        from metadata: [String: Any],
        prefix: String,
        into lengths: inout [String: Int]
    ) {
        for schemaName in ["inputSchema", "outputSchema", "stateSchema"] {
            collectContextLengths(from: metadata[schemaName], prefix: "\(prefix).\(schemaName)", into: &lengths)
        }

        if let functions = metadata["functions"] as? [[String: Any]] {
            for function in functions {
                let functionName = function["name"] as? String ?? "function"
                for schemaName in ["inputSchema", "outputSchema", "stateSchema"] {
                    collectContextLengths(
                        from: function[schemaName],
                        prefix: "\(prefix).\(functionName).\(schemaName)",
                        into: &lengths
                    )
                }
            }
        }
    }

    private static func collectContextLengths(
        from value: Any?,
        prefix: String,
        into lengths: inout [String: Int]
    ) {
        guard let entries = value as? [[String: Any]] else { return }
        for entry in entries {
            guard let name = entry["name"] as? String,
                  let shape = entry["shape"] as? String,
                  let context = contextLength(fromShape: shape, tensorName: name) else {
                continue
            }
            lengths["\(prefix).\(name)"] = context
        }
    }

    private static func contextLength(fromShape shape: String, tensorName: String) -> Int? {
        let numbers = shape
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        if tensorName == "causal_mask_full" {
            return numbers.last
        }
        if tensorName == "kv_cache_full" || tensorName == "kv_cache_unified" {
            return numbers.count >= 3 ? numbers[numbers.count - 2] : nil
        }
        if tensorName == "kv14_k" || tensorName == "kv14_v" {
            return numbers.count >= 3 ? numbers[numbers.count - 2] : nil
        }
        return nil
    }

    private static func ropeLengths(in directory: URL) throws -> [String: Int] {
        let names = ["cos_full.npy", "sin_full.npy", "cos_sliding.npy", "sin_sliding.npy"]
        var lengths: [String: Int] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            lengths[name] = try npyFirstDimension(at: url)
        }
        return lengths
    }

    private static func npyFirstDimension(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard data.count > 10 else {
            throw ValidationError(message: "\(url.lastPathComponent) is not a valid .npy file.")
        }
        let major = data[6]
        let minor = data[7]
        let headerLengthOffset = 8
        let headerLengthByteCount = major == 1 ? 2 : 4
        guard data.count >= headerLengthOffset + headerLengthByteCount else {
            throw ValidationError(message: "\(url.lastPathComponent) has a truncated .npy header.")
        }

        let headerLength: Int
        if major == 1 {
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
        } else {
            headerLength = Int(data[8])
                | (Int(data[9]) << 8)
                | (Int(data[10]) << 16)
                | (Int(data[11]) << 24)
        }
        let headerStart = headerLengthOffset + headerLengthByteCount
        let headerEnd = headerStart + headerLength
        guard headerEnd <= data.count,
              let header = String(data: data[headerStart..<headerEnd], encoding: .ascii) else {
            throw ValidationError(message: "\(url.lastPathComponent) has an unreadable .npy header.")
        }
        guard let shapeRange = header.range(of: #"'shape':"#) ?? header.range(of: #""shape":"#) else {
            throw ValidationError(message: "\(url.lastPathComponent) .npy header is missing shape.")
        }
        let shapeText = header[shapeRange.upperBound...]
        guard let open = shapeText.firstIndex(of: "("),
              let comma = shapeText[open...].firstIndex(of: ",") else {
            throw ValidationError(message: "\(url.lastPathComponent) .npy shape is unsupported for Lumina validation.")
        }
        let firstDimensionText = shapeText[shapeText.index(after: open)..<comma]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstDimension = Int(firstDimensionText), firstDimension > 0 else {
            throw ValidationError(message: "\(url.lastPathComponent) .npy first dimension is invalid.")
        }
        _ = minor
        return firstDimension
    }
}
