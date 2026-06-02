export type LuminaRuntimeProviders = {
  model: (plannerInputJson: string) => string
  modelMetadata?: (metadataRequestJson: string) => string
  tool?: (toolCallJson: string) => string
  context?: (contextRequestJson: string) => string
  permission?: (permissionRequestJson: string) => string
  confirmation?: (confirmationRequestJson: string) => string
  guardrail?: (guardrailRequestJson: string) => string
  compaction?: (compactionRequestJson: string) => string
  hook?: (hookEventJson: string) => string
  event?: (eventJson: string) => void
  audit?: (auditJson: string) => void
  trace?: (traceJson: string) => void
  metrics?: (metricJson: string) => void
  span?: (spanJson: string) => void
}

type NativeRuntimeModule = {
  create(configurationJson: string, bridge: LuminaAgentRuntime): Object
  destroy(handle: Object): void
  registerToolSchema(handle: Object, toolSchemaJson: string): string
  registerExternalToolProvider(handle: Object, providerJson: string): string
  registerHookRoute(handle: Object, routeJson: string): string
  run(handle: Object, requestJson: string): string
  runReplay(handle: Object, requestJson: string, replayJson: string): string
  createSession(handle: Object, requestJson: string): Object
  createSessionFromCheckpoint(handle: Object, checkpointJson: string): Object
  runSession(handle: Object, session: Object): string
  runSessionReplay(handle: Object, session: Object, replayJson: string): string
  resumeSession(handle: Object, session: Object, observationJson: string): string
  snapshotSession(session: Object): string
  exportSessionCheckpoint(session: Object): string
  sessionSetState(handle: Object, session: Object, scope: string, key: string, valueJson: string): string
  sessionGetState(session: Object, scope: string, key: string): string
  sessionDeleteState(handle: Object, session: Object, scope: string, key: string): string
  destroySession(session: Object): void
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

  registerExternalToolProvider(providerJson: string): string {
    return luminaRuntimeNative.registerExternalToolProvider(this.requireHandle(), providerJson)
  }

  registerHookRoute(routeJson: string): string {
    return luminaRuntimeNative.registerHookRoute(this.requireHandle(), routeJson)
  }

  run(requestJson: string): string {
    return luminaRuntimeNative.run(this.requireHandle(), requestJson)
  }

  runReplay(requestJson: string, replayJson: string): string {
    return luminaRuntimeNative.runReplay(this.requireHandle(), requestJson, replayJson)
  }

  createSession(requestJson: string): LuminaAgentRuntimeSession {
    return new LuminaAgentRuntimeSession(this.requireHandle(), luminaRuntimeNative.createSession(this.requireHandle(), requestJson))
  }

  createSessionFromCheckpoint(checkpointJson: string): LuminaAgentRuntimeSession {
    return new LuminaAgentRuntimeSession(this.requireHandle(), luminaRuntimeNative.createSessionFromCheckpoint(this.requireHandle(), checkpointJson))
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

  provideModelMetadata(metadataRequestJson: string): string {
    return this.providers.modelMetadata?.(metadataRequestJson) ?? '{}'
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

  evaluateGuardrail(guardrailRequestJson: string): string {
    return this.providers.guardrail?.(guardrailRequestJson) ?? '{"decision":"allow"}'
  }

  compactContext(compactionRequestJson: string): string {
    return this.providers.compaction?.(compactionRequestJson) ?? '{"status":"skipped"}'
  }

  dispatchHook(hookEventJson: string): string {
    return this.providers.hook?.(hookEventJson) ?? '{}'
  }

  emitEvent(eventJson: string): void {
    this.providers.event?.(eventJson)
  }

  writeAudit(auditJson: string): void {
    this.providers.audit?.(auditJson)
  }

  writeTrace(traceJson: string): void {
    this.providers.trace?.(traceJson)
  }

  writeMetric(metricJson: string): void {
    this.providers.metrics?.(metricJson)
  }

  writeSpan(spanJson: string): void {
    this.providers.span?.(spanJson)
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

export class LuminaAgentRuntimeSession {
  constructor(
    private readonly runtimeHandle: Object,
    private handle: Object | null
  ) {}

  run(): string {
    return luminaRuntimeNative.runSession(this.runtimeHandle, this.requireHandle())
  }

  runReplay(replayJson: string): string {
    return luminaRuntimeNative.runSessionReplay(this.runtimeHandle, this.requireHandle(), replayJson)
  }

  resume(observationJson: string): string {
    return luminaRuntimeNative.resumeSession(this.runtimeHandle, this.requireHandle(), observationJson)
  }

  snapshot(): string {
    return luminaRuntimeNative.snapshotSession(this.requireHandle())
  }

  exportCheckpoint(): string {
    return luminaRuntimeNative.exportSessionCheckpoint(this.requireHandle())
  }

  setState(scope: string, key: string, valueJson: string): string {
    return luminaRuntimeNative.sessionSetState(this.runtimeHandle, this.requireHandle(), scope, key, valueJson)
  }

  getState(scope: string, key: string): string {
    return luminaRuntimeNative.sessionGetState(this.requireHandle(), scope, key)
  }

  deleteState(scope: string, key: string): string {
    return luminaRuntimeNative.sessionDeleteState(this.runtimeHandle, this.requireHandle(), scope, key)
  }

  close(): void {
    const handle = this.handle
    this.handle = null
    if (handle !== null) {
      luminaRuntimeNative.destroySession(handle)
    }
  }

  private requireHandle(): Object {
    if (this.handle === null) {
      throw new Error('LuminaAgentRuntimeSession is closed')
    }
    return this.handle
  }
}
