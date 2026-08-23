# 决策登记

本页记录当前影响实现和文档的高层决策。完整的产品契约和规划背景仍保留在 `docs/plans/`；本页只维护“现在应该按什么做”和“哪些旧决策不再适用”。

## 当前有效决策

| 决策 | 当前规则 | 依据 |
| --- | --- | --- |
| 本机优先、单一操作员 | 一台 Mac 为多位家人管理报告；不引入账号、云同步或协作服务。 | [`2026-08-01-002`](plans/2026-08-01-002-feat-kinlogue-plaintext-mvp-plan.md)、README |
| 明文 MVP | 原件、成员、OCR、搜索字段在 App Sandbox 本地明文保存；不使用 Keychain/应用层加密。 | [`2026-08-01-002`](plans/2026-08-01-002-feat-kinlogue-plaintext-mvp-plan.md)、[`PRIVACY.md`](../PRIVACY.md) |
| digest 只做损坏检测与精确去重 | SHA-256 参与本机精确去重和完整性检查，但不是认证、保密、防篡改或防回滚。 | `PlaintextVault`、隐私说明 |
| manifest 单一提交点 | 先写 immutable objects，再原子发布 `library.json`/`inbox.json`；恢复只接受完整 generation。 | `PlaintextVault`、`PlaintextLANInboxStore` |
| 人工确认 OCR | OCR/候选抽取保留来源和原文；用户确认前不能进 timeline/search/comparison，不能生成诊断。 | `HealthRecord`、`SourceField`、`ImportState` |
| 临时配对 LAN | 用户明确 start；一次性 code + session cookie + CSRF；普通 HTTP，只针对可信任私人 LAN。 | [`lan-upload.md`](lan-upload.md)、LAN plan R1–R4/R18–R21 |
| 单一待确认队列 | 手机只追加独立文件且不排序；Mac 按完整内容合并原件，用户在单一队列中单选/多选后决定报告页序、成员和日期。 | LAN plan U16–U20、`LANInboxItem`、`LANReportArchiveCoordinator` |
| 两级 exact duplicate | 手机仅在有界逐块比较确认相同时忽略重复选择；Mac 以 SHA-256 + length 合并原件，再以完整 source multiset 复用已有报告。partial overlap 和 near-similar 不跳过。 | LAN plan U16–U18、`ReportFingerprint` |
| window-scoped receiving | 手动停止、锁屏/睡眠、network path change、最后主窗口关闭和退出都会停止；焦点丢失不停止；重开需明确 start。 | `LANSessionLifecycleMonitor`、LAN acceptance |
| LAN 不设固定总字节 quota | 允许上传 regular file，仍受 protocol/item-count/concurrency/decoder-safety 上限和真实磁盘失败约束。 | LAN plan U16–U20、`LANInboxAdmissionPolicy` |
| private-repo ad-hoc candidate | 版本 tag 可在 private GitHub 仓库发布未经 Developer ID 签名或 notarization 的 arm64 ad-hoc Pre-release，只供有仓库读取权限的授权测试者下载；面向公众的分发、Developer ID 和 notarization 均未执行。 | [release workflow](../.github/workflows/release.yml)、[`adhoc-candidate-install.md`](adhoc-candidate-install.md)、验收矩阵 |
| DICOM exact 包的进程隔离 | DICOM-Swift 1.3.3 只链接进单独签名、无网络 entitlement、无 Vault-root 权限的 XPC Helper；主 App/Core/Platform 不 import/link `DicomCore`，只通过有界 Foundation IPC contract 交换一个只读 descriptor 与最小 DTO。 | [`2026-08-06-001`](plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md) KTD1–KTD2、[`release 边界探针`](sources/2026-08-07-dicom-swift-1.3.3-release-boundary.md) |
| DICOM 是受限辅助能力 | DICOM 只帮助保存检查原件和查看明确支持的二维灰度 MR；不扩张为诊断、测量、PACS 或通用影像工作站。 | [`dicom.md`](dicom.md)、[`project-overview.md`](project-overview.md) |
| 首发前 current-only | 项目未公开发布，只支持 catalog v3 与 ordering policy v2；开发期 v1/v2 reader/migrator、policy v1 和 predecessor/rollback 路径已删除。除恢复先前由用户明确发起、且已写入有效 durable deletion receipt 的整库删除外，旧开发 Vault、未知版本、未知非空目录和损坏布局继续非破坏性 fail closed；App 不自动迁移、覆盖或删除其字节，用户可在仓库外导出后手工重置。 | 用户 2026-08-12 决策、[`storage.md`](storage.md)、[`dicom.md`](dicom.md) |

## 已被 supersede 的早期决策

[`2026-08-01-001-feat-kinlogue-macos-vault-plan.md`](plans/2026-08-01-001-feat-kinlogue-macos-vault-plan.md) 早期计划曾以“加密 Vault、Keychain、加密 backup/restore”为 MVP 方向；它已被明文 MVP 计划的 `supersedes` 字段覆盖。它仍然保留 threat model、早期 target 规划和未来安全升级的背景，但不能作为当前代码或隐私文案的事实来源。

因此当前 Agent 不应：

- 把 AES-GCM、Keychain、recovery key 或 encrypted backup 写成已实现能力；
- 恢复旧计划的 Security.framework/密钥依赖以“完成文档”；
- 把旧计划的加密威胁模型当成当前明文保护承诺。

## 当前开放门禁

这些是发布/产品证据缺口，不是可以在文档中用推断填掉的问题：

1. macOS 14 和 macOS 15 独立机器上的 LAN/安装矩阵。
2. 指定版本 iOS Safari 与 Android Chrome 的地址、QR、配对、多文件、重试、重复跳过和生命周期矩阵。
3. 锁屏、屏保、睡眠、快速用户切换、网络路径变化、退出/唤醒的安装后人工回执。
4. 真实私有样本 OCR 抽检与键盘/VoiceOver 检查。
5. 未来是否加入应用层加密、Keychain、可验证明文到加密迁移、备份/恢复或云同步；在决策完成前保持当前边界。

## 决策更新规则

新决策必须写清：问题、选择、未选择的替代方案、影响的代码/文档、迁移/回滚要求、验证门禁和日期。完成后更新本页、相关专题页、`docs/index.md` 和 [`docs/log.md`](log.md)；不通过删除旧段落来抹掉历史。
