# Personal Memory 与 Knowledge

Personal Memory 用于保存用户明确提供、可在以后任务中复用的个人偏好或背景。写入记忆可能需要确认，搜索由 `local.search` 等当前可见能力完成。

Knowledge 用于产品文档和用户导入的参考资料。它拥有独立的 Store、索引、设置和删除生命周期，通过 BM25 与向量检索按需召回。

Knowledge 不是个人记忆，Personal Memory 也不会自动成为知识库。询问“我以前说过什么”时应搜索 Personal Memory；询问导入文档内容时应搜索 Knowledge。
