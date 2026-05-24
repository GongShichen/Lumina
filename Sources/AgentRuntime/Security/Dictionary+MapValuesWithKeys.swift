import Foundation

extension Dictionary where Key == String, Value == LuminaJSONValue {
    func mapValuesWithKeys(_ transform: (String, LuminaJSONValue) -> LuminaJSONValue) -> [String: LuminaJSONValue] {
        var result: [String: LuminaJSONValue] = [:]
        for (key, value) in self {
            result[key] = transform(key, value)
        }
        return result
    }
}
