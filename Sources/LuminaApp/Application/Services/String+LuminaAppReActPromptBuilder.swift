import LuminaAgentClient
import Foundation

extension String {
    func truncated(to limit: Int) -> String {
        guard count > limit else { return self }
        let end = index(startIndex, offsetBy: max(0, limit - 1))
        return String(self[..<end]) + "..."
    }
}

extension Dictionary where Key == String, Value == LuminaJSONValue {
    var compactModelTraceValue: String {
        guard !isEmpty else { return "{}" }
        let pairs = sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.compactModelTraceValue)"
        }
        return "{\(pairs.joined(separator: ","))}"
    }
}

extension LuminaJSONValue {
    var compactModelTraceValue: String {
        switch self {
        case let .string(value):
            return "\"\(value.truncated(to: 80))\""
        case let .number(value):
            return "\(value)"
        case let .bool(value):
            return value ? "true" : "false"
        case let .object(value):
            return value.compactModelTraceValue
        case let .array(values):
            return "[\(values.prefix(4).map(\.compactModelTraceValue).joined(separator: ","))\(values.count > 4 ? ",..." : "")]"
        case .null:
            return "null"
        }
    }
}
