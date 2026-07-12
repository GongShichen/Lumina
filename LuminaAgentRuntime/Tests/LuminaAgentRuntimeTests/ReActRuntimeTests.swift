import XCTest
@testable import LuminaAgentRuntimeApple

final class ReActRuntimeTests: XCTestCase {
    func testRuntimeExecutesReActActionObservationResult() async {
        let model = ScriptedReActModel(steps: [
            .action(thought: "Need local context.", call: LuminaToolCall(toolName: "local.search", arguments: ["query": .string("coffee")])),
            .result("### Done\n\nFound context.")
        ])
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "local.search", status: .succeeded, content: [.markdown("### Result\n\n- coffee")])
        }
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: luminaTestRuntimeConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "查 coffee"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertEqual(result.reactTrace?.actionCount, 1)
        XCTAssertTrue(result.reactTrace?.observations.first?.summary.contains("coffee") == true)
    }

    func testRuntimeLoadsInjectedContextBeforeReActStepGeneration() async {
        let contextProvider = CountingContextProvider()
        let model = ContextAwareReActModel()
        let runtime = LuminaAgentRuntime(
            tools: [],
            stepGenerator: model,
            contextProvider: contextProvider,
            configuration: luminaTestRuntimeConfiguration
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "用我的记忆回答"))

        let loadCount = await contextProvider.loadCount
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(result.plan.summary.contains("真实记忆摘要"))
    }

    func testYoloModeSkipsPermissionAndConfirmationButExecutesTool() async {
        let calls = ActorBox(0)
        let permissionGate = CountingDenyPermissionGate()
        let confirmation = CountingDenyConfirmationCoordinator()
        let tool = AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "calendar.create",
                description: "Create event",
                parameters: [
                    LuminaToolParameterSchema(name: "title", type: .string, description: "Title")
                ],
                sideEffect: .systemWrite,
                destructive: true,
                requiresConfirmation: true
            )
        ) { _, _ in
            await calls.increment()
            return LuminaToolResult(callID: UUID(), toolName: "calendar.create", status: .succeeded, content: [.text("created")])
        }
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: ScriptedReActModel(steps: [
                .action(thought: "Create.", call: LuminaToolCall(toolName: "calendar.create", arguments: ["title": .string("Demo")])),
                .result("done")
            ]),
            configuration: luminaTestRuntimeConfiguration(yoloMode: true),
            permissionGate: permissionGate,
            confirmationCoordinator: confirmation
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "create"))
        let callCount = await calls.value
        let permissionCount = await permissionGate.count
        let confirmationCount = await confirmation.count

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(permissionCount, 0)
        XCTAssertEqual(confirmationCount, 0)
    }

    func testYoloModeDoesNotBypassSchemaValidation() async {
        let calls = ActorBox(0)
        let tool = AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "calendar.create",
                description: "Create event",
                parameters: [
                    LuminaToolParameterSchema(name: "title", type: .string, description: "Title")
                ],
                sideEffect: .systemWrite,
                requiresConfirmation: true
            )
        ) { _, _ in
            await calls.increment()
            return LuminaToolResult(callID: UUID(), toolName: "calendar.create", status: .succeeded)
        }
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: ScriptedReActModel(steps: [
                .action(thought: "Create.", call: LuminaToolCall(toolName: "calendar.create", arguments: [:])),
                .result("handled validation")
            ]),
            configuration: luminaTestRuntimeConfiguration(yoloMode: true)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "create"))
        let callCount = await calls.value

        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(result.toolResults.first?.status, .failed)
        XCTAssertTrue(result.toolResults.first?.errorMessage?.contains("missing required parameter title") == true)
    }

    func testPermissionStateIsExportedInSessionCheckpoint() {
        let runtime = LuminaAgentRuntime(
            tools: [],
            stepGenerator: ScriptedReActModel(steps: [.result("done")]),
            configuration: luminaTestRuntimeConfiguration(yoloMode: true)
        )
        guard let session = runtime.createSession(request: LuminaAgentRequest(text: "snapshot")) else {
            XCTFail("Expected session")
            return
        }

        let permissionState = session.permissionStateSnapshot()
        let checkpoint = session.exportCheckpoint()

        XCTAssertTrue(permissionState.contains(#""yolo_mode":true"#))
        XCTAssertTrue(checkpoint.contains(#""permission_state""#))
        XCTAssertTrue(checkpoint.contains(#""yolo_mode":true"#))
    }

    func testPermissionAndConfirmationAreNotToolSchemas() async {
        let runtime = LuminaAgentRuntime(
            tools: [
                AnyLuminaAgentTool(schema: LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
                    LuminaToolResult(callID: UUID(), toolName: "local.search", status: .succeeded)
                }
            ],
            stepGenerator: ScriptedReActModel(steps: [.result("done")]),
            configuration: luminaTestRuntimeConfiguration
        )

        let schemaNames = await runtime.availableToolSchemas().map(\.name)

        XCTAssertTrue(schemaNames.contains("local.search"))
        XCTAssertTrue(schemaNames.contains("runtime.mcp_discovery"))
        XCTAssertFalse(schemaNames.contains("permission"))
        XCTAssertFalse(schemaNames.contains("confirmation"))
        XCTAssertFalse(schemaNames.contains("permission_request"))
        XCTAssertFalse(schemaNames.contains("confirmation_request"))
        XCTAssertFalse(schemaNames.contains("ask_user"))
    }

    func testToolRouterReturnsFailedResultForMissingRequiredParameter() async {
        let schema = LuminaToolSchema(
            name: "file.save_note",
            description: "Save note",
            parameters: [
                LuminaToolParameterSchema(name: "body", type: .string, description: "Body")
            ],
            sideEffect: .appLocalWrite
        )
        let calls = ActorBox(0)
        let tool = AnyLuminaAgentTool(schema: schema) { _, _ in
            await calls.increment()
            return LuminaToolResult(callID: UUID(), toolName: "file.save_note", status: .succeeded)
        }
        let router = LuminaToolRouter(
            tools: [tool],
            permissionGate: LuminaDefaultPermissionGate(),
            confirmationCoordinator: LuminaAlwaysConfirmCoordinator()
        )

        let (result, _, _) = await router.execute(
            call: LuminaToolCall(toolName: "file.save_note", arguments: [:], requiresConfirmation: false),
            request: LuminaAgentRequest(text: "save")
        )

        XCTAssertEqual(result.status, .failed)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
        XCTAssertTrue(result.errorMessage?.contains("missing required parameter body") == true)
    }

    func testToolRouterRejectsReminderAliasesWithoutRequiredTitle() async {
        let schema = LuminaToolSchema(
            name: "reminder.create",
            description: "Create reminder",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "Reminder title."),
                LuminaToolParameterSchema(name: "dueDateISO", type: .dateISO8601, description: "Due date.", required: false)
            ],
            sideEffect: .readOnly
        )
        let captured = ArgumentBox()
        let tool = AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await captured.set(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "reminder.create", status: .succeeded)
        }
        let router = LuminaToolRouter(tools: [tool])

        let (result, _, _) = await router.execute(
            call: LuminaToolCall(
                toolName: "reminder.create",
                arguments: [
                    "text": .string("LuminaTest 带伞"),
                    "time": .string("2026-06-05T08:00:00+08:00")
                ]
            ),
            request: LuminaAgentRequest(text: "明天早上 8 点提醒我 LuminaTest 带伞")
        )

        let arguments = await captured.value

        XCTAssertEqual(result.status, LuminaToolResultStatus.failed)
        XCTAssertTrue(arguments.isEmpty)
        XCTAssertTrue(result.errorMessage?.contains("missing required parameter title") == true)
    }

    func testToolRouterRejectsFileUpdateAliasesWithoutRequiredFilename() async {
        let schema = LuminaToolSchema(
            name: "file.update_note",
            description: "Update note",
            parameters: [
                LuminaToolParameterSchema(name: "filename", type: .string, description: "Filename."),
                LuminaToolParameterSchema(name: "body", type: .string, description: "Body."),
                LuminaToolParameterSchema(name: "mode", type: .string, description: "Mode.", required: false)
            ],
            sideEffect: .readOnly
        )
        let captured = ArgumentBox()
        let tool = AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await captured.set(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "file.update_note", status: .succeeded)
        }
        let router = LuminaToolRouter(tools: [tool])

        let (result, _, _) = await router.execute(
            call: LuminaToolCall(
                toolName: "file.update_note",
                arguments: [
                    "note": .string("LuminaTest-daily.md"),
                    "update": .string("今天的进展")
                ]
            ),
            request: LuminaAgentRequest(text: "给 LuminaTest-daily.md 追加今天的进展")
        )

        let arguments = await captured.value

        XCTAssertEqual(result.status, LuminaToolResultStatus.failed)
        XCTAssertTrue(arguments.isEmpty)
        XCTAssertTrue(result.errorMessage?.contains("missing required parameter filename") == true)
    }

    func testToolRouterRejectsLedgerRecordAliasesWithoutRequiredMemo() async {
        let schema = LuminaToolSchema(
            name: "ledger.record",
            description: "Record ledger",
            parameters: [
                LuminaToolParameterSchema(name: "memo", type: .string, description: "Memo."),
                LuminaToolParameterSchema(name: "amount", type: .number, description: "Amount.", required: false)
            ],
            sideEffect: .readOnly
        )
        let captured = ArgumentBox()
        let tool = AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await captured.set(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "ledger.record", status: .succeeded)
        }
        let router = LuminaToolRouter(tools: [tool])

        let (result, _, _) = await router.execute(
            call: LuminaToolCall(
                toolName: "ledger.record",
                arguments: [
                    "note": .string("LuminaTest 咖啡"),
                    "amount": .string("42")
                ]
            ),
            request: LuminaAgentRequest(text: "记录 42 元 LuminaTest 咖啡支出")
        )

        let arguments = await captured.value

        XCTAssertEqual(result.status, LuminaToolResultStatus.failed)
        XCTAssertTrue(arguments.isEmpty)
        XCTAssertTrue(result.errorMessage?.contains("missing required parameter memo") == true)
    }

    func testToolRouterPassesLedgerUpdateObjectAliasesThrough() async {
        let schema = LuminaToolSchema(
            name: "ledger.update",
            description: "Update ledger",
            parameters: [
                LuminaToolParameterSchema(name: "id", type: .string, description: "ID."),
                LuminaToolParameterSchema(name: "memo", type: .string, description: "Memo.", required: false),
                LuminaToolParameterSchema(name: "amount", type: .number, description: "Amount.", required: false)
            ],
            sideEffect: .readOnly
        )
        let captured = ArgumentBox()
        let tool = AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await captured.set(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "ledger.update", status: .succeeded)
        }
        let router = LuminaToolRouter(tools: [tool])

        let (result, _, _) = await router.execute(
            call: LuminaToolCall(
                toolName: "ledger.update",
                arguments: [
                    "id": .string("ledger-1"),
                    "query": .string("LuminaTest 咖啡"),
                    "update": .object(["amount": .number(40)])
                ]
            ),
            request: LuminaAgentRequest(text: "把 LuminaTest 咖啡金额改成 40 元")
        )

        let arguments = await captured.value

        XCTAssertEqual(result.status, LuminaToolResultStatus.succeeded)
        XCTAssertEqual(arguments["id"]?.stringValue, "ledger-1")
        XCTAssertNil(arguments["amount"]?.numberValue)
        XCTAssertNotNil(arguments["update"])
    }

    func testToolRouterRejectsLedgerUpdateQueryWithoutRequiredID() async {
        let schema = LuminaToolSchema(
            name: "ledger.update",
            description: "Update ledger",
            parameters: [
                LuminaToolParameterSchema(name: "id", type: .string, description: "ID."),
                LuminaToolParameterSchema(name: "amount", type: .number, description: "Amount.", required: false)
            ],
            sideEffect: .readOnly
        )
        let captured = ArgumentBox()
        let tool = AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await captured.set(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "ledger.update", status: .succeeded)
        }
        let router = LuminaToolRouter(tools: [tool])

        let (result, _, _) = await router.execute(
            call: LuminaToolCall(
                toolName: "ledger.update",
                arguments: [
                    "query": .string("LuminaTest 咖啡"),
                    "update": .object(["amount": .number(40)])
                ]
            ),
            request: LuminaAgentRequest(text: "把 LuminaTest 咖啡账目金额改成 40 元")
        )

        let arguments = await captured.value

        XCTAssertEqual(result.status, LuminaToolResultStatus.failed)
        XCTAssertTrue(arguments.isEmpty)
        XCTAssertTrue(result.errorMessage?.contains("missing required parameter id") == true)
    }

    func testToolRouterRejectsContactUpdateQueryWithoutRequiredName() async {
        let schema = LuminaToolSchema(
            name: "contacts.update",
            description: "Update contact",
            parameters: [
                LuminaToolParameterSchema(name: "name", type: .string, description: "Name."),
                LuminaToolParameterSchema(name: "email", type: .string, description: "Email.")
            ],
            sideEffect: .readOnly
        )
        let captured = ArgumentBox()
        let tool = AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await captured.set(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "contacts.update", status: .succeeded)
        }
        let router = LuminaToolRouter(tools: [tool])

        let (result, _, _) = await router.execute(
            call: LuminaToolCall(
                toolName: "contacts.update",
                arguments: [
                    "query": .string("LuminaTest test"),
                    "email": .string("test@example.com")
                ]
            ),
            request: LuminaAgentRequest(text: "给 LuminaTest test 加一个邮箱 test@example.com")
        )

        let arguments = await captured.value

        XCTAssertEqual(result.status, LuminaToolResultStatus.failed)
        XCTAssertTrue(arguments.isEmpty)
        XCTAssertTrue(result.errorMessage?.contains("missing required parameter name") == true)
    }

    func testToolRouterPassesCalendarAvailabilityArgumentsThrough() async {
        let schema = LuminaToolSchema(
            name: "calendar.availability",
            description: "Check availability",
            parameters: [
                LuminaToolParameterSchema(name: "startDateISO", type: .dateISO8601, description: "Start date."),
                LuminaToolParameterSchema(name: "endDateISO", type: .dateISO8601, description: "End date.")
            ],
            sideEffect: .readOnly
        )
        let captured = ArgumentBox()
        let tool = AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await captured.set(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "calendar.availability", status: .succeeded)
        }
        let router = LuminaToolRouter(tools: [tool])

        let (result, _, _) = await router.execute(
            call: LuminaToolCall(
                toolName: "calendar.availability",
                arguments: [
                    "startDateISO": .string("2026-06-05T00:00:00+08:00"),
                    "endDateISO": .string("2026-06-05T00:30:00+08:00")
                ]
            ),
            request: LuminaAgentRequest(text: "我明天下午三点到四点有空吗")
        )

        let arguments = await captured.value
        XCTAssertEqual(result.status, LuminaToolResultStatus.succeeded)
        XCTAssertEqual(arguments["startDateISO"]?.stringValue, "2026-06-05T00:00:00+08:00")
        XCTAssertEqual(arguments["endDateISO"]?.stringValue, "2026-06-05T00:30:00+08:00")
    }

    func testToolRouterPassesCalendarUpdateArgumentsThrough() async {
        let schema = LuminaToolSchema(
            name: "calendar.update",
            description: "Update calendar event",
            parameters: [
                LuminaToolParameterSchema(name: "id", type: .string, description: "Event id."),
                LuminaToolParameterSchema(name: "startDateISO", type: .dateISO8601, description: "Start date."),
                LuminaToolParameterSchema(name: "endDateISO", type: .dateISO8601, description: "End date.")
            ],
            sideEffect: .readOnly
        )
        let captured = ArgumentBox()
        let tool = AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await captured.set(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "calendar.update", status: .succeeded)
        }
        let router = LuminaToolRouter(tools: [tool])

        let (result, _, _) = await router.execute(
            call: LuminaToolCall(
                toolName: "calendar.update",
                arguments: [
                    "id": .string("event-1"),
                    "startDateISO": .string("2026-06-05T07:00:00+08:00"),
                    "endDateISO": .string("2026-06-05T07:15:00+08:00")
                ]
            ),
            request: LuminaAgentRequest(text: "把 LuminaTest 明天 7 点的日程改成 7 点半")
        )

        let arguments = await captured.value
        XCTAssertEqual(result.status, LuminaToolResultStatus.succeeded)
        XCTAssertEqual(arguments["startDateISO"]?.stringValue, "2026-06-05T07:00:00+08:00")
        XCTAssertEqual(arguments["endDateISO"]?.stringValue, "2026-06-05T07:15:00+08:00")
    }

    func testRuntimeExecutesModelToolArgumentsWithoutAnnotation() async {
        let schema = LuminaToolSchema(
            name: "calendar.create",
            description: "Create event",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "Title."),
                LuminaToolParameterSchema(name: "startDateISO", type: .dateISO8601, description: "Start date."),
                LuminaToolParameterSchema(name: "endDateISO", type: .dateISO8601, description: "End date.")
            ],
            sideEffect: .readOnly
        )
        let captured = ArgumentBox()
        let tool = AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await captured.set(arguments)
            return LuminaToolResult(
                callID: UUID(),
                toolName: "calendar.create",
                status: .succeeded,
                output: ["title": arguments["title"] ?? .string("")]
            )
        }
        let model = ScriptedReActModel(steps: [
            .action(
                thought: "Create event.",
                call: LuminaToolCall(
                    toolName: "calendar.create",
                    arguments: [
                        "title": .string("LuminaTest 去上厕所"),
                        "startDateISO": .string("2026-06-05T07:00:00+08:00"),
                        "endDateISO": .string("2026-06-05T07:30:00+08:00")
                    ],
                    requiresConfirmation: false
                )
            ),
            .result("done")
        ])
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: luminaTestRuntimeConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "创建明天上午 7 点的日程：LuminaTest 去上厕所"))

        let arguments = await captured.value
        let output = result.toolResults.first?.output

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(arguments["startDateISO"]?.stringValue, "2026-06-05T07:00:00+08:00")
        XCTAssertEqual(arguments["endDateISO"]?.stringValue, "2026-06-05T07:30:00+08:00")
        XCTAssertNil(output?["_executed_arguments"])
    }

    func testRuntimeHookOrderIsObservable() async {
        let hook = RecordingRuntimeHook()
        let runtime = LuminaAgentRuntime(
            tools: [],
            stepGenerator: ScriptedReActModel(steps: [.result("done")]),
            configuration: luminaTestRuntimeConfiguration,
            hooks: [hook]
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "hello"))
        let events = await hook.events

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(events.starts(with: [
            .runStarted,
            .contextLoaded,
            .stepContextReady,
            .beforeModel,
            .afterModel,
            .beforeNormalization,
            .afterNormalization,
            .stepProduced,
            .resultGenerated
        ]))
        XCTAssertEqual(events.last, .runEnded)
    }

    func testRuntimeHookCanAppendContextBeforeModel() async {
        let runtime = LuminaAgentRuntime(
            tools: [],
            stepGenerator: ContextAwareReActModel(),
            configuration: luminaTestRuntimeConfiguration,
            hooks: [AppendingContextHook()]
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "use hook context"))

        XCTAssertTrue(result.plan.summary.contains("hook supplied context"))
    }

    func testRuntimeHookFailureFailsRun() async {
        let runtime = LuminaAgentRuntime(
            tools: [],
            stepGenerator: ScriptedReActModel(steps: [.result("done")]),
            configuration: luminaTestRuntimeConfiguration,
            hooks: [FailingRuntimeHook()]
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "hello"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.plan.summary.contains("hook failed"))
    }

    func testAgentRuntimeTargetDoesNotReferencePersonalMemoryOrMemoryToolNames() throws {
        let runtimeRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/LuminaAgentRuntimeCore")
        let enumerator = FileManager.default.enumerator(at: runtimeRoot, includingPropertiesForKeys: nil)
        var swiftFiles: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                swiftFiles.append(url)
            }
        }

        for file in swiftFiles {
            let contents = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(contents.contains("import PersonalMemory"), "\(file.path) imports PersonalMemory")
            XCTAssertFalse(contents.contains("memory.ingest_text"), "\(file.path) contains an app memory tool name")
        }
    }

    func testRuntimeAutoCompactsTraceNearContextBudgetAndPreservesToolBudget() async {
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(
                callID: UUID(),
                toolName: "local.search",
                status: .succeeded,
                content: [.markdown(String(repeating: "本地检索结果很长。", count: 180))]
            )
        }
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: BudgetAwareReActModel(),
            configuration: luminaTestRuntimeConfiguration(
                maximumToolCalls: 2,
                maximumReActIterations: 8,
                maximumObservationCharacters: 900,
                contextWindowTokens: 225,
                compactThresholdTokens: 180,
                preservedStepsAfterCompaction: 0
            )
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "连续检索两次"))

        XCTAssertEqual(result.toolResults.count, 2)
        XCTAssertEqual(result.reactTrace?.actionCount, 2)
        XCTAssertTrue((result.reactTrace?.compactionCount ?? 0) > 0)
        XCTAssertTrue(result.reactTrace?.observations.contains(where: { $0.toolName == "runtime.context_compaction" }) == true)
        XCTAssertTrue(result.plan.summary.contains("compactions="))
    }

    func testValidationFailureCanBeReplayedForIdenticalToolCall() async {
        let schema = LuminaToolSchema(
            name: "calendar.delete",
            description: "Delete event",
            parameters: [
                LuminaToolParameterSchema(name: "id", type: .string, description: "Event identifier.")
            ],
            sideEffect: .systemWrite
        )
        let tool = AnyLuminaAgentTool(schema: schema) { _, _ in
            XCTFail("Validation failure should happen before the tool callback.")
            return LuminaToolResult(callID: UUID(), toolName: "calendar.delete", status: .failed)
        }
        let model = ScriptedReActModel(steps: [
            .action(thought: "Try delete.", call: LuminaToolCall(toolName: "calendar.delete", arguments: [:])),
            .action(thought: "Repeat delete.", call: LuminaToolCall(toolName: "calendar.delete", arguments: [:])),
            .result("done")
        ])
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: model,
            configuration: luminaTestRuntimeConfiguration(maximumConsecutiveReplayObservations: 2)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "delete"))
        let replayed = result.toolResults.filter { $0.output["replayed"]?.boolValue == true }

        XCTAssertEqual(result.toolResults.count, 2)
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed.first?.toolName, "calendar.delete")
    }

    func testCallerKeyedSideEffectReplaysWithoutExplicitInstanceKey() async {
        let schema = LuminaToolSchema(
            name: "reminder.create",
            description: "Create reminder",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "Reminder title."),
                LuminaToolParameterSchema(name: "dueDateISO", type: .string, description: "Due date.", required: false)
            ],
            sideEffect: .systemWrite,
            idempotencyPolicy: "caller_keyed"
        )
        let calls = ActorBox(0)
        let tool = AnyLuminaAgentTool(schema: schema) { _, _ in
            await calls.increment()
            return LuminaToolResult(callID: UUID(), toolName: "reminder.create", status: .succeeded, content: [.text("created")])
        }
        let model = ScriptedReActModel(steps: [
            .action(thought: "Create.", call: LuminaToolCall(toolName: "reminder.create", arguments: ["title": .string("LuminaTest"), "dueDateISO": .string("2026-06-15T08:00:00Z")])),
            .action(thought: "Try again with drifted date.", call: LuminaToolCall(toolName: "reminder.create", arguments: ["title": .string("LuminaTest"), "dueDateISO": .string("2026-06-16T08:00:00Z")])),
            .result("done")
        ])
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: model,
            configuration: luminaTestRuntimeConfiguration(maximumConsecutiveReplayObservations: 3)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "create reminder"))
        let replayed = result.toolResults.filter { $0.output["replayed"]?.boolValue == true }
        let callCount = await calls.value

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(result.toolResults.count, 2)
        XCTAssertEqual(replayed.count, 1)
    }

    func testCallerKeyedSideEffectAllowsDistinctInstanceKeys() async {
        let schema = LuminaToolSchema(
            name: "reminder.create",
            description: "Create reminder",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "Reminder title."),
                LuminaToolParameterSchema(name: "instance_id", type: .string, description: "Distinct requested instance.", required: false)
            ],
            sideEffect: .systemWrite,
            idempotencyPolicy: "caller_keyed"
        )
        let calls = ActorBox(0)
        let tool = AnyLuminaAgentTool(schema: schema) { _, _ in
            await calls.increment()
            return LuminaToolResult(callID: UUID(), toolName: "reminder.create", status: .succeeded, content: [.text("created")])
        }
        let model = ScriptedReActModel(steps: [
            .action(thought: "Create first.", call: LuminaToolCall(toolName: "reminder.create", arguments: ["title": .string("LuminaTest"), "instance_id": .string("one")])),
            .action(thought: "Create second.", call: LuminaToolCall(toolName: "reminder.create", arguments: ["title": .string("LuminaTest"), "instance_id": .string("two")])),
            .result("done")
        ])
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: model,
            configuration: luminaTestRuntimeConfiguration()
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "create two reminders"))
        let callCount = await calls.value

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(result.toolResults.count, 2)
        XCTAssertFalse(result.toolResults.contains { $0.output["replayed"]?.boolValue == true })
    }

    func testReActParserPreservesUnknownToolForRuntimeObservation() throws {
        let json = """
        {"type":"tool_use","thinking":"x","tool_name":"missing","parameters":{},"requires_confirmation":false}
        """

        let step = try LuminaReActStepParser.parse(json: json, availableTools: [])
        XCTAssertEqual(step.kind, .action)
        XCTAssertEqual(step.action?.toolName, "missing")
    }

    func testReActParserParsesStandardFinalAnswerShape() throws {
        let step = try LuminaReActStepParser.parse(
            json: """
            {"type":"result","content":"## 完成\\n\\n已处理。"}
            """,
            availableTools: []
        )

        XCTAssertEqual(step.kind, .result)
        XCTAssertEqual(step.resultMarkdown, "## 完成\n\n已处理。")
    }

    func testReActParserAcceptsCompleteStructuredTransportSteps() throws {
        let askUserSchema = LuminaToolSchema(name: "ask_user", description: "Ask user", parameters: [], sideEffect: .readOnly)
        let reasoning = try LuminaReActStepParser.parse(
            json: """
            {"schema_version":"1.0","step_id":"s1","type":"reasoning","thinking":"Need one more detail.","confidence":0.72,"needs_more_context":true,"requires_followup":true}
            """,
            availableTools: []
        )
        XCTAssertEqual(reasoning.kind, .thought)

        let ask = try LuminaReActStepParser.parse(
            json: """
            {"schema_version":"1.0","step_id":"s2","type":"ask_user","thinking":"Need a preference.","questions":[{"id":"time","question":"几点？"}],"allow_custom_answer":true,"requires_followup":true}
            """,
            availableTools: [askUserSchema]
        )
        XCTAssertEqual(ask.action?.toolName, "ask_user")

        let cannotComplete = try LuminaReActStepParser.parse(
            json: """
            {"schema_version":"1.0","step_id":"s3","type":"cannot_complete","thinking":"No permission.","reason":"缺少权限。","recoverable_actions":["打开设置"],"requires_followup":false}
            """,
            availableTools: []
        )
        XCTAssertEqual(cannotComplete.kind, .result)
        XCTAssertTrue(cannotComplete.resultMarkdown?.contains("缺少权限") == true)
    }

    func testReActParserRejectsLegacyActionShape() throws {
        let json = """
        {"kind":"action","thinking":"x","action":{"toolName":"local.search","arguments":{},"requiresConfirmation":false}}
        """

        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: json,
            availableTools: [LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)]
        ))
    }

    func testReActParserRejectsLegacyThoughtStepType() throws {
        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: """
            {"type":"thinking","thinking":"old step name","requires_followup":true}
            """,
            availableTools: []
        ))
    }

    func testReActParserAcceptsFlatToolUseShape() throws {
        let schema = LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)

        let step = try LuminaReActStepParser.parse(
            json: """
            {"type":"tool_use","thinking":"x","tool_name":"local.search","parameters":{"query":"coffee"},"requires_confirmation":false}
            """,
            availableTools: [schema]
        )

        XCTAssertEqual(step.action?.toolName, "local.search")
        XCTAssertEqual(step.action?.arguments["query"], .string("coffee"))
    }

    func testReActParserAcceptsMultiToolUseShape() throws {
        let schemas = [
            LuminaToolSchema(name: "device.current_time", description: "Time", parameters: [], sideEffect: .readOnly),
            LuminaToolSchema(name: "network.status", description: "Network", parameters: [], sideEffect: .readOnly)
        ]
        let step = try LuminaReActStepParser.parse(
            json: """
            {"type":"multi_tool_use","thinking":"Gather both signals.","tool_calls":[{"tool_name":"device.current_time","parameters":{},"requires_confirmation":false},{"tool_name":"network.status","parameters":{},"requires_confirmation":true}]}
            """,
            availableTools: schemas
        )

        XCTAssertEqual(step.kind, .multiAction)
        XCTAssertEqual(step.toolCalls.map(\.toolName), ["device.current_time", "network.status"])
        XCTAssertTrue(step.toolCalls[1].requiresConfirmation)
    }

    func testReActParserRejectsMalformedMultiToolUseShape() throws {
        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: "{\"type\":\"multi_tool_use\",\"tool_calls\":[]}",
            availableTools: []
        ))
        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: "{\"type\":\"multi_tool_use\",\"tool_calls\":[{\"tool_name\":\"device.current_time\",\"parameters\":\"not-an-object\"}]}",
            availableTools: []
        ))
    }

    func testRuntimeExecutesReadOnlyMultiToolCallsInOrder() async {
        let first = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "device.current_time", description: "Time", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "device.current_time", status: .succeeded, content: [.text("10:00")])
        }
        let second = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "network.status", description: "Network", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "network.status", status: .succeeded, content: [.text("online")])
        }
        let runtime = LuminaAgentRuntime(
            tools: [first, second],
            stepGenerator: ScriptedReActModel(steps: [
                .multiAction(thought: "Gather", calls: [
                    LuminaToolCall(toolName: "device.current_time", arguments: [:]),
                    LuminaToolCall(toolName: "network.status", arguments: [:])
                ]),
                .result("done")
            ]),
            configuration: luminaTestRuntimeConfiguration(yoloMode: true)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "check time and network"))

        XCTAssertEqual(result.toolResults.map(\.toolName), ["device.current_time", "network.status"])
        XCTAssertTrue(result.toolResults.allSatisfy { $0.status == .succeeded })
    }

    func testReadOnlyMultiToolFailureContinuesToRemainingCalls() async {
        let first = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "device.current_time", description: "Time", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "device.current_time", status: .failed, errorMessage: "clock unavailable")
        }
        let second = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "network.status", description: "Network", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "network.status", status: .succeeded)
        }
        let runtime = LuminaAgentRuntime(
            tools: [first, second],
            stepGenerator: ScriptedReActModel(steps: [
                .multiAction(thought: "Gather", calls: [
                    LuminaToolCall(toolName: "device.current_time", arguments: [:]),
                    LuminaToolCall(toolName: "network.status", arguments: [:])
                ]),
                .result("done")
            ]),
            configuration: luminaTestRuntimeConfiguration(yoloMode: true)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "check time and network"))

        XCTAssertEqual(result.toolResults.map(\.toolName), ["device.current_time", "network.status"])
        XCTAssertEqual(result.toolResults.first?.status, .failed)
        XCTAssertEqual(result.toolResults.last?.status, .succeeded)
    }

    func testSideEffectMultiToolFailureStopsRemainingCalls() async {
        let calls = ActorBox(0)
        let first = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "calendar.create", description: "Create", parameters: [], sideEffect: .systemWrite)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "calendar.create", status: .failed, errorMessage: "calendar unavailable")
        }
        let second = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "reminder.create", description: "Create", parameters: [], sideEffect: .systemWrite)) { _, _ in
            await calls.increment()
            return LuminaToolResult(callID: UUID(), toolName: "reminder.create", status: .succeeded)
        }
        let runtime = LuminaAgentRuntime(
            tools: [first, second],
            stepGenerator: ScriptedReActModel(steps: [
                .multiAction(thought: "Write both", calls: [
                    LuminaToolCall(toolName: "calendar.create", arguments: [:]),
                    LuminaToolCall(toolName: "reminder.create", arguments: [:])
                ]),
                .result("done")
            ]),
            configuration: luminaTestRuntimeConfiguration(yoloMode: true)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "write both"))

        let executedSecond = await calls.value
        XCTAssertEqual(executedSecond, 0)
        XCTAssertEqual(result.toolResults.map(\.toolName), ["calendar.create"])
        XCTAssertEqual(result.toolResults.first?.status, .failed)
    }

    func testMultiToolIgnoresInternalRuntimeCallsWhenConfigured() async {
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "network.status", description: "Network", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "network.status", status: .succeeded)
        }
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: ScriptedReActModel(steps: [
                .multiAction(thought: "Use helper and task tool", calls: [
                    LuminaToolCall(toolName: "runtime.mcp_discovery", arguments: [:]),
                    LuminaToolCall(toolName: "network.status", arguments: [:])
                ]),
                .result("done")
            ]),
            configuration: luminaTestRuntimeConfiguration(yoloMode: true, ignoreInternalToolCalls: true)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "check network"))

        XCTAssertEqual(result.toolResults.map(\.toolName), ["network.status"])
        XCTAssertFalse(result.toolResults.contains { $0.toolName.hasPrefix("runtime.") })
    }

    func testReActParserRejectsNonStandardToolCallAliases() throws {
        let schema = LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)

        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: """
            {"type":"tool_use","thinking":"x","tool_call":{"name":"local.search","parameters":{}}}
            """,
            availableTools: [schema]
        ))

        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: """
            {"type":"tool_call","function":"local.search()","args":{}}
            """,
            availableTools: [schema]
        ))

        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: """
            {"type":"tool_use","reasoning":"x","tool_name":"local.search","parameters":{},"requires_confirmation":false}
            """,
            availableTools: [schema]
        ))

        XCTAssertThrowsError(try LuminaReActStepParser.parse(
            json: """
            {"type":"tool_use","thinking":"x","tool_use":{"name":"local.search","input":{},"requires_confirmation":false}}
            """,
            availableTools: [schema]
        ))
    }

    func testIterationLimitReturnsMarkdownResult() async {
        let model = ScriptedReActModel(steps: [.thought("still thinking"), .thought("again")])
        let runtime = LuminaAgentRuntime(
            tools: [],
            stepGenerator: model,
            configuration: luminaTestRuntimeConfiguration(maximumToolCalls: 2, maximumReActIterations: 1)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "do it"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.reactTrace?.terminationReason, "budget")
        XCTAssertTrue(result.plan.summary.contains("执行预算"))
    }

    func testReActFinalDoesNotNestMarkdownHeadingInsideListItem() async {
        let model = StaticReActModel(toolName: "device.current_time")
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "device.current_time", description: "Current time", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(
                callID: UUID(),
                toolName: "device.current_time",
                status: .succeeded,
                output: ["localizedTime": .string("10:41")],
                content: [.markdown("### 本机时间\n\n- 时间：10:41")]
            )
        }
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: luminaTestRuntimeConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "现在几点"))

        XCTAssertFalse(result.plan.summary.contains("- **device.current_time**: ###"))
        XCTAssertTrue(result.plan.summary.contains("## 执行结果"))
        XCTAssertTrue(result.plan.summary.contains("### 本机时间"))
        XCTAssertFalse(result.plan.summary.contains("localizedTime"))
    }

    func testReActFinalDeduplicatesRepeatedObservations() async {
        let model = StaticReActModel(toolName: "local.search")
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(
                callID: UUID(),
                toolName: "local.search",
                status: .succeeded,
                output: ["results": .array([])],
                content: [.markdown("### 本地检索结果\n\n没有找到结果。")]
            )
        }
        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: model,
            configuration: luminaTestRuntimeConfiguration(maximumToolCalls: 3)
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "查本地数据"))

        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertEqual(result.plan.summary.components(separatedBy: "### 本地检索结果").count - 1, 1)
        XCTAssertFalse(result.plan.summary.contains("results"))
    }
}

final class AgentRuntimePerformanceTests: XCTestCase {
    func testRunStreamFirstEventLatency() async {
        let runtime = LuminaAgentRuntime(tools: [], stepGenerator: LuminaUnavailableReActStepGenerator(), configuration: luminaTestRuntimeConfiguration)
        let start = ContinuousClock.now
        var firstEventMilliseconds = Double.greatestFiniteMagnitude

        for await _ in runtime.runStream(request: LuminaAgentRequest(text: "hello")) {
            firstEventMilliseconds = TestClock.milliseconds(since: start)
            break
        }

        XCTAssertLessThan(firstEventMilliseconds, PerformanceBudget.strict ? 50 : 500)
    }

    func testNoAvailableModelFailsRunInsteadOfCompleting() async {
        let runtime = LuminaAgentRuntime(tools: [], stepGenerator: LuminaUnavailableReActStepGenerator(), configuration: luminaTestRuntimeConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "帮我创建提醒"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.plan.summary.contains("No available ReAct step generator"))
        XCTAssertTrue(result.toolResults.isEmpty)
    }

    func testMockReActReadOnlyRunLatency() async {
        let tool = AnyLuminaAgentTool(schema: LuminaToolSchema(name: "local.search", description: "Search", parameters: [], sideEffect: .readOnly)) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "local.search", status: .succeeded)
        }
        var samples: [Double] = []

        for _ in 0..<20 {
            let model = ScriptedReActModel(steps: [
                .action(thought: "search", call: LuminaToolCall(toolName: "local.search", arguments: [:])),
                .result("done")
            ])
            let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: luminaTestRuntimeConfiguration)
            let start = ContinuousClock.now
            _ = await runtime.run(request: LuminaAgentRequest(text: "查"))
            samples.append(TestClock.milliseconds(since: start))
        }

        XCTAssertLessThan(samples.percentile95, PerformanceBudget.strict ? 180 : 800)
    }

    func testCancellationLatencyForSlowModel() async {
        let runtime = LuminaAgentRuntime(tools: [], stepGenerator: SlowReActModel(delayNanoseconds: 2_000_000_000), configuration: luminaTestRuntimeConfiguration)
        let task = Task { await runtime.run(request: LuminaAgentRequest(text: "cancel")) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.value
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 100 : 500)
    }

}

private actor ScriptedReActModel: LuminaReActStepGenerator {
    private var steps: [LuminaReActStep]

    init(steps: [LuminaReActStep]) {
        self.steps = steps
    }

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        guard !steps.isEmpty else { return .result("done") }
        return steps.removeFirst()
    }
}

private struct SlowReActModel: LuminaReActStepGenerator {
    var delayNanoseconds: UInt64

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return .result("done")
    }
}

private struct StaticReActModel: LuminaReActStepGenerator {
    var toolName: String

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        guard context.trace.actionCount == 0 else {
            let observations = context.trace.observations.reduce(into: [LuminaReActObservation]()) { partial, observation in
                let signature = "\(observation.toolName)|\(observation.status.rawValue)|\(observation.summary)"
                guard !partial.contains(where: { "\($0.toolName)|\($0.status.rawValue)|\($0.summary)" == signature }) else { return }
                partial.append(observation)
            }
            let markdown = observations.map { observation in
                let summary = observation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                return summary.hasPrefix("#") ? summary : "### \(observation.toolName)\n\n\(summary)"
            }.joined(separator: "\n\n")
            return .result("## 执行结果\n\n\(markdown)")
        }
        return .action(thought: "static", call: LuminaToolCall(toolName: toolName, arguments: [:]))
    }
}

private actor CountingContextProvider: LuminaRuntimeContextProvider {
    private(set) var loadCount = 0

    func loadContext(_ request: LuminaRuntimeContextRequest) async throws -> LuminaRuntimeContext {
        loadCount += 1
        return LuminaRuntimeContext(sections: [
            LuminaRuntimeContextSection(
                id: "memory:real",
                title: "真实记忆",
                summary: "真实记忆摘要",
                content: "真实记忆摘要",
                source: "local/test",
                sensitivity: .normal,
                disclosureLevel: 0
            )
        ])
    }
}

private struct ContextAwareReActModel: LuminaReActStepGenerator {
    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        LuminaReActStep(kind: .result, resultMarkdown: context.loadedContext.sections.first?.summary ?? "missing context")
    }
}

private actor RecordingRuntimeHook: LuminaAgentRuntimeHook {
    private(set) var events: [LuminaAgentRuntimeHookEvent] = []

    func handle(
        event: LuminaAgentRuntimeHookEvent,
        context: LuminaAgentRuntimeHookContext
    ) async throws -> [LuminaAgentRuntimeHookDirective] {
        events.append(event)
        return []
    }
}

private struct AppendingContextHook: LuminaAgentRuntimeHook {
    func handle(
        event: LuminaAgentRuntimeHookEvent,
        context: LuminaAgentRuntimeHookContext
    ) async throws -> [LuminaAgentRuntimeHookDirective] {
        guard event == .stepContextReady else { return [] }
        return [
            .appendContextSection(LuminaRuntimeContextSection(
                id: "hook.context",
                title: "Hook Context",
                summary: "hook supplied context",
                content: "hook supplied context",
                source: "hook/test"
            ))
        ]
    }
}

private struct FailingRuntimeHook: LuminaAgentRuntimeHook {
    func handle(
        event: LuminaAgentRuntimeHookEvent,
        context: LuminaAgentRuntimeHookContext
    ) async throws -> [LuminaAgentRuntimeHookDirective] {
        if event == .runStarted {
            throw NSError(domain: "hook failed", code: 1)
        }
        return []
    }
}

private struct BudgetAwareReActModel: LuminaReActStepGenerator {
    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        guard context.trace.actionCount < 2 else {
            return .result("done compactions=\(context.trace.compactionCount)")
        }
        return .action(
            thought: "search",
            call: LuminaToolCall(toolName: "local.search", arguments: ["query": .string("budget")])
        )
    }
}

private actor ActorBox {
    private var storage: Int

    init(_ value: Int) {
        self.storage = value
    }

    var value: Int {
        storage
    }

    func increment() {
        storage += 1
    }
}

private actor ArgumentBox {
    private var storage: [String: LuminaJSONValue] = [:]

    var value: [String: LuminaJSONValue] {
        storage
    }

    func set(_ value: [String: LuminaJSONValue]) {
        storage = value
    }
}

private actor CountingDenyPermissionGate: LuminaPermissionGate {
    private var storage = 0

    var count: Int {
        storage
    }

    func decision(for call: LuminaToolCall, schema: LuminaToolSchema, request: LuminaAgentRequest) async -> LuminaPermissionDecision {
        storage += 1
        return .denied(reason: "blocked by test")
    }
}

private actor CountingDenyConfirmationCoordinator: LuminaConfirmationCoordinator {
    private var storage = 0

    var count: Int {
        storage
    }

    func confirm(call: LuminaToolCall, schema: LuminaToolSchema, reason: String) async -> Bool {
        storage += 1
        return false
    }
}

enum PerformanceBudget {
    static var strict: Bool {
        ProcessInfo.processInfo.environment["LUMINA_STRICT_PERF"] == "1"
    }
}

enum TestClock {
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}

private extension Array where Element == Double {
    var percentile95: Double {
        guard !isEmpty else { return 0 }
        let sortedValues = sorted()
        let index = Swift.min(sortedValues.count - 1, Int(Double(sortedValues.count - 1) * 0.95))
        return sortedValues[index]
    }
}
