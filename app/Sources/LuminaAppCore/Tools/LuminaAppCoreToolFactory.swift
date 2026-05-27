import LuminaAgentRuntime
import Foundation
import PersonalMemory

public enum LuminaAppCoreToolFactory {
    public static func makeTools(
        memoryStore: LuminaMemoryStore,
        ledgerStore: LuminaLedgerStore,
        subscriptionStore: LuminaSubscriptionStore,
        messageDrafts: LuminaMessageDraftCenter,
        calendarStore: LuminaVolatileCalendarStore = LuminaVolatileCalendarStore(),
        notificationStore: LuminaScheduledNotificationStore = LuminaScheduledNotificationStore(),
        documentsDirectory: URL = FileManager.default.temporaryDirectory,
        searchContacts: @escaping LuminaContactsSearchTool.SearchContacts = { _, _ in [] },
        currentLocation: @escaping LuminaLocationCurrentTool.CurrentLocation = {
            throw CancellationError()
        },
        readClipboard: @escaping LuminaClipboardReadTool.ReadClipboard = { nil },
        openURL: @escaping LuminaURLOpenTool.OpenURL = { _ in true },
        askUser: @escaping LuminaAskUserTool.AskUser = { request in
            LuminaAskUserResponse(requestID: request.id, answers: [], cancelled: true)
        }
    ) -> [AnyLuminaAgentTool] {
        let baseTools = [
            LuminaCurrentTimeTool().eraseToAnyTool(),
            LuminaAskUserTool(askUser: askUser).eraseToAnyTool(),
            LuminaMediaImportTool(memoryStore: memoryStore).eraseToAnyTool(),
            LuminaLocalSearchTool(memoryStore: memoryStore).eraseToAnyTool(),
            LuminaCalendarSearchTool(store: calendarStore).eraseToAnyTool(),
            LuminaCalendarCreateTool(store: calendarStore).eraseToAnyTool(),
            LuminaReminderCreateTool(store: calendarStore).eraseToAnyTool(),
            LuminaContactsSearchTool(searchContacts: searchContacts).eraseToAnyTool(),
            LuminaLocationCurrentTool(currentLocation: currentLocation).eraseToAnyTool(),
            LuminaNotificationScheduleTool(store: notificationStore).eraseToAnyTool(),
            LuminaClipboardReadTool(readClipboard: readClipboard).eraseToAnyTool(),
            LuminaFileSaveNoteTool(documentsDirectory: documentsDirectory).eraseToAnyTool(),
            LuminaURLOpenTool(openURL: openURL).eraseToAnyTool(),
            LuminaMemoryIngestTextTool(memoryStore: memoryStore).eraseToAnyTool(),
            LuminaMessageComposeTool(messageDrafts: messageDrafts).eraseToAnyTool(),
            LuminaLedgerRecordTool(store: ledgerStore).eraseToAnyTool(),
            LuminaLedgerSearchTool(store: ledgerStore).eraseToAnyTool(),
            LuminaSubscriptionAddTool(store: subscriptionStore, memoryStore: memoryStore).eraseToAnyTool()
        ]
        let extendedTools = LuminaExtendedToolCatalog.makeTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            calendarStore: calendarStore,
            documentsDirectory: documentsDirectory,
            openURL: openURL
        )
        return baseTools + extendedTools
    }
}
