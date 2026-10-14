# GRDB 7.11.1 文本字节边界核对（2026-10-11）

本页依据 Package.resolved 锁定的 GRDB 7.11.1、revision `b83108d10f42680d78f23fe4d4d80fc88dab3212` 的本地 checkout，不把后续版本行为推断为当前能力。

## 一手代码

- [String 的绑定和读取](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/GRDB/Core/Support/StandardLibrary/StandardLibrary.swift)：String 绑定使用负长度的 sqlite3_bind_text；直接读取通过 String(cString:)。
- [DatabaseValue](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/GRDB/Core/DatabaseValue.swift)：从 SQLite TEXT 拷贝值同样使用 C 字符串。
- [Row](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/GRDB/Core/Row.swift)：fetchOne/fetchAll 会复制 cursor 行；cursor 上公开的 withUnsafeData 通过 sqlite3_column_blob 和 sqlite3_column_bytes 给出长度明确的临时字节视图，视图不能逃逸闭包。

## 对项目的约束

领域成员名、来源显示名和来源转录允许嵌入 NUL。默认绑定会截断这些值，默认 Row 拷贝也不能用于保真读取；先复制 Row 再读取其 Data 已经太晚。

项目通过已有 GRDB API 在绑定时传 UTF-8 Data 并显式 CAST 为 TEXT，在 cursor 有效期间解码完整 UTF-8，再形成拥有自身内容的 Row。无法解码的文本保留为二进制异常值，由对应行 codec 拒绝，避免把一行损坏扩大成整个分页失败。数据库编码必须回读为 UTF-8。未新增 C 绑定、修改依赖、改变语义摘要或 logical-v1 格式；具体代码和回归见 [SQLite 存储](../sqlite-storage.md)。
