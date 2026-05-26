import Foundation

#if canImport(CoreML)
import CoreML

public enum LuminaCoreMLModelConfigurationFactory {
    public static func make(
        computeUnits: MLComputeUnits,
        functionName: String? = nil
    ) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        configuration.functionName = functionName
        applyOptimizationHints(to: configuration, computeUnits: computeUnits)
        return configuration
    }

    public static func applyOptimizationHints(
        to configuration: MLModelConfiguration,
        computeUnits: MLComputeUnits
    ) {
        guard usesGPU(computeUnits) else { return }
        configuration.allowLowPrecisionAccumulationOnGPU = true
        if #available(iOS 18.0, macOS 15.0, *) {
            var hints = MLOptimizationHints()
            hints.reshapeFrequency = .infrequent
            hints.specializationStrategy = .fastPrediction
            configuration.optimizationHints = hints
        }
    }

    private static func usesGPU(_ computeUnits: MLComputeUnits) -> Bool {
        switch computeUnits {
        case .cpuAndGPU, .all:
            return true
        default:
            return false
        }
    }
}

#endif
