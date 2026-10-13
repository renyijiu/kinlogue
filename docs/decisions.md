# 决策登记

本页记录当前影响实现和文档的高层决策。完整的产品契约和规划背景仍保留在 `docs/plans/`；本页只维护“现在应该按什么做”和“哪些旧决策不再适用”。

## 当前有效决策

| 决策 | 当前规则 | 依据 |
| --- | --- | --- |
| 本机优先、单一操作员 | 一台 Mac 为多位家人管理报告；不引入账号、云同步或协作服务。 | [`2026-08-01-002`](plans/2026-08-01-002-feat-kinlogue-plaintext-mvp-plan.md)、README |
| 明文 MVP | 原件、成员、OCR、搜索字段在 App Sandbox 本地明文保存；不使用 Keychain/应用层加密。 | [`2026-08-01-002`](plans/2026-08-01-002-feat-kinlogue-plaintext-mvp-plan.md)、[`PRIVACY.md`](../PRIVACY.md) |
| digest 只做损坏检测与精确去重 | SHA-256 参与本机精确去重和完整性检查，但不是认证、保密、防篡改或防回滚。 | `SQLiteLibraryStore`、隐私说明 |
| 数据库事务是单一提交点 | 原件先以 staged 状态写入并同步，领域引用和 live 状态在同一个数据库事务里发布；中断后只可能看到完整的旧提交或完整的新提交。 | `SQLiteLibraryStore`、[`sqlite-storage.md`](sqlite-storage.md) |
| 人工确认 OCR | OCR/候选抽取保留来源和原文；用户确认前不能进 timeline/search/comparison，不能生成诊断。 | `HealthRecord`、`SourceField`、`ImportState` |
| 临时配对 LAN | 用户明确 start；一次性 code + session cookie + CSRF；普通 HTTP，只针对可信任私人 LAN。 | [`lan-upload.md`](lan-upload.md)、LAN plan R1–R4/R18–R21 |
| 单一待确认队列 | 手机只追加独立文件且不排序；Mac 按完整内容合并原件，用户在单一队列中单选/多选后决定报告页序、成员和日期。 | LAN plan U16–U20、`LANInboxItem`、`LANReportArchiveCoordinator` |
| 两级 exact duplicate | 手机仅在有界逐块比较确认相同时忽略重复选择；Mac 以 SHA-256 + length 合并原件，再以完整 source multiset 复用已有报告。partial overlap 和 near-similar 不跳过。 | LAN plan U16–U18、`ReportFingerprint` |
| window-scoped receiving | 手动停止、锁屏/睡眠、network path change、最后主窗口关闭和退出都会停止；焦点丢失不停止；重开需明确 start。 | `LANSessionLifecycleMonitor`、LAN acceptance |
| LAN 不设固定总字节 quota | 允许上传 regular file，仍受 protocol/item-count/concurrency/decoder-safety 上限和真实磁盘失败约束。 | LAN plan U16–U20、`LANInboxAdmissionPolicy` |
| private-repo ad-hoc candidate | 版本 tag 可在 private GitHub 仓库发布未经 Developer ID 签名或 notarization 的 arm64 ad-hoc Pre-release，只供有仓库读取权限的授权测试者下载；面向公众的分发、Developer ID 和 notarization 均未执行。 | [release workflow](../.github/workflows/release.yml)、[`adhoc-candidate-install.md`](adhoc-candidate-install.md)、验收矩阵 |
| DICOM exact 包的进程隔离 | DICOM-Swift 1.5.0 只链接进单独签名、无网络 entitlement、无 Vault-root 权限的 XPC Helper；主 App/Core/Platform 不 import/link `DicomCore`，只通过有界 Foundation IPC contract 交换一个只读 descriptor 与最小 DTO。 | [`2026-08-06-001`](plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md) KTD1–KTD2、[`release 边界探针`](sources/2026-08-07-dicom-swift-1.3.3-release-boundary.md)、[1.5.0 依赖核对](sources/dicom-swift-1.5.0-dependency-review-2026-09-16.md) |
| DICOM 是受限辅助能力 | DICOM 只帮助保存检查原件和查看明确支持的二维灰度 MR；不扩张为诊断、测量、PACS 或通用影像工作站。 | [`dicom.md`](dicom.md)、[`project-overview.md`](project-overview.md) |
| 已确认影像只经时间线进入 | 已确认检查与报告共用成员时间线和右栏详情，侧边栏不设“医学影像”导航项；“只看影像”由时间线类型筛选承担。数据层隔离不变：影像仍不进入 OCR、搜索或比较。 | 用户 2026-10-11 决策、[`dicom.md`](dicom.md)、[`design-system.md`](design-system.md) |
| 首发前 current-only | 项目未公开发布，只支持当前的 SQLite schema 与 ordering policy v2；开发期的 JSON 清单存储、v1/v2 reader/migrator、policy v1 和 predecessor/rollback 路径已删除。除恢复先前由用户明确发起、且已写入有效 durable deletion receipt 的整库删除外，旧开发 Vault、未知版本、未知非空目录和损坏布局继续非破坏性 fail closed；App 不自动迁移、覆盖或删除其字节，用户可在仓库外导出后手工重置。 | 用户 2026-08-12 决策、[`storage.md`](storage.md)、[`dicom.md`](dicom.md) |

## [2026-09-16] 最低系统调整为 macOS 26

以个人自用为主要场景，停止支持 macOS 26 以下版本，避免继续承担旧系统兼容性维护。主 App、DICOM Helper、XPC 验证宿主及构建门禁统一要求 macOS 26.0；不再保留 macOS 14/15 的当前验收义务。依据见 [`Package.swift`](../Package.swift)、[`Info.plist`](../packaging/Info.plist) 和[当前候选证据](acceptance/current-release.md)。

这次调整只改变运行系统下限，不迁移资料库、不改变备份格式，也不表示 macOS 26/27 已完成安装与人工验收。旧系统用户不能运行新构建；若需退回旧构建，仍须先核实资料格式兼容性。历史计划、来源笔记和已绑定工件的验收记录保留原系统范围，当前系统矩阵以候选账本为准。

## [2026-10-11] 品牌定位改为以人为单位、一人管全家

**问题**：产品计划从健康记录整理延伸为健康助手（接入运动数据和模型问答）。需要判断“续页 / Kinlogue”的名称、标语和图标是否仍然适用，以及文档现在应当写到哪一步。

**选择**（用户 2026-10-11 决策）：

- 定位为“个人维度，但可以管理整个家庭”：以人为单位组织资料，一位使用者统一照看全家。这与现有的单一操作员、多家庭成员实现一致。
- 保留“续页”和“Kinlogue”两个名称；`Kin` 的释义从“家人”改为“自己和家人”。
- 应用图标沿用“纸页 + 连续的线 + 节点”的意象，改由矢量母版生成，并使用精确的品牌母色。
- 健康助手只记录为方向。运动数据、模型问答和相应的隐私承诺改写都未实现，不进入当前产品契约。

**未选择的替代方案**：

- 改名。`Kinlogue` 已写入 bundle identifier、Application Support 目录名和 `.kinloguebackup` 扩展名，改名需要迁移；而现有名称在新定位下仍然成立。
- 去掉纸页、只保留线索的图标。纸页代表“有来源的原件”，是产品区别于一般健康问答应用的地方。
- 现在就把“健康助手”“有据可问”写成当前标语。这会把未实现的能力写成现状，并与“不提供诊断、趋势判断或治疗建议”的承诺冲突。

**影响的代码/文档**：[`README.md`](../README.md)、[`project-overview.md`](project-overview.md)、新增的 [`brand.md`](brand.md)、[`design-system.md`](design-system.md)、[`index.md`](index.md)；`packaging/AppIcon.svg`、`packaging/AppIcon-small.svg`、`packaging/AppIcon.png`、`packaging/Kinlogue.iconset/` 和 `scripts/render-app-icon.swift`。为了让被替换的图标位图通过历史隐私门禁，`scripts/privacy-history-guard.sh` 改为允许同一路径登记多条已审查摘要，见 [`privacy-and-security.md`](privacy-and-security.md)。App 内文案、`PRIVACY.md`、Info.plist 和本地化资源没有变化。

**迁移/回滚**：不涉及资料库、备份格式、bundle identifier 或用户数据。回滚图标只需恢复旧位图；摘要清单只追加，不需要回退。

**验证门禁**：历史隐私门禁的回归测试、当前树隐私门禁和文档门禁见 [`log.md`](log.md)。图标在 macOS 26/27 的 Dock、Finder 中的实际显示，以及深色或着色外观，尚未人工核对。

## [2026-10-13] 资料库只保留 SQLite，删除 JSON 清单存储

**问题**：界面入口和安装验收改用 SQLite 资料库之后，JSON 清单存储（`PlaintextVault`、独立的 LAN inbox 清单、跨进程写锁、JSON 备份来源和临时查询适配器）只剩测试和跨进程 fixture 在用。两套实现并存，每个共享类型都要同时支持两种后端，一批测试验证的是界面永远走不到的代码。

**选择**（[SQLite 与架构重构计划](plans/2026-10-10-2322-refactor-sqlite-architecture-plan.md) 的收尾单元；用户 2026-10-12 同意按评审建议执行）：删除 JSON 实现以及只为它存在的类型和测试，共享类型收敛为只支持 SQLite。删除之前先把仍有意义的测试移植到 SQLite 资料库上；第二 owner、强退恢复、整根替换和备份仓库并发发布的测试保留并改用 SQLite 资料库。

**未选择的替代方案**：保留 JSON 实现作为测试参照——它已不是界面的行为，对它的断言不能证明产品正确；提供 JSON 到 SQLite 的自动迁移——项目尚未公开发布，继续沿用“首发前 current-only”。

**影响的代码/文档**：Core、Platform、App、跨进程 fixture 和各层测试；[`storage.md`](storage.md)、[`sqlite-storage.md`](sqlite-storage.md)、[`architecture.md`](architecture.md) 及各专题页。测试脚本去掉了只为被删类型存在的专用 XCTest 通道和隔离的 DICOM 门禁，CI 的测试分区由三个减为两个，见 [`testing-and-release.md`](testing-and-release.md)。

**迁移/回滚要求**：没有迁移。早先的 JSON 资料库目录和文件树格式的恢复点会被识别并拒绝，字节保持不变；需要旧实现的人从 Git 历史取回。回滚即还原这次改动。

**验证门禁**：自动化结果和未执行的门禁见 [`log.md`](log.md) 与 [当前验收账本](acceptance/current-release.md)；`run-acceptance.sh`、macOS 26 和人工门禁没有执行。

## 已被 supersede 的早期决策

[`2026-08-01-001-feat-kinlogue-macos-vault-plan.md`](plans/2026-08-01-001-feat-kinlogue-macos-vault-plan.md) 早期计划曾以“加密 Vault、Keychain、加密 backup/restore”为 MVP 方向；它已被明文 MVP 计划的 `supersedes` 字段覆盖。它仍然保留 threat model、早期 target 规划和未来安全升级的背景，但不能作为当前代码或隐私文案的事实来源。

“manifest 单一提交点”（先写 immutable objects，再原子发布 `library.json` / `inbox.json`）是 JSON 清单存储时期的规则，已由上面 2026-10-13 的决策取代；提交点现在是数据库事务。

因此当前 Agent 不应：

- 把 AES-GCM、Keychain、recovery key 或 encrypted backup 写成已实现能力；
- 恢复旧计划的 Security.framework/密钥依赖以“完成文档”；
- 把旧计划的加密威胁模型当成当前明文保护承诺。

## 当前开放门禁

这些是发布/产品证据缺口，不是可以在文档中用推断填掉的问题：

1. macOS 26 和 macOS 27 独立机器上的 LAN/安装矩阵。
2. 指定版本 iOS Safari 与 Android Chrome 的地址、QR、配对、多文件、重试、重复跳过和生命周期矩阵。
3. 锁屏、屏保、睡眠、快速用户切换、网络路径变化、退出/唤醒的安装后人工回执。
4. 真实私有样本 OCR 抽检与键盘/VoiceOver 检查。
5. 未来是否加入应用层加密、Keychain、可验证明文到加密迁移、备份/恢复或云同步；在决策完成前保持当前边界。
6. 是否以及如何引入运动数据和模型问答（数据来源、本机或联网、非诊断边界、隐私承诺改写）；在决策完成前，HealthKit、互联网服务、趋势分析和诊断性输出继续属于当前明确不做。待决事项见 [`brand.md`](brand.md)。

## 决策更新规则

新决策必须写清：问题、选择、未选择的替代方案、影响的代码/文档、迁移/回滚要求、验证门禁和日期。完成后更新本页、相关专题页、`docs/index.md` 和 [`docs/log.md`](log.md)；不通过删除旧段落来抹掉历史。
