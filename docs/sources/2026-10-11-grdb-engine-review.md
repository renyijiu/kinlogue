---
title: GRDB 固定依赖与 Apple SQLite engine 点时核查
author: GRDB maintainers / SQLite project / Kinlogue local verification
captured: 2026-10-11
kind: dependency-review
---

# 核查来源

- [GRDB 7.11.1 release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1) 与 [固定 Package.swift](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/Package.swift)：tag 解析为 `b83108d10f42680d78f23fe4d4d80fc88dab3212`；本仓库 `Package.resolved` 固定同一 revision，使用系统 SQLite，不启用 SPI 文档生成依赖。
- [GRDB security](https://github.com/groue/GRDB.swift/security)：查询时页面显示没有 published advisories、没有 SECURITY.md。这只是公告页面点时结果，不是代码审计或无漏洞保证。
- [固定 LICENSE](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/LICENSE)：MIT、Copyright 2015–2025 Gwendal Roué，全文进入 `THIRD_PARTY_NOTICES.md`。
- [固定 privacy manifest](https://github.com/groue/GRDB.swift/blob/b83108d10f42680d78f23fe4d4d80fc88dab3212/GRDB/PrivacyInfo.xcprivacy)：声明 tracking=false，tracking domains、collected data 和 accessed API arrays 为空；SwiftPM `GRDB_GRDB.bundle` 随主 App 打包并纳入精确资源门禁。
- [SQLite db_config](https://www.sqlite.org/c3ref/c_dbconfig_defensive.html)：DEFENSIVE 和 extension loading 连接选项。

# 本机观察

macOS 27 / Xcode 27 本机 C 探针读取到系统 SQLite 3.54.0；`SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION` 返回 SQLITE_MISUSE，同时 `sqlite3_compileoption_used("OMIT_LOAD_EXTENSION") == 1`。扩展功能已被编译移除，适配器显式验证该事实，再将有效状态记录为 disabled。DEFENSIVE 配置和回读为 1；DELETE、EXTRA=3、fullfsync=1、foreign_keys=1、trusted_schema=0 由内核测试回读。

该观察不能外推到 macOS 26。目标库只采用本仓库自建 schema；外来 SQLite 文件不是备份交换格式，后续 U6 使用逻辑快照。编译选项核查不代替 Apple engine 安全更新或独立密码学审计。
