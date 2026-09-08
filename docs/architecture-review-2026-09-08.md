# 2026-09-08 设计与架构审查

审查基线为公开仓库 `main` 的 `9b4f2194a3c0b80b5926b79c45bc417eeaeceaa5`。范围包含领域规则、Vault/导入、备份恢复、LAN/手机页面、App/UI、DICOM/XPC、构建与发布；不是只审查最近一次 diff。各领域独立审查后回到实际调用链核验，上游已经解决的上传排队、备份 sequence 和 pending enrollment 问题不重复列为缺陷。

总体判断：现有分层适合单机、单用户产品，应保留 Foundation-only Core、Platform 的文件与系统能力、App composition root，以及 descriptor-only DICOM XPC 隔离。本轮发现的主要问题集中在完整性检查与删除的衔接、异步工作生命周期、时间语义和不同层的资源预算，而不是缺少架构层。

本页记录审查与本地改进，不代表公开发布验收通过。当前测试账本与候选状态只见 [当前候选证据](acceptance/current-release.md)。

## 已核实的问题与改进范围

| 编号 | 优先级 | 用户可见后果 | 修复位置与原则 |
| --- | --- | --- | --- |
| 1 | P1 | 已归档对象同长度损坏后，去重归档可能移除投递箱的完好副本 | [PlaintextLANInboxStore](../Sources/KinloguePlatform/LAN/PlaintextLANInboxStore.swift)：在最终清理边界、同一 mutation lease 内验证实际目标原件与 OCR |
| 2 | P1 | 整库恢复时，旧 App 状态和独立 Viewer 像素仍可能存活 | [AppComposition](../Sources/KinlogueApp/App/AppComposition.swift)、[RestoreModel](../Sources/KinlogueApp/ViewModels/RestoreModel.swift)：复用删除流程的 App/LAN/Viewer 撤销 |
| 3 | P1 | DICOM 原文件在检查后被换成 FIFO，导入与 Vault lease 可能无限等待 | [DICOMFolderScanner](../Sources/KinloguePlatform/DICOM/DICOMFolderScanner.swift)：非阻塞打开后继续检查类型、身份与长度 |
| 4 | P2 | 备份成功后仍延后保留清理，旧恢复点累积 | [BackupOperationCoordinator](../Sources/KinlogueApp/Backup/BackupOperationCoordinator.swift)：使用验证完成时间评估 witness，保留真正时钟回退保护 |
| 5 | P2 | 取消恢复准备后仍继续全量解密，立即重试增加磁盘与 I/O 压力 | [LiveRestoreService](../Sources/KinlogueApp/Backup/LiveRestoreService.swift)：实际取消并等待旧 preparation 清理 |
| 6 | P2 | 两份合法的大 PDF 合并后，重新识别撞上快照累计上限 | [AppServices](../Sources/KinlogueApp/App/AppServices.swift)：按来源逐份读取，保持草稿 revision 检查与现有内存上限 |
| 7 | P2 | 刷新或保存冲突后，列表已更新而右侧详情仍是旧记录 | [AppModel](../Sources/KinlogueApp/App/AppModel.swift)：同一 snapshot 更新选中记录，保留仍有效的原件 |
| 8 | P2 | OCR/确认处理中继续编辑表单，迟到结果覆盖新输入 | [ImportReviewView](../Sources/KinlogueApp/Views/ImportReviewView.swift)：使用现有忙碌状态禁用表单 |
| 9 | P2 | 文件比较期间移除旧选择，仍将新选择作为重复项丢弃 | [手机页面](../Sources/KinloguePlatform/Resources/LANUpload/app.js)：异步比较后重验候选身份与有效性 |
| 10 | P2 | 并发 reserve 突破会话上限，状态响应无法编码 | [LANReceiver](../Sources/KinloguePlatform/LAN/LANReceiver.swift)：将已接纳和在途预留一起计数 |
| 11 | P2 | 合法奇数像素的 8-bit DICOM 被拒绝 | [DICOM Helper](../Sources/KinlogueDICOMDecoderHelper/KinlogueDICOMDecoderHelper.swift)：区分偶数字节 Value Length 与实际 sample 长度 |
| 12 | P2 | Helper crash/watchdog 退出跳过 defer，临时原件残留累积 | [DICOM Helper](../Sources/KinlogueDICOMDecoderHelper/KinlogueDICOMDecoderHelper.swift)：写入前 unlink，以 descriptor 保留有界独立副本，由内核在退出时回收 |
| 13 | P2 | 正式分发只重签主 App，内嵌 Helper 不满足公证要求 | [正式打包脚本](../scripts/package-distribution.sh)：内层资源、Helper、App 依次签名并逐层验证 |
| 14 | P2 | 直接打包也声称全部 workflow 门禁通过 | [ad-hoc 打包脚本](../scripts/package-adhoc-candidate.sh)、[正式打包脚本](../scripts/package-distribution.sh)：只记录实际证据，未执行的汇总门禁保持 `notExecuted` |

以上基线缺陷均已修复，并由 [实现日志](log.md) 保留证据。问题 1 的修复位于最终移除投递箱的共同路径，只在首次去重返回前校验会被错误恢复分支绕过。问题 4 同时修正暂停后使用过期事件时间检查时钟的竞态：完成时间取 writer 回读验证后的时刻，scheduler 用读取配置后的当前时钟判断连续性，事件时间仍用于静默与重试。

## 验证方式

归档完整性、大文件重新识别和并发预留回归先在旧实现上失败，再验证修复：两份各 65 MiB 合法合成 PDF 触发旧快照上限；同长度损坏目标原件导致旧归档流程清空投递箱；在途 reserve 使旧会话超过可编码上限。表单禁用采用现有源码契约测试，实际键盘和 VoiceOver 行为仍需人工验收。

| 交接边界 | 可复核的回归入口 |
| --- | --- |
| 真实 Vault、逐来源 OCR 与损坏目标保护 | [识别集成测试](../Tests/KinlogueAppTests/LiveAppServiceRecognitionIntegrationTests.swift)、[LAN 归档测试](../Tests/KinloguePlatformTests/LANReportArchiveTests.swift) |
| writer 完成时间、保留与 scheduler | [协调器测试](../Tests/KinlogueAppTests/BackupOperationCoordinatorTests.swift)、[调度测试](../Tests/KinlogueAppTests/BackupSchedulerTests.swift)、[真实备份 service 测试](../Tests/KinlogueAppTests/LiveBackupServiceTests.swift) |
| 恢复取消、App/LAN/独立窗口撤销 | [恢复 service 测试](../Tests/KinlogueAppTests/BackupRestoreServiceTests.swift)、[恢复界面模型测试](../Tests/KinlogueAppTests/RestoreModelTests.swift) |
| 详情刷新与编辑保护 | [AppModel 测试](../Tests/KinlogueAppTests/AppModelTests.swift)、[核对表单契约](../Tests/KinlogueAppTests/ImportReviewViewSafetyTests.swift) |
| LAN admission 和手机异步去重 | [文件生命周期测试](../Tests/KinloguePlatformTests/LANReceiverFileLifecycleTests.swift)、[实际手机脚本 Node VM 回归](../Tests/KinloguePlatformTests/LANPhoneAssetSafetyTests.swift) |
| DICOM 源类型切换、lease 释放与 Helper 像素 | [扫描器测试](../Tests/KinloguePlatformTests/DICOMFolderScannerTests.swift)、[导入集成测试](../Tests/KinloguePlatformTests/DICOMImportWorkflowIntegrationTests.swift)、[真实 XPC probe](../Sources/KinlogueDICOMXPCProbe/KinlogueDICOMXPCProbe.swift) |
| 匿名临时副本、签名与发布证据 | [DICOM 打包契约](../Tests/KinlogueAppTests/DICOMPackagingBoundaryTests.swift)、[执行实际脚本片段的发布回归](../Tests/KinlogueAppTests/ReleaseScriptSafetyTests.swift) |

验证环境为 macOS 26.6.2 / arm64、Xcode 26.6（17F113）、Swift 6.3.3；全部数据为合成资料。

| 命令或门禁 | 本次结果与边界 |
| --- | --- |
| 相关 suite 的 `scripts/test.sh --filter` | 191 tests / 22 suites 通过，包含本轮回归 |
| 完整 `scripts/test.sh` | 退出码 0；主测试清单与[账本](acceptance/current-release.md)完全匹配；13 项独立 XCTest、验收扫描、跨进程存储、大小写别名锁、DICOM 导入、安装式 LAN 生产 HTTP 探针、真实双流 RSS/背压门禁均通过 |
| `scripts/verify-dicom-xpc.sh` | 退出码 0；当前工作树 Release App/Helper 的 ad-hoc 构建、实际像素解码（含奇数像素与非法 padding）、SIGKILL、hang watchdog、日志 canary、零 runtime socket 通过 |
| `scripts/lint.sh` | 退出码 0；warnings-as-errors 构建和 package graph 校验通过 |
| `scripts/privacy-guard.sh` | 当前树隐私门禁通过；不作为所有公开 Git refs 历史扫描的替代 |
| `scripts/verify-docs.sh`、`scripts/compile-localizations.sh --check`、`git diff --check` | 通过；索引、链接、候选账本与本地化契约保持一致 |
| 正式签名编排 | 合成命令回归和 shell 语法通过，未使用真实 Developer ID 凭据或提交公证 |

以上运行针对本轮修复提交前的工作树；当时尚未执行要求 clean source 的 `verify-app.sh` 和绑定不可变 ref 的安装验收。源码提交与 PR 不自动升级发布状态；真实 XPC 的通过不替代整套候选证据。

## 保留的设计与后续优化顺序

- **保留目标分层与 XPC 隔离。** 当前没有把 decoder、文件系统或 HTTP 实现移入 Core 的必要，也没有引入新的状态管理或依赖注入框架的依据。
- **保留不可变对象与 manifest 最后发布。** 单用户资料库目前不需要为架构整齐而迁移数据库；先测接近当前对象上限时的端到端查询、刷新和备份延迟，再决定是否建立可重建的派生索引。
- **保留现有流式导出与 LAN 背压。** 逐来源 OCR 降低同时持有的输入数据，不通过放宽内存上限掩盖不同层的预算冲突。
- **将集成测试放在状态交接处。** mock 单独返回成功不能证明 writer 与 retention 使用同一时间语义，也不能证明 backend 撤销已经清空 UI。优先增加这些交接的回归，避免用更多源码字符串断言代替行为。
- **继续按实际用户任务控制范围。** 报告核对、查找、回到原件和可恢复备份仍是主任务；DICOM 保持辅助查看，不扩展为通用影像工作站。

## 外部实践与证据边界

参考 Swift 官方在 GitHub 上的 actor 重入和协作取消提案、Apple SwiftNIO 的非阻塞 I/O 原则、ZIPFoundation 的分块接口、Apple 嵌套签名要求及 DICOM padding 规范；原始链接和采用范围见 [来源笔记](sources/architecture-review-practices-2026-09-08.md)。没有仅因其他项目采用某个框架而添加依赖，也没有更改产品的明文 Vault、普通 HTTP 或非诊断承诺。

本轮采用整树分域审查，未运行独立跨供应商模型审查；自动化只使用合成资料。真实手机、macOS 14/15 独立机器、私有 OCR/DICOM 样本、Powerbox/网盘/外置卷、键盘/VoiceOver、独立密码学审计和正式 Developer ID/notarization 仍按 [发布门禁](testing-and-release.md) 单独验证。

## 实际变更文件

本轮共修改或新增 49 个文件；其中测试、探针和知识库维护单列，未改变依赖锁文件、entitlement 或资料库格式。


<details>
<summary>生产与探针</summary>

- [Sources/KinlogueApp/App/AppComposition.swift](../Sources/KinlogueApp/App/AppComposition.swift)
- [Sources/KinlogueApp/App/AppModel.swift](../Sources/KinlogueApp/App/AppModel.swift)
- [Sources/KinlogueApp/App/AppServices.swift](../Sources/KinlogueApp/App/AppServices.swift)
- [Sources/KinlogueApp/Backup/BackupOperationCoordinator.swift](../Sources/KinlogueApp/Backup/BackupOperationCoordinator.swift)
- [Sources/KinlogueApp/Backup/BackupScheduler.swift](../Sources/KinlogueApp/Backup/BackupScheduler.swift)
- [Sources/KinlogueApp/Backup/LiveBackupService.swift](../Sources/KinlogueApp/Backup/LiveBackupService.swift)
- [Sources/KinlogueApp/Backup/LiveRestoreService.swift](../Sources/KinlogueApp/Backup/LiveRestoreService.swift)
- [Sources/KinlogueApp/ViewModels/RestoreModel.swift](../Sources/KinlogueApp/ViewModels/RestoreModel.swift)
- [Sources/KinlogueApp/Views/ImportReviewView.swift](../Sources/KinlogueApp/Views/ImportReviewView.swift)
- [Sources/KinlogueDICOMDecoderHelper/KinlogueDICOMDecoderHelper.swift](../Sources/KinlogueDICOMDecoderHelper/KinlogueDICOMDecoderHelper.swift)
- [Sources/KinlogueDICOMTestSupport/GeneratedDICOMFixture.swift](../Sources/KinlogueDICOMTestSupport/GeneratedDICOMFixture.swift)
- [Sources/KinlogueDICOMXPCProbe/KinlogueDICOMXPCProbe.swift](../Sources/KinlogueDICOMXPCProbe/KinlogueDICOMXPCProbe.swift)
- [Sources/KinloguePlatform/DICOM/DICOMFolderScanner.swift](../Sources/KinloguePlatform/DICOM/DICOMFolderScanner.swift)
- [Sources/KinloguePlatform/LAN/LANReceiver.swift](../Sources/KinloguePlatform/LAN/LANReceiver.swift)
- [Sources/KinloguePlatform/LAN/PlaintextLANInboxStore.swift](../Sources/KinloguePlatform/LAN/PlaintextLANInboxStore.swift)
- [Sources/KinloguePlatform/Resources/LANUpload/app.js](../Sources/KinloguePlatform/Resources/LANUpload/app.js)

</details>


<details>
<summary>回归测试</summary>

- [Tests/KinlogueAppTests/AppModelTests.swift](../Tests/KinlogueAppTests/AppModelTests.swift)
- [Tests/KinlogueAppTests/BackupOperationCoordinatorTests.swift](../Tests/KinlogueAppTests/BackupOperationCoordinatorTests.swift)
- [Tests/KinlogueAppTests/BackupRestoreServiceTests.swift](../Tests/KinlogueAppTests/BackupRestoreServiceTests.swift)
- [Tests/KinlogueAppTests/BackupSchedulerTests.swift](../Tests/KinlogueAppTests/BackupSchedulerTests.swift)
- [Tests/KinlogueAppTests/DICOMPackagingBoundaryTests.swift](../Tests/KinlogueAppTests/DICOMPackagingBoundaryTests.swift)
- [Tests/KinlogueAppTests/ImportReviewViewSafetyTests.swift](../Tests/KinlogueAppTests/ImportReviewViewSafetyTests.swift)
- [Tests/KinlogueAppTests/LiveAppServiceRecognitionIntegrationTests.swift](../Tests/KinlogueAppTests/LiveAppServiceRecognitionIntegrationTests.swift)
- [Tests/KinlogueAppTests/LiveBackupServiceTests.swift](../Tests/KinlogueAppTests/LiveBackupServiceTests.swift)
- [Tests/KinlogueAppTests/ReleaseScriptSafetyTests.swift](../Tests/KinlogueAppTests/ReleaseScriptSafetyTests.swift)
- [Tests/KinlogueAppTests/RestoreModelTests.swift](../Tests/KinlogueAppTests/RestoreModelTests.swift)
- [Tests/KinloguePlatformTests/DICOMFolderScannerTests.swift](../Tests/KinloguePlatformTests/DICOMFolderScannerTests.swift)
- [Tests/KinloguePlatformTests/DICOMImportWorkflowIntegrationTests.swift](../Tests/KinloguePlatformTests/DICOMImportWorkflowIntegrationTests.swift)
- [Tests/KinloguePlatformTests/LANPhoneAssetSafetyTests.swift](../Tests/KinloguePlatformTests/LANPhoneAssetSafetyTests.swift)
- [Tests/KinloguePlatformTests/LANReceiverFileLifecycleTests.swift](../Tests/KinloguePlatformTests/LANReceiverFileLifecycleTests.swift)
- [Tests/KinloguePlatformTests/LANReportArchiveTests.swift](../Tests/KinloguePlatformTests/LANReportArchiveTests.swift)

</details>


<details>
<summary>发布脚本</summary>

- [scripts/package-adhoc-candidate.sh](../scripts/package-adhoc-candidate.sh)
- [scripts/package-distribution.sh](../scripts/package-distribution.sh)

</details>


<details>
<summary>知识库与证据</summary>

- [docs/acceptance/current-release.md](../docs/acceptance/current-release.md)
- [docs/adhoc-candidate-install.md](../docs/adhoc-candidate-install.md)
- [docs/architecture-review-2026-09-08.md](../docs/architecture-review-2026-09-08.md)
- [docs/architecture.md](../docs/architecture.md)
- [docs/backup-and-restore.md](../docs/backup-and-restore.md)
- [docs/design-system.md](../docs/design-system.md)
- [docs/dicom.md](../docs/dicom.md)
- [docs/import-and-ocr.md](../docs/import-and-ocr.md)
- [docs/index.md](../docs/index.md)
- [docs/lan-upload.md](../docs/lan-upload.md)
- [docs/log.md](../docs/log.md)
- [docs/privacy-and-security.md](../docs/privacy-and-security.md)
- [docs/sources/README.md](../docs/sources/README.md)
- [docs/sources/architecture-review-practices-2026-09-08.md](../docs/sources/architecture-review-practices-2026-09-08.md)
- [docs/storage.md](../docs/storage.md)
- [docs/testing-and-release.md](../docs/testing-and-release.md)

</details>
