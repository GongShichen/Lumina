import Foundation

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? String { return Int(value) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return Double(value) }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? String { return Bool(value) }
        return nil
    }
}
