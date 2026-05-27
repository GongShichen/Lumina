import Foundation
import PersonalMemory

struct LuminaLazyEmbeddingProvider: LuminaEmbeddingProvider {
    let dimension: Int
    private let loader: Loader
    private let readinessStore: LuminaModelReadinessStore?

    init(
        dimension: Int,
        readinessStore: LuminaModelReadinessStore? = nil,
        load: @escaping @Sendable () -> LoadResult
    ) {
        self.dimension = dimension
        self.readinessStore = readinessStore
        self.loader = Loader(load: load)
    }

    func embed(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        let result = await loader.provider()
        if result.source == "Hashing fallback" {
            await readinessStore?.markEmbeddingUnavailable(result.message)
        } else {
            await readinessStore?.markEmbeddingReady(source: result.source, message: result.message)
        }
        return try await result.provider.embed(text)
    }

    struct LoadResult: Sendable {
        var provider: any LuminaEmbeddingProvider
        var source: String
        var message: String

        static func fallback(_ provider: any LuminaEmbeddingProvider, message: String) -> LoadResult {
            LoadResult(provider: provider, source: "Hashing fallback", message: message)
        }

        static func model(_ provider: any LuminaEmbeddingProvider, source: String, message: String) -> LoadResult {
            LoadResult(provider: provider, source: source, message: message)
        }
    }

    private actor Loader {
        private var cachedResult: LoadResult?
        private let load: @Sendable () -> LoadResult

        init(load: @escaping @Sendable () -> LoadResult) {
            self.load = load
        }

        func provider() -> LoadResult {
            if let cachedResult {
                return cachedResult
            }
            let result = load()
            cachedResult = result
            return result
        }
    }
}
