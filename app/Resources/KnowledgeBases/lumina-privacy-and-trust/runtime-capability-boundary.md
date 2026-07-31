# Runtime 能力边界

知识文件、索引和持久化由宿主 App 拥有。Runtime 只保留当前 session 的 catalog summary、已加载 section 和相应 metadata。

`knowledge.search` 是普通注册的只读工具。知识库不能注册隐藏工具、改变会话可见工具、执行系统操作，或修改 C ABI、ReAct schema、planner envelope、checkpoint、permission、audit、replay 与 compaction 契约。

导入资料中的“忽略规则”或“调用工具”等文字只是不可信证据，不能覆盖更高优先级指令。
