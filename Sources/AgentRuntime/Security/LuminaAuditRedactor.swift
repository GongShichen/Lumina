import Foundation

public enum LuminaAuditRedactor {
    public static func redact(arguments: [String: LuminaJSONValue], schema: LuminaToolSchema) -> [String: LuminaJSONValue] {
        let sensitiveNames = Set(schema.parameters.filter(\.sensitive).map(\.name))
        let implicitSensitiveNames: Set<String> = ["password", "token", "secret", "body", "message", "recipient", "email", "phone"]

        return arguments.mapValuesWithKeys { key, value in
            if sensitiveNames.contains(key) || implicitSensitiveNames.contains(key.lowercased()) {
                return .string("<redacted>")
            }
            return value
        }
    }
}
