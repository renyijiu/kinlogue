# Kinlogue 项目知识库

这是当前项目 Wiki 的导航入口。产品契约、实现边界和验收证据分别由对应专题页维护；代码、测试、`Package.swift`、打包配置和脚本仍是最终可执行事实。

## 从哪里开始

- 新贡献者或 Agent：先读 [`../AGENTS.md`](../AGENTS.md)，再读 [`project-overview.md`](project-overview.md)。
- 准备 issue、PR 或安全报告：读 [`../CONTRIBUTING.md`](../CONTRIBUTING.md) 和 [`../SECURITY.md`](../SECURITY.md)，只使用合成数据。
- 想理解模块与调用链：读 [`architecture.md`](architecture.md)。
- 想改资料库、格式版本、删除或导出：读 [`storage.md`](storage.md)、[`sqlite-storage.md`](sqlite-storage.md) 和 [`privacy-and-security.md`](privacy-and-security.md)。
- 想改报告导入/OCR：读 [`import-and-ocr.md`](import-and-ocr.md)。
- 想改手机上传：读 [`lan-upload.md`](lan-upload.md)。
- 想改 DICOM：读 [`dicom.md`](dicom.md)。
- 想构建、测试或发布候选包：读 [`testing-and-release.md`](testing-and-release.md) 和 [`acceptance/current-release.md`](acceptance/current-release.md)。
- 想公开源码或净化 Git 历史：读 [`privacy-and-security.md`](privacy-and-security.md) 和 [`testing-and-release.md`](testing-and-release.md)。
- 想了解同步目录备份/恢复：读 [`backup-and-restore.md`](backup-and-restore.md)、实施计划和 [`acceptance/current-release.md`](acceptance/current-release.md)。
- 想改界面或文案：读 [`design-system.md`](design-system.md) 和 [`localization.md`](localization.md)。
- 想改名称、标语、应用图标或了解产品方向：读 [`brand.md`](brand.md)。
- 想了解或修改成员对话（AI 对话，实验）：先读 [`../PRIVACY.md`](../PRIVACY.md) 的对应一节和 [`privacy-and-security.md`](privacy-and-security.md)，再读 [成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md) 与 [成员对话验收矩阵](acceptance/member-chat-matrix.md)；真实 Codex 的 bridge 段与边界问题已检查，界面与失败场景的人工门禁尚未执行。

当前最低系统已调整为 macOS 26，主要面向个人自用；Xcode 27 构建适配、CI Metal 组件准备、基线检查名兼容与 DICOM 崩溃恢复探针的重启等待预算见 [`testing-and-release.md`](testing-and-release.md)，转录编辑器的系统写作工具边界见 [`import-and-ocr.md`](import-and-ocr.md)；旧系统支持决策见 [`decisions.md`](decisions.md)，macOS 26/27 验收状态见 [`acceptance/current-release.md`](acceptance/current-release.md)。

本分支按 [SQLite 与架构重构计划](plans/2026-10-10-2322-refactor-sqlite-architecture-plan.md) 把资料库从 JSON 清单换成 [SQLite 数据库加不可变原件](sqlite-storage.md)，并已合入 main 的时间线、配色和品牌更新。备份与去重的平方增长、容量格式、App 任务归属、报告/OCR、LAN、规范化 DICOM、逻辑备份/严格恢复、原件导出、按需查询、提交观察和空闲完整性巡检都已实现并有真实链路测试。**正式界面入口从 2026-10-12 起只打开 SQLite 资料库**；已有的 JSON 资料库会被原样保留并拒绝打开，本分支没有提供转换。搜索在近上限资料库上的计时见 [搜索复测](storage-search-measurement-2026-10-12.md)，其余规模结果见 [首批实测](storage-refactor-measurement-2026-10-11.md)。安装验收各阶段已改在 SQLite 资料库上运行。早先的 JSON 清单实现已于 2026-10-13 删除，仓库里只剩 SQLite 这一种存储实现，测试和跨进程 fixture 也只使用它。尚未完成：迁移后的 `run-acceptance.sh` 没有重跑；切换后的 App bundle 只通过了干净源码上的构建与静态验证，没有安装或运行；macOS 26、真实手机和人工门禁未执行；状态以 [验收账本](acceptance/current-release.md) 为准。

## 当前边界

| 主题 | 稳定结论 | 权威页 |
| --- | --- | --- |
| 产品 | Mac 优先、单用户操作、以人为单位并可照看全家的本机健康记录整理工具；不提供诊断 | [`project-overview.md`](project-overview.md) |
| 隐私 | 活动 Vault 为 App Sandbox 内明文；外部恢复点认证加密；公开历史门禁覆盖已删除附件、凭据路径与恢复码；无账号、内置云同步、遥测或第三方崩溃 SDK | [`../PRIVACY.md`](../PRIVACY.md)、[`privacy-and-security.md`](privacy-and-security.md) |
| 备份 | 用户选择目录、metadata-only 状态加载与自动关闭、自动开关、离线有界退避及已覆盖状态收敛、2–30 份本地保留、generation/keep 围栏的单扫描批量清理、app-private 跨进程 lease 与 witness 高水位线性发布、pending 设置恢复/确认放弃、LAN 预处理结果随逻辑快照恢复而进行中的上传不进入恢复点、生产恢复事务逐 phase SIGKILL 收敛与 activation 后损坏回滚、手动备份、Finder 中显示恢复点和整库替换恢复；网盘远端状态未知 | [`backup-and-restore.md`](backup-and-restore.md) |
| 报告 | 本机 OCR 只生成有来源候选；用户确认后才进入时间线、搜索和比较；搜索命中检验表格行时逐格列出原文，不解析数值、不判断正常与否 | [`import-and-ocr.md`](import-and-ocr.md)、[`decisions.md`](decisions.md) |
| LAN | 用户显式开启的临时普通 HTTP 会话，绑定所选 Mac 接口并在 HTTP 前拒绝非同 IPv4/IPv6 网络前缀对端，仍只适用于可信任私人网络；成功配对推进浏览器 session generation，手机轮询再以 mutation epoch、revision 与取消 tombstone 防止陈旧状态回退 | [`lan-upload.md`](lan-upload.md) |
| 成员对话 | 默认关闭的实验功能；用户开启并按对话确认后，单独签名的沙盒 bridge 经用户本机已登录的 Codex 发送一位成员的已确认报告投影；模型没有工具，回答不进入时间线、搜索或导出，对话只在内存；这是唯一的外发例外，不是匿名化 | [`../PRIVACY.md`](../PRIVACY.md)、[`acceptance/member-chat-matrix.md`](acceptance/member-chat-matrix.md) |
| DICOM | 底层 DICOM-Swift 固定为 1.5.0，codec 依赖和资源仅进入独立 Helper；受限的辅助能力；支持边界窄、非诊断，不代表产品转向通用影像工作站 | [`dicom.md`](dicom.md) |
| 发布 | 源码仓库已公开，但尚未正式发布可下载产品；GitHub CI 在 pull request 上只运行 macOS 26 基线，main push 与手工触发时再加 Xcode 27 预览矩阵；每个系统用两个互斥 runner 覆盖同一全局主测试账本，另用一个独立 runner 并行验证 clean-source bundle 与 DICOM XPC，强制终止不得冒充成功；验收扫描所需 `ripgrep` 由固定版本与 SHA-256 的 CI 引导提供；版本 tag 还必须可从 canonical `main` 到达才能进入构建 | [`testing-and-release.md`](testing-and-release.md)、[`acceptance/current-release.md`](acceptance/current-release.md) |

当前 Swift package 声明最低 Swift tools 6.2，使用 Swift 6 language mode；本机 Xcode 27 / Swift 6.4 构建说明见 [`testing-and-release.md`](testing-and-release.md)。只发布 `Kinlogue` App product；Core、Platform 与测试辅助程序保持为内部 target。持续集成以 GitHub Actions 为唯一当前入口，已经完成使命的 Codemagic 试验配置和 LAN feasibility host 只保留历史文档证据，不再进入构建图。

当前候选抽取规则为 extraction version 6：标签与取值的配对、医院抬头兜底、表单名称、识别异体字、检验表格的表头别名与并排表格的处理见 [`import-and-ocr.md`](import-and-ocr.md)；带文字层的 PDF 仍抽不出表格；规则移植自 Go 预览的合成版式夹具，真实样本命中率尚未验证。

当前报告界面在进入时间线时默认打开最新记录、在侧边栏为待确认草稿计数并显示文件名、在导入期间显示识别状态并解释首次识别的等待，报告复核页支持 Command-Return 确认，搜索结果卡片显示报告日期、加粗标出搜索词，并逐格列出命中的检验表格行或显示命中处上下文；规则与未做的人工检查见 [`design-system.md`](design-system.md) 第 20–26 条。

当前报告复核通过一次有界读取取得同一提交上的草稿、OCR、成员与首个原件；PDF 原件打开只发布页数，所选页 metadata 和 raster 在 actor 内按需读取。具体一致性与 UI 并发边界分别见 [`sqlite-storage.md`](sqlite-storage.md#报告ocr-与窄查询)、[`import-and-ocr.md`](import-and-ocr.md) 和 [`design-system.md`](design-system.md)。

整库恢复确认后，共享 lifecycle 会取消并等待已经进入的报告 import/retry/OCR、LAN、DICOM 与导出任务；并发恢复 preparation 以 generation 隔离，activation 失败只允许退出重启。事实与回归入口见 [`backup-and-restore.md`](backup-and-restore.md)、[`architecture.md`](architecture.md) 和 [`import-and-ocr.md`](import-and-ocr.md)。

当前设置页支持对原备份目录重新授权，并保持手动备份忙碌状态；恢复 ViewModel 的迟到权限回调不会清理新恢复点。手机批量上传的本地排队状态也不会被 reservation 轮询覆盖。实现与回归入口分别见 [`backup-and-restore.md`](backup-and-restore.md) 和 [`lan-upload.md`](lan-upload.md)。

界面配色统一由 `KinlogueTheme` 的语义令牌、共享按钮/列表行/信息卡样式和逐窗口亮色外观声明承担；页面文件不直接使用系统灰、系统状态色或圆角数值。规则、例外与源码门禁见 [`design-system.md`](design-system.md)。

## 当前专题

### 产品与架构

- [`project-overview.md`](project-overview.md)：唯一当前产品契约、用户流程、边界和产品验收定义。
- [`brand.md`](brand.md)：名称、定位、标语、应用图标母版，以及健康助手方向（模型问答的第一步已作为实验实现，其余未实现）。
- [`architecture.md`](architecture.md)：target 图、运行时组装、跨层调用和并发边界。
- [`architecture-review-2026-09-08.md`](architecture-review-2026-09-08.md)：公开 main 的完整设计/架构审查、已核实问题、最小改进与外部实践依据。
- [`domain-and-data-model.md`](domain-and-data-model.md)：领域对象、状态机、来源和去重语义。
- [`decisions.md`](decisions.md)：当前决策、已取代决策和开放门禁。

### 平台与用户能力

- [`storage-search-measurement-2026-10-12.md`](storage-search-measurement-2026-10-12.md)：搜索改用预筛键与按摘要缓存后，近上限资料库上的计时、基线对照和未测范围。
- [`search-presentation-measurement-2026-10-14.md`](search-presentation-measurement-2026-10-14.md)：搜索卡片列出命中行与摘录之后的首页计时对照，以及真实 OCR 走完导入、确认和搜索的合成版式核对。
- [`sqlite-storage.md`](sqlite-storage.md)：SQLite 资料库的内核、报告/OCR、LAN 与规范化 DICOM 事务、逻辑备份/恢复、实体字节预算、窄查询、单实例、完整性和原件生命周期。
- [`storage.md`](storage.md)：资料库根目录与布局、其他格式的拒绝、文件系统安全与删除、资源上限和原件导出。
- [`backup-and-restore.md`](backup-and-restore.md)：加密恢复点、目录授权、自动化、保留和整库恢复。
- [`import-and-ocr.md`](import-and-ocr.md)：报告文件校验、本机 OCR、候选抽取和人工确认。
- [`lan-upload.md`](lan-upload.md)：临时接收会话、协议、队列、生命周期和安全限制。
- [`dicom.md`](dicom.md)：DICOM 导入、索引、XPC、Viewer、生命周期和支持边界。
- [`privacy-and-security.md`](privacy-and-security.md)：工程威胁模型和隐私保护边界。
- [`design-system.md`](design-system.md)：视觉系统、交互状态和无障碍约束。
- [`localization.md`](localization.md)：中英资源、运行时语言切换和文案门禁。
- [`concurrency-safety-audit.md`](concurrency-safety-audit.md)：Swift 6 并发安全清单与维护规则。

### 构建与验收

- [`testing-and-release.md`](testing-and-release.md)：验证命令、证据规则、签名和发布流程。
- [`acceptance/README.md`](acceptance/README.md)：当前候选矩阵与历史验收入口。
- [`acceptance/member-chat-matrix.md`](acceptance/member-chat-matrix.md)：成员对话的自动化证据、发布门禁和未执行的人工矩阵。
- [`adhoc-candidate-install.md`](adhoc-candidate-install.md)：ad-hoc 候选包的下载和信任边界。

### 历史与原始证据

- [`ideation/2026-08-13-cloud-backup-and-sync-ideation.html`](ideation/2026-08-13-cloud-backup-and-sync-ideation.html)：云端备份、iCloud/CloudKit 与多设备同步的候选方向调研；这是点时方案比较，不代表当前能力或已批准路线。
- [`plans/README.md`](plans/README.md)：实施计划目录；计划保留决策历史，不充当当前能力清单。
- [`sources/README.md`](sources/README.md)：外部来源和阶段契约目录。
- [`log.md`](log.md)：按时间追加的实现与验证记录。

## 维护规则

README 合成预览的当前树与历史媒体校验边界见 [`privacy-and-security.md`](privacy-and-security.md)。

1. 先修改拥有该事实的专题页，再更新本索引的链接或一句话摘要。
2. 发布版本、测试数量、候选 revision 和门禁状态只写入 [`acceptance/current-release.md`](acceptance/current-release.md)；其他页面只链接，不复制。
3. 历史计划、来源和日志不因精简而删除；通过局部目录区分 current、archive 和 superseded。
4. 行为变化必须同步最相关专题页和 [`log.md`](log.md)，并运行 `scripts/verify-docs.sh`。
