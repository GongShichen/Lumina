import Foundation

public struct LuminaLocationSnapshot: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double
    public var timestamp: Date
    public var locality: String?

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        timestamp: Date = Date(),
        locality: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.locality = locality
    }
}
