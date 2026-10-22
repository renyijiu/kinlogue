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
| 明文 ZIP 备份 | 备份、导出与恢复只有一种文件：不加密的 `.zip`（索引 + logical-v1 数据 + 按成员排列的全部原件）。写进用户所选文件夹或保存面板所选位置；保留 1–30 份，只删除本机写入且未被改动的文件；恢复只读索引点名的条目并整库替换。不再读取加密 `.kinloguebackup`。 | 用户 2026-10-19 决策、[`backup-and-restore.md`](backup-and-restore.md)、[`PRIVACY.md`](../PRIVACY.md) |
| 成员对话是唯一的外发例外 | 默认关闭。用户开启并按对话确认后，单独签名的沙盒 XPC bridge 启动用户本机已登录的 Codex，只经 stdin 发送一位成员的已确认报告投影与问答；模型没有工具，回答不进入时间线、搜索或比较；对话保存在资料库并随备份 ZIP 写出。主 App 的 entitlement 不变。 | [成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md) D1–D8、E1–E2，[`PRIVACY.md`](../PRIVACY.md) |
| 首发前 current-only | 项目未公开发布，只支持当前的 SQLite schema（版本 3）与 ordering policy v2，不做原地迁移，旧 schema 的资料库由新构建从备份恢复来升级（见下文 2026-10-18、2026-10-19）；开发期的 JSON 清单存储、v1/v2 reader/migrator、policy v1 和 predecessor/rollback 路径已删除。除恢复先前由用户明确发起、且已写入有效 durable deletion receipt 的整库删除外，旧开发 Vault、未知版本、未知非空目录和损坏布局继续非破坏性 fail closed；App 不自动迁移、覆盖或删除其字节，用户可在仓库外导出后手工重置。 | 用户 2026-08-12 决策、[`storage.md`](storage.md)、[`dicom.md`](dicom.md) |

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

**影响的代码/文档**：[`SQLiteLibraryOwner.swift`](../Sources/KinloguePlatform/Storage/SQLiteLibraryOwner.swift) 的 `isFile(recordedAs:)` 及其在原件生命周期、LAN 上传和逻辑备份来源中的调用点；`BackupLocalConfigurationStore` 的 `removeForDestructiveReset`；[`sqlite-storage.md`](sqlite-storage.md)、[`backup-and-restore.md`](backup-and-restore.md)。

**当时没有处理的同类依赖**（已由下一条决策处理）：备份配置记录自身、备份目标目录的身份、恢复事务和整库删除的收据仍然记录并比较设备号。前两者在卷被重新编号后使备份需要重新设置；后两者只在一次操作中断、且恰好在下次启动前卷被重新编号时才会无法收敛。这些没有改动，也没有验证过界面在这些情况下的表现。

**迁移/回滚要求**：没有迁移，已有的行不用改写。回滚即还原比较方式。

**验证门禁**：自动化结果见 [`log.md`](log.md)；真实的卷重新编号只能通过改写行里记录的设备号来模拟，没有在重启前后实测。

## [2026-10-13] 备份配置、备份目录和各类收据里记录的身份同样不比较设备号

**问题**：上一条只处理了原件行。备份配置记录用设备号加 inode 标识自己的目录、用户选择的父目录和 repository；验证记录里的摘要把 repository 和恢复点文件的设备号都算了进去；恢复、整库删除、初始化、备份捕获的收据和 DICOM 导入日志也记录设备号。卷被重新编号后，备份配置读取失败且无法重新设置；一次中断的恢复、删除、初始化或影像导入则让之后的每次启动失败或留下永不清理的残留。反向验证逐项复现了这些失败。

**选择**：这些记录下来的身份一律只比较 inode，设备号照原样保留、不改写。备份这一侧通过 `BackupFilesystemIdentity` 和 `BackupRestoreDirectoryIdentity` 的相等性统一实现，而不是逐个调用点改写：比较点有三十多处，漏掉任何一处的后果都要等到卷被重新编号才显现。验证记录的摘要改用配置里登记的设备号代替文件当前的设备号，使已有的验证记录在重新编号前后算出同一个值。

**未选择的替代方案**：发现设备号变化时把配置改写成当前值——验证记录的摘要也得跟着重算，需要访问 repository 并且要能从中断中恢复，而且外接卷每次挂载都可能触发；给摘要换一个不含设备号的新版本——已有的验证记录全部失配，保留策略要等新的备份逐个补齐才能恢复；逐个调用点区分“记录的”和“当前的”身份——更精确，但两种身份是同一个类型，分类错一处就是一个潜伏的故障。

**代价**：同一次运行里取得的两个身份之间也不再比较设备号。需要“在同一个卷上”的地方保留了显式的设备号比较；其余比较的双方本来就在同一个父目录之下。一个不同的卷上恰好有相同 inode 的目录，并且经同一个 bookmark 解析到、里面还有同一个备份集的有效内容，才会被当成同一个 repository，这种情况实际上只有整盘克隆会出现。

**影响的代码/文档**：`BackupLocalConfigurationStore.swift`、`EncryptedCheckpointRestore.swift`、`BackupRepository.swift`、`EncryptedCheckpointWriter.swift`、整库删除事务、初始化收据、捕获收据和 DICOM 暂存归属；[`backup-and-restore.md`](backup-and-restore.md)、[`sqlite-storage.md`](sqlite-storage.md)。

**后续**：本条列出的备份配置、repository 与验证记录已随 2026-10-19 的决策删除；新的设置存储、文件夹记录和账本沿用只比较 inode 的规则。

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

## [2026-10-15] 叙述命中按句呈现、识别误读只提示不替换、已确认报告可按新规则整理

**问题**：同一帖子的[后续回复](sources/2026-10-15-carehealth-thread-followup.md)里，有用户想对比多份超声报告的关键信息，也有用户因为 OCR 加手工补录太繁琐而放弃使用。续页对叙述型报告的搜索只显示第一处命中附近约 120 字的摘录；复核时识别误读要用户自己发现；已确认报告不参与抽取规则升级，version 6 的表格改进只惠及新导入的报告。

**选择**（用户 2026-10-15 决策，按“看看如何优化”后给出的建议实施）：

1. **叙述命中按句呈现**：没有命中表格行时，从已确认的检查结果和检查结论里列出含搜索词的句子，最多 3 句，先检查结果后检查结论，每句标明出自哪个字段，另有几处匹配时注明。句子按“。；;！!？?”切分，不按换行（识别结果在页面折行处换行）也不按句点（与小数点相同）；单句过长时只截取命中附近，与摘录相同。仍是对原文的呈现：不提取、不比较、不判断。命中只在其他字段时仍显示摘录。
2. **异常标记带上所在行（抽取规则 version 7）**：报告印的高低标记落在已识别的检验表格行里时，异常标记取整行（项目、带标记的结果、参考值），来源引用指向整行；印在单独“提示”列里的标记也算。表格外的标记照旧。
3. **识别误读只提示**：复核页和已确认记录的编辑页在检查结果下列出“可能的识别错误”，只覆盖合成核对中实际见过的三种：结果格里数值后的“个”或“T”应为“↑”，“UIL”应为“U/L”，项目名里的“自细胞/自蛋白/自球比”应为“白”。每条由用户点“采纳”或“忽略”，不预先替换；采纳按用户修正保存，识别原文保留。与“査→查”预先还原不同，箭头有医学含义，自动替换错了会凭空造出异常标记。
4. **已确认报告按新规则整理**：打开一份 OCR 结果由旧规则抽取的已确认报告时，App 用当前规则对保存的 OCR block 重新抽取（不重新识别原件），字段有差异就在详情页显示提示。用户在对照页逐项勾选，默认全部保留；用户改过或手动填写的字段注明“使用新规则会替换你的修改”。保存时记录 revision 加一，同一事务里把保留的 OCR 文档换成新候选与当前规则版本，此后不再提示；不勾选任何字段也会这样记下。成员、日期和备注不参与。

**未选择的替代方案**：叙述报告按器官或项目抽取结构化字段再对比——超出“只呈现原文”的边界，且需要新的抽取模型；识别误读自动替换或按词典大范围纠错——会在用户没注意时改写原文，规则越多误报越多；已确认报告升级规则时自动覆盖未修改的字段——用户确认过的内容在不知情时被改变；整库批量重新整理入口——先做逐份提示，批量入口以后再定。

**影响的代码/文档**：新增 [`SearchPassage`](../Sources/KinlogueCore/Domain/SearchPassage.swift)、[`RecognitionSuggestion`](../Sources/KinlogueCore/OCR/RecognitionSuggestion.swift)、[`RecordRuleUpdate`](../Sources/KinlogueCore/Import/RecordRuleUpdate.swift)、[`RecognitionSuggestionsPanel`](../Sources/KinlogueApp/Views/RecognitionSuggestionsPanel.swift) 与 [`RecordRuleUpdateView`](../Sources/KinlogueApp/Views/RecordRuleUpdateView.swift)；[`ReportCandidateExtractor`](../Sources/KinlogueCore/OCR/ReportCandidateExtractor.swift) 升到 version 7；[`SQLiteReportSearch`](../Sources/KinloguePlatform/Storage/SQLiteReportSearch.swift) 记住检查结果与结论两个字段的位置；[`SQLiteReportRepository`](../Sources/KinloguePlatform/Storage/SQLiteReportRepository.swift) 新增读取记录与其 OCR 文档、以及二者同事务更新；[`AppModel`](../Sources/KinlogueApp/App/AppModel.swift)、[`LiveAppService`](../Sources/KinlogueApp/App/AppServices.swift)、[`TimelineView`](../Sources/KinlogueApp/Views/TimelineView.swift)、[`RecordDetailView`](../Sources/KinlogueApp/Views/RecordDetailView.swift) 与中英文案。专题页见 [`project-overview.md`](project-overview.md)、[`domain-and-data-model.md`](domain-and-data-model.md)、[`import-and-ocr.md`](import-and-ocr.md)、[`sqlite-storage.md`](sqlite-storage.md)、[`design-system.md`](design-system.md)。

**迁移/回滚要求**：没有 schema、搜索行或备份格式变化。按新规则整理会改写该报告保留的 OCR 文档行（候选与规则版本），blocks 不变，只在用户保存时发生；回滚代码后旧版本照常读取，只是不再提示。version 7 只影响之后的抽取，已确认记录不会被自动改写。

**验证门禁**：定向测试与完整测试见 [`log.md`](log.md)，叙述命中的规模计时见 [搜索呈现测量](search-presentation-measurement-2026-10-14.md#叙述命中按句呈现的复测2026-10-15)。三种识别误读规则只来自合成核对，真实报告上的命中与误报没有核对；按新规则整理只用合成 block 验证过；键盘、VoiceOver 与窄窗口下的对照页仍属人工矩阵。

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

**迁移/回滚要求**：首版对话只在内存，设置在 App 偏好的 `assistant.*` 键；保存对话带来的 schema 迁移见下一节。已经发送给服务方的内容不能因回滚而撤回。

**验证门禁**：自动化与未执行的人工门禁见[成员对话验收矩阵](acceptance/member-chat-matrix.md)。2026-10-16 经使用者同意，用真实 Codex 经签名沙盒 bridge 跑了完整一轮和 21 个合成边界问题，回答守住第 3.2 节边界（[来源笔记](sources/2026-10-16-member-chat-real-codex-check.md)）；这次检查发现并修正了沙盒改写 supervisor `HOME` 导致始终“未登录”的问题。App 界面上的人工检查、失败场景，以及 Developer ID 与公证下 temporary exception 的表现仍未执行。

## [2026-10-16] 资料库第一次 schema 迁移：v1 到 v2，只为保存成员对话

> **已被 2026-10-18 的决定取代**：首发前不再保留任何原地迁移，只认当前 schema，旧资料库经恢复点升级（见下一节）。本条只解释当时为什么做了迁移；它描述的迁移代码与测试已删除。

**问题**：保存成员对话（计划 U7、D8）要在资料库里加表，而“首发前 current-only”规定只支持当前 schema，未知版本一律失败关闭、不迁移。用户的真实资料库已经是 schema 版本 1。

**选择**（用户 2026-10-15 同意 D8，作为 current-only 的唯一例外；2026-10-16 要求实现 U7）：

- 当前版本为 2；版本 1 只作为迁移输入，其他版本照旧失败关闭、不改写。版本 1 的 DDL 原样冻结在代码里，只用于校验迁移输入。
- 普通打开时，在单实例 owner 下、普通服务开始之前，先按版本 1 做完整校验，再在单个事务里只新增三张对话表、写 `user_version = 2`、更新 `library_state` 的 schema identity 及该行摘要；不读取、不改写其他行，也不碰原件。提交后按版本 2 重新校验。
- 恢复点的逻辑流升到版本 2，reader 同时接受版本 1；版本 1 恢复点恢复为没有对话的版本 2 资料库。
- 迁移只建空表，耗时与资料库大小无关，因此没有单独的“正在升级”启动页，也不自动备份；建议在升级前手动做一次恢复点。

**未选择的替代方案**：单独的对话数据库文件——不需要迁移，但对话和记录不在同一事务里，默认也不进入恢复点；继续只在内存里保存——不满足 D8。

**迁移/回滚要求**：迁移后更早的构建打不开这个资料库（照旧以“格式不受支持”失败关闭、不改写），也读不了版本 2 恢复点。需要回到旧构建时，只能用迁移前的恢复点在旧构建中恢复。

**验证门禁**（当时；相应测试与冻结的版本 1 资料库已于 2026-10-18 随迁移删除）：`SQLiteSchemaMigrationTests` 用 2026-10-16 由迁移前代码写出并冻结的版本 1 资料库：已有行逐行不变、`library_state` 只有 identity 与摘要变化、未知版本与带漂移的版本 1 不被改写、四个中断点（含真实进程强退）之后只剩完整的版本 1 或版本 2；两个版本 1 和一个版本 2 冻结逻辑流可以恢复。真实资料库上的迁移没有在测试中执行。

## [2026-10-18] 资料库 schema 版本 3，首发前不做原地迁移

**问题**：[分层上下文包](plans/2026-10-18-feat-member-chat-layered-context-plan.md)让包内编号覆盖最多 300 份报告，一轮回答可能引用超过 20 份；但 schema 版本 2 的 `assistant_turn_sources` 用 `CHECK(position < 20)` 写死了每轮最多 20 个来源，超过时保存会失败、这一轮回答丢失。用户的真实资料库已经是版本 2。

**选择**（用户 2026-10-18）：

- 先选择“现在升 schema”，而不是保持 20 并把超出的引用显示为“未保存来源”。随后用户提出 App 还没发布、可以去掉迁移逻辑，选择简化：首发前**只认当前 schema**，不保留任何原地迁移。2026-10-16 为保存对话所做的 v1→v2 迁移一并撤销，回到原有的“首发前 current-only”。
- 当前版本为 3，每轮来源上限 `AssistantLimits.maxTurnSources` 为 300，与目录上限一致。版本 1、2 以及未知版本的资料库一律“格式不受支持”失败关闭，不改写、不删除；启动页照旧只提供“从恢复点恢复”。
- **恢复点是唯一的升级途径**：在旧构建里做一次恢复点，在新构建的启动页从它恢复。逻辑流升到版本 3（记录种类与版本 2 相同），reader 继续接受版本 1 至 3；版本 2 流里每轮超过 20 个来源视为无效流。首发前以后的 schema 变化同样走这条路，不再写迁移代码。

**未选择的替代方案**：

- 原地迁移（v1、v2 都迁到 v3）——已经实现并通过测试，但需要冻结每个旧版本的 DDL 和资料库夹具、故障注入点与真实进程强退测试；首发前每次 schema 变化都要重复一遍。只有作者自己在用，恢复点路径足够。
- 保持 20 个来源——不动 schema，但分层上下文包正是为“列出历年结果”这类会引用多份报告的问题而做，降级会经常出现。

**后续**：2026-10-19 起备份改为明文 ZIP、不再读取加密恢复点，升级途径改为从备份 ZIP 恢复，见下一节。

**迁移/回滚要求**：没有原地迁移。已有的版本 1、2 资料库需要先用旧构建做恢复点，再在新构建中恢复；恢复会整根替换资料库目录。更早的构建打不开版本 3 资料库，也读不了版本 3 恢复点；需要回到旧构建时，只能用旧构建写的恢复点在旧构建中恢复。

**验证门禁**：[`SQLiteLibraryStoreTests`](../Tests/KinloguePlatformTests/SQLiteLibraryStoreTests.swift) 核对版本 1、2 和更新的版本都以“格式不受支持”被拒且字节不变；冻结的版本 1、版本 2 逻辑流照常恢复到版本 3 资料库并以版本 3 重新写出同样的记录；[`AssistantConversationStoreTests`](../Tests/KinloguePlatformTests/AssistantConversationStoreTests.swift) 核对各版本流的来源上限。

## [2026-10-19] 备份去掉加密，与导出合并为一种明文 ZIP

**问题**：备份与恢复和“导出原始文件”是两套写入器、两种文件。加密恢复点要求恢复码、设备签名身份、隐藏 repository、witness 与 publication lease，设置和排障都重；用户无法在 Finder 里看清备份里有什么、也无法自己管理份数。导出只含已确认原件，不能用来恢复。

**选择**（用户 2026-10-19 提出合并、“接受明文备份的代价，4 个决定都按推荐来”；设计见 [明文 ZIP 备份计划](plans/2026-10-19-1715-feat-plain-zip-backup-export-plan.md)）：

1. 只有一种文件：明文 `.zip`。包内是 `kinlogue-backup.json` 索引、说明文件、`data/library.klog`（逻辑流，格式不变；当前写版本 3）和 `files/` 下按成员与日期排列的全部原件，每个原件只出现一次。索引的 `encryption` 字段固定为 `"none"`，为以后整包外加一层加密预留。
2. 立即备份和自动备份写进用户所选的文件夹本身（不建子文件夹），排他重命名、从不覆盖；“导出备份到…”写到保存面板所选位置，格式相同、可以恢复，不计入保留。
3. 保留份数由用户设定（1–30，默认 5）。超出时直接删除，不移到废纸篓；只删除账本里记着的、本机写入且名字、inode、大小、修改时间都没变的单链接普通文件，对不上的从账本移除而不删除；新备份没发布并核对完成前一个旧文件也不删。
4. 恢复直接选一个 `.zip`：整个文件当作不可信输入，只读索引点名的条目，逐项核对长度、CRC-32 和 SHA-256，包内名字从不用来建文件；沿用 staging、preflight 收据和 whole-root 恢复事务。恢复时关闭自动备份。
5. 不再读取加密 `.kinloguebackup` 恢复点（决定 1）；不保留单独的“只含已确认原件”导出，给医生看时解压后发送对应成员的文件夹（决定 2）。

**未选择的替代方案**：保留加密并只简化设置流程——恢复码和设备身份仍是主要负担，且备份仍不可直接浏览；保留旧恢复点的只读路径——要留下约 3,000 行密码学与容器代码，项目尚未发布、只影响自用；为医生保留单成员导出模式——同一写入器上的第二种不可恢复格式，用户需要区分两种文件；在所选文件夹里固定建“续页备份”子文件夹——用户可以在选择面板里自己新建；把多余备份移到废纸篓——外置盘和网络卷上未必可用，且不释放空间。

**代价**：备份不再保密。拿到文件的人能读取全部成员、报告、OCR 转录和原件；放在网盘同步目录里时，网盘服务商和能登录该账号的人都能读取。SHA-256 与 CRC-32 只发现意外损坏，同时改了内容和索引的包会被当作有效备份。设置页、导出面板和包内说明文件写明备份不加密；[`PRIVACY.md`](../PRIVACY.md) 与 [`README.md`](../README.md) 建议把备份放在开启 FileVault 的磁盘、加密外置盘或加密磁盘映像上。整份备份含全家人的资料，不应直接交给医生。

**影响的代码/文档**：新增 Core 的 [`BackupArchiveIndex`](../Sources/KinlogueCore/Backup/BackupArchiveIndex.swift)、[`BackupArchivePlan`](../Sources/KinlogueCore/Backup/BackupArchivePlan.swift)、[`BackupRetention`](../Sources/KinlogueCore/Backup/BackupRetention.swift)，Platform 的 [`BackupArchiveWriter`](../Sources/KinloguePlatform/Backup/BackupArchiveWriter.swift)、[`BackupArchiveReader`](../Sources/KinloguePlatform/Backup/BackupArchiveReader.swift)、[`BackupSettingsStore`](../Sources/KinloguePlatform/Backup/BackupSettingsStore.swift)、[`BackupFolderRetention`](../Sources/KinloguePlatform/Backup/BackupFolderRetention.swift)，App 的 [`BackupFolderAuthority`](../Sources/KinlogueApp/Backup/BackupFolderAuthority.swift)、[`LiveBackupService`](../Sources/KinlogueApp/Backup/LiveBackupService.swift)、[`BackupExportModel`](../Sources/KinlogueApp/ViewModels/BackupExportModel.swift) 与设置页“数据备份与导出”分区；[`BackupArchiveRestore`](../Sources/KinloguePlatform/Backup/BackupArchiveRestore.swift) 由加密恢复改为按索引读 ZIP。删除恢复码、密钥层级、HPKE/AES-GCM 容器、设备签名身份与信任记录、repository、witness、publication lease、旧导出器及其测试。专题页见 [`backup-and-restore.md`](backup-and-restore.md)、[`storage.md`](storage.md)、[`sqlite-storage.md`](sqlite-storage.md)、[`privacy-and-security.md`](privacy-and-security.md)，以及 [`README.md`](../README.md)、[`PRIVACY.md`](../PRIVACY.md)、[`SECURITY.md`](../SECURITY.md)。

**迁移/回滚要求**：资料库 schema 与逻辑流格式不变，没有资料库迁移。2026-10-18 规定的升级途径因此从加密恢复点改为备份 ZIP：已有的版本 1、2 资料库只有当时构建写的加密恢复点，需要先用合入本决策之前、能读加密恢复点的 schema 3 构建恢复一次，之后当前构建可以直接打开。旧版本在 `Application Support/Kinlogue/BackupIdentity/` 留下的设备私钥、恢复公钥和验证记录在启动时只按已知文件名移除（2026-10-22 起取消：首发前不保留这类清理代码，残留文件由用户自行删除）；用户文件夹里的 `.kinloguebackup` 和隐藏 `.kinlogue-backup-v1` 目录不被改动，当前版本也不读取它们。需要用旧恢复点恢复的人只能使用旧版本 App，因此升级后应先做一份新的 ZIP 备份。回滚代码后旧版本不认识 ZIP，也不认识新的 `Backup/settings.json`，需要重新完成加密备份设置。

**验证门禁**：自动化结果见 [`log.md`](log.md)。安装后的 App 上实际选择文件夹、备份、轮换与恢复，接近上限的 ZIP64 规模，阿里云盘、百度网盘客户端对文件夹的处理，外置盘与 NAS，Windows 与访达对中文路径的解压，以及键盘和 VoiceOver 均未执行，状态见 [`acceptance/current-release.md`](acceptance/current-release.md)。

## 已被 supersede 的早期决策

[`2026-08-01-001-feat-kinlogue-macos-vault-plan.md`](plans/2026-08-01-001-feat-kinlogue-macos-vault-plan.md) 早期计划曾以“加密 Vault、Keychain、加密 backup/restore”为 MVP 方向；它已被明文 MVP 计划的 `supersedes` 字段覆盖。它仍然保留 threat model、早期 target 规划和未来安全升级的背景，但不能作为当前代码或隐私文案的事实来源。

[`2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md`](plans/2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md) 的加密恢复点、恢复码和设备身份已由上面 2026-10-19 的决策取代，代码已删除；它只用于解释早期设计和威胁模型。

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
5. 未来是否加入应用层加密、Keychain、可验证明文到加密迁移、备份加密或云同步；在决策完成前保持当前边界。
6. 是否以及如何引入运动数据（数据来源、本机或联网、隐私承诺改写），以及模型问答在首版之后的扩展（Claude Code、本机模型、按问题检索）。首版成员对话见上面 2026-10-16 的决策和[成员对话验收矩阵](acceptance/member-chat-matrix.md)，其中界面与失败场景的人工门禁尚未执行。在对应决策完成前，HealthKit、趋势分析和诊断性输出继续属于当前明确不做；其余待决事项见 [`brand.md`](brand.md)。

## 决策更新规则

新决策必须写清：问题、选择、未选择的替代方案、影响的代码/文档、迁移/回滚要求、验证门禁和日期。完成后更新本页、相关专题页、`docs/index.md` 和 [`docs/log.md`](log.md)；不通过删除旧段落来抹掉历史。
