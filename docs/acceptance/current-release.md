# 当前候选证据

<!-- release-facts: short=0.5.0 build=5 minimum-macos=14.0 tests=1035 suites=94 automated-gates=passed overall=pendingManual -->

本页是当前版本、测试清单、候选身份和发布状态的唯一权威账本。其他页面只链接本页，不复制这些易漂移数字。

## 状态摘要

| 维度 | 当前状态 | 说明 |
| --- | --- | --- |
| 源码自动化 | `passed` | `scripts/test.sh` 已完成 1035 tests / 94 suites，并以单线程隔离执行真实双流 LAN RSS/背压用例 1 test / 1 suite |
| clean-source bundle / XPC | `notExecuted` | 最终净化快照尚未重新运行 `scripts/verify-app.sh --require-clean-source` 与同一 bundle 的 XPC 门禁 |
| Git 历史隐私 | `verified-local` | 当前公开候选由净化 tree 建立为唯一 root commit，并已对该 ref 通过 history guard；推送后仍须在隔离 clone 对全部公开 refs 复验 |
| 公开托管 | `external` | CI、CodeQL、Dependabot 与治理文件已入库；GitHub 安全设置、branch rules 和 workflow 运行属于可变远端状态，必须在托管平台实时核对，不把它们固化成 commit 内的永久结论 |
| 公共分发 | `notExecuted` | 没有 Developer ID、notarization 或正式公众下载渠道证明 |
| 整体状态 | `pendingManual` | 自动化即使通过，也不能覆盖真实设备、真实样本、Powerbox 和可访问性人工门禁 |

`automated-gates` 只描述当前 source ref 是否完成整套自动化；`overall` 描述包含人工门禁的候选整体状态。当前完整测试清单为 1035 tests / 94 suites；真实双流 LAN RSS/背压用例另按脚本要求单线程隔离通过。源码自动化通过不替代下列安装、真机与人工门禁。

## 开源 baseline 身份

| 字段 | 当前值 |
| --- | --- |
| Short version / build | `0.5.0` / `5` |
| 最低系统 | macOS `14.0` |
| Baseline ref | `open-source-baseline-2026-08-23`；只允许指向通过隔离历史验证的单根公开 commit |
| Git 历史 | 当前候选为一个净化 root commit；不迁移旧私有 branches、tags、PR refs、releases 或原 commit metadata |
| 工件 | 尚未为该 baseline 生成或发布 App ZIP |
| 签名与渠道 | Developer ID / notarization `notExecuted`；不得把历史 ad-hoc 结果冒充当前公共候选 |

baseline ref 可以预先写入源码后再创建，不要求在 commit 内容中自引用 SHA；一旦发布不得移动或复用该 tag。任何 `passed` 证据必须绑定这个不可变 ref、环境和实际命令。

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
