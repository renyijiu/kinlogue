---
title: SQLite 计划修订的主线、规模测量与决策对照证据
author: Kinlogue 项目测量记录；用户评审；SQLite Project
captured: 2026-10-11
kind: pattern-reference
---

# SQLite 计划修订证据

用途：支撑 [统一重构计划](../plans/2026-10-10-2322-refactor-sqlite-architecture-plan.md) 的修订。测量数字来自已存在的报告；本轮读取报告、探针与生产代码，没有重新运行规模探针。原始资料位于另一未提交工作树（未公开），本笔记保留来源身份和必要摘录，不将其冒充本轮执行结果。

## 主线与来源身份

- `git ls-remote origin refs/heads/main` 核对远端为 `09f57b11143e05aa944c1b716e05737ccd813a12`；该提交合入 PR #13。`Package.swift` 为 Swift tools 6.2、macOS 26.0、DICOM-Swift 1.5.0；CI 以 macOS 26 为基线、27 为兼容性观察矩阵。当前编辑工作树仍为 `main@4f0f2d8`，本轮没有切分支、合并或覆盖既有改动。
- 测量工作基于 `claude/relaxed-moore-ad4d9a@09f57b1` 加未提交的探针。以下为读取时文件身份；路径为来源树中的相对路径，不表示已合入本工作树。

| 来源文件 | SHA-256 |
| --- | --- |
| `docs/storage-scale-measurement-2026-10-10.md` | `bdbb19834973380a8cd23614d19e7885fa6a224d2bd442b0d0b9076ced2634f5` |
| `scripts/run-storage-scale-probe.sh` | `4f5a95ff664fbfd118ebd17b66d658a965870a440f41cab1a0c2ab8d19a81faa` |
| `Sources/KinlogueStorageProcessFixture/StorageScaleProbe.swift` | `8476a9c9bb28c5b7ea03e7cdc08563571c9d7e7514cef4b50df4cbecac1cba9a` |
| `docs/plans/2026-10-10-001-refactor-sqlite-library-catalog-plan.md` | `87eaaa4600a451ae6e5a2045390a7fb237df5c8ec5fd8ed1ec03a356d064218a` |

## 测量摘录与适用边界

报告环境：Mac13,1 / M1 Max / 64 GB / 内置 APFS，macOS 27.0.1（26A434）、Xcode 27.0、Swift 6.4，Release 构建、热页缓存。报告档每份原件 64 KiB、OCR 约 27 KB / 60 blocks；近上限档 9,990 份报告、9,791 条已确认记录、19,980 个对象、manifest 55 MiB。照片档保持结构、原件改为每份 1 MiB。

| 指标 | 来源结果 | 统计口径 |
| --- | --- | --- |
| 近上限刷新 / 复核快照 | 4,859 / 4,877 ms | 7 次中位数；只含存储链路，不含 SwiftUI |
| 保存复核 / 确认 / 编辑 | 13,414 / 13,400 / 13,354 ms | 7 次中位数 |
| 导入一个新原件 | 48,707 ms | 7 次中位数，包含精确去重 |
| 搜索无命中 / 稀有词 / 日期 | 328 / 469 / 528 ms | 7 次中位数，**不是 p95** |
| 操作进程峰值 | 4.40 GB footprint | 与最大 RSS 分开记录 |
| 启动：报告档 | 18.97 / 14.24 / 14.17 s | 三个新进程、热缓存 |
| 启动：照片档 9.76 GiB | 41.5 / 43.0 / 44.5 s | 三个新进程、热缓存 |
| 近上限手机发布 / 队列刷新 | 19.7–20.4 s / 2.19–2.25 s | stored 项，无 OCR，不含 HTTP |
| 500 份报告创建恢复点 | 243 s，估算 233 s | 完整发布实测一次；另一次早期运行 232 s |
| 近上限 937 MiB 创建恢复点 | 估算 87,528 s，约 24.3 h | 超过 900 s 预算，**没有完成实测** |
| 照片档备份 | 准备 21.6 s 后 resource-limit 拒绝 | 因当前 2 GiB 格式上限，未生成完整恢复点 |

原件从 624 MiB 增至 9.76 GiB，启动增加约 27–30 秒；不是对任意硬件、文件形状都成立的线性系数。未测冷缓存、真实资料、其他系统、完整 UI、DICOM 解码、恢复耗时；大队列增长测量中止。SQLite 新实现没有同口径结果。

## 与代码的交叉核实

- 备份 source（`Sources/KinloguePlatform/Backup/PlaintextLibraryBackupSource.swift`，已删除） 每打开一项调用全源 revision 验证；VaultRootBinding（`Sources/KinloguePlatform/Storage/VaultRootBinding.swift`，已删除） 路径重新解析 manifest。重复工作随条目数和 manifest 大小相乘。
- `格式限制` 不只有 2 GiB / 20,000 条目，还有限制 30,000 frames、16 MiB canonical manifest；writer、reader、trust verifier、repository、restore 的长度检查必须同步。
- DuplicateDetector（`Sources/KinlogueCore/Import/DuplicateDetector.swift`，已删除） 逐记录调用 [ReportFingerprint](../../Sources/KinlogueCore/Import/ReportFingerprint.swift)，后者每次为全量附件重建字典。
- [ImportDraftDocument](../../Sources/KinlogueCore/Import/ImportDraft.swift) 包含 blocks、candidates 和 reviewState；OCR 文档并非纯可丢弃缓存，复核保存必须进入同一元数据事务。

## 转达与另一份计划的区别

读取到的另一份计划仍标为“提议，未批准”。其 3.4 节建议 DICOM index 存独立表 BLOB，3.5 节建议单实例生命周期排他锁，第 8 节建议逻辑快照，第 10 节明确全部角色适配后一次切换。因此“索引已决定规范化成表”和“已经决定两次切换”不能由该文件证实；也不能据文件还原所有会话口头决定。本轮以用户直接评审及统一计划的新明确选择为准，不修改另一工作树的计划。

## SQLite 官方完整性与持久性依据

获取日 2026-10-10 至 11 日，作者 SQLite Project：

- [PRAGMA](https://sqlite.org/pragma.html)：`application_id` 是应用标识，`user_version` 由应用管理；`quick_check` 不覆盖 UNIQUE、索引与表一致性，完整检查仍不替代 `foreign_key_check`。DELETE 模式的 `synchronous=EXTRA` 额外同步 journal 删除后的目录，`fullfsync=ON` 在 macOS 请求 F_FULLFSYNC。未知 PRAGMA 可能被忽略，因此设置后必须核实。
- [连接防御配置](https://sqlite.org/c3ref/c_dbconfig_defensive.html)、[不可信输入防护](https://sqlite.org/security.html)：关闭 trusted schema / extension loading、启用 defensive 和资源限制是防御措施，不是对任意 SQLite 文件的安全认证。新备份选择逻辑记录流，恢复端自己建立数据库。

本项目采用：明确启动 / 读取 / 巡检 / 恢复的验证层次；保留有限资源、失效屏障与意外损坏检测；不宣称 SQLite 自带每行校验和或 trusted_schema 能禁止一切恶意 schema。最低支持 macOS 26 的 Apple SQLite 构建行为及真实断电持久性仍未验证。
