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
        val event: EventSink = EventSink {},
        val audit: AuditSink = AuditSink {}
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

    fun interface EventSink {
        fun emit(eventJson: String)
    }

    fun interface AuditSink {
        fun append(auditJson: String)
    }

    private var nativeHandle: Long = Native.create(configurationJson, this)

    fun registerToolSchema(toolSchemaJson: String): String =
        Native.registerToolSchema(nativeHandle, toolSchemaJson)

    fun run(requestJson: String): String =
        Native.run(nativeHandle, requestJson)

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

    private fun emitEvent(eventJson: String) {
        providers.event.emit(eventJson)
    }

    private fun writeAudit(auditJson: String) {
        providers.audit.append(auditJson)
    }

    private object Native {
        init {
            System.loadLibrary("lumina_agent_runtime_android_jni")
        }

        external fun create(configurationJson: String, bridge: LuminaAgentRuntime): Long
        external fun destroy(handle: Long)
        external fun registerToolSchema(handle: Long, toolSchemaJson: String): String
        external fun run(handle: Long, requestJson: String): String
        external fun cancel(handle: Long, requestId: String?): String
        external fun exportContracts(): String
    }

    companion object {
        fun exportContracts(): String = Native.exportContracts()
    }
}

