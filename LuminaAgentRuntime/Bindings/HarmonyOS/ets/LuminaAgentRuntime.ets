export type LuminaRuntimeProviders = {
  model: (plannerInputJson: string) => string
  tool?: (toolCallJson: string) => string
  context?: (contextRequestJson: string) => string
  permission?: (permissionRequestJson: string) => string
  confirmation?: (confirmationRequestJson: string) => string
  event?: (eventJson: string) => void
  audit?: (auditJson: string) => void
}

type NativeRuntimeModule = {
  create(configurationJson: string, bridge: LuminaAgentRuntime): Object
  destroy(handle: Object): void
  registerToolSchema(handle: Object, toolSchemaJson: string): string
  run(handle: Object, requestJson: string): string
  cancel(handle: Object, requestId?: string): string
  exportContracts(): string
}

declare const luminaRuntimeNative: NativeRuntimeModule

export class LuminaAgentRuntime {
  private handle: Object | null

  constructor(
    configurationJson: string = '{}',
    private readonly providers: LuminaRuntimeProviders
  ) {
    this.handle = luminaRuntimeNative.create(configurationJson, this)
  }

  registerToolSchema(toolSchemaJson: string): string {
    return luminaRuntimeNative.registerToolSchema(this.requireHandle(), toolSchemaJson)
  }

  run(requestJson: string): string {
    return luminaRuntimeNative.run(this.requireHandle(), requestJson)
  }

  cancel(requestId?: string): string {
    return luminaRuntimeNative.cancel(this.requireHandle(), requestId)
  }

  close(): void {
    const handle = this.handle
    this.handle = null
    if (handle !== null) {
      luminaRuntimeNative.destroy(handle)
    }
  }

  provideModelStep(plannerInputJson: string): string {
    return this.providers.model(plannerInputJson)
  }

  executeTool(toolCallJson: string): string {
    return this.providers.tool?.(toolCallJson) ?? '{"status":"failed","content":"","errorMessage":"tool provider unavailable"}'
  }

  loadContext(contextRequestJson: string): string {
    return this.providers.context?.(contextRequestJson) ?? 'null'
  }

  decidePermission(permissionRequestJson: string): string {
    return this.providers.permission?.(permissionRequestJson) ?? '{"decision":"allowed"}'
  }

  confirm(confirmationRequestJson: string): string {
    return this.providers.confirmation?.(confirmationRequestJson) ?? '{"confirmed":false,"reason":"confirmation provider unavailable"}'
  }

  emitEvent(eventJson: string): void {
    this.providers.event?.(eventJson)
  }

  writeAudit(auditJson: string): void {
    this.providers.audit?.(auditJson)
  }

  static exportContracts(): string {
    return luminaRuntimeNative.exportContracts()
  }

  private requireHandle(): Object {
    if (this.handle === null) {
      throw new Error('LuminaAgentRuntime is closed')
    }
    return this.handle
  }
}
