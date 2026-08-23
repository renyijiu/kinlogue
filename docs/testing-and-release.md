# 测试、构建与发布验收

本页拥有验证命令、证据分层和发布流程。当前版本、测试数量、候选 revision 与门禁状态只在 [`acceptance/current-release.md`](acceptance/current-release.md) 维护；历史阶段计数和工件 hash 留在 [`log.md`](log.md)、[`sources/`](sources/README.md) 和归档验收页。

## 环境前提

- macOS 14 或更高版本；`Package.swift` 使用 Swift 6 language mode。
- `swift build` / `swift test` 可使用 SwiftPM 和 Command Line Tools。
- 完整 App bundle、签名、XPC 和安装验收要求 `/Applications/Xcode.app/Contents/Developer`。
- 当前 CI 工具链和锁定依赖不证明最低 macOS 14/15 的独立机器兼容性。
- `Package.resolved`、SwiftNIO、ZIPFoundation 和 DICOM-Swift 的精确版本由 package graph 与 bundle 门禁验证。

## 验证命令

| 命令 | 证明什么 | 不能替代 |
| --- | --- | --- |
| `scripts/lint.sh` | 源码卫生、warnings-as-errors build、package graph 和文档结构 | 运行时行为或安装验收 |
| `swift build --disable-sandbox` | 当前 SwiftPM 源码可编译 | 完整 `.app`、签名、资源或 XPC |
| `scripts/compile-localizations.sh --check` | String Catalog 与提交资源一致 | 人工语言/VoiceOver 检查 |
| `scripts/test.sh` | Core、Platform、App、跨进程和脚本安全主套件；随后独立真实 Socket/RSS 门禁 | clean-source bundle、真实设备和人工矩阵 |
| `scripts/privacy-guard.sh` | 私有 fixture、隐私措辞、canary 和 forbidden values | 运行中系统权限或用户环境 |
| `scripts/privacy-history-guard.sh [--ref <ref>]...` | public-bound reachable Git 历史中的已删除附件、`.env`/私钥路径、完整格式恢复码、常见凭据、私密库存证据和 forbidden values | PR/Issue/Actions log、release asset、fork 或托管平台缓存 |
| `scripts/verify-package-graph.sh <dump-package.json>` | target/product/依赖 allow-list | 最终 Mach-O/link map |
| `scripts/verify-app.sh` | release build、Info.plist、资源、entitlement、签名、依赖和隐私 | 安装后用户流程 |
| `scripts/verify-dicom-xpc.sh --use-verified-app` | 同一已验证 bundle 的真实 XPC、签名、恶意输入、SIGKILL、hang watchdog、socket/log canary | 更广真实 DICOM 兼容矩阵 |
| `scripts/build-acceptance-app.sh` | 从已验证 executable 组装隔离合成验收身份 | 生产身份或真实用户资料 |
| `scripts/run-acceptance.sh` | 安装后报告、DICOM、重启、强制终止、Viewer workload、删除和清理 | 真实样本、最低系统和可访问性 |
| `scripts/verify-app-zip-safety.sh <zip>` | ZIP 条目、路径、类型和大小写安全 | Apple 签名或 notarization |
| `scripts/package-adhoc-candidate.sh v<version>` | 把同一 clean-source ad-hoc bundle/report 打成 private Pre-release 候选并复验 | Developer ID/notarized 公共分发 |

`dist/`、`.build/` 和 `.swiftpm/` 是被忽略的本机产物，不能提交或当作跨机器证据。完整命令必须记录 source revision、环境、工件身份和未执行门禁。

## 测试证据规则

`scripts/test.sh` 把 Swift Testing 的唯一成功 summary 保存为权限 `0600` 的临时日志，并以 `KINLOGUE_REQUIRE_TEST_EVIDENCE=1` 交给 `scripts/verify-docs.sh`。evidence mode 缺少文件、出现多个 summary 或 tests/suites 与当前候选账本不一致时都会失败。

定向 `--filter` 只证明受影响路径，不更新全量测试清单。真实 Socket/RSS 压力 case 从普通并发主套件分离，以单 worker 和显式环境变量运行，避免其他测试污染资源基线。

行为改动先跑受影响 target 的 focused tests，再按风险扩到 `scripts/test.sh`。涉及存储、HTTP、生命周期、重试、XPC 或发布脚本时，至少核对一次真实跨层链路，不能只依赖全 mock 测试。

## Test target 责任

| Target | 覆盖重点 |
| --- | --- |
| `KinlogueCoreTests` | 领域 validation、来源、状态机、查询、fingerprint 和导出计划 |
| `KinloguePlatformTests` | Vault、原子文件、导入/OCR、LAN、DICOM、导出、加密 checkpoint/恢复、并发和故障注入 |
| `KinlogueAppTests` | App service、ViewModel、backup scheduler/retention/restore UI、runtime identity、脚本/bundle 约束和真实 Vault 组合 |
| `KinlogueStorageProcessTests` | 真正跨进程的 Vault/inbox/catalog 锁、提交、恢复和清理 |

整库恢复的跨进程证据直接绑定生产 `BackupRestoreVerifier` 与 `BackupRestoreTransaction`，fixture 只生成合成 checkpoint、在 test-only SPI fault phase 发送 `SIGKILL`、重启后调用 production `reconcile()`，再用真实 Vault 与 durable LAN inbox strict reader 验证终态。矩阵覆盖 existing root 的六个 durable phase，以及 absent root 适用的五个 phase；源码门禁禁止 fixture 重新声明 activation receipt/phase 或复制 rollback/cleanup 算法。源码 process tests 与安装 probe 使用同一逐 phase 终态表，安装 runner 还对每项分别要求 transaction/preflight receipt、staging 与 rollback 全部清理。Platform integration 另在有效 preparation 后破坏 committed staging object，证明 production `activate` 的 activation 后 strict validation 返回 `graphInvalid`，并恢复精确旧树或无根状态且清理全部 restore artifacts。该证据属于当前 Mac 上的源码/真实进程自动化；只有实际执行安装 probe 才能形成已安装工件证据，两者都不代表 macOS 14/15 独立机器、真实 Powerbox/File Provider 目录或人工恢复已经通过。

## CI

### GitHub Actions

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) 在 main pull request、main push 和手工触发时依次运行 lint、隐私、全量测试、clean-source bundle 验证和同一 bundle 的 DICOM XPC 门禁。workflow 使用最小 token 权限、固定 action SHA、30 分钟 job 上限，以及主测试/隔离门禁各自的 deadline。`pull_request_target` 被禁止。

[`codeql.yml`](../.github/workflows/codeql.yml) 在独立 macOS runner 上以 manual build 分析 Swift，只有分析 job 取得 `security-events: write`；checkout 与 CodeQL action 均固定完整 SHA。Dependabot 同时维护 SwiftPM git 依赖和 GitHub Actions pin，更新仍必须经过相同 CI、隐私与人工 review，不能自动扩大依赖或权限边界。

[`.github/workflows/release.yml`](../.github/workflows/release.yml) 只处理精确指向 checkout 的版本 tag。package job 在构建前同时运行 current-tree privacy guard 和 reachable-history privacy guard；构建脚本仍在只读 job 运行。独立 publish job 不 checkout、不执行仓库脚本，只复验固定资产后获得 Release 写权限。它发布的是 arm64 ad-hoc Pre-release，不是公开可信分发；公开仓库会让候选可公开下载，因此每次 tag 前必须复核未 notarize 的信任提示和资产内容。GitHub Actions 是当前唯一 CI；已删除的 Codemagic 试验配置只在 [`log.md`](log.md) 和 [CI/CD 来源笔记](sources/github-actions-macos-ci-cd-2026-08-05.md) 中保留历史证据。

## 候选与签名边界

`packaging/Info.plist` 是 bundle version、build、最低系统和系统用途说明的来源；不再携带 catalog、DICOM policy、Vault envelope、LAN enabled 或 release-role 私有标记。当前候选身份见 [当前候选证据](acceptance/current-release.md)。

生产 entitlement 只允许 App Sandbox、用户选择文件读写、持久 app-scope bookmark 和当前 LAN receiver 所需的入站 server 能力。没有 `network.client`、iCloud/CloudKit 或 Keychain entitlement；隔离 acceptance 身份的额外能力不能进入正式 bundle。

ad-hoc 签名适用于本机开发和知情测试者手动安装，但没有 Developer ID、notarization 或 Apple 检查链。未来启用公共分发时必须重新建立凭据、hardened runtime、notary、staple、Gatekeeper 和发布渠道门禁，不能把今天的 ad-hoc 包原地改称正式发布。

## Current-only 开发格式

项目尚未公开发布，当前实现只支持 catalog v3 和 DICOM ordering policy v2。旧 reader/migrator、predecessor/successor/rollback 生产入口和对应操作脚本已经删除；发布验证只检查当前 bundle，不再把开发期格式往返当作候选门禁。

除恢复先前由用户明确发起、且已写入有效 durable deletion receipt 的整库删除外，旧开发 Vault、未知版本、未知非空目录和损坏布局仍非破坏性失败关闭：App 不自动迁移、覆盖或删除其字节。需要保留旧开发资料时，应先使用对应旧代码在仓库外导出，或由用户明确手工重置开发 Vault。当前规则见 [`storage.md`](storage.md) 和 [`decisions.md`](decisions.md)；历史决策仍保留在计划、来源和追加式日志中。

## 当前证据与人工门禁

[`acceptance/current-release.md`](acceptance/current-release.md) 区分当前源码自动化、最近完整 bundle/安装证据和整体人工状态。LAN 与 DICOM 的详细证据分别由 [LAN 矩阵](acceptance/lan-upload-matrix.md) 和 [DICOM 矩阵](acceptance/dicom-mri-viewer-matrix.md) 拥有。

自动化不能覆盖以下人工门禁：

- 真实私有样本 OCR；
- 键盘、VoiceOver、动态语言和 AppKit canvas；
- macOS 14/15 独立机器；
- iOS Safari/Android Chrome 真机、网络隔离、防火墙和锁屏/睡眠/网络变化；
- 真实 `NSSavePanel`、外置卷、覆盖保存和打印；
- 真实 Powerbox 备份目录、外置盘/NAS，以及阿里云盘/百度网盘等客户端的上传、占位文件、冲突副本与删除传播；
- 干净 Mac 上仅凭恢复码与 `.kinloguebackup` 的完整人工恢复；
- Developer ID、notarization 和任何需要用户接受系统提示的发布动作。

报告状态只使用 `passed`、`pendingManual`、`notExecuted` 和 `blocked`。任何 `passed` 都必须绑定具体 revision、工件和环境，不能从历史低层测试推断当前候选已通过。
