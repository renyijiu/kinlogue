# 测试、构建与发布验收

本页拥有验证命令、证据分层和发布流程。当前版本、测试数量、候选 revision 与门禁状态只在 [`acceptance/current-release.md`](acceptance/current-release.md) 维护；历史阶段计数和工件 hash 留在 [`log.md`](log.md)、[`sources/`](sources/README.md) 和归档验收页。

## 环境前提

- macOS 26 或更高版本；`Package.swift` 声明最低 Swift tools 6.2，与 DICOM-Swift 及其 codec 依赖一致。主 package 的 `.v6` 和 Helper 的 `SWIFT_VERSION = 6.0` 均表示 Swift 6 language mode，不是编译器的小版本。
- 当前本机 Xcode 27 使用 Apple Swift 6.4 编译；最低工具链声明不限制使用更新编译器，也不将最低运行系统提高到 macOS 27。Swift 6.2 工具链及 macOS 26 独立机器仍需单独验证。
- `swift build` / `swift test` 可使用 SwiftPM 和 Command Line Tools。
- 完整 App bundle、签名、XPC 和安装验收要求 `/Applications/Xcode.app/Contents/Developer`。
- Xcode 27 使用默认 Swift Build 引擎；DICOM 资源需要可调用的 Metal Toolchain。缺失时运行 `xcodebuild -downloadComponent MetalToolchain`，并用 `xcrun --sdk macosx metal --version` 验证；组件安装后定位缓存陈旧时可执行 `xcrun --kill-cache`。`build-app.sh` 在构建前检查组件，不自动下载或安装。 打包脚本接受旧引擎平铺资源与 Swift Build 的 `Contents/Resources` 两种布局，拒绝符号链接，并统一整理为现有最终包布局；Platform metadata、手机页面、ZIPFoundation 隐私清单和 App 本地化继续受原有精确资源白名单约束。
- `build-app.sh` 用 Xcode 自带的 `actool` 把 [`packaging/Assets.xcassets`](../packaging/Assets.xcassets) 编译为主包的 `Contents/Resources/Assets.car`，并要求编译结果与 `Info.plist` 的 `NSAccentColorName` 一致后才复制和签名。`verify-app.sh` 的精确资源清单包含这个文件，并用 `assetutil --info` 确认归档里只有一个与 Primary 同值的不透明 sRGB 强调色；归档内嵌构建时间戳，因此按内容而不是固定哈希校验。
- CI 在工具链准备阶段探测 Metal；缺失时显式下载官方 Metal Toolchain、清理 xcrun 定位缓存并再次验证。下载或复验失败会终止该 job，本机 `build-app.sh` 仍只检查组件。
- 当前 CI 工具链和锁定依赖不证明 macOS 26/27 的独立机器兼容性。
- `Package.resolved`、SwiftNIO、ZIPFoundation 和 DICOM-Swift 的精确版本由 package graph 与 bundle 门禁验证。
- `scan-acceptance.sh` 要求 `ripgrep`；GitHub Actions 的质量与发布 package job 使用仓库脚本下载固定的 14.1.1 Apple Silicon archive，核对 SHA-256 后才把私有工具目录加入后续步骤的 `PATH`，不使用可漂移的 Homebrew 安装。引导脚本对下载失败、摘要不符、意外归档布局和已有错误版本失败关闭，并抑制底层工具的非必要错误输出；对应行为由合成命令夹具覆盖。

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
| `scripts/verify-assistant-xpc.sh` | 成员对话 bridge 作为签名沙盒 XPC：生产 entitlement 下本机 Codex 通过能力检查（只走本机模拟服务，不耗额度）、例外目录之外的 CLI 被拒；多一处只读例外的验证签名下，假 CLI 的回答、npm 式包装、跨连接取消和 bridge 被杀后的整组清理。需要本机 Codex 才执行第一项 | 真实一轮问答、Developer ID/公证、macOS 26 |
| `scripts/build-app.sh --with-assistant-bridge` | 开发构建中嵌入并签名成员对话 bridge；默认构建与 `verify-app.sh` 不含它 | 发布包验证 |
| `scripts/build-acceptance-app.sh` | 从已验证 executable 组装隔离合成验收身份 | 生产身份或真实用户资料 |
| `scripts/run-acceptance.sh` | 安装后报告、DICOM、重启、强制终止、Viewer workload、删除和清理；各阶段经界面使用的启动链路打开 SQLite 资料库。迁移到 SQLite 之后脚本尚未重跑 | 真实样本、最低系统和可访问性 |
| `scripts/verify-app-zip-safety.sh <zip>` | ZIP 条目、路径、类型和大小写安全 | Apple 签名或 notarization |
| `scripts/package-adhoc-candidate.sh v<version>` | 把同一 clean-source ad-hoc bundle/report 打成 private Pre-release 候选并复验 | Developer ID/notarized 公共分发 |

`dist/`、`.build/` 和 `.swiftpm/` 是被忽略的本机产物，不能提交或当作跨机器证据。完整命令必须记录 source revision、环境、工件身份和未执行门禁。

DICOM 外部 SIGKILL 探针分别验证崩溃收敛和后续恢复：中断仍须在 2 秒内返回固定失败；恢复请求单独使用 30 秒预算，容纳 `launchd.plist(5)` 记录的默认 10 秒重启节流及启动时间。生产请求仍为 10 秒超时、Helper 仍为 9 秒硬 watchdog；探针不重试失败请求，也不把 timeout 当作恢复成功。

## 测试证据规则

`scripts/test.sh` 把各主 target 的 Swift Testing 成功 summary 保存为权限 `0600` 的同一临时日志；同时从完整 `swift test list` 生成唯一的全局 primary tests/suites inventory。`KINLOGUE_REQUIRE_TEST_EVIDENCE=1` 下，`scripts/verify-docs.sh` 要求实际全量 summary 或这份确定性全局 inventory，且任一证据与当前候选主账不一致都会失败。两分片 CI 的每个 runner 都复验同一全局 inventory，因此任一分片都不能仅凭本分片成功而放过陈旧账本；本机 `0/1` 还必须用全部实际 summary 再核对一次。条件式和真实进程门禁由各自非零退出状态失败关闭，不重复计入该 Swift Testing 主账。

定向 `--filter` 只证明受影响路径，不更新全量测试清单。全量运行由一次 `swift test list` 构建并列出全部测试；Core 使用一个 `--no-parallel` helper，Platform/App 每个短生命周期 helper 最多包含两个完整多项测试容器，其余单项容器每批最多 16 项。完整多项容器不会跨 helper 拆分；每个 helper 只包含一个 target，避免 Xcode 27 按 target 启动进程后输出多份 summary。helper 数量由实际 inventory 决定，精确 tests/suites 汇总监督保持不变。

全部测试都是 Swift Testing 测试。原先为 `LANDerivedArtifactSinkTests` 单独构建 XCTest bundle、逐 case 启动有界进程的专用通道，已随该类型和 JSON 存储一起删除；那条通道在 macOS 26 远端 runner 上的排查经过保留在[实现日志](log.md)。GitHub CI 对每个系统使用两个全新 runner：`0/2` 与 `1/2` 以确定性模数分摊 primary helper，二者都用同一 planner 口径复验全局主账；`0/2` 另外运行 Core、验收扫描和各项隔离门禁。本机默认 `0/1` 运行完整主账。

planner 将清单标识规范化为 SwiftPM 实际过滤标识，以完整 target 前缀和词边界避免前缀误匹配，并对未知 target、运行标识冲突、缺失隔离门禁、重复或遗漏匹配失败关闭；每个 shard 同时冻结预期 tests/suites，并独立输出排除隔离门禁后的全局 primary inventory。分片监督器先从有界输出尾部去除 ANSI 控制序列、统一空白，再匹配精确成功 summary；匹配后才启动 5 秒退出宽限期并输出不含测试内容的期望/已观察计数标记。监督器在 helper 存活期间持续记录自己的后代 PID 与进程启动身份；即使测试进程另建 process group 或在前台命令退出后被重新托管，也只会向仍匹配该身份的本分片后代发信号。成功 summary 之后命令或任何已跟踪后代仍不收敛时，监督器会清理该分片进程并返回非零，而不会把被强制终止的测试记为成功；命令非零、错配/缺失 summary、清理不完整或超时同样失败关闭。各 shard 使用同一已构建 test bundle；本机完整路径的所有成功 summary（兼容单数 `suite` 与复数 `suites`）汇总后仍必须精确匹配候选主账。CI 只把 SwiftPM build jobs 限为两个。该边界避免真实进程、锁、网络和文件同步测试在近千条用例共用的长生命周期 helper 中累积进程级状态，同时不减少测试或放宽断言。仅在大小写不敏感卷启用的别名锁测试不进入固定主账，而是单独串行运行；跨进程 storage target、带真实 I/O/取消时限的 DICOM 导入集成、验收扫描、安装 LAN 生产 HTTP 探针和真实 Socket/RSS 压力 case 也继续分离，分别以 `--no-parallel`、`-j 1` 运行并拥有独立 deadline；扫描 suite 自身保留 serialized trait，RSS case 仍要求显式环境变量。跨进程 storage fixture 通过 `Process.terminationHandler` 驱动的多等待者观察器收敛退出状态，不在后台 GCD worker 上调用可能失去唤醒的 `waitUntilExit()`。

在分区 0 中，验收扫描在 inventory build 完成后、Core/primary helper 与跨进程 storage 之前运行；它仍是 `--no-parallel -j 1` 的独立门禁。后续 fresh runner 证据证明统一的 70 不是 helper churn，而是 GitHub macOS 26 镜像缺少 scanner 明确要求的 `rg`；CI 在测试前通过固定版本与 SHA-256 的引导脚本补齐该工具，scanner 对工具缺失继续失败关闭。提前运行的顺序仍隔离扫描与真实进程门禁，但不再被描述成这次 70 的根因修复。

验收 scanner 的生产路径继续扫描真实 `Sources/`、`Tests/`、`scripts/`、`packaging/`、`docs/`、`.build/`、`dist/`、安装 App、运行产物和崩溃报告。只有已受私有目录身份与权限校验约束的内部合成测试模式改用夹具内的 `Repository` 根；夹具显式把 canary 放进合成 `.build` 并要求扫描失败。这样测试不会因反复读取当前 cold-build 目录而受其体积影响，也没有缩小真实验收扫描范围。

行为改动先跑受影响 target 的 focused tests，再按风险扩到 `scripts/test.sh`。涉及存储、HTTP、生命周期、重试、XPC 或发布脚本时，至少核对一次真实跨层链路，不能只依赖全 mock 测试。

## Test target 责任

| Target | 覆盖重点 |
| --- | --- |
| `KinlogueCoreTests` | 领域 validation、来源、状态机、查询、fingerprint 和导出计划 |
| `KinloguePlatformTests` | Vault、原子文件、导入/OCR、LAN、DICOM、导出、加密 checkpoint/恢复、并发和故障注入 |
| `KinlogueAppTests` | App service、ViewModel、backup scheduler/retention/restore UI、runtime identity、脚本/bundle 约束和真实 Vault 组合 |
| `KinlogueStorageProcessTests` | 真正跨进程的资料库 owner、原件与上传各交接窗口的强退恢复、整库恢复各阶段，以及备份仓库的并发发布 |

整库恢复的跨进程证据直接绑定生产 `BackupRestoreVerifier` 与 `BackupRestoreTransaction`，fixture 只生成合成 checkpoint、在 test-only SPI fault phase 发送 `SIGKILL`、重启后调用 production `reconcile()`，再对资料库做严格打开和逻辑校验来验证终态。矩阵覆盖 existing root 的六个 durable phase，以及 absent root 适用的五个 phase；源码门禁禁止 fixture 重新声明 activation receipt/phase 或复制 rollback/cleanup 算法。源码 process tests 与安装 probe 使用同一逐 phase 终态表，安装 runner 还对每项分别要求 transaction/preflight receipt、staging 与 rollback 全部清理。真实进程测试另有两个场景在新根激活之后破坏其中一个原件，要求下一个进程的 `reconcile()` 发现校验失败，恢复精确旧树或无根状态并清理全部 restore artifacts。该证据属于当前 Mac 上的源码/真实进程自动化；只有实际执行安装 probe 才能形成已安装工件证据，两者都不代表 macOS 26/27 独立机器、真实 Powerbox/File Provider 目录或人工恢复已经通过。

## CI

### GitHub Actions

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) 在 main pull request、main push 和手工触发时并行运行三个 job：质量 job 运行 lint、隐私门禁和主测试分区 `0/2`；bundle job 在自己的全新 checkout 上运行 clean-source bundle 验证和同一 bundle 的 DICOM XPC 门禁；第三个 job 运行 `1/2` 测试分区。pull request 只在 `macos-26` 上运行这三个 job；main push 和手工触发时，每个 job 还在 `xcode-27` 上各运行一次。macOS 26 是阻塞基线，Xcode 27 public-preview runner 的 job 使用 `continue-on-error`，失败仍显示但暂不阻塞基线；合并前需要 Xcode 27 结果时，须对该分支手工触发 workflow。macOS 26 job 的检查名不带后缀，依次为 `Lint and test`、`Verify bundle and DICOM XPC` 和 `Complementary test partition`（原先的 `Dedicated LAN derived-artifact tests` 检查已不存在，托管平台的规则若仍要求它，需要在那里移除）；Xcode 27 job 显式增加后缀，避免矩阵自动命名让必需检查永久缺失。仓库规则实际要求哪些检查属于可变远端状态，须在托管平台核对。两个系统独立核对相同全局账本，不能把一个系统的分区算到另一个系统。镜像状态依据 [GitHub 官方镜像说明](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)，远端运行结果须实际核对。质量 job 在这些门禁前运行 [`install-ci-ripgrep.sh`](../scripts/install-ci-ripgrep.sh)，只接受固定版本、固定 archive 名与固定 SHA-256 的 Apple Silicon 二进制；release package job 使用同一入口。workflow 使用最小 token 权限、固定 action SHA、30 分钟 job 上限，以及主测试/隔离门禁各自的 deadline。`pull_request_target` 被禁止。

[`codeql.yml`](../.github/workflows/codeql.yml) 在独立 macOS runner 上以 manual build 分析 Swift，只有分析 job 取得 `security-events: write`；checkout 与 CodeQL action 均固定完整 SHA。Dependabot 同时维护 SwiftPM git 依赖和 GitHub Actions pin，更新仍必须经过相同 CI、隐私与人工 review，不能自动扩大依赖或权限边界。

[`.github/workflows/release.yml`](../.github/workflows/release.yml) 只处理精确指向 checkout、且 source revision 可从公开仓库 `main` 到达的版本 tag。package job 的第一个可执行步骤不复用可变 remote 或仓库脚本，而是用不含凭据的公开 GitHub URL 把 canonical `main` 直接取到临时 remote-tracking ref；tag/checkout/event revision 必须严格相等，且 `git merge-base --is-ancestor` 必须证明 source revision 是 canonical `main` 的祖先，任何 fetch、解析或 ancestry 失败都会在构建前关闭。随后 package job 才运行 current-tree privacy guard、reachable-history privacy guard 和只读构建脚本。独立 publish job 不 checkout、不执行仓库脚本，只复验固定资产后获得 Release 写权限。它发布的是 arm64 ad-hoc Pre-release，不是公开可信分发；公开仓库会让候选可公开下载，因此每次 tag 前必须复核托管端版本 tag 规则、未 notarize 的信任提示和资产内容。GitHub Actions 是当前唯一 CI；已删除的 Codemagic 试验配置只在 [`log.md`](log.md) 和 [CI/CD 来源笔记](sources/github-actions-macos-ci-cd-2026-08-05.md) 中保留历史证据。

## 候选与签名边界

`packaging/Info.plist` 是 bundle version、build、最低系统和系统用途说明的来源；不再携带 catalog、DICOM policy、Vault envelope、LAN enabled 或 release-role 私有标记。当前候选身份见 [当前候选证据](acceptance/current-release.md)。

生产 entitlement 只允许 App Sandbox、用户选择文件读写、持久 app-scope bookmark 和当前 LAN receiver 所需的入站 server 能力。没有 `network.client`、iCloud/CloudKit 或 Keychain entitlement；隔离 acceptance 身份的额外能力不能进入正式 bundle。

ad-hoc 签名适用于本机开发和知情测试者手动安装，但没有 Developer ID、notarization 或 Apple 检查链。未来启用公共分发时必须重新建立凭据、hardened runtime、notary、staple、Gatekeeper 和发布渠道门禁，不能把今天的 ad-hoc 包原地改称正式发布。

`package-distribution.sh` 在正式凭据可用时按 Helper 的资源 bundle、Helper XPC、主 App 的顺序分别签名；Helper 保持独立的 sandbox-only entitlement，两个可执行目标都启用 hardened runtime 和 secure timestamp。上传公证前与最终 ZIP 解压后都逐层核对 Developer ID、Team、时间戳，以及两个可执行目标的 identifier、runtime 和精确 entitlement。合成命令回归只证明签名编排和拒绝路径，真实 Developer ID、公证与安装仍须独立执行。

两个打包器只消费绑定当前源码的 bundle 验证报告，并复验签名与 ZIP；它们不观察完整 workflow，生成的 `compatibility.workflowReleaseGates` 因而保持 `notExecuted`。完整 lint、测试、历史隐私与 XPC 门禁的通过证据以实际执行这些命令的 workflow run 为准，不能由打包成功推断。

## Current-only 开发格式

项目尚未公开发布，当前实现只支持当前的数据库 schema 和 DICOM ordering policy v2。旧 reader/migrator、predecessor/successor/rollback 生产入口和对应操作脚本已经删除；发布验证只检查当前 bundle，不再把开发期格式往返当作候选门禁。

除恢复先前由用户明确发起、且已写入有效 durable deletion receipt 的整库删除外，旧开发 Vault、未知版本、未知非空目录和损坏布局仍非破坏性失败关闭：App 不自动迁移、覆盖或删除其字节。需要保留旧开发资料时，应先使用对应旧代码在仓库外导出，或由用户明确手工重置开发 Vault。当前规则见 [`storage.md`](storage.md) 和 [`decisions.md`](decisions.md)；历史决策仍保留在计划、来源和追加式日志中。

## 当前证据与人工门禁

[`acceptance/current-release.md`](acceptance/current-release.md) 区分当前源码自动化、最近完整 bundle/安装证据和整体人工状态。LAN 与 DICOM 的详细证据分别由 [LAN 矩阵](acceptance/lan-upload-matrix.md) 和 [DICOM 矩阵](acceptance/dicom-mri-viewer-matrix.md) 拥有。

自动化不能覆盖以下人工门禁：

- 真实私有样本 OCR；
- 键盘、VoiceOver、动态语言和 AppKit canvas；
- macOS 26/27 独立机器；
- iOS Safari/Android Chrome 真机、网络隔离、防火墙和锁屏/睡眠/网络变化；
- 真实 `NSSavePanel`、外置卷、覆盖保存和打印；
- 真实 Powerbox 备份目录、外置盘/NAS，以及阿里云盘/百度网盘等客户端的上传、占位文件、冲突副本与删除传播；
- 干净 Mac 上仅凭恢复码与 `.kinloguebackup` 的完整人工恢复；
- Developer ID、notarization 和任何需要用户接受系统提示的发布动作。

报告状态只使用 `passed`、`pendingManual`、`notExecuted` 和 `blocked`。任何 `passed` 都必须绑定具体 revision、工件和环境，不能从历史低层测试推断当前候选已通过。

## 存储规模探针

[`run-storage-scale-probe.sh`](../scripts/run-storage-scale-probe.sh) 复用非发布 `KinlogueStorageProcessFixture` 的合成数据入口，规模性能不进入主测试清单。它只在受控临时目录生成数据并由脚本清理，执行前预留源库、恢复点和恢复库同时存在的容量。`--tier reports-1000 --tier reports-20000 --tier photos-20000` 分别测小库、近对象上限与约 10 GiB 原件：每档生成一个 SQLite 资料库，再依次测量打开到首批摘要（三次）、搜索、短操作、逻辑捕获，以及完整的加密发布、严格恢复和 reconcile；`photos` 档不重复搜索和操作采样。`--tier capacity-20000` 是自成一体的一档：暂存 20,000 个唯一原件后做完整的发布与严格恢复。昂贵的 inbox 增长测量须显式传 `--inbox`。输出的是 min/median/max 等实测值，不作为生产 p95 验收。

脚本的档位在删除 JSON 存储时改为驱动 SQLite 的各项命令；改写后只实跑过最小的 `reports-100` 档（2026-10-13，macOS 27.0.1，各阶段退出码 0），其余档位没有重跑。此前的实测数字来自直接调用同一批探针命令，见 [首批实测](storage-refactor-measurement-2026-10-11.md) 与 [搜索复测](storage-search-measurement-2026-10-12.md)。样本机、档位、数据形状和实测/估算区别必须随结果记录；不默认运行昂贵的 `--all`。
