#if DEBUG
import Darwin
import Foundation
import LuminaAgentRuntime
import LuminaAppCore
import LuminaModelRuntime
import PersonalMemory

@_silgen_name("LuminaMiniCPMV46GenerateReActJSON")
private func regressionNativeGenerate(
    _ modelDirectory: UnsafePointer<CChar>, _ backend: UnsafePointer<CChar>,
    _ prompt: UnsafePointer<CChar>, _ contextLength: Int32,
    _ maxOutputTokens: Int32, _ safetyMarginTokens: Int32
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("LuminaModelRuntimeFreeCString")
private func regressionNativeFree(_ pointer: UnsafeMutablePointer<CChar>?)

/// Runs the production model and prompt policy against isolated tool implementations.
/// This entry point is opt-in and never selects a remote inference provider.
@MainActor
enum LuminaToolCallingRegression {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LUMINA_TOOL_CALL_REGRESSION"] == "1"
    }

    private static var hasStarted = false

    static func runAndExit() async {
        guard isEnabled, !hasStarted else { return }
        hasStarted = true
        do {
            let passed = try await run()
            terminate(passed ? 0 : 1)
        } catch {
            log("fatal", ["error": error.localizedDescription])
            terminate(2)
        }
    }

    private static func terminate(_ status: Int32) -> Never {
        // Exercise normal native teardown after committing the report and diagnostics.
        fflush(nil)
        Darwin.exit(status)
    }

    private struct Scenario: Codable {
        let id: String
        let text: String
        let expectedTools: [String]

        static let all: [Self] = [
            .init(id: "reminder", text: "明天早上八点提醒我吃早餐", expectedTools: ["device.current_time", "reminder.create"]),
            .init(id: "notification", text: "明天早上八点给我发一条本地通知，标题是吃早餐，正文是记得吃早餐。", expectedTools: ["device.current_time", "notification.schedule"]),
            .init(id: "calendar_update", text: "把明天上午七点的“LuminaTest 项目同步”日程改到上午七点半，时长保持三十分钟。", expectedTools: ["device.current_time", "calendar.search", "calendar.update"]),
            .init(id: "cross_domain", text: "明天早上八点提醒我吃早餐，并在明天下午三点创建一个持续半小时、标题为项目同步的日历日程。", expectedTools: ["device.current_time", "reminder.create", "calendar.create"])
        ]
    }

    private struct CaseReport: Codable {
        let scenario: Scenario
        let repetition: Int
        let passed: Bool
        let failures: [String]
        let expectedDates: [String: String]
        let toolCalls: [LuminaToolCall]
        let observations: [LuminaReActObservation]
        let events: [LuminaCalendarEvent]
        let reminders: [LuminaReminderItem]
        let iterations: Int
        let promptTokens: [Int]
        let totalPromptTokens: Int
        let elapsedMilliseconds: Double
        let modelMetrics: [LuminaModelInferenceMetrics]
        let result: LuminaAgentRunResult?
    }

    private struct Report: Codable {
        let startedAt: Date
        var finishedAt: Date?
        let platform: String
        let modelPath: String
        let promptStyle: String
        let configuration: LuminaAgentRuntimeConfiguration
        let isolatedTools: Bool
        var passed: Bool
        var cases: [CaseReport]
    }

    private struct EngineCheck: Codable {
        let name: String
        let passed: Bool
        let detail: String
        let elapsedMilliseconds: Double
        var nativePhases: [String] = []
        var nativeResponse: [String: LuminaJSONValue]? = nil
    }

    private struct EngineCheckReport: Codable {
        let modelPath: String
        let startedAt: Date
        var finishedAt: Date?
        var passed = false
        var checks: [EngineCheck] = []
    }

    private static func run() async throws -> Bool {
        let variables = ProcessInfo.processInfo.environment
        let outputURL = URL(fileURLWithPath: variables["LUMINA_TOOL_CALL_REGRESSION_REPORT"] ??
            FileManager.default.temporaryDirectory.appendingPathComponent("lumina-tool-calling-report.json").path)
        let requested = variables["LUMINA_TOOL_CALL_REGRESSION_CASES"]?.split(separator: ",").map(String.init)
        let scenarios = Scenario.all.filter { requested?.contains($0.id) ?? true }
        guard !scenarios.isEmpty, requested?.allSatisfy({ id in Scenario.all.contains { $0.id == id } }) ?? true else {
            throw NSError(domain: "LuminaToolCallingRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown or empty regression case selection."])
        }
        let repetitions = min(10, max(1, Int(variables["LUMINA_TOOL_CALL_REGRESSION_REPETITIONS"] ?? "1") ?? 1))
        guard let modelURL = LuminaLocalModelSelection.original.resolvedMiniCPMV46ModelURL() else {
            throw NSError(domain: "LuminaToolCallingRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "Local MiniCPM model bundle was not found."])
        }
        let configuration = AppEnvironment.live().runtimeConfiguration
        let metricsStore = LuminaModelInferenceMetricsStore()
        let readinessStore = LuminaModelReadinessStore()
        let preferencesName = "Lumina.ToolCallingRegression.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: preferencesName) else {
            throw NSError(domain: "LuminaToolCallingRegression", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create isolated model preferences."])
        }
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let modelSelection = LuminaLocalModelSelectionStore(defaults: preferences)
        let stepGenerator = LocalModelBootstrap.makeStepGenerator(
            readinessStore: readinessStore,
            metricsStore: metricsStore,
            memoryStore: LuminaMemoryStore(),
            localModelSelection: modelSelection
        )
        var report = Report(
            startedAt: Date(),
            platform: ProcessInfo.processInfo.operatingSystemVersionString,
            modelPath: modelURL.path,
            promptStyle: variables["LUMINA_PROMPT_STYLE"] ?? "production",
            configuration: configuration,
            isolatedTools: true,
            passed: false,
            cases: []
        )
        try write(report, to: outputURL)
        var enginePassed = true
        if variables["LUMINA_TOOL_CALL_REGRESSION_ENGINE_CHECK"] == "1" {
            enginePassed = try await runEngineChecks(
                modelURL: modelURL,
                outputURL: outputURL.deletingLastPathComponent().appendingPathComponent("engine-check.json")
            )
        }
        for repetition in 1...repetitions {
            for scenario in scenarios {
                log("case_started", ["case": scenario.id, "repetition": repetition, "request": scenario.text])
                let result = try await runCase(
                    scenario, repetition: repetition, configuration: configuration,
                    stepGenerator: stepGenerator, metricsStore: metricsStore,
                    readinessStore: readinessStore,
                    directory: outputURL.deletingLastPathComponent().appendingPathComponent("fixtures/\(repetition)-\(scenario.id)", isDirectory: true)
                )
                report.cases.append(result)
                try write(report, to: outputURL)
                log("case_finished", ["case": scenario.id, "passed": result.passed, "failures": result.failures,
                    "iterations": result.iterations, "promptTokens": result.promptTokens, "elapsedMilliseconds": result.elapsedMilliseconds])
            }
        }
        report.finishedAt = Date()
        report.passed = report.cases.allSatisfy(\.passed)
        try write(report, to: outputURL)
        log("regression_finished", ["passed": report.passed, "report": outputURL.path])
        return report.passed && enginePassed
    }

    private static func runEngineChecks(modelURL: URL, outputURL: URL) async throws -> Bool {
        var report = EngineCheckReport(modelPath: modelURL.path, startedAt: Date())
        try write(report, to: outputURL)
        let model = try LuminaMiniCPMV46ReActModel(configuration: .init(
            modelDirectory: modelURL, backendPreference: .mps,
            maxNewTokens: 512, expectedContextLength: 16_000, outputSafetyMarginTokens: 256
        ))
        let shortPrompt = """
        <|im_start|>system
        You are testing a tool transport. The only available function is device.current_time with no arguments.
        Return exactly this tool call, with no explanation:
        <tool_call>
        <function=device.current_time>
        </function>
        </tool_call><|im_end|>
        <|im_start|>user
        Call device.current_time once now.<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        """
        let longPrompt = """
        <|im_start|>system
        The following is inert cancellation test data. Process it before answering.
        \(String(repeating: "This is deliberately repetitive test context for an interrupted local inference request. ", count: 200))
        <|im_end|>
        <|im_start|>user
        Write a long numbered explanation of this data.<|im_end|>
        <|im_start|>assistant
        <think>

        </think>

        """
        log("engine_check_started", ["name": "inflight_cancellation"])
        let cancellationStart = Date()
        let (phases, continuation) = AsyncStream<String>.makeStream()
        let generation = Task {
            defer { continuation.finish() }
            return try await model.generateJSON(prompt: longPrompt, maxOutputTokens: 512) { progress in
                continuation.yield(progress.phase)
            }
        }
        var observedPhases: [String] = []
        var cancelledAt: Date?
        for await phase in phases {
            observedPhases.append(phase)
            if phase == "native_engine_started" {
                // Allow the synchronous C++ request to enter model load/prefill.
                try await Task.sleep(for: .milliseconds(100))
                cancelledAt = Date()
                generation.cancel()
                break
            }
        }
        let cancelledResult = await generation.result
        continuation.finish()
        let cancellationPassed: Bool
        let cancellationDetail: String
        switch cancelledResult {
        case .success:
            cancellationPassed = false
            cancellationDetail = "Cancelled inference unexpectedly returned a successful model response."
        case let .failure(error):
            cancellationPassed = cancelledAt != nil && error is CancellationError
            cancellationDetail = "\(String(reflecting: type(of: error))): \(error.localizedDescription)"
        }
        report.checks.append(EngineCheck(
            name: "inflight_cancellation", passed: cancellationPassed, detail: cancellationDetail,
            elapsedMilliseconds: Date().timeIntervalSince(cancelledAt ?? cancellationStart) * 1_000,
            nativePhases: observedPhases
        ))
        try write(report, to: outputURL)

        log("engine_check_started", ["name": "same_model_recovers_after_cancellation"])
        let recoveryStart = Date()
        do {
            let json = try await model.generateJSON(prompt: shortPrompt, maxOutputTokens: 256)
            let step = try LuminaReActStepParser.parse(json: json, availableTools: [LuminaAppCore.LuminaCurrentTimeTool().schema])
            let calls = step.action.map { [$0] } ?? step.toolCalls
            let passed = calls.count == 1 && calls[0].toolName == "device.current_time" && calls[0].arguments.isEmpty
            report.checks.append(EngineCheck(
                name: "same_model_recovers_after_cancellation", passed: passed, detail: json,
                elapsedMilliseconds: Date().timeIntervalSince(recoveryStart) * 1_000
            ))
        } catch {
            report.checks.append(EngineCheck(
                name: "same_model_recovers_after_cancellation", passed: false, detail: error.localizedDescription,
                elapsedMilliseconds: Date().timeIntervalSince(recoveryStart) * 1_000
            ))
        }
        try write(report, to: outputURL)

        log("engine_check_started", ["name": "native_context_budget_rejection"])
        let budgetStart = Date()
        let nativeJSON = modelURL.path.withCString { modelPath in
            "mps".withCString { backend in
                longPrompt.withCString { prompt in
                    guard let pointer = regressionNativeGenerate(modelPath, backend, prompt, 100, 32, 0) else { return "" }
                    defer { regressionNativeFree(pointer) }
                    return String(cString: pointer)
                }
            }
        }
        let response = try? JSONDecoder().decode([String: LuminaJSONValue].self, from: Data(nativeJSON.utf8))
        let error = response?["error"]?.stringValue ?? ""
        let output = response?["output"]?.stringValue ?? ""
        let budgetPassed = response?["ok"]?.boolValue == false
            && error.localizedCaseInsensitiveContains("context") && output.isEmpty
        report.checks.append(EngineCheck(
            name: "native_context_budget_rejection", passed: budgetPassed,
            detail: nativeJSON.isEmpty ? "Native entry point returned no response." : error,
            elapsedMilliseconds: Date().timeIntervalSince(budgetStart) * 1_000,
            nativeResponse: response
        ))
        report.finishedAt = Date()
        report.passed = report.checks.allSatisfy(\.passed)
        try write(report, to: outputURL)
        log("engine_check_finished", ["passed": report.passed, "report": outputURL.path])
        return report.passed
    }

    private static func runCase(
        _ scenario: Scenario,
        repetition: Int,
        configuration: LuminaAgentRuntimeConfiguration,
        stepGenerator: any LuminaReActStepGenerator,
        metricsStore: LuminaModelInferenceMetricsStore,
        readinessStore: LuminaModelReadinessStore,
        directory: URL
    ) async throws -> CaseReport {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendarStore = LuminaVolatileCalendarStore()
        var fixtureID: String?
        if scenario.id == "calendar_update" {
            let start = tomorrow(hour: 7, reference: Date())
            fixtureID = await calendarStore.addEvent(LuminaCalendarEvent(
                title: "LuminaTest 项目同步", startDate: start,
                endDate: start.addingTimeInterval(1_800), notes: "Isolated tool calling regression fixture"
            ))
        }
        let tools = AppToolFactory.makeEvaluationTools(
            memoryStore: LuminaMemoryStore(), ledgerStore: LuminaLedgerStore(url: nil),
            subscriptionStore: LuminaSubscriptionStore(url: nil), messageDrafts: LuminaMessageDraftCenter(),
            calendarStore: calendarStore, documentsDirectory: directory
        )
        let runtime = LuminaAgentRuntime(
            tools: tools, stepGenerator: stepGenerator, contextProvider: LuminaEmptyRuntimeContextProvider(),
            configuration: configuration, permissionGate: LuminaAppRuntimePermissionGate(),
            confirmationCoordinator: LuminaAlwaysConfirmCoordinator(), auditLogger: LuminaInMemoryAuditLogger(),
            hooks: [LuminaAppMemoryPolicyRuntimeHook(), LuminaToolRecoveryRuntimeHook()]
        )
        let mark = metricsStore.mark()
        let start = Date()
        var iterations = 0
        var calls: [LuminaToolCall] = []
        var observations: [LuminaReActObservation] = []
        var result: LuminaAgentRunResult?
        for await event in runtime.runStream(request: LuminaAgentRequest(
            systemInstructions: LuminaAppSystemInstructions.taskExecution, text: scenario.text
        )) {
            switch event {
            case .stepGenerationStarted:
                iterations += 1
            case let .actionProposed(call):
                calls.append(call)
                log("tool_proposed", ["case": scenario.id, "tool": call.toolName, "arguments": jsonObject(call.arguments)])
            case let .multiActionProposed(proposed):
                calls.append(contentsOf: proposed)
                for call in proposed {
                    log("tool_proposed", ["case": scenario.id, "tool": call.toolName, "arguments": jsonObject(call.arguments)])
                }
            case let .observationCreated(observation):
                observations.append(observation)
                log("observation", ["case": scenario.id, "tool": observation.toolName,
                    "status": observation.status.rawValue, "output": jsonObject(observation.output),
                    "error": observation.errorMessage ?? ""])
            case let .finished(finalResult):
                result = finalResult
            default:
                break
            }
        }
        // The recorder publishes metrics on the main actor; let queued recordings finish.
        await Task.yield()
        let metrics = metricsStore.metrics(after: mark)
        iterations = max(iterations, metrics.count)
        let events = await calendarStore.allEvents()
        let reminders = await calendarStore.allReminders()
        let successful = observations.filter { $0.status == .succeeded && !$0.replayed }
        let successfulNames = successful.map(\.toolName)
        let currentTime = successful.first { $0.toolName == "device.current_time" }
        let reference = parseDate(currentTime?.output["iso8601"]?.stringValue)
        var failures: [String] = []
        var expectedDates: [String: String] = [:]
        if result == nil { failures.append("Runtime did not emit a finished result.") }
        if let result, result.status != .succeeded && result.status != .partiallySucceeded {
            failures.append("Runtime status: \(result.status.rawValue).")
        }
        let failedTerminations: Set<String> = [
            "cannot-complete", "budget", "iteration-budget", "reasoning-budget", "tool-budget",
            "replay-loop", "model-empty-output", "invalid-model-output", "cancelled", "stopped"
        ]
        if let reason = result?.reactTrace?.terminationReason, failedTerminations.contains(reason) {
            failures.append("Runtime terminated before normal completion: \(reason).")
        }
        if result?.plan.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            failures.append("No final answer after completing the requested operations.")
        }
        if metrics.isEmpty || metrics.contains(where: { $0.computeUnits.localizedCaseInsensitiveContains("remote") }) || readinessStore.snapshot.lastRunUsedFallback {
            failures.append("The run was not completed entirely with measured local model inference.")
        }
        for name in scenario.expectedTools where !successfulNames.contains(name) {
            failures.append("Missing successful tool: \(name).")
        }
        let unexpected = Set(observations.map(\.toolName)).subtracting(scenario.expectedTools).filter { !$0.hasPrefix("runtime.") }.sorted()
        if !unexpected.isEmpty { failures.append("Unexpected tools: \(unexpected.joined(separator: ", ")).") }
        let writes = Set(scenario.expectedTools.filter { $0.hasSuffix(".create") || $0.hasSuffix(".update") || $0 == "notification.schedule" })
        for name in writes where successfulNames.filter({ $0 == name }).count != 1 {
            failures.append("Expected exactly one successful execution of \(name).")
        }
        let firstWrite = observations.firstIndex { writes.contains($0.toolName) && $0.status == .succeeded }
        let firstTime = observations.firstIndex { $0.toolName == "device.current_time" && $0.status == .succeeded }
        if reference == nil || currentTime?.output["timeZoneIdentifier"]?.stringValue == nil {
            failures.append("Current-time observation is missing structured ISO time or timezone.")
        }
        if let firstWrite, firstTime == nil || firstTime! >= firstWrite {
            failures.append("A write succeeded before a real current-time observation.")
        }
        if let reference {
            let breakfast = tomorrow(hour: 8, reference: reference)
            if scenario.id == "reminder" || scenario.id == "cross_domain" {
                expectedDates["reminder.dueDateISO"] = iso(breakfast)
                let title = reminders.first?.title ?? ""
                let isBreakfast = title.contains("早餐") || title.localizedCaseInsensitiveContains("breakfast")
                if reminders.count != 1 || !isBreakfast || !sameDate(reminders.first?.dueDate, breakfast) {
                    failures.append("The isolated reminder store does not contain exactly one breakfast reminder at tomorrow 08:00.")
                }
            }
            if scenario.id == "notification" {
                expectedDates["notification.dateISO"] = iso(breakfast)
                let notification = successful.first { $0.toolName == "notification.schedule" }
                var executed: [String: LuminaJSONValue] = [:]
                if case let .object(arguments)? = notification?.output["executedArguments"] { executed = arguments }
                if !sameDate(parseDate(notification?.output["fireDate"]?.stringValue), breakfast)
                    || notification?.output["title"]?.stringValue?.contains("早餐") != true
                    || notification?.output["identifier"]?.stringValue?.isEmpty != false
                    || executed["body"]?.stringValue?.contains("早餐") != true {
                    failures.append("Notification output does not contain the requested title, body and tomorrow 08:00 date.")
                }
                if !reminders.isEmpty || !events.isEmpty { failures.append("Notification unexpectedly created a reminder or calendar event.") }
            }
            if scenario.id == "calendar_update" {
                let expected = tomorrow(hour: 7, minute: 30, reference: reference)
                expectedDates["calendar.startDateISO"] = iso(expected)
                if events.count != 1 || events.first?.id.uuidString != fixtureID || !sameDate(events.first?.startDate, expected) || !sameDate(events.first?.endDate, expected.addingTimeInterval(1_800)) {
                    failures.append("Calendar fixture was not updated to tomorrow 07:30 with its identity and 30-minute duration preserved.")
                }
                let search = observations.firstIndex { $0.toolName == "calendar.search" && $0.status == .succeeded }
                let update = observations.firstIndex { $0.toolName == "calendar.update" && $0.status == .succeeded }
                if search == nil || update == nil || search! >= update! {
                    failures.append("Calendar update did not follow a successful search observation.")
                }
                if calls.last(where: { $0.toolName == "calendar.update" })?.arguments["id"]?.stringValue != fixtureID {
                    failures.append("Calendar update did not use the real fixture ID returned by search.")
                }
            }
            if scenario.id == "cross_domain" {
                let expected = tomorrow(hour: 15, reference: reference)
                expectedDates["calendar.startDateISO"] = iso(expected)
                if events.count != 1 || events.first?.title.contains("项目同步") != true || !sameDate(events.first?.startDate, expected) || !sameDate(events.first?.endDate, expected.addingTimeInterval(1_800)) {
                    failures.append("Cross-domain task did not also create the requested 15:00 calendar event lasting 30 minutes.")
                }
            }
        }
        return CaseReport(
            scenario: scenario, repetition: repetition, passed: failures.isEmpty, failures: failures,
            expectedDates: expectedDates, toolCalls: calls, observations: observations,
            events: events, reminders: reminders, iterations: iterations,
            promptTokens: metrics.map(\.promptTokens), totalPromptTokens: metrics.reduce(0) { $0 + $1.promptTokens },
            elapsedMilliseconds: Date().timeIntervalSince(start) * 1_000, modelMetrics: metrics, result: result
        )
    }

    private static func tomorrow(hour: Int, minute: Int = 0, reference: Date) -> Date {
        let calendar = Calendar.current
        let nextDay = calendar.date(byAdding: .day, value: 1, to: reference)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: nextDay)!
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private static func sameDate(_ actual: Date?, _ expected: Date) -> Bool {
        actual.map { abs($0.timeIntervalSince(expected)) < 1 } ?? false
    }

    private static func iso(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }

    private static func write<T: Encodable>(_ report: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private static func jsonObject<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }

    private static func log(_ event: String, _ fields: [String: Any]) {
        var record = fields
        record["event"] = event
        record["timestamp"] = iso(Date())
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data(("[LuminaToolCallingRegression] " + line + "\n").utf8))
    }
}
#endif
