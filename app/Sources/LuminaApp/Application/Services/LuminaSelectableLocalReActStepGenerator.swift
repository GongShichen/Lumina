import LuminaAgentRuntime

struct LuminaSelectableLocalReActStepGenerator: LuminaReActStepGenerator {
    let selectionStore: LuminaLocalModelSelectionStore
    let readinessStore: LuminaModelReadinessStore?
    let makeGenerator: @Sendable (LuminaLocalModelSelection) -> any LuminaReActStepGenerator

    private let cache = Cache()

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        let selection = await selectionStore.currentSelection()
        print("[Lumina][SelectableGenerator] Current selection: \(selection.rawValue) (\(selection.displayName))")
        let generator = await cache.generator(for: selection, makeGenerator: makeGenerator)
        await readinessStore?.markModelReady(
            source: selection.displayName,
            message: "当前本地模型选择：\(selection.displayName)。"
        )
        return try await generator.nextStep(context: context)
    }

    private actor Cache {
        private var generators: [LuminaLocalModelSelection: any LuminaReActStepGenerator] = [:]

        func generator(
            for selection: LuminaLocalModelSelection,
            makeGenerator: @Sendable (LuminaLocalModelSelection) -> any LuminaReActStepGenerator
        ) -> any LuminaReActStepGenerator {
            if let generator = generators[selection] {
                return generator
            }
            let generator = makeGenerator(selection)
            generators[selection] = generator
            return generator
        }
    }
}
