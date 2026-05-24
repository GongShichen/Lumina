import Foundation

public struct LuminaCancellationToken: Sendable {
    public init() {}

    public func checkCancellation() throws {
        try Task.checkCancellation()
    }
}
