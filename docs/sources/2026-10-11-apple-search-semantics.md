# Apple 本地化子串匹配 API 核对（2026-10-11）

本页保存 U8 搜索优化所依据的外部 API 契约，不把临时探针的结果写成系统兼容性保证。

## 官方来源

- Apple：[localizedCaseInsensitiveContains(_:)](https://developer.apple.com/documentation/swift/stringprotocol/localizedcaseinsensitivecontains(_:))；核对其官方 Markdown 版本。
- Apple：[CFStringFindWithOptionsAndLocale(_:_:_:_:_:_:)](https://developer.apple.com/documentation/corefoundation/cfstringfindwithoptionsandlocale(_:_:_:_:_:_:))；核对其官方 Markdown 版本。

## 来源陈述的事实

Swift API 对非空查询执行大小写不敏感、非字面匹配，并考虑当前 locale；文档将其等价表达为带大小写选项和当前 locale 的 `range` 查找。由此不能将 SQLite `lower` / `LIKE` 或逐字节匹配默认视为同一契约。

Core Foundation API 接受显式 locale 和查找选项；空查询返回未找到。locale 会影响相等关系，官方以土耳其语 I 的大小写为例。传入空 locale 使用系统 locale，不能直接等同于一次查询捕获的用户当前 locale。

## 对项目的约束

搜索是否命中仍以各个已确认来源字段的 Foundation 谓词为准。若采用 CF 预筛，两步必须共用一次查询捕获的 locale；预筛不能产生漏匹配，最终匹配不能跨字段边界。实现选择与等价回归、性能证据在 [SQLite 存储专题](../sqlite-storage.md) 记录，不能由 API 文档单独证明优化正确或达标。
