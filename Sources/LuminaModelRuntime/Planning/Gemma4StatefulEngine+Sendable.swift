import Foundation

#if canImport(CoreML) && canImport(CoreMLLLM) && canImport(Tokenizers)
import CoreML
import CoreMLLLM
import Tokenizers

@available(iOS 18.0, macOS 15.0, *)
extension Gemma4StatefulEngine: @retroactive @unchecked Sendable {}
#endif
