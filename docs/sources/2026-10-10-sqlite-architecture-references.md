---
title: SQLite 架构重构的一手参考资料
author: SQLite Project; GRDB.swift contributors
captured: 2026-10-10
kind: pattern-reference
---

# SQLite 架构重构的一手参考资料

用途：为 [分阶段重构计划](../plans/2026-10-10-2322-refactor-sqlite-architecture-plan.md) 提供数据库适用边界、并发、快照、搜索和依赖兼容性依据。以下是必要摘要与定位，不代表 Kinlogue 已完成接入或性能验证。

## SQLite Project

| 来源 URL | 获取时的必要摘要 | 本项目采用 / 待验证 |
| --- | --- | --- |
| [Appropriate Uses](https://sqlite.org/whentouse.html) | 本地应用数据存储是 SQLite 的适用场景 | 单机元数据存储候选；不能据此推导性能收益 |
| [Isolation](https://sqlite.org/isolation.html) | 写事务串行；WAL 允许读写并行，不等于多个并行 writer | 首期单连接串行；保留实体 revision 和跨进程协调 |
| [Atomic Commit](https://sqlite.org/atomiccommit.html#multi_file_commit) | 说明数据库文件及事务提交边界 | **项目推断**：事务不自动包含附件 rename / unlink，必须继续设计文件发布和回收协议 |
| [WAL 文件](https://sqlite.org/wal.html#the_wal_file)、[错误备份风险](https://sqlite.org/howtocorrupt.html#backup_or_restore_while_a_transaction_is_active) | WAL 是数据库持久状态的一部分；活动数据库不能只复制主文件当完整备份 | 不直接打包活动 DB / sidecar；使用受控快照 |
| [Online Backup API](https://sqlite.org/backup.html)、[backup finish / step 契约](https://sqlite.org/c3ref/backup_finish.html) | 支持一致数据库复制；finish 成功本身不证明已经完整复制，step 必须完成 | 生成独立快照；**项目推断**：附件集仍需单独固定并防 GC |
| [WAL-reset bug](https://sqlite.org/wal.html#the_wal_reset_bug) | 官方记录多连接写入 / checkpoint 的罕见损坏问题，影响 3.7.0–3.51.2，修复为 3.51.3，另有 3.44.6 / 3.50.7 backport | 目标 Apple engine / backport 待核实；不能只升级 Swift 包就宣称 engine 已修复，首期不用 WAL |
| [FTS5 trigram](https://sqlite.org/fts5.html#the_trigram_tokenizer) | trigram 全文查询不能匹配不足三个 Unicode 字符的词；特定 LIKE / GLOB 查询可能退回扫描 | 保留既有短中文子串语义，不把 FTS5 当无成本等价替换 |
| [版权声明](https://sqlite.org/copyright.html) | SQLite 核心为 public domain | 依赖和分发说明仍须核对实际引入组件 |

## GRDB.swift

固定参考 **v7.11.1**，不宣称它是获取日最新版本。

- [README](https://github.com/groue/GRDB.swift/blob/v7.11.1/README.md)、[Package.swift](https://github.com/groue/GRDB.swift/blob/v7.11.1/Package.swift)、[Release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1)：声明 Swift 6.1+ / Xcode 16.3+、macOS 10.15+、SQLite 3.20+；与当前 main 声明基线存在兼容交集，尚无 Kinlogue 构建 / 安装证据。
- [Database migrations](https://github.com/groue/GRDB.swift/blob/v7.11.1/GRDB/Documentation.docc/Migrations.md)：提供迁移 API；开发便利的 erase-on-schema-change 不能用于本项目生产资料库。
- [Custom SQLite Builds](https://github.com/groue/GRDB.swift/blob/v7.11.1/Documentation/CustomSQLiteBuilds.md)：默认使用系统 SQLite，所述自定义构建路线不能视为现有 SwiftPM 接入的直接替换。计划不引入自带 engine。
- [LICENSE](https://github.com/groue/GRDB.swift/blob/v7.11.1/LICENSE)：MIT；若采用，更新第三方声明并检查实际资源与链接边界。

采用范围：以现成事务 / 查询 / 迁移封装减少手写 SQLite 绑定；不承诺 GRDB 观察者能够自动接收任意跨进程写入，也不将它作为文件协调、备份附件快照或生命周期的替代品。

## 证据限制

以上是官方文档与固定 tag 源码核查。未执行项目内编译、最低系统实机测试、engine 配置验证、故障注入、旧格式迁移或性能测量。SQLite 核心行为与项目文件协议之间的推导已标注；最终行为以计划所列真实链路验收为准。
