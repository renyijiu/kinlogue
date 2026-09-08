# 当前候选证据

<!-- release-facts: short=0.5.0 build=5 minimum-macos=14.0 tests=994 suites=91 automated-gates=not-verified overall=pendingManual -->

本页是当前版本、测试清单、候选身份和发布状态的唯一权威账本。其他页面只链接本页，不复制这些易漂移数字。

## 状态摘要

| 维度 | 当前状态 | 说明 |
| --- | --- | --- |
| 源码自动化 | `not-verified` | 当前确定性主测试清单为 994 tests / 91 suites；本轮完整 `scripts/test.sh`、lint、文档、本地化与当前树隐私门禁已在提交前通过，逐项结果见[架构审查](../architecture-review-2026-09-08.md)，尚未登记绑定不可变 source ref 的整套候选证据 |
| clean-source bundle / XPC | `notExecuted` | 本轮提交前的 dirty-source Release 构建和真实 XPC 门禁已通过；尚未登记 `scripts/verify-app.sh --require-clean-source` 及绑定同一不可变 source ref 的候选证据 |
| Git 历史隐私 | `verified-baseline` | 历史已验证基线为 `f9cc99b8adcfbfeba35bddc8575a8a464d25eaa2`；历史通过不替代每次公开推送前对待发布 ref 运行 history guard，全部公开 refs 仍须单独核验 |
| 公开托管 | `external` | CI、CodeQL、Dependabot 与治理文件已入库；GitHub 安全设置、branch rules 和 workflow 运行属于可变远端状态，必须在托管平台实时核对，不把它们固化成 commit 内的永久结论 |
| 公共分发 | `notExecuted` | 没有 Developer ID、notarization 或正式公众下载渠道证明 |
| 整体状态 | `pendingManual` | 自动化即使通过，也不能覆盖真实设备、真实样本、Powerbox 和可访问性人工门禁 |

`automated-gates` 只描述当前 source ref 是否完成整套自动化；`overall` 描述包含人工门禁的候选整体状态。当前确定性主测试清单为 994 tests / 91 suites；derived-artifact XCTest 由已构建 bundle 的完整 inventory 动态发现并逐 case 启动有界进程，不再维护手写 selector 名单。仅在大小写不敏感卷启用的别名锁测试，以及 storage process、DICOM 导入集成、验收扫描、安装 LAN 生产 HTTP 探针和真实双流 LAN RSS/背压用例另按脚本要求分别串行隔离。条件式测试在不适用卷上明确跳过，不进入固定主账。源码自动化通过不替代下列安装、真机与人工门禁。

## 开源 baseline 身份

| 字段 | 当前值 |
| --- | --- |
| Short version / build | `0.5.0` / `5` |
| 最低系统 | macOS `14.0` |
| 审查起点 | 公开 `main` 的 `9b4f2194a3c0b80b5926b79c45bc417eeaeceaa5`；本轮修复以它为基础，源码提交与 PR 不自动成为发布候选 |
| Git 历史 | 公开历史由净化 root commit 及其公开后续提交组成；不迁移旧私有 branches、tags、PR refs、releases 或原 commit metadata |
| 工件 | 尚未为当前修复生成或发布可绑定的 App ZIP |
| 签名与渠道 | Developer ID / notarization `notExecuted`；不得把历史 ad-hoc 结果冒充当前公共候选 |

候选 ref 可以预先写入源码后再创建，不要求在 commit 内容中自引用 SHA；一旦发布不得移动或复用该 tag。任何 `passed` 证据必须绑定不可变 ref、环境和实际命令。

## 当前源码能力证据边界

Core、Platform、App 与真实跨进程测试已经分别覆盖报告/OCR、LAN inbox、DICOM XPC、原件导出、加密 checkpoint、保留、离线重试、跨进程 publication 和恢复事务。各能力的具体证明与未执行项由 [LAN 矩阵](lan-upload-matrix.md)、[DICOM 矩阵](dicom-mri-viewer-matrix.md)、[备份与恢复](../backup-and-restore.md)及[测试与发布](../testing-and-release.md)维护。

这些聚焦证据在最终完整门禁登记前只能描述对应行为，不能把本页的源码自动化或公共发布状态提升为 `passed`。

## 发布前人工门禁

- macOS 14 和 macOS 15 独立机器上的安装、启动、重启、删除和功能矩阵；
- 指定 iOS Safari / Android Chrome 真机上的配对、上传、重试和生命周期；
- 真实私有样本 OCR 和更广 DICOM 样本，但不把样本或可逆身份写入仓库；
- 真实 `NSSavePanel`、外置卷、覆盖保存、打印和导出后检查；
- 真实 Powerbox 备份目录、外置盘/NAS、第三方网盘客户端传播，以及干净 Mac 恢复；
- 键盘、VoiceOver、焦点、动态语言和 AppKit canvas 人工检查；
- 独立密码学/安全审计；
- Developer ID、notarization 和最终公共分发渠道。

任何新证据必须写明绑定的 source ref、工件身份、环境和未执行项。历史阶段数字留在 [实现日志](../log.md)、[来源层](../sources/README.md) 或归档验收页，不回填到本页的当前状态。
