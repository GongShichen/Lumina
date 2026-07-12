import Foundation

enum LuminaLocalModelSelection: String, CaseIterable, Identifiable, Sendable {
    case original
    case agenticDPO

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:
            "原始 MiniCPM-V 4.6"
        case .agenticDPO:
            "Agentic DPO 微调模型"
        }
    }

    var shortLabel: String {
        switch self {
        case .original:
            "原始"
        case .agenticDPO:
            "微调"
        }
    }

    var bundleDirectoryName: String {
        switch self {
        case .original:
            "MiniCPMV46ReActModel"
        case .agenticDPO:
            "MiniCPMV46ReActModel-AgenticSFTDPO-Q8"
        }
    }

    var modelEnvironmentKeys: [String] {
        switch self {
        case .original:
            ["LUMINA_MINICPMV46_ORIGINAL_MODEL", "LUMINA_MINICPMV46_MODEL"]
        case .agenticDPO:
            ["LUMINA_MINICPMV46_AGENTIC_DPO_MODEL"]
        }
    }

    var modelBundleCandidates: [String] {
        switch self {
        case .original:
            ["MiniCPMV46ReActModel", "MiniCPMV46Model"]
        case .agenticDPO:
            ["MiniCPMV46ReActModel-AgenticSFTDPO-Q8", "MiniCPMV46AgenticDPOReActModel", "MiniCPMV46AgenticDPOModel"]
        }
    }

    func resolvedMiniCPMV46ModelURL(sourceFilePath: StaticString = #filePath) -> URL? {
        for key in modelEnvironmentKeys {
            guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { continue }
            let url = URL(fileURLWithPath: value).standardizedFileURL
            if Self.directoryExists(url) {
                return url
            }
        }

        for candidate in modelBundleCandidates {
            if let url = Bundle.main.url(forResource: candidate, withExtension: nil, subdirectory: "Models"),
               Self.directoryExists(url) {
                return url.standardizedFileURL
            }
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Models/\(candidate)", isDirectory: true),
               Self.directoryExists(url) {
                return url.standardizedFileURL
            }
            if let url = Bundle.main.resourceURL?.appendingPathComponent(candidate, isDirectory: true),
               Self.directoryExists(url) {
                return url.standardizedFileURL
            }
        }

        #if DEBUG
        for root in Self.developmentRepositoryRoots(sourceFilePath: "\(sourceFilePath)") {
            let bundleParent = self == .original ? "original" : "trained"
            let preferred = root
                .appendingPathComponent("model/bundles/\(bundleParent)", isDirectory: true)
                .appendingPathComponent(bundleDirectoryName, isDirectory: true)
            if Self.directoryExists(preferred) {
                return preferred.standardizedFileURL
            }
            for candidate in modelBundleCandidates {
                let url = root
                    .appendingPathComponent("model/bundles/\(bundleParent)", isDirectory: true)
                    .appendingPathComponent(candidate, isDirectory: true)
                if Self.directoryExists(url) {
                    return url.standardizedFileURL
                }
            }
        }
        #endif

        return nil
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    #if DEBUG
    private static func developmentRepositoryRoots(sourceFilePath: String) -> [URL] {
        var seeds: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            Bundle.main.bundleURL,
            Bundle.main.resourceURL ?? Bundle.main.bundleURL,
            URL(fileURLWithPath: sourceFilePath).deletingLastPathComponent()
        ]

        let executableURL = Bundle.main.executableURL ?? Bundle.main.bundleURL
        seeds.append(executableURL.deletingLastPathComponent())

        var roots: [URL] = []
        var seen = Set<String>()
        for seed in seeds {
            var current = seed.standardizedFileURL
            while current.path != "/" {
                let marker = current.appendingPathComponent("model/bundles", isDirectory: true)
                if directoryExists(marker), seen.insert(current.path).inserted {
                    roots.append(current)
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return roots
    }
    #endif
}
