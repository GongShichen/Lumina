import LuminaAgentClient
@preconcurrency import EventKit
import Foundation
import LuminaAppCore
import PersonalMemory

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
import AppKit
#endif

enum AppToolFactory {
    static func makeTools(
        memoryStore: LuminaMemoryStore,
        ledgerStore: LuminaLedgerStore,
        subscriptionStore: LuminaSubscriptionStore,
        messageDrafts: LuminaMessageDraftCenter,
        askUser: AskUserCoordinator
    ) -> [AnyLuminaAgentTool] {
        makeTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            messageDrafts: messageDrafts,
            askUser: askUser.ask
        )
    }

    static func makeTools(
        memoryStore: LuminaMemoryStore,
        ledgerStore: LuminaLedgerStore,
        subscriptionStore: LuminaSubscriptionStore,
        messageDrafts: LuminaMessageDraftCenter,
        askUser: @escaping LuminaAskUserTool.AskUser
    ) -> [AnyLuminaAgentTool] {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        let baseTools: [AnyLuminaAgentTool] = [
            LuminaCurrentTimeTool().eraseToAnyTool(),
            LuminaAskUserTool(askUser: askUser).eraseToAnyTool(),
            LuminaMediaImportTool(memoryStore: memoryStore).eraseToAnyTool(),
            LuminaLocalSearchTool(memoryStore: memoryStore).eraseToAnyTool(),
            LuminaCalendarSearchTool().eraseToAnyTool(),
            LuminaCalendarCreateTool().eraseToAnyTool(),
            LuminaReminderCreateTool().eraseToAnyTool(),
            LuminaContactsSearchTool().eraseToAnyTool(),
            LuminaLocationCurrentTool().eraseToAnyTool(),
            LuminaNotificationScheduleTool().eraseToAnyTool(),
            LuminaClipboardReadTool().eraseToAnyTool(),
            LuminaFileSaveNoteTool(documentsDirectory: documentsDirectory).eraseToAnyTool(),
            LuminaURLOpenTool().eraseToAnyTool(),
            LuminaMemoryIngestTextTool(memoryStore: memoryStore).eraseToAnyTool(),
            LuminaMessageComposeTool(messageDrafts: messageDrafts).eraseToAnyTool(),
            LuminaLedgerRecordTool(store: ledgerStore).eraseToAnyTool(),
            LuminaLedgerSearchTool(store: ledgerStore).eraseToAnyTool(),
            LuminaSubscriptionAddTool(store: subscriptionStore, memoryStore: memoryStore).eraseToAnyTool()
        ]
        let platformWeatherHealth = Self.weatherHealthExecutors()
        let extendedTools = LuminaExtendedToolCatalog.makeTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            calendarStore: LuminaVolatileCalendarStore(),
            documentsDirectory: documentsDirectory,
            openURL: Self.openURL,
            currentWeather: platformWeatherHealth.currentWeather,
            forecastWeather: platformWeatherHealth.forecastWeather,
            healthSummary: platformWeatherHealth.healthSummary,
            healthSamples: platformWeatherHealth.healthSamples,
            contactsCreate: LuminaContactMutationExecutor.createContact,
            contactsUpdate: LuminaContactMutationExecutor.updateContact,
            contactsOpen: LuminaContactMutationExecutor.openContact,
            sharePrepare: LuminaShareExecutor.prepareShare,
            clipboardWrite: LuminaClipboardWriteExecutor.writeClipboard,
            includePIMTools: false
        )
        return baseTools + LuminaEventKitManagementToolFactory.makeTools() + Self.platformFilteredTools(extendedTools)
    }

    private static func weatherHealthExecutors() -> (
        currentWeather: LuminaExtendedToolCatalog.CurrentWeather?,
        forecastWeather: LuminaExtendedToolCatalog.ForecastWeather?,
        healthSummary: LuminaExtendedToolCatalog.HealthSummary?,
        healthSamples: LuminaExtendedToolCatalog.HealthSamples?
    ) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return (
            LuminaWeatherHealthExecutor.currentWeather,
            LuminaWeatherHealthExecutor.forecastWeather,
            LuminaWeatherHealthExecutor.healthSummary,
            LuminaWeatherHealthExecutor.healthSamples
        )
        #else
        return (nil, nil, nil, nil)
        #endif
    }

    private static func platformFilteredTools(_ tools: [AnyLuminaAgentTool]) -> [AnyLuminaAgentTool] {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return tools
        #else
        return tools.filter { tool in
            !tool.schema.name.hasPrefix("weather.") && !tool.schema.name.hasPrefix("health.")
        }
        #endif
    }

    @MainActor
    private static func openURL(_ url: URL) async -> Bool {
        #if canImport(UIKit)
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url) { success in
                continuation.resume(returning: success)
            }
        }
        #elseif os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }
}
