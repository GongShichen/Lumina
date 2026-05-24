import Foundation

#if canImport(CoreML)
import CoreML

extension MLComputeUnits {
    var descriptionForLumina: String {
        switch self {
        case .cpuOnly:
            return "CPU"
        case .cpuAndGPU:
            return "CPU+GPU"
        case .cpuAndNeuralEngine:
            return "CPU+ANE"
        case .all:
            return "CPU+GPU+ANE"
        @unknown default:
            return "Core ML default"
        }
    }
}
#endif
