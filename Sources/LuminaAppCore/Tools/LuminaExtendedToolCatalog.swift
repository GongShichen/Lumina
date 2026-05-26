import LuminaAgentClient
import Foundation
import PersonalMemory

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(Vision)
import Vision
#endif

public enum LuminaExtendedToolCatalog {
    public typealias OpenURL = @Sendable (URL) async -> Bool
    public typealias CurrentWeather = @Sendable ([String: LuminaJSONValue]) async throws -> LuminaToolResult
    public typealias ForecastWeather = @Sendable ([String: LuminaJSONValue]) async throws -> LuminaToolResult
    public typealias HealthSummary = @Sendable ([String: LuminaJSONValue]) async throws -> LuminaToolResult
    public typealias HealthSamples = @Sendable ([String: LuminaJSONValue]) async throws -> LuminaToolResult
    public typealias ContactsMutation = @Sendable ([String: LuminaJSONValue]) async throws -> LuminaToolResult
    public typealias SharePrepare = @Sendable ([String: LuminaJSONValue]) async throws -> LuminaToolResult
    public typealias ClipboardWrite = @Sendable ([String: LuminaJSONValue]) async throws -> LuminaToolResult

    public static func makeTools(
        memoryStore: LuminaMemoryStore,
        ledgerStore: LuminaLedgerStore,
        subscriptionStore: LuminaSubscriptionStore,
        calendarStore: LuminaVolatileCalendarStore,
        documentsDirectory: URL,
        openURL: @escaping OpenURL,
        currentWeather: CurrentWeather? = nil,
        forecastWeather: ForecastWeather? = nil,
        healthSummary: HealthSummary? = nil,
        healthSamples: HealthSamples? = nil,
        contactsCreate: ContactsMutation? = nil,
        contactsUpdate: ContactsMutation? = nil,
        contactsOpen: ContactsMutation? = nil,
        sharePrepare: SharePrepare? = nil,
        clipboardWrite: ClipboardWrite? = nil,
        includePIMTools: Bool = true
    ) -> [AnyLuminaAgentTool] {
        var tools: [LuminaConfiguredTool] = []
        if includePIMTools {
            tools += pimTools(calendarStore: calendarStore)
        }
        tools += communicationTools(openURL: openURL, contactsCreate: contactsCreate, contactsUpdate: contactsUpdate, contactsOpen: contactsOpen, sharePrepare: sharePrepare, clipboardWrite: clipboardWrite)
        tools += memoryLedgerSubscriptionTools(memoryStore: memoryStore, ledgerStore: ledgerStore, subscriptionStore: subscriptionStore)
        tools += contentTools(memoryStore: memoryStore, documentsDirectory: documentsDirectory)
        tools += systemTools(documentsDirectory: documentsDirectory)
        tools += weatherAndHealthTools(
            currentWeather: currentWeather,
            forecastWeather: forecastWeather,
            healthSummary: healthSummary,
            healthSamples: healthSamples
        )
        return tools.map { $0.eraseToAnyTool() }
    }
}
