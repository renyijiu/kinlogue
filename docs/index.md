# Kinlogue 项目知识库

这是当前项目 Wiki 的导航入口。产品契约、实现边界和验收证据分别由对应专题页维护；代码、测试、`Package.swift`、打包配置和脚本仍是最终可执行事实。

## 从哪里开始

- 新贡献者或 Agent：先读 [`../AGENTS.md`](../AGENTS.md)，再读 [`project-overview.md`](project-overview.md)。
- 准备 issue、PR 或安全报告：读 [`../CONTRIBUTING.md`](../CONTRIBUTING.md) 和 [`../SECURITY.md`](../SECURITY.md)，只使用合成数据。
- 想理解模块与调用链：读 [`architecture.md`](architecture.md)。
- 想改 Vault、格式版本、删除或导出：读 [`storage.md`](storage.md) 和 [`privacy-and-security.md`](privacy-and-security.md)。
- 想改报告导入/OCR：读 [`import-and-ocr.md`](import-and-ocr.md)。
- 想改手机上传：读 [`lan-upload.md`](lan-upload.md)。
- 想改 DICOM：读 [`dicom.md`](dicom.md)。
- 想构建、测试或发布候选包：读 [`testing-and-release.md`](testing-and-release.md) 和 [`acceptance/current-release.md`](acceptance/current-release.md)。
- 想公开源码或净化 Git 历史：读 [`privacy-and-security.md`](privacy-and-security.md) 和 [`testing-and-release.md`](testing-and-release.md)。
- 想了解同步目录备份/恢复：读 [`backup-and-restore.md`](backup-and-restore.md)、实施计划和 [`acceptance/current-release.md`](acceptance/current-release.md)。
- 想改界面或文案：读 [`design-system.md`](design-system.md) 和 [`localization.md`](localization.md)。

## 当前边界

| 主题 | 稳定结论 | 权威页 |
| --- | --- | --- |
| 产品 | Mac 优先、单用户、多家庭成员的本机健康记录整理工具；不提供诊断 | [`project-overview.md`](project-overview.md) |
| 隐私 | 活动 Vault 为 App Sandbox 内明文；外部恢复点认证加密；公开历史门禁覆盖已删除附件、凭据路径与恢复码；无账号、内置云同步、遥测或第三方崩溃 SDK | [`../PRIVACY.md`](../PRIVACY.md)、[`privacy-and-security.md`](privacy-and-security.md) |
| 备份 | 用户选择目录、metadata-only 状态加载与自动关闭、自动开关、离线有界退避及已覆盖状态收敛、2–30 份本地保留、generation/keep 围栏的单扫描批量清理、app-private 跨进程 lease 与 witness 高水位线性发布、pending 设置恢复/确认放弃、LAN derived 完整恢复与 transient partial 排除、生产恢复事务逐 phase SIGKILL 收敛与 activation 后损坏回滚、手动备份、Finder 中显示恢复点和整库替换恢复；网盘远端状态未知 | [`backup-and-restore.md`](backup-and-restore.md) |
| 报告 | 本机 OCR 只生成有来源候选；用户确认后才进入时间线、搜索和比较 | [`import-and-ocr.md`](import-and-ocr.md) |
| LAN | 用户显式开启的临时普通 HTTP 会话，只适用于可信任私人网络；成功配对推进浏览器 session generation，手机轮询再以 mutation epoch、revision 与取消 tombstone 防止陈旧状态回退 | [`lan-upload.md`](lan-upload.md) |
| DICOM | 受限的辅助能力；支持边界窄、非诊断，不代表产品转向通用影像工作站 | [`dicom.md`](dicom.md) |
| 发布 | 项目尚未公开发布；自动化状态、候选身份和人工门禁分开记录 | [`acceptance/current-release.md`](acceptance/current-release.md) |

当前 Swift package 只发布 `Kinlogue` App product；Core、Platform 与测试辅助程序保持为内部 target。持续集成以 GitHub Actions 为唯一当前入口，已经完成使命的 Codemagic 试验配置和 LAN feasibility host 只保留历史文档证据，不再进入构建图。

当前报告复核通过一次有界 Vault 快照取得同一 generation 的草稿、OCR、成员与首个原件；PDF 原件打开只发布页数，所选页 metadata 和 raster 在 actor 内按需读取。具体一致性与 UI 并发边界分别见 [`storage.md`](storage.md)、[`import-and-ocr.md`](import-and-ocr.md) 和 [`design-system.md`](design-system.md)。

整库恢复确认后，共享 lifecycle 会取消并等待已经进入的报告 import/retry/OCR、LAN、DICOM 与导出任务；并发恢复 preparation 以 generation 隔离，activation 失败只允许退出重启。事实与回归入口见 [`backup-and-restore.md`](backup-and-restore.md)、[`architecture.md`](architecture.md) 和 [`import-and-ocr.md`](import-and-ocr.md)。

## 当前专题

### 产品与架构

- [`project-overview.md`](project-overview.md)：唯一当前产品契约、用户流程、边界和产品验收定义。
- [`architecture.md`](architecture.md)：target 图、运行时组装、跨层调用和并发边界。
- [`domain-and-data-model.md`](domain-and-data-model.md)：领域对象、状态机、来源和去重语义。
- [`decisions.md`](decisions.md)：当前决策、已取代决策和开放门禁。

### 平台与用户能力

- [`storage.md`](storage.md)：Vault/inbox 布局、原子提交、恢复、删除和导出。
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
- [`adhoc-candidate-install.md`](adhoc-candidate-install.md)：private ad-hoc 候选包的下载和信任边界。

### 历史与原始证据

- [`ideation/2026-08-13-cloud-backup-and-sync-ideation.html`](ideation/2026-08-13-cloud-backup-and-sync-ideation.html)：云端备份、iCloud/CloudKit 与多设备同步的候选方向调研；这是点时方案比较，不代表当前能力或已批准路线。
- [`plans/README.md`](plans/README.md)：实施计划目录；计划保留决策历史，不充当当前能力清单。
- [`sources/README.md`](sources/README.md)：外部来源和阶段契约目录。
- [`log.md`](log.md)：按时间追加的实现与验证记录。

## 维护规则

1. 先修改拥有该事实的专题页，再更新本索引的链接或一句话摘要。
2. 发布版本、测试数量、候选 revision 和门禁状态只写入 [`acceptance/current-release.md`](acceptance/current-release.md)；其他页面只链接，不复制。
3. 历史计划、来源和日志不因精简而删除；通过局部目录区分 current、archive 和 superseded。
4. 行为变化必须同步最相关专题页和 [`log.md`](log.md)，并运行 `scripts/verify-docs.sh`。
