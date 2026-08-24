# 测试、构建与发布验收

本页拥有验证命令、证据分层和发布流程。当前版本、测试数量、候选 revision 与门禁状态只在 [`acceptance/current-release.md`](acceptance/current-release.md) 维护；历史阶段计数和工件 hash 留在 [`log.md`](log.md)、[`sources/`](sources/README.md) 和归档验收页。

## 环境前提

- macOS 14 或更高版本；`Package.swift` 使用 Swift 6 language mode。
- `swift build` / `swift test` 可使用 SwiftPM 和 Command Line Tools。
- 完整 App bundle、签名、XPC 和安装验收要求 `/Applications/Xcode.app/Contents/Developer`。
- 当前 CI 工具链和锁定依赖不证明最低 macOS 14/15 的独立机器兼容性。
- `Package.resolved`、SwiftNIO、ZIPFoundation 和 DICOM-Swift 的精确版本由 package graph 与 bundle 门禁验证。
- `scan-acceptance.sh` 要求 `ripgrep`；GitHub Actions 的质量与发布 package job 使用仓库脚本下载固定的 14.1.1 Apple Silicon archive，核对 SHA-256 后才把私有工具目录加入后续步骤的 `PATH`，不使用可漂移的 Homebrew 安装。

## 验证命令

| 命令 | 证明什么 | 不能替代 |
| --- | --- | --- |
| `scripts/lint.sh` | 源码卫生、warnings-as-errors build、package graph 和文档结构 | 运行时行为或安装验收 |
| `swift build --disable-sandbox` | 当前 SwiftPM 源码可编译 | 完整 `.app`、签名、资源或 XPC |
| `scripts/compile-localizations.sh --check` | String Catalog 与提交资源一致 | 人工语言/VoiceOver 检查 |
| `scripts/test.sh` | Core、Platform、App 和脚本安全主套件；随后独立运行条件式大小写别名、跨进程 storage、DICOM 导入集成、验收扫描、安装 LAN 生产 HTTP 与真实 Socket/RSS 门禁 | clean-source bundle、真实设备和人工矩阵 |
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

`scripts/test.sh` 把各主 target 的 Swift Testing 成功 summary 保存为权限 `0600` 的同一临时日志，并以 `KINLOGUE_REQUIRE_TEST_EVIDENCE=1` 交给 `scripts/verify-docs.sh`。evidence mode 缺少文件、没有成功 summary，或所有 summary 汇总后的 tests/suites 与当前候选主账不一致时都会失败。独立的 XCTest、条件式和真实进程门禁由各自非零退出状态失败关闭，不重复计入该 Swift Testing 主账。

定向 `--filter` 只证明受影响路径，不更新全量测试清单。全量运行先以 `swift build --build-tests --disable-swift-testing --enable-xctest` 构建 test bundle，再由 `xcrun xctest -XCTest` 为 `LANDerivedArtifactSinkTests` 的 13 个固定 case 分别启动有界进程，并逐项核对精确 1/0 通过摘要；随后从 `swift test list` 取得其余可执行 inventory。Core 使用一个 `--no-parallel` helper，Platform/App 每个短生命周期 helper 最多包含两个完整多项测试容器，其余单项容器每批最多 16 项。容器不会跨 helper 拆分，本机主账路径共 49 个 Platform/App helper。

macOS 26 远端已连续证明 derived-artifact 的 fresh runner 先后可能停在 SwiftPM 测试运行握手和具体 XCTest case。禁用 Swift Testing 后由 SwiftPM 启动 XCTest 的路径完成 189.40 秒 cold build，但 `swift-package` 与 `xctest` 又共同存活 18 分 43 秒且没有测试事件；改为直接 `xcrun xctest` 后，230.68 秒 cold build 和前 6 个 case 均成功，随后 `testProductionStoreBudgetIsReservedBeforeAnyDerivedActorHop` 启动但在 180 秒 deadline 内不返回。该测试原先从 cooperative executor 启动四个任务，再让每项同步阻塞在 actor hop 前的故障注入闸门；小型 runner 可因此耗尽负责恢复测试方法的 executor。现在只有这段刻意同步阻塞的测试调用由独立 OS 线程发起，生产 sink、内存上限和断言不变。专用命令仍只让 SwiftPM build test bundle，再为 13 个固定 case 分别启动 `xcrun xctest`，任何 case 缺少精确 1/0 摘要均失败。GitHub CI 仍使用三个全新 runner：`0/3` 与 `1/3` 以确定性模数分别运行主账的 25 与 24 个 helper，`2/3` 在 inventory/list 前只运行 derived-artifact XCTest 13/1，成功后仍运行文档门禁。本机默认 `0/1` 先执行同一门禁，再运行完整主账。

planner 将清单标识规范化为 SwiftPM 实际过滤标识，以完整 target 前缀和词边界避免前缀误匹配，并对未知 target、运行标识冲突、缺失隔离门禁、缺失专用容器、重复或遗漏匹配失败关闭；每个 shard 同时冻结预期 tests/suites。分片监督器先从有界输出尾部去除 ANSI 控制序列、统一空白，再匹配精确成功 summary；匹配后才启动 5 秒退出宽限期并输出不含测试内容的期望/已观察计数标记。监督器在 helper 存活期间持续记录自己的后代 PID 与进程启动身份；即使 SwiftPM 测试进程另建 process group 或在前台命令退出后被重新托管，也只会向仍匹配该身份的本分片后代发信号。若 helper 仍不收敛，监督器清理这些已跟踪进程后记为成功；命令在宽限期内返回的非零状态、错配/缺失 summary、清理不完整，或在外层 deadline 前 5 秒触发的内层超时仍失败关闭。各 shard 使用同一已构建 test bundle；本机完整路径的所有成功 summary（兼容单数 `suite` 与复数 `suites`）汇总后仍必须精确匹配候选主账。CI 只把 SwiftPM build jobs 限为两个。该边界避免真实进程、锁、网络和文件同步测试在近千条用例共用的长生命周期 helper 中累积进程级状态，同时不减少测试或放宽断言。仅在大小写不敏感卷启用的别名锁测试不进入固定主账，而是单独串行运行；跨进程 storage target、带真实 I/O/取消时限的 DICOM 导入集成、验收扫描、安装 LAN 生产 HTTP 探针和真实 Socket/RSS 压力 case 也继续分离，分别以 `--no-parallel`、`-j 1` 运行并拥有独立 deadline；扫描 suite 自身保留 serialized trait，RSS case 仍要求显式环境变量。跨进程 storage fixture 通过 `Process.terminationHandler` 驱动的多等待者观察器收敛退出状态，不在后台 GCD worker 上调用可能失去唤醒的 `waitUntilExit()`。

在分区 0 中，验收扫描在 inventory build 完成后、Core/primary helper 与跨进程 storage 之前运行；它仍是 `--no-parallel -j 1` 的独立门禁。后续 fresh runner 证据证明统一的 70 不是 helper churn，而是 GitHub macOS 26 镜像缺少 scanner 明确要求的 `rg`；CI 在测试前通过固定版本与 SHA-256 的引导脚本补齐该工具，scanner 对工具缺失继续失败关闭。提前运行的顺序仍隔离扫描与真实进程门禁，但不再被描述成这次 70 的根因修复。

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

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) 在 main pull request、main push 和手工触发时依次运行 lint、隐私、全量测试、clean-source bundle 验证和同一 bundle 的 DICOM XPC 门禁。质量 job 在这些门禁前运行 [`install-ci-ripgrep.sh`](../scripts/install-ci-ripgrep.sh)，只接受固定版本、固定 archive 名与固定 SHA-256 的 Apple Silicon 二进制；release package job 使用同一入口。workflow 使用最小 token 权限、固定 action SHA、30 分钟 job 上限，以及主测试/隔离门禁各自的 deadline。`pull_request_target` 被禁止。

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
