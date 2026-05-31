import Foundation
import LuminaAgentRuntimeCore

public enum LuminaReActTransport {
    public static func extractFirstStandardJSONObject(from text: String) -> String? {
        let pointer = text.withCString { LuminaReActExtractFirstStandardObject($0) }
        defer {
            if let pointer { LuminaAgentRuntimeReleaseString(pointer) }
        }
        guard let pointer else { return nil }
        let json = String(cString: pointer)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["ok"] as? Bool) == true,
              let value = (object["value"] as? String) ?? (object["json"] as? String)
        else { return nil }
        return value
    }

    public static func normalizeXMLTags(from text: String) -> String? {
        let pointer = text.withCString { textPointer in
            "xml_tags".withCString { dialectPointer in
                LuminaReActNormalizeStepText(textPointer, dialectPointer)
            }
        }
        defer {
            if let pointer { LuminaAgentRuntimeReleaseString(pointer) }
        }
        guard let pointer else { return nil }
        let json = String(cString: pointer)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["ok"] as? Bool) == true,
              let value = (object["value"] as? String) ?? (object["json"] as? String)
        else { return nil }
        return value
    }
}
