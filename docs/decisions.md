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
| 成员对话是唯一的外发例外 | 默认关闭。用户开启并按对话确认后，单独签名的沙盒 XPC bridge 启动用户本机已登录的 Codex，只经 stdin 发送一位成员的已确认报告投影与问答；模型没有工具，回答不进入时间线、搜索、比较或导出，对话只在内存。主 App 的 entitlement 不变。 | [成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md) D1–D8、E1–E2，[`PRIVACY.md`](../PRIVACY.md) |
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

## [2026-10-13] 资料库里记录的文件身份不比较设备号

**问题**：原件行记录登记时的设备号和 inode，读取、备份、删除时要求两者都与磁盘上的文件一致。用户把现有资料迁入新格式时，恢复停在清除旧备份配置这一步；核对发现那份配置记录的目录 inode 没变，设备号却从登记时的值变成了另一个值。macOS 不保证同一个卷的设备号跨重启或系统更新保持不变。按这个比较方式，卷被重新编号后资料库里的每个原件都会被判为无效；反向验证（把比较改回去）复现了这一点。

**选择**：记录下来的身份只比较 inode。原件总是从原件目录里按名字、以 no-follow 方式打开，而原件目录自身的身份在资料库打开期间固定，所以文件不可能在别的卷上，设备号不增加任何判别力。表结构、行摘要的算法和逻辑备份格式都不变，登记时的设备号继续写入。清除本机备份配置（恢复和重置时）也不再要求配置内容有效，只确认同名位置是当前用户私有的普通文件。

**未选择的替代方案**：打开资料库时把所有行的设备号改写成当前值——要在只读的打开路径上写库并重算行摘要，中断时留下一半新一半旧；去掉设备号列——改变表结构和行摘要，而项目只支持当前 schema；保留比较并提示用户“资料库已损坏”——数据完好，这是误报。

**影响的代码/文档**：[`SQLiteLibraryOwner.swift`](../Sources/KinloguePlatform/Storage/SQLiteLibraryOwner.swift) 的 `isFile(recordedAs:)` 及其在原件生命周期、LAN 上传和逻辑备份来源中的调用点；[`BackupLocalConfigurationStore`](../Sources/KinloguePlatform/Backup/BackupLocalConfigurationStore.swift) 的 `removeForDestructiveReset`；[`sqlite-storage.md`](sqlite-storage.md)、[`backup-and-restore.md`](backup-and-restore.md)。

**当时没有处理的同类依赖**（已由下一条决策处理）：备份配置记录自身、备份目标目录的身份、恢复事务和整库删除的收据仍然记录并比较设备号。前两者在卷被重新编号后使备份需要重新设置；后两者只在一次操作中断、且恰好在下次启动前卷被重新编号时才会无法收敛。这些没有改动，也没有验证过界面在这些情况下的表现。

**迁移/回滚要求**：没有迁移，已有的行不用改写。回滚即还原比较方式。

**验证门禁**：自动化结果见 [`log.md`](log.md)；真实的卷重新编号只能通过改写行里记录的设备号来模拟，没有在重启前后实测。

## [2026-10-13] 备份配置、备份目录和各类收据里记录的身份同样不比较设备号

**问题**：上一条只处理了原件行。备份配置记录用设备号加 inode 标识自己的目录、用户选择的父目录和 repository；验证记录里的摘要把 repository 和恢复点文件的设备号都算了进去；恢复、整库删除、初始化、备份捕获的收据和 DICOM 导入日志也记录设备号。卷被重新编号后，备份配置读取失败且无法重新设置；一次中断的恢复、删除、初始化或影像导入则让之后的每次启动失败或留下永不清理的残留。反向验证逐项复现了这些失败。

**选择**：这些记录下来的身份一律只比较 inode，设备号照原样保留、不改写。备份这一侧通过 `BackupFilesystemIdentity` 和 `BackupRestoreDirectoryIdentity` 的相等性统一实现，而不是逐个调用点改写：比较点有三十多处，漏掉任何一处的后果都要等到卷被重新编号才显现。验证记录的摘要改用配置里登记的设备号代替文件当前的设备号，使已有的验证记录在重新编号前后算出同一个值。

**未选择的替代方案**：发现设备号变化时把配置改写成当前值——验证记录的摘要也得跟着重算，需要访问 repository 并且要能从中断中恢复，而且外接卷每次挂载都可能触发；给摘要换一个不含设备号的新版本——已有的验证记录全部失配，保留策略要等新的备份逐个补齐才能恢复；逐个调用点区分“记录的”和“当前的”身份——更精确，但两种身份是同一个类型，分类错一处就是一个潜伏的故障。

**代价**：同一次运行里取得的两个身份之间也不再比较设备号。需要“在同一个卷上”的地方保留了显式的设备号比较；其余比较的双方本来就在同一个父目录之下。一个不同的卷上恰好有相同 inode 的目录，并且经同一个 bookmark 解析到、里面还有同一个备份集的有效内容，才会被当成同一个 repository，这种情况实际上只有整盘克隆会出现。

**影响的代码/文档**：[`BackupLocalConfigurationStore.swift`](../Sources/KinloguePlatform/Backup/BackupLocalConfigurationStore.swift)、[`EncryptedCheckpointRestore.swift`](../Sources/KinloguePlatform/Backup/EncryptedCheckpointRestore.swift)、[`BackupRepository.swift`](../Sources/KinloguePlatform/Backup/BackupRepository.swift)、[`EncryptedCheckpointWriter.swift`](../Sources/KinloguePlatform/Backup/EncryptedCheckpointWriter.swift)、整库删除事务、初始化收据、捕获收据和 DICOM 暂存归属；[`backup-and-restore.md`](backup-and-restore.md)、[`sqlite-storage.md`](sqlite-storage.md)。

**仍然含设备号、没有改动的地方**：owner 锁文件的命名（重新编号后改用新名字，不影响互斥）、安装验收运行的归属收据（只在一次验收运行内有效）以及各处同一次运行内的身份比较。

**迁移/回滚要求**：没有迁移，记录格式不变。回滚即还原相等性和摘要的取值方式；回滚后在重新编号之后新写入的验证记录会与旧算法失配。

**验证门禁**：自动化结果见 [`log.md`](log.md)；卷重新编号仍然只通过改写记录里的设备号模拟，没有在重启前后实测，外接卷和网盘目录上的备份目录也没有实测。

## [2026-10-14] 搜索结果列出命中的检验表格行，属于呈现

**问题**：一款[同类 iPhone 应用](sources/2026-10-14-carehealth-competitor-notes.md)把检验报告拆成一行行指标，搜索指标名就能看到历次数值。续页的表格抽取已经把每行写成“项目⇥结果⇥参考值”，存在已确认的检查结果里，但搜索只返回整条报告，搜索卡片上也没有日期。需要判断：按日期列出同一项目的原文数值，算“呈现来源”还是“趋势分析”。

**选择**（用户 2026-10-14 决策）：算呈现。搜索结果卡片显示报告日期；搜索词出现在已确认检查结果的某个表格行里时，卡片在结论的位置逐格列出这些行，最多 8 行，并注明另有几行匹配。

- 只取已确认记录检查结果（`reportedResults`）中至少有两个非空单元格的制表符分隔行；标题、结论、异常标记等其他字段里的行不列出。
- 单元格逐字显示：不解析数值、单位或范围，不跨报告比较，不画图、不加箭头，也不判断正常与否；报告自己印的“↑”“H”留在原单元格里。这一块界面不使用任何状态色。
- 结果沿用搜索已有的时间线顺序；按成员筛选时，就是这个人这一项目的历次记录。
- 不新增持久化字段，不改搜索表、schema 或备份格式。

同日用户又确认两项搜索呈现：卡片上的标题、机构和命中行里，搜索词加粗并用 Primary 标出（同一套本地化、不区分大小写的匹配）；没有命中表格行、搜索词又不在卡片已显示的标题、机构或日期里时，在结论的位置显示命中字段的一段上下文（命中处之前最多 30 个字符，总长约 120 个字符，空白折叠为一个空格，两端截断处加省略号）。摘录直接取自已校验的搜索字段，不多读详情；只命中成员名时不显示摘录。README“为什么做续页”同时补上纸质报告褪色、线上报告有查看或下载期限这一动机。

**未选择的替代方案**：把每行存成结构化指标（名称、数值、单位、参考范围）并在复核页逐行确认——查询更快，也能做单项历史页，但要改 schema、备份格式和复核界面，而资料库不提供迁移；按项目名自动合并、画趋势图或按参考范围标注正常/异常——同名项目可能来自不同时点或方法（例如空腹与餐后），合并和判断都会写出原报告没有的结论；只在详情页把检查结果排成表格——不解决“按项目找历次数值”。

**影响的代码/文档**：新增 [`ReportedResultLine`](../Sources/KinlogueCore/Domain/ReportedResultLine.swift) 与 [`SearchExcerpt`](../Sources/KinlogueCore/Domain/SearchExcerpt.swift)；[`LibraryReportSummary`](../Sources/KinlogueCore/Domain/LibraryReportQuery.swift) 增加有界的命中行与摘录；[`SQLiteReportSearch`](../Sources/KinloguePlatform/Storage/SQLiteReportSearch.swift) 的 `match` 与 [`SQLiteReportRepository`](../Sources/KinloguePlatform/Storage/SQLiteReportRepository.swift) 的搜索分页；[`TimelineView`](../Sources/KinlogueApp/Views/TimelineView.swift) 的搜索卡片、`SearchHighlight` 与中英文案；[`README.md`](../README.md)。专题页见 [`project-overview.md`](project-overview.md)、[`domain-and-data-model.md`](domain-and-data-model.md)、[`import-and-ocr.md`](import-and-ocr.md)、[`sqlite-storage.md`](sqlite-storage.md)、[`design-system.md`](design-system.md)。“当前明确不做”里的趋势分析不变。

**迁移/回滚要求**：没有持久化变化，已有资料库和恢复点无需迁移；回滚只需撤回代码。

**验证门禁**：定向测试见 [`log.md`](log.md)。近上限资料库的首页计时对照和合成版式的端到端核对见 [搜索呈现测量](search-presentation-measurement-2026-10-14.md)：除每份列出报告的表格行全部命中的情况外，首页与不做呈现时相差不超过 3 ms。真实报告上抽取出的表格行质量、键盘与 VoiceOver 朗读仍属人工矩阵。

## [2026-10-16] 成员对话：经用户本机 Codex 的外发例外

**问题**：用户希望按家庭成员用对话方式了解和询问其资料（2026-10-15）。这要把报告内容发给模型服务，与“不连接互联网或云服务”的承诺冲突；还要决定外部 CLI 在哪个进程运行、发送什么、何时同意，以及回答能说什么。

**选择**（用户 2026-10-15 确定计划第 9 节的 D1–D8、E1–E2；2026-10-16 要求按计划继续 U6，包括默认把 bridge 放进构建）：

- 外发只经用户本机已安装并登录的 Codex，续页不内置模型服务或密钥；功能默认关闭，在设置中开启。首版只做 Codex（D6）。
- 方案 A（D1）：单独签名、启用 App Sandbox 的 XPC bridge，加 `network.client`、本机回环 listener、`~/.codex/` 读写和 `/opt/homebrew/`、`/usr/local/` 只读例外；主 App 的 entitlement 不变。
- 模型没有工具，只发送事先组好、可逐字预览的上下文包（D2）；同意按对话计，CLI、模型或上下文包变化即失效（D3）；机构名称默认不发送（D7）。
- 允许按时间描述性地排列同一项目的原文结果并逐条引用，不做好转、恶化或正常与否的判断（D5）。这是与“当前不做趋势分析”的边界：排列原文属于呈现，判断属于趋势分析。
- 只支持 Codex 自己登录的 OpenAI 账号，不加载用户的 Codex 配置（E2）；代理变量在设置中填写（E1），界面首版只提供一个代理地址字段，同时写入 `HTTPS_PROXY` 与 `HTTP_PROXY`。
- 首版不保存对话（D4）；保存对话与资料库 v1→v2 迁移在 U7 单独发布（D8）。

**未选择的替代方案**：主 App 直接启动 CLI——子进程继承主 App 的沙盒，读不到登录、没有出站网络，给主 App 加例外又会扩大主进程权限；非沙盒 helper（方案 B）——行为最可预测，但 helper 不受沙盒约束；内置锁定版本的 Codex 并自做授权（方案 C）——不复用用户已有登录，体积约 247 MB；反向 MCP 桥接（方案 D）——对话不在 App 内，外部进程要读 App 容器；让模型按需调用工具读取资料——D2 否决。

**影响的代码/文档**：`Sources/KinlogueAssistant*/`、`KinlogueCore/Assistant`、`KinloguePlatform/Assistant`、App 的 `AssistantService`、对话与设置模型和界面；[`packaging/KinlogueAssistantBridge.entitlements`](../packaging/KinlogueAssistantBridge.entitlements)；`build-app.sh`、`verify-app.sh`、`package-distribution.sh`、`build-acceptance-app.sh`、`privacy-guard.sh`、`verify-assistant-xpc.sh`；README、PRIVACY、[`privacy-and-security.md`](privacy-and-security.md)、[`project-overview.md`](project-overview.md)、[`architecture.md`](architecture.md)、[`design-system.md`](design-system.md)、[`localization.md`](localization.md)、[`testing-and-release.md`](testing-and-release.md)、[`brand.md`](brand.md)、`AGENTS.md` 和[成员对话验收矩阵](acceptance/member-chat-matrix.md)。

**迁移/回滚要求**：没有持久化变化，对话只在内存，设置在 App 偏好的 `assistant.*` 键；回滚只需撤回代码与发布门禁。已经发送给服务方的内容不能因回滚而撤回。

**验证门禁**：自动化与未执行的人工门禁见[成员对话验收矩阵](acceptance/member-chat-matrix.md)。经真实 Codex 的完整一轮、第 3.2 节回答边界的人工检查，以及 Developer ID 与公证下 temporary exception 的表现，都还没有执行。

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
6. 是否以及如何引入运动数据（数据来源、本机或联网、隐私承诺改写），以及模型问答在首版之后的扩展（U7 保存对话与第一次 schema 迁移、Claude Code、本机模型、按问题检索）。首版成员对话见上面 2026-10-16 的决策和[成员对话验收矩阵](acceptance/member-chat-matrix.md)，其中经真实 Codex 的人工门禁尚未执行。在对应决策完成前，HealthKit、趋势分析和诊断性输出继续属于当前明确不做；其余待决事项见 [`brand.md`](brand.md)。

## 决策更新规则

新决策必须写清：问题、选择、未选择的替代方案、影响的代码/文档、迁移/回滚要求、验证门禁和日期。完成后更新本页、相关专题页、`docs/index.md` 和 [`docs/log.md`](log.md)；不通过删除旧段落来抹掉历史。
