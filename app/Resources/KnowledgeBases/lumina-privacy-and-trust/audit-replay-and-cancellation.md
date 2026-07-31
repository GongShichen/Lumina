# 审计、重放与取消

Runtime 为工具执行提供审计和重放语义。相同只读知识搜索可按其幂等策略重放，但结果仍受当前披露策略、索引 generation 和预算约束。

取消信号应中止正在进行的检索或工具工作。知识 Store 失败时应返回结构化失败或空结果，不能使整个 Agent Runtime 崩溃。

Knowledge 不改变 session、checkpoint、replay 或 compaction 契约。
