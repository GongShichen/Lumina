import Foundation

actor LuminaBenchmarkTraceLogger {
    private let url: URL
    private let encoder = JSONEncoder()
    private var sequence = 0

    init(reportDirectory: URL, timestamp: Int = Int(Date().timeIntervalSince1970)) {
        self.url = reportDirectory.appendingPathComponent("LuminaBenchmarkTrace-\(timestamp).jsonl")
        encoder.outputFormatting = [.sortedKeys]
    }

    var fileURL: URL {
        url
    }

    func record(_ event: String, fields: [String: String] = [:]) async {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            sequence += 1
            var payload = fields
            payload["event"] = event
            payload["sequence"] = "\(sequence)"
            payload["pid"] = "\(ProcessInfo.processInfo.processIdentifier)"
            payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
            let data = try encoder.encode(payload)
            let line = data + Data([0x0A])
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            #if DEBUG
            print("[Lumina][BenchmarkTrace] failed to write \(event): \(error.localizedDescription)")
            #endif
        }
    }
}
