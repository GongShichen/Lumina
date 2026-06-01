package dev.lumina.agent.runtime

class LuminaAgentRuntime(
    configurationJson: String = "{}",
    private val providers: Providers
) : AutoCloseable {
    data class Providers(
        val model: ModelProvider,
        val tool: ToolProvider = ToolProvider { """{"status":"failed","content":"","errorMessage":"tool provider unavailable"}""" },
        val context: ContextProvider = ContextProvider { "null" },
        val permission: PermissionProvider = PermissionProvider { """{"decision":"allowed"}""" },
        val confirmation: ConfirmationProvider = ConfirmationProvider { """{"confirmed":false,"reason":"confirmation provider unavailable"}""" },
        val guardrail: GuardrailProvider = GuardrailProvider { """{"decision":"allow"}""" },
        val hook: HookProvider = HookProvider { "{}" },
        val event: EventSink = EventSink {},
        val audit: AuditSink = AuditSink {},
        val trace: TraceSink = TraceSink {},
        val metrics: MetricsSink = MetricsSink {},
        val span: SpanSink = SpanSink {}
    )

    fun interface ModelProvider {
        fun nextStep(plannerInputJson: String): String
    }

    fun interface ToolProvider {
        fun execute(toolCallJson: String): String
    }

    fun interface ContextProvider {
        fun load(contextRequestJson: String): String
    }

    fun interface PermissionProvider {
        fun decide(permissionRequestJson: String): String
    }

    fun interface ConfirmationProvider {
        fun confirm(confirmationRequestJson: String): String
    }

    fun interface GuardrailProvider {
        fun evaluate(guardrailRequestJson: String): String
    }

    fun interface HookProvider {
        fun dispatch(hookEventJson: String): String
    }

    fun interface EventSink {
        fun emit(eventJson: String)
    }

    fun interface AuditSink {
        fun append(auditJson: String)
    }

    fun interface TraceSink {
        fun append(traceJson: String)
    }

    fun interface MetricsSink {
        fun append(metricJson: String)
    }

    fun interface SpanSink {
        fun append(spanJson: String)
    }

    private var nativeHandle: Long = Native.create(configurationJson, this)

    fun registerToolSchema(toolSchemaJson: String): String =
        Native.registerToolSchema(nativeHandle, toolSchemaJson)

    fun registerExternalToolProvider(providerJson: String): String =
        Native.registerExternalToolProvider(nativeHandle, providerJson)

    fun registerHookRoute(routeJson: String): String =
        Native.registerHookRoute(nativeHandle, routeJson)

    fun run(requestJson: String): String =
        Native.run(nativeHandle, requestJson)

    fun runReplay(requestJson: String, replayJson: String): String =
        Native.runReplay(nativeHandle, requestJson, replayJson)

    fun createSession(requestJson: String): AgentSession =
        AgentSession(this, Native.createSession(nativeHandle, requestJson))

    fun createSessionFromCheckpoint(checkpointJson: String): AgentSession =
        AgentSession(this, Native.createSessionFromCheckpoint(nativeHandle, checkpointJson))

    fun cancel(requestId: String? = null): String =
        Native.cancel(nativeHandle, requestId)

    override fun close() {
        val handle = nativeHandle
        nativeHandle = 0
        if (handle != 0L) {
            Native.destroy(handle)
        }
    }

    private fun provideModelStep(plannerInputJson: String): String =
        providers.model.nextStep(plannerInputJson)

    private fun executeTool(toolCallJson: String): String =
        providers.tool.execute(toolCallJson)

    private fun loadContext(contextRequestJson: String): String =
        providers.context.load(contextRequestJson)

    private fun decidePermission(permissionRequestJson: String): String =
        providers.permission.decide(permissionRequestJson)

    private fun confirm(confirmationRequestJson: String): String =
        providers.confirmation.confirm(confirmationRequestJson)

    private fun evaluateGuardrail(guardrailRequestJson: String): String =
        providers.guardrail.evaluate(guardrailRequestJson)

    private fun dispatchHook(hookEventJson: String): String =
        providers.hook.dispatch(hookEventJson)

    private fun emitEvent(eventJson: String) {
        providers.event.emit(eventJson)
    }

    private fun writeAudit(auditJson: String) {
        providers.audit.append(auditJson)
    }

    private fun writeTrace(traceJson: String) {
        providers.trace.append(traceJson)
    }

    private fun writeMetric(metricJson: String) {
        providers.metrics.append(metricJson)
    }

    private fun writeSpan(spanJson: String) {
        providers.span.append(spanJson)
    }

    class AgentSession internal constructor(
        private val runtime: LuminaAgentRuntime,
        private var sessionHandle: Long
    ) : AutoCloseable {
        fun run(): String = Native.runSession(runtime.nativeHandle, sessionHandle)
        fun runReplay(replayJson: String): String = Native.runSessionReplay(runtime.nativeHandle, sessionHandle, replayJson)
        fun resume(observationJson: String): String = Native.resumeSession(runtime.nativeHandle, sessionHandle, observationJson)
        fun snapshot(): String = Native.snapshotSession(sessionHandle)
        fun exportCheckpoint(): String = Native.exportSessionCheckpoint(sessionHandle)
        fun setState(scope: String, key: String, valueJson: String): String =
            Native.sessionSetState(runtime.nativeHandle, sessionHandle, scope, key, valueJson)
        fun getState(scope: String, key: String): String =
            Native.sessionGetState(sessionHandle, scope, key)
        fun deleteState(scope: String, key: String): String =
            Native.sessionDeleteState(runtime.nativeHandle, sessionHandle, scope, key)

        override fun close() {
            val handle = sessionHandle
            sessionHandle = 0
            if (handle != 0L) {
                Native.destroySession(handle)
            }
        }
    }

    private object Native {
        init {
            System.loadLibrary("lumina_agent_runtime_android_jni")
        }

        external fun create(configurationJson: String, bridge: LuminaAgentRuntime): Long
        external fun destroy(handle: Long)
        external fun registerToolSchema(handle: Long, toolSchemaJson: String): String
        external fun registerExternalToolProvider(handle: Long, providerJson: String): String
        external fun registerHookRoute(handle: Long, routeJson: String): String
        external fun run(handle: Long, requestJson: String): String
        external fun runReplay(handle: Long, requestJson: String, replayJson: String): String
        external fun createSession(handle: Long, requestJson: String): Long
        external fun createSessionFromCheckpoint(handle: Long, checkpointJson: String): Long
        external fun runSession(handle: Long, sessionHandle: Long): String
        external fun runSessionReplay(handle: Long, sessionHandle: Long, replayJson: String): String
        external fun resumeSession(handle: Long, sessionHandle: Long, observationJson: String): String
        external fun snapshotSession(sessionHandle: Long): String
        external fun exportSessionCheckpoint(sessionHandle: Long): String
        external fun sessionSetState(handle: Long, sessionHandle: Long, scope: String, key: String, valueJson: String): String
        external fun sessionGetState(sessionHandle: Long, scope: String, key: String): String
        external fun sessionDeleteState(handle: Long, sessionHandle: Long, scope: String, key: String): String
        external fun destroySession(sessionHandle: Long)
        external fun cancel(handle: Long, requestId: String?): String
        external fun exportContracts(): String
    }

    companion object {
        fun exportContracts(): String = Native.exportContracts()
    }
}
