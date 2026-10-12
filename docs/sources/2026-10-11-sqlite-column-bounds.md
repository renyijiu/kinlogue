# SQLite 大字段读取边界核对（2026-10-11）

本页记录热查询字节预算依赖的 SQLite 官方行为。系统版本的实际能力仍由引擎探针验证。

## 官方来源

- [SQLite length / octet_length](https://www.sqlite.org/lang_corefunc.html#octet_length)
- [SQLite CASE expression](https://www.sqlite.org/lang_expr.html#the_case_expression)

## 来源陈述的事实

`length(TEXT)` 计算字符数，在 NUL 处停止；`length(BLOB)` 计算字节数。前者需要读取字符串，后者可以从元数据获得长度。

`octet_length` 返回当前数据库编码下的字节数。参数为直接的 TEXT 或 BLOB 列时，可从元数据取得长度，不读取整个内容。不能把字符数当作 UTF-8 字节预算，也不能忽略嵌入 NUL 后的内容。

`CASE` 按需计算分支。因此读取前的字节上限应控制 SQL 实际返回内容的分支。无条件同时选择“大字段”和“长度”，再在 Swift 中判断，只能限制后续 Swift 拷贝，不能据此声称 SQLite 虚拟机没有先加载字段。

## 对项目的约束

热查询先验证直接列的字节长度，只在预算内返回正文；超限目标以固定语义错误隔离。引擎核实包括 UTF-8、NUL、BLOB 与 NULL，不能把当前 macOS 27 的结果代替 macOS 26 验证。实际实现与证据见 [SQLite 存储专题](../sqlite-storage.md)。
