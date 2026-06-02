import LuminaAgentRuntime
import Combine
import Foundation
import LuminaModelRuntime
import PersonalMemory
import Security

#if canImport(CoreML)
import CoreML
#endif

enum LocalModelBootstrap {
    private enum ModelKind: String {
        case structuredModel
        case embedding
    }

    static func makeStepGenerator(
        readinessStore: LuminaModelReadinessStore? = nil,
        metricsStore: LuminaModelInferenceMetricsStore? = nil,
        memoryStore: LuminaMemoryStore,
        localModelSelection: LuminaLocalModelSelectionStore,
        remoteSettings: LuminaRemoteInferenceSettingsStore? = nil
    ) -> any LuminaReActStepGenerator {
        let local = LuminaSelectableLocalReActStepGenerator(
            selectionStore: localModelSelection,
            readinessStore: readinessStore,
            makeGenerator: { selection in
                LuminaLazyReActStepGenerator(fallback: unavailableStepGenerator(), readinessStore: readinessStore) {
                    makeEagerStepGenerator(
                        memoryStore: memoryStore,
                        metricsStore: metricsStore,
                        selection: selection
                    )
                }
            }
        )
        guard let remoteSettings else { return local }
        return LuminaRemoteFallbackReActStepGenerator(
            settings: remoteSettings,
            local: local,
            readinessStore: readinessStore,
            metricsStore: metricsStore
        )
    }

    static func makeEmbeddingProvider(readinessStore: LuminaModelReadinessStore? = nil) -> any LuminaEmbeddingProvider {
        LuminaLazyEmbeddingProvider(dimension: preferredEmbeddingDimension(), readinessStore: readinessStore) {
            makeEagerEmbeddingProvider()
        }
    }

    private static func makeEagerStepGenerator(
        memoryStore: LuminaMemoryStore,
        metricsStore: LuminaModelInferenceMetricsStore?,
        selection: LuminaLocalModelSelection
    ) -> LuminaLazyReActStepGenerator.LoadResult {
        let promptBuilder = LuminaAppReActPromptBuilder()
        if let miniCPMURL = miniCPMV46ModelURL(selection: selection) {
            if #available(iOS 18.0, macOS 15.0, *) {
                do {
                    let stepMaxNewTokens = 2_048
                    let model = try LuminaMiniCPMV46ReActModel(configuration: .init(
                        modelDirectory: miniCPMURL,
                        backendPreference: miniCPMV46BackendPreference,
                        maxNewTokens: stepMaxNewTokens,
                        expectedContextLength: 16_000,
                        outputSafetyMarginTokens: 256,
                        metricsRecorder: { metrics in
                            metricsStore?.record(metrics)
                        }
                    ))
                    log("Loaded MiniCPM-V 4.6 model bundle at \(miniCPMURL.path)")
                    let source = "\(selection.displayName) · MiniCPM-V 4.6 GGUF · \(model.bundleInfo.contextLength) ctx · \(model.bundleInfo.quantization)"
                    let maxOutputFrom2KPrompt = model.bundleInfo.maximumSupportedOutputTokens(
                        inputTokenCount: 2_000,
                        safetyMargin: 256,
                        configurationCap: stepMaxNewTokens
                    )
                    return .model(
                        LuminaModelBackedReActStepGenerator(
                            model: model,
                            promptBuilder: promptBuilder.build(context:),
                            fallback: LuminaUnavailableReActStepGenerator()
                        ),
                        source: source,
                        message: "\(selection.displayName) 已连接：architecture \(model.bundleInfo.architecture)，context \(model.bundleInfo.contextLength)，\(model.bundleInfo.quantization)，动态单步输出上限当前最高 \(maxOutputFrom2KPrompt) tokens，推理入口为 LuminaModelRuntimeCore 原生 C++ engine。"
                    )
                } catch {
                    log("MiniCPM-V 4.6 model failed to initialize: \(error.localizedDescription)")
                    return .fallback(
                        unavailableStepGenerator(),
                        message: "\(selection.displayName) 初始化失败：\(error.localizedDescription)。当前没有可用模型。"
                    )
                }
            } else {
                return .fallback(
                    unavailableStepGenerator(),
                    message: "当前系统版本不支持 \(selection.displayName)；当前没有可用模型。"
                )
            }
        }

        log("Local ReAct model was not found. Requests will fail instead of using app-side rules.")
        return .fallback(
            unavailableStepGenerator(),
            message: "没有找到 \(selection.displayName)；当前没有可用模型。请确认对应 GGUF bundle 已安装在 app/Resources/Models。"
        )
    }

    private static func unavailableStepGenerator() -> any LuminaReActStepGenerator {
        LuminaUnavailableReActStepGenerator()
    }

    private static func makeEagerEmbeddingProvider() -> LuminaLazyEmbeddingProvider.LoadResult {
        #if canImport(CoreML)
        if let url = firstModelURL(kind: .embedding, candidates: ["BGETextEmbedding", "LocalEmbedding"]) {
            if let tokenizerURL = tokenizerURL(for: url),
               let provider = try? LuminaBGECoreMLEmbeddingProvider(configuration: .init(
                   modelURL: url,
                   tokenizerURL: tokenizerURL,
                   computeUnits: modelComputeUnits,
                   normalizeOutput: true
               )) {
                log("Loaded BGE Core ML embedding model at \(url.path)")
                return .model(provider, source: url.lastPathComponent, message: "端侧 embedding 已加载：\(url.lastPathComponent)。")
            }

            if let provider = try? LuminaCoreMLEmbeddingProvider(configuration: .init(
                modelURL: url,
                textInputName: "text",
                embeddingOutputName: "embedding",
                dimension: embeddingDimension(for: url),
                computeUnits: modelComputeUnits,
                normalizeOutput: true
            )) {
                log("Loaded local embedding Core ML model at \(url.path)")
                return .model(provider, source: url.lastPathComponent, message: "端侧 embedding 已加载：\(url.lastPathComponent)。")
            }
        }

        #endif

        log("BGETextEmbedding.mlmodelc was not found. Falling back to LuminaHashingEmbeddingProvider.")
        return .fallback(
            LuminaHashingEmbeddingProvider(),
            message: "没有找到 BGETextEmbedding.mlmodelc；检索 embedding 使用确定性 hashing fallback。"
        )
    }

    private static func preferredEmbeddingDimension() -> Int {
        #if canImport(CoreML)
        if let url = firstModelURL(kind: .embedding, candidates: ["BGETextEmbedding", "LocalEmbedding"]) {
            return embeddingDimension(for: url)
        }
        #endif
        return LuminaHashingEmbeddingProvider().dimension
    }

    private static func tokenizerURL(for modelURL: URL) -> URL? {
        if let value = ProcessInfo.processInfo.environment["LUMINA_EMBEDDING_TOKENIZER"], !value.isEmpty {
            let url = URL(fileURLWithPath: value)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let parent = modelURL.deletingLastPathComponent()
        let candidates = [
            parent.appendingPathComponent("tokenizer.json"),
            parent.appendingPathComponent("BGETextEmbedding-tokenizer.json"),
            parent.deletingLastPathComponent().appendingPathComponent("tokenizer.json")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        if let url = Bundle.main.url(forResource: "BGETextEmbedding-tokenizer", withExtension: "json") {
            return url
        }
        if let url = Bundle.main.url(forResource: "tokenizer", withExtension: "json", subdirectory: "Models/BGETextEmbedding") {
            return url
        }
        return nil
    }

    private static func embeddingDimension(for url: URL) -> Int {
        url.lastPathComponent.contains("BGETextEmbedding") ? 512 : 768
    }

    private static func firstModelURL(kind: ModelKind, candidates: [String]) -> URL? {
        if let override = processEnvironmentModelURL(kind: kind), FileManager.default.fileExists(atPath: override.path) {
            return override
        }

        for candidate in candidates {
            if let url = Bundle.main.url(forResource: candidate, withExtension: "mlmodelc") {
                return url
            }
            if let url = Bundle.main.url(forResource: candidate, withExtension: "mlmodelc", subdirectory: "Models") {
                return url
            }
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Models/\(candidate).mlmodelc"),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func processEnvironmentModelURL(kind: ModelKind) -> URL? {
        let key = kind == .structuredModel ? "LUMINA_MINICPMV46_MODEL" : "LUMINA_EMBEDDING_MODEL"
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return nil
    }

    private static func miniCPMV46ModelURL(selection: LuminaLocalModelSelection) -> URL? {
        print("[Lumina][Bootstrap] Resolving URL for selection: \(selection.rawValue)")
        let environmentKeys: [String]
        let bundleCandidates: [String]
        switch selection {
        case .original:
            environmentKeys = ["LUMINA_MINICPMV46_ORIGINAL_MODEL", "LUMINA_MINICPMV46_MODEL"]
            bundleCandidates = ["MiniCPMV46ReActModel", "MiniCPMV46Model"]
        case .agenticDPO:
            environmentKeys = ["LUMINA_MINICPMV46_AGENTIC_DPO_MODEL"]
            bundleCandidates = ["MiniCPMV46ReActModel-AgenticSFTDPO-Q8", "MiniCPMV46AgenticDPOReActModel", "MiniCPMV46AgenticDPOModel"]
        }

        for key in environmentKeys {
            guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { continue }
            let url = URL(fileURLWithPath: value)
            if FileManager.default.fileExists(atPath: url.path) {
                print("[Lumina][Bootstrap] Found model via ENV (\(key)): \(url.path)")
                return url
            }
        }

        for candidate in bundleCandidates {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Models/\(candidate)"),
               FileManager.default.fileExists(atPath: url.path) {
                print("[Lumina][Bootstrap] Found model via Bundle (\(candidate)): \(url.path)")
                return url
            }
        }
        print("[Lumina][Bootstrap] ERROR: No model found for selection: \(selection.rawValue)")
        return nil
    }

    private static func log(_ message: String) {
        #if DEBUG
        print("[Lumina][LocalModelBootstrap] \(message)")
        #endif
    }

    #if canImport(CoreML)
    private static var modelComputeUnits: MLComputeUnits {
        if let override = ProcessInfo.processInfo.environment["LUMINA_COREML_COMPUTE_UNITS"]?.lowercased() {
            switch override {
            case "cpu":
                return .cpuOnly
            case "gpu", "mps", "cpuandgpu", "cpu+gpu":
                return .cpuAndGPU
            case "ane", "cpuandneuralengine", "cpu+ane":
                return .cpuAndNeuralEngine
            case "all":
                return .all
            default:
                break
            }
        }
        #if targetEnvironment(simulator)
        return .cpuOnly
        #elseif targetEnvironment(macCatalyst) || os(macOS)
        return .cpuAndGPU
        #else
        return .cpuAndNeuralEngine
        #endif
    }
    #endif

    private static var miniCPMV46BackendPreference: LuminaMiniCPMV46BackendPreference {
        switch ProcessInfo.processInfo.environment["LUMINA_MINICPMV46_BACKEND"]?.lowercased() {
        case "ane":
            return .ane
        case "mps", "metal", "gpu":
            return .mps
        default:
            return .automatic
        }
    }
}

struct LuminaRemoteInferenceConfiguration: Equatable, Sendable {
    var baseURL: String
    var apiKey: String
    var model: String

    var normalizedBaseURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    var isComplete: Bool {
        normalizedBaseURL != nil &&
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@MainActor
final class LuminaRemoteInferenceSettingsStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var baseURL: String
    @Published private(set) var model: String
    @Published private(set) var hasAPIKey: Bool

    private let defaults: UserDefaults
    private let keychain = LuminaAPIKeyKeychain()
    private let baseURLKey = "lumina.remoteInference.baseURL"
    private let modelKey = "lumina.remoteInference.model"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURL = defaults.string(forKey: baseURLKey) ?? ""
        self.model = defaults.string(forKey: modelKey) ?? ""
        self.hasAPIKey = ((try? keychain.readAPIKey()) ?? "").isEmpty == false
    }

    var modeDescription: String {
        currentConfiguration().isComplete ? "API streaming" : "Local inference"
    }

    func currentConfiguration() -> LuminaRemoteInferenceConfiguration {
        LuminaRemoteInferenceConfiguration(
            baseURL: baseURL,
            apiKey: (try? keychain.readAPIKey()) ?? "",
            model: model
        )
    }

    func apiKeyForDisplay() -> String {
        (try? keychain.readAPIKey()) ?? ""
    }

    func save(baseURL: String, model: String, apiKey: String) throws {
        let cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(cleanBaseURL, forKey: baseURLKey)
        defaults.set(cleanModel, forKey: modelKey)
        self.baseURL = cleanBaseURL
        self.model = cleanModel

        let cleanAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanAPIKey.isEmpty {
            if !hasAPIKey {
                try keychain.deleteAPIKey()
            }
        } else {
            try keychain.saveAPIKey(cleanAPIKey)
        }
        hasAPIKey = try keychain.readAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func clear() {
        defaults.removeObject(forKey: baseURLKey)
        defaults.removeObject(forKey: modelKey)
        try? keychain.deleteAPIKey()
        baseURL = ""
        model = ""
        hasAPIKey = false
    }
}

private struct LuminaAPIKeyKeychain {
    private let service = "dev.local.Lumina.remoteInference"
    private let account = "openai-compatible-api-key"

    func readAPIKey() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw KeychainError.status(status, operation: "read") }
        guard let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func saveAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        var query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus, operation: "add") }
            return
        }
        throw KeychainError.status(status, operation: "update")
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status, operation: "delete")
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus, operation: String)

        var errorDescription: String? {
            switch self {
            case let .status(status, operation):
                "Keychain \(operation) failed with status \(status)."
            }
        }
    }
}

struct LuminaRemoteFallbackReActStepGenerator: LuminaReActStepGenerator {
    let settings: LuminaRemoteInferenceSettingsStore
    let local: any LuminaReActStepGenerator
    let readinessStore: LuminaModelReadinessStore?
    let metricsStore: LuminaModelInferenceMetricsStore?

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        let configuration = await settings.currentConfiguration()
        guard configuration.isComplete else {
            return try await local.nextStep(context: context)
        }
        do {
            let remoteModel = LuminaOpenAICompatibleStreamingModel(configuration: configuration, metricsStore: metricsStore)
            await readinessStore?.markModelReady(
                source: "OpenAI-compatible API · \(configuration.model)",
                message: "本次优先使用远程 OpenAI-compatible 流式 API。"
            )
            let generator = LuminaModelBackedReActStepGenerator(
                model: remoteModel,
                promptBuilder: LuminaAppReActPromptBuilder().build(context:),
                fallback: LuminaUnavailableReActStepGenerator()
            )
            let step = try await generator.nextStep(context: context)
            await readinessStore?.markModelReady(
                source: "OpenAI-compatible API · \(configuration.model)",
                message: "本次由远程 API 流式生成标准 ReAct action/result。"
            )
            return step
        } catch {
            await readinessStore?.markModelFallback("远程 API 失败，已回落本地推理：\(error.localizedDescription)")
            return try await local.nextStep(context: context)
        }
    }
}

struct LuminaOpenAICompatibleStreamingModel: LuminaLocalDynamicOutputStreamingStructuredInferenceModel {
    let configuration: LuminaRemoteInferenceConfiguration
    let metricsStore: LuminaModelInferenceMetricsStore?
    private let client = LuminaOpenAICompatibleStreamingClient()

    func generateJSON(prompt: String) async throws -> String {
        try await generateJSON(prompt: prompt, maxOutputTokens: nil)
    }

    func generateJSON(prompt: String, maxOutputTokens: Int?) async throws -> String {
        try await generateJSON(prompt: prompt, maxOutputTokens: maxOutputTokens) { _ in }
    }

    func generateJSON(
        prompt: String,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> String {
        try await generateJSON(prompt: prompt, maxOutputTokens: nil, progress: progress)
    }

    func generateJSON(
        prompt: String,
        maxOutputTokens: Int?,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> String {
        let startedAt = ContinuousClock.now
        let result = try await client.streamChatCompletion(
            configuration: configuration,
            prompt: prompt,
            maxOutputTokens: maxOutputTokens,
            progress: progress
        )
        let totalMs = Self.milliseconds(since: startedAt)
        metricsStore?.record(LuminaModelInferenceMetrics(
            modelName: configuration.model,
            computeUnits: "Remote API",
            contextLength: 0,
            promptTokens: result.promptTokenEstimate,
            outputTokens: result.outputTokenEstimate,
            maxOutputTokens: maxOutputTokens ?? 0,
            timeToFirstTokenMilliseconds: result.timeToFirstTokenMilliseconds,
            generationMilliseconds: totalMs,
            totalMilliseconds: totalMs,
            tokensPerSecond: totalMs > 0 ? Double(result.outputTokenEstimate) / (totalMs / 1_000) : 0,
            loadMilliseconds: 0,
            tokenizerMilliseconds: 0
        ))
        return result.text
    }

    func generateJSON(
        input: LuminaStructuredStepGenerationInput,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> String {
        try await generateJSON(prompt: input.prompt, maxOutputTokens: input.maxOutputTokensHint, progress: progress)
    }

    func generateJSON(input: LuminaStructuredStepGenerationInput) async throws -> String {
        try await generateJSON(prompt: input.prompt, maxOutputTokens: input.maxOutputTokensHint)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

private struct LuminaOpenAICompatibleStreamingClient: Sendable {
    struct StreamResult: Sendable {
        var text: String
        var promptTokenEstimate: Int
        var outputTokenEstimate: Int
        var timeToFirstTokenMilliseconds: Double?
    }

    private let retryPolicy = LuminaOpenAICompatibleRetryPolicy()

    func streamChatCompletion(
        configuration: LuminaRemoteInferenceConfiguration,
        prompt: String,
        maxOutputTokens: Int?,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> StreamResult {
        var lastError: Error?
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                return try await streamOnce(configuration: configuration, prompt: prompt, maxOutputTokens: maxOutputTokens, progress: progress)
            } catch let error as LuminaOpenAICompatibleStreamingError {
                lastError = error
                let request = retryPolicy.request(for: error, attempt: attempt)
                let decision = await retryPolicy.decideRetry(for: request)
                guard decision.action == .retry else { throw error }
                progress(LuminaStructuredInferenceProgress(
                    phase: "remote.api.retrying",
                    elapsedMilliseconds: 0,
                    promptTokens: Self.estimateTokens(prompt),
                    outputTokens: 0,
                    partialOutput: "retry attempt \(attempt + 1) after \(error.localizedDescription.truncatedForLuminaRemoteProgress(to: 120))"
                ))
                try await sleepBeforeRetry(delayMilliseconds: decision.delayMilliseconds)
            } catch {
                lastError = error
                let request = retryPolicy.request(for: error, attempt: attempt)
                let decision = await retryPolicy.decideRetry(for: request)
                guard decision.action == .retry else { throw error }
                progress(LuminaStructuredInferenceProgress(
                    phase: "remote.api.retrying",
                    elapsedMilliseconds: 0,
                    promptTokens: Self.estimateTokens(prompt),
                    outputTokens: 0,
                    partialOutput: "retry attempt \(attempt + 1) after \(error.localizedDescription.truncatedForLuminaRemoteProgress(to: 120))"
                ))
                try await sleepBeforeRetry(delayMilliseconds: decision.delayMilliseconds)
            }
        }
        throw lastError ?? LuminaOpenAICompatibleStreamingError.transport("Remote API failed without details.")
    }

    private func streamOnce(
        configuration: LuminaRemoteInferenceConfiguration,
        prompt: String,
        maxOutputTokens: Int?,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> StreamResult {
        guard let baseURL = configuration.normalizedBaseURL else {
            throw LuminaOpenAICompatibleStreamingError.configuration("Base URL is invalid.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: configuration.model,
            messages: [Message(role: "user", content: prompt)],
            stream: true,
            maxTokens: maxOutputTokens
        ))

        let startedAt = ContinuousClock.now
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LuminaOpenAICompatibleStreamingError.transport("Remote API returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LuminaOpenAICompatibleStreamingError.httpStatus(http.statusCode, retryAfter: retryAfter(from: http))
        }

        var accumulated = ""
        var outputTokens = 0
        var firstTokenMs: Double?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8) else { continue }
            let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: data)
            let delta = chunk.choices.compactMap(\.delta.content).joined()
            guard !delta.isEmpty else { continue }
            if firstTokenMs == nil {
                firstTokenMs = Self.milliseconds(since: startedAt)
            }
            accumulated += delta
            outputTokens = Self.estimateTokens(accumulated)
            progress(LuminaStructuredInferenceProgress(
                phase: "remote.api.streaming",
                elapsedMilliseconds: Self.milliseconds(since: startedAt),
                promptTokens: Self.estimateTokens(prompt),
                outputTokens: outputTokens,
                partialOutput: accumulated.truncatedForLuminaRemoteProgress(to: 320)
            ))
        }

        guard !accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LuminaOpenAICompatibleStreamingError.transport("Remote API streamed no content.")
        }
        return StreamResult(
            text: accumulated,
            promptTokenEstimate: Self.estimateTokens(prompt),
            outputTokenEstimate: outputTokens,
            timeToFirstTokenMilliseconds: firstTokenMs
        )
    }

    private func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        if let date = HTTPDateFormatter.shared.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    private func sleepBeforeRetry(delayMilliseconds: Int) async throws {
        let milliseconds = max(0, delayMilliseconds)
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func estimateTokens(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let maxTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    private struct Message: Encodable {
        let role: String
        let content: String
    }

    private struct ChatCompletionChunk: Decodable {
        let choices: [Choice]
    }

    private struct Choice: Decodable {
        let delta: Delta
    }

    private struct Delta: Decodable {
        let content: String?
    }
}

private struct LuminaOpenAICompatibleRetryPolicy: LuminaRuntimeRetryProvider {
    let maxAttempts = 3

    func request(for error: Error, attempt: Int) -> LuminaRuntimeRetryRequest {
        let classified = classify(error)
        return LuminaRuntimeRetryRequest(
            sessionID: "remote-api",
            runID: "remote-api",
            stage: "external_provider",
            attempt: attempt,
            maxAttempts: maxAttempts,
            errorCode: classified.code,
            errorCategory: classified.category,
            recoverable: classified.recoverable,
            retryAfterSeconds: classified.retryAfter ?? 0
        )
    }

    func decideRetry(for request: LuminaRuntimeRetryRequest) async -> LuminaRuntimeRetryDecision {
        guard request.attempt < request.maxAttempts else {
            return .init(action: .fallback, reason: "remote retry attempts exhausted")
        }
        guard request.recoverable else {
            return .init(action: .fallback, reason: "remote error is not retryable")
        }
        return .init(
            action: .retry,
            delayMilliseconds: delayMilliseconds(for: request),
            reason: "remote OpenAI-compatible retry policy"
        )
    }

    private func classify(_ error: Error) -> (code: String, category: String, recoverable: Bool, retryAfter: TimeInterval?) {
        if let error = error as? LuminaOpenAICompatibleStreamingError {
            switch error {
            case .configuration:
                return ("configuration", "configuration", false, nil)
            case let .httpStatus(status, retryAfter):
                return ("http_\(status)", "http", [408, 409, 429, 500, 502, 503, 504].contains(status), retryAfter)
            case .transport:
                return ("transport", "network", true, nil)
            }
        }
        if let urlError = error as? URLError {
            let retryableCodes: Set<URLError.Code> = [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet,
                .internationalRoamingOff,
                .callIsActive,
                .dataNotAllowed
            ]
            return ("url_\(urlError.code.rawValue)", "network", retryableCodes.contains(urlError.code), nil)
        }
        return ("unknown", "transport", false, nil)
    }

    private func delayMilliseconds(for request: LuminaRuntimeRetryRequest) -> Int {
        let retryAfter = request.retryAfterSeconds > 0 ? request.retryAfterSeconds : nil
        let base = retryAfter ?? min(8, pow(2, Double(max(0, request.attempt - 1))))
        let seconds = min(8, max(0.2, base * Double.random(in: 0.75...1.25)))
        return Int((seconds * 1_000).rounded())
    }
}

private enum LuminaOpenAICompatibleStreamingError: LocalizedError, Sendable {
    case configuration(String)
    case httpStatus(Int, retryAfter: TimeInterval?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case let .configuration(message), let .transport(message):
            return message
        case let .httpStatus(status, _):
            return "Remote API returned HTTP \(status)."
        }
    }
}

private final class HTTPDateFormatter: @unchecked Sendable {
    static let shared = HTTPDateFormatter()
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    }

    func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}

private extension String {
    func truncatedForLuminaRemoteProgress(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit))
    }
}
