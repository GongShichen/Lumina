import Foundation

public extension Dictionary where Key == String, Value == LuminaJSONValue {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }

    func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    func number(_ key: String) -> Double? {
        self[key]?.numberValue
    }
}
