from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

SCHEMA_VERSION = "lumina.agentic_rl.v1"


class LuminaModel(BaseModel):
    model_config = ConfigDict(extra="allow", populate_by_name=True)


class TaskPayload(LuminaModel):
    id: str
    instruction: str
    category: str
    expected_tools: list[str] = Field(alias="expectedTools")
    difficulty: str
    cleanup_prefixes: list[str] = Field(default_factory=list, alias="cleanupPrefixes")


class EnvironmentPayload(LuminaModel):
    app: str
    runtime: str
    schema_version: str = Field(alias="schemaVersion")
    local_only: bool = Field(alias="localOnly")


class MessagePayload(LuminaModel):
    role: str
    content: str


class TrajectoryStep(LuminaModel):
    type: Literal["thought", "action", "observation", "final"]
    content: str | None = None
    tool_name: str | None = Field(default=None, alias="toolName")
    parameters: dict[str, Any] | None = None
    observation_status: str | None = Field(default=None, alias="observationStatus")
    elapsed_milliseconds: float = Field(default=0.0, alias="elapsedMilliseconds")


class OutcomePayload(LuminaModel):
    status: str
    reward: float
    tool_precision: float = Field(alias="toolPrecision")
    tool_recall: float = Field(alias="toolRecall")
    tool_f1: float = Field(alias="toolF1")
    active_runtime_milliseconds: float = Field(alias="activeRuntimeMilliseconds")
    wall_clock_milliseconds: float = Field(alias="wallClockMilliseconds")
    confirmation_wait_milliseconds: float = Field(alias="confirmationWaitMilliseconds")
    system_permission_wait_milliseconds: float = Field(alias="systemPermissionWaitMilliseconds")
    total_milliseconds: float = Field(alias="totalMilliseconds")
    step_generation_milliseconds: float = Field(alias="stepGenerationMilliseconds")
    tool_milliseconds: float = Field(alias="toolMilliseconds")
    memory_access_disabled: bool = Field(alias="memoryAccessDisabled")
    failure_summary: str | None = Field(default=None, alias="failureSummary")


class TrajectoryRecord(LuminaModel):
    id: str
    schema_version: str = Field(alias="schemaVersion")
    created_at: datetime = Field(alias="createdAt")
    task: TaskPayload
    environment: EnvironmentPayload
    messages: list[MessagePayload]
    steps: list[TrajectoryStep]
    actual_tools: list[str] = Field(alias="actualTools")
    outcome: OutcomePayload
    model_metrics: list[dict[str, Any]] = Field(default_factory=list, alias="modelMetrics")

    @field_validator("schema_version")
    @classmethod
    def validate_schema_version(cls, value: str) -> str:
        if value != SCHEMA_VERSION:
            raise ValueError(f"unsupported schemaVersion {value!r}; expected {SCHEMA_VERSION!r}")
        return value

    @field_validator("steps")
    @classmethod
    def require_final_or_action(cls, value: list[TrajectoryStep]) -> list[TrajectoryStep]:
        if not value:
            raise ValueError("trajectory must contain at least one step")
        return value


class ValidationIssue(LuminaModel):
    line: int
    error: str
