import Foundation

extension String {
    func truncatedForLuminaMiniCPMProgress(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit))
    }
}
