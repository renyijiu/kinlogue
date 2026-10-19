# 当前候选证据

<!-- release-facts: short=0.5.0 build=5 minimum-macos=26.0 tests=1120 suites=103 automated-gates=not-verified overall=pendingManual -->

本页是当前版本、测试清单、候选身份和发布状态的唯一权威账本。其他页面只链接本页，不复制这些易漂移数字。

## 状态摘要

| 维度 | 当前状态 | 说明 |
| --- | --- | --- |
| 源码自动化 | `not-verified` | 当前主清单 1120 tests / 103 suites。2026-10-19 把加密备份与原件导出合并为明文 ZIP 备份包，删除了加密、签名、repository 与旧导出的代码和测试，加入索引、路径规划、保留、ZIP 读写、设置账本与恢复的测试；这一改动之后的完整 `scripts/test.sh` 与各门禁结果见[实现日志](../log.md) 2026-10-19 一节。尚未绑定不可变 source ref，安装、系统与人工验收另列 |
| clean-source bundle / XPC | `notExecuted` | 2026-10-12 在本机提交 `a595f8234c23a3455cfcfbdf149ce8506b1c5f3a`（干净工作树，macOS 27.0.1 / Xcode 27.0）上，`scripts/verify-app.sh --require-clean-source` 通过：Release 构建、ad-hoc 签名与完整性、含 `Assets.car` 和 GRDB privacy manifest 的精确资源清单、entitlement 白名单、最低系统 26.0、DICOM Helper 结构与主进程隔离、无 Keychain / Security 依赖。该提交只存在于本机分支，不是已发布的不可变 ref，因此本行状态不变；`verify-dicom-xpc.sh` 的真实 XPC 探针、安装验收和 synthetic smoke 没有在该提交上运行 |
| Git 历史隐私 | `verified-baseline` | 历史已验证基线为 `f9cc99b8adcfbfeba35bddc8575a8a464d25eaa2`；历史通过不替代每次公开推送前对待发布 ref 运行 history guard，全部公开 refs 仍须单独核验 |
| 公开托管 | `external` | CI、CodeQL、Dependabot 与治理文件已入库；GitHub 安全设置、branch rules 和 workflow 运行属于可变远端状态，必须在托管平台实时核对，不把它们固化成 commit 内的永久结论 |
| 公共分发 | `notExecuted` | 没有 Developer ID、notarization 或正式公众下载渠道证明 |
| 整体状态 | `pendingManual` | 自动化即使通过，也不能覆盖真实设备、真实样本、Powerbox 和可访问性人工门禁 |

`automated-gates` 只描述当前 source ref 是否完成整套自动化；`overall` 描述包含人工门禁的候选整体状态。当前确定性主测试清单为 1120 tests / 103 suites，全部是 Swift Testing 测试。仅在大小写不敏感卷启用的资料库别名锁测试，以及 storage process、验收扫描、安装 LAN 生产 HTTP 探针和真实双流 LAN RSS/背压用例另按脚本要求分别串行隔离。条件式测试在不适用卷上明确跳过，不进入固定主账。源码自动化通过不替代下列安装、真机与人工门禁。

## 开源 baseline 身份

| 字段 | 当前值 |
| --- | --- |
| Short version / build | `0.5.0` / `5` |
| 最低系统 | macOS `26.0` |
| 审查起点 | 开源审查起点为 `9b4f2194a3c0b80b5926b79c45bc417eeaeceaa5`；本轮首批存储重构基于 `origin/main@09f57b11143e05aa944c1b716e05737ccd813a12` 的未提交工作树，尚非发布候选 |
| Git 历史 | 公开历史由净化 root commit 及其公开后续提交组成；不迁移旧私有 branches、tags、PR refs、releases 或原 commit metadata |
| 工件 | 尚未为当前修复生成或发布可绑定的 App ZIP |
| 签名与渠道 | Developer ID / notarization `notExecuted`；不得把历史 ad-hoc 结果冒充当前公共候选 |

候选 ref 可以预先写入源码后再创建，不要求在 commit 内容中自引用 SHA；一旦发布不得移动或复用该 tag。任何 `passed` 证据必须绑定不可变 ref、环境和实际命令。

## 当前源码能力证据边界

Core、Platform、App 与真实跨进程测试已经分别覆盖报告/OCR、LAN inbox、DICOM XPC、ZIP 备份包的写入与读回、索引与路径规划、只删本机写入文件的保留、离线重试、恶意或损坏备份的拒绝和恢复事务。各能力的具体证明与未执行项由 [LAN 矩阵](lan-upload-matrix.md)、[DICOM 矩阵](dicom-mri-viewer-matrix.md)、[备份与恢复](../backup-and-restore.md)及[测试与发布](../testing-and-release.md)维护。

DICOM-Swift 1.5.0 升级的历史验证保留在[实现日志](../log.md)及 [DICOM 专题](../dicom.md)。本轮 SQLite 资料库在 macOS 27 上完成全量测试及收口定向回归；dirty-source 构建、lint 与包边界的各次证据见实现日志。界面入口已于 2026-10-12 切到 SQLite；`run-acceptance.sh` 的 seed、restart、强制终止、LAN、DICOM 与 cleanup 阶段随后也改为打开 SQLite 资料库，除 DICOM 外的阶段有进程内测试，但脚本本身在迁移后没有重跑，DICOM 阶段因此完全没有执行过；切换后的 App bundle 通过了下表所列的静态验证，但没有安装或运行。独立 Release 探针曾以当时的加密恢复点完成近上限、实际约 9.76 GiB 原件和 20,001 个原件的发布/严格恢复，改为 ZIP 备份包后未在这一规模重跑；存储启动、短操作及相关资源数值门槛通过；搜索在 2026-10-12 改用预筛键后，同一规模的 macOS 27 探针低于计划门槛，见[搜索复测](../storage-search-measurement-2026-10-12.md)。其余规模收益及未达目标见[实测记录](../storage-refactor-measurement-2026-10-11.md)。这些本机证据不自动绑定新的 clean-source 发布候选。

这些聚焦证据在最终完整门禁登记前只能描述对应行为，不能把本页的源码自动化或公共发布状态提升为 `passed`。

## 发布前人工门禁

- macOS 26 和 macOS 27 独立机器上的安装、启动、重启、删除和功能矩阵；
- 指定 iOS Safari / Android Chrome 真机上的配对、上传、重试和生命周期；
- 真实私有样本 OCR 和更广 DICOM 样本，但不把样本或可逆身份写入仓库；
- 真实 `NSSavePanel`、外置卷、覆盖保存、导出备份后的解压、打印与检查；
- 真实 Powerbox 备份文件夹、立即/自动备份与保留轮换、外置盘/NAS、第三方网盘客户端传播，以及干净 Mac 上从备份压缩包恢复；
- 接近上限（ZIP64、约 25,000 个原件）的备份写入与恢复耗时；
- 键盘、VoiceOver、焦点、动态语言和 AppKit canvas 人工检查；
- 独立安全审计（含 ZIP 解析）；
- Developer ID、notarization 和最终公共分发渠道。

任何新证据必须写明绑定的 source ref、工件身份、环境和未执行项。历史阶段数字留在 [实现日志](../log.md)、[来源层](../sources/README.md) 或归档验收页，不回填到本页的当前状态。
