# Project Knowledge Log

本文件是项目知识库的追加式日志。每个条目记录一次可复核的 ingest、query、lint 或重大文档维护；不要改写历史条目来伪造当前状态。最新状态以专题页和代码/测试为准。

## [2026-09-06] fix/review | 修复公开 main 的上传队列与备份恢复交互

- **基线**：以公开 `main` 的 `b33383d025556d662e371a50252102e00a6f70f6` 为起点；本次不包含旧私有分支历史。
- **手机上传**：同 attempt 的 reservation 轮询保留本地 queued 状态，避免并发槽释放后文件被跳过；终态仍由 Mac 结果覆盖。
- **恢复与备份状态**：恢复权限回调重验 generation，迟到 UI 结果不再调用全局 staging cancel；手动备份有独立 in-flight 状态，激活/刷新不会恢复按钮或允许重复提交。
- **目录授权**：已启用备份可以重新选择原父目录；只在父目录和 repository 身份均匹配时 CAS 更新 bookmark，错误目录和替换 inode 不创建文件或改写配置。中英文案与运行时资源同步。
- **验证**：当前 Mac 上定向回归 53 tests / 7 suites 与完整 `scripts/test.sh` 通过，主测试清单经脚本核对为 981 tests / 90 suites；独立 derived XCTest 13/13、验收扫描 14/1、storage process 33/1、DICOM 导入 17/1、LAN 生产 HTTP 1/1 与真实双流 LAN RSS/背压 1/1 均通过。`scripts/lint.sh`（warnings-as-errors 构建、依赖图和文档）、当前树 `scripts/privacy-guard.sh`、本地化资源核对与 `git diff --check` 通过。以上为未提交工作树的本机证据，尚未绑定不可变候选；真实手机、Powerbox 人工授权、VoiceOver、独立 macOS 版本、完整安装包与正式分发门禁尚未执行。

## [2026-08-28] security/lan | 将接收准入绑定到接口网络前缀

- **行为与边界**：生产 receiver 启动前重新确认所选接口、地址和连续非零 netmask 的精确身份；transport 在安装 child initializer 与 HTTP pipeline 前，按该 IPv4/IPv6 前缀拒绝缺失、不可解析、跨地址族、IPv4-mapped IPv6 或越界的真实对端。接口前缀变化也会让网络监控失败关闭。传输仍是普通 HTTP，只适用于可信任私人网络；当前契约见 [`lan-upload.md`](lan-upload.md) 和 [`privacy-and-security.md`](privacy-and-security.md)。
- **开源门禁收口**：历史隐私门禁为 11 个正式 AppIcon 路径绑定已审查 SHA-256，并逐个检查所有可达历史对象；PR 的主质量 job 使用完整 checkout 后同时运行当前树与 `HEAD` 历史门禁。release workflow 重新从无凭据 canonical HTTPS remote 获取 `main` 并拒绝不在其祖先链上的标签。主测试分片以 977 tests / 89 suites 的确定性全局 inventory 核对账本，derived-artifact XCTest 从真实 bundle 动态发现并逐 case 运行，进程监管不再把测试或后代仍存活的状态转换成成功。
- **结构整理**：`LANDerivedArtifactSinkTests.swift` 的共用 fixture/helper 已移入专用 support 文件，原测试类与 13 个 selector 保持不变；GitHub Actions 的发布来源图测试移入同一 `GitHubActionsWorkflowTests` 的独立 extension 文件，原主文件降至 1000 行以下且不改变 suite 身份。
- **回归证据**：[`LANDeliveryPrerequisiteTests.swift`](../Tests/KinloguePlatformTests/LANDeliveryPrerequisiteTests.swift) 覆盖 netmask 连续性、前缀边界、无效配置及 HTTP 前拒绝，[`LANNetworkMonitorTests.swift`](../Tests/KinloguePlatformTests/LANNetworkMonitorTests.swift) 覆盖同接口、同地址但前缀改变时停止接收。
- **验证与未执行**：正常 macOS 进程权限下完整 `scripts/test.sh` 通过主清单 977 tests / 89 suites、动态 derived XCTest 13/13、验收扫描 14/1、storage process 33/1、DICOM 导入集成 17/1、安装 LAN 生产 HTTP 1/1 及真实双流 LAN RSS/背压 1/1；文档、当前树隐私、`HEAD` 历史隐私与 diff 门禁通过。当前修复仍是未提交工作树，不能据此把 clean-source App/XPC 或安装验收登记为公开候选已通过；macOS 14/15 独立机器、真实 iOS/Android 浏览器、防火墙/网络隔离及其他人工矩阵仍未执行，候选状态保持 [`not-verified` / `pendingManual`](acceptance/current-release.md)。

## [2026-08-24] repository/governance | 统一公开仓库名称

- **仓库身份**：公开仓库现在统一使用 `renyijiu/kinlogue`；Issue 模板中的私密漏洞报告入口已同步到新的 Security Advisory 地址，并由治理回归锁定。生产代码与兼容性文件名中的 `publication` 表示恢复点发布协议，不是仓库名称，因此保持不变。

## [2026-08-24] docs/release | 同步验收扫描当前计数

- **事实修正**：验收 scanner 新增合成 `.build` 泄漏和非法 `Repository` 符号链接两项回归后，独立 suite 的当前计数为 14 tests / 1 suite；[`acceptance/current-release.md`](acceptance/current-release.md) 从旧的 12/1 同步为 14/1。只修正文档计数，不改变实现、发布边界或既有验收结论。

## [2026-08-24] ci/reliability | 验收扫描回归使用私有合成仓库根

- **合并后远端 RED**：PR #3 四项检查全绿并 squash 合并后，同一 tree 的 `main` push 在 177.46 秒 cold build 与 inventory planning 后，让独立 `AcceptanceScanScriptTests` 持续到 180 秒 deadline 并返回 124；进程诊断精确留下 `swift-package → swiftpm-testing → zsh → rg`。scanner 的内部夹具此前仍为每个参数化 case 扫描真实 `.build`，因此运行时间取决于当前 cold-build 体积，而不是业务或泄漏断言。
- **修复与边界**：内部测试模式现在只接受夹具私有、非符号链接、当前用户所有且权限 `0700` 的 `Repository` 根，并以它替代真实仓库扫描根；新增回归把 run-specific canary 写入合成 `.build` 并要求 `KLA_SCAN_MATCH`。未设置内部测试根的生产路径仍扫描真实 source、tests、scripts、packaging、docs、`.build`、`dist`、安装 App、运行产物与崩溃报告，工具缺失、身份错误和扫描错误继续失败关闭。
- **本机验证**：focused scanner 14/1 在约 8.7 秒通过；`KINLOGUE_BUILD_JOBS=2 scripts/test.sh` 又完成 derived XCTest 13/13、与候选账本一致的主测试、storage 33/1、条件别名 1/0、DICOM 17/1、验收扫描 14/1、安装 LAN 1/1 与 Socket/RSS 1/1。lint、文档、隐私、shell 语法和 diff 门禁通过；App/XPC 与新 PR 远端检查仍以后续复验为准。

## [2026-08-24] ci/reliability | 同步故障注入不再阻塞 cooperative executor

- **远端 RED 与精确根因边界**：PR #3 的 fresh macOS 26 / Swift 6.3.3 专用 runner 在 230.68 秒完成 test bundle cold build；直接 `xcrun xctest` 随后通过前 6 个 derived-artifact case，但 `testProductionStoreBudgetIsReservedBeforeAnyDerivedActorHop` 启动后没有返回，最终由 180 秒 deadline 以 124 终止，诊断只留下对应 `xctest` 根进程。这推翻了“剩余问题只在 SwiftPM/XCTest 启动握手”的假设，并把故障限定到该并发测试。
- **修复与边界**：该测试原先从 Swift cooperative executor 创建四个任务，再让每项同步等待 actor hop 前故障注入闸门；较小 executor 可能被四个等待者占满，负责观察入口和释放闸门的测试续体因而无法恢复。现在只把刻意同步阻塞的 `write` 调用放到独立 OS 线程，返回的真实生产 task 仍由测试异步等待；`LANDerivedArtifactSink`、生产 admission 上限、四所有者 16 MiB 高水位、拒绝/清理断言均未改变。专用脚本同时把 13 个固定 selector 拆成 13 个各自有 deadline 的 `xcrun xctest` 进程，并逐项要求精确 1/0 摘要，既避免 0-test 假成功，也把未来停滞绑定到单个无内容 selector。
- **本机验证**：修复后的精确 case 与整组直接 XCTest 分别通过 1/1、13/13；`KINLOGUE_BUILD_JOBS=2 scripts/test.sh` 又在 152.27 秒构建后完成逐 case derived-artifact 13/13、主账 964/89、storage 33/1、条件别名 1/0、DICOM 17/1、验收扫描 12/1、安装 LAN 1/1 与 Socket/RSS 1/1。App bundle、DICOM XPC、隐私及远端新 head 仍以后续复验为准。

## [2026-08-24] ci/reliability | SwiftPM 只构建专用 XCTest bundle

- **远端 RED 与边界收窄**：PR #3 的 XCTest-only fresh `2/3` runner 在 189.40 秒完成 cold build，但随后 `swift-package` 父进程与其 `xctest` 子进程共同存活 18 分 43 秒，仍没有任何 suite/case 事件，最终由 1,200 秒 deadline 返回 124；同一 head 的主质量门禁和补充分区分别在 20 分 34 秒、6 分 4 秒通过。这否定了“只把 case 从 Swift Testing 迁到 XCTest 即可收敛”的假设，也证明失败位于 SwiftPM 测试运行握手或 XCTest bundle 启动边界，而不是编译或已报告的业务断言失败。
- **proof-first 与修正**：脚本契约先要求 `--build-tests`、`--show-bin-path` 和 `xcrun xctest -XCTest KinloguePlatformTests.LANDerivedArtifactSinkTests` 的固定顺序，并在旧脚本缺少 build-only 入口时稳定 RED。专用路径现在只让 SwiftPM 构建禁用 Swift Testing 的 XCTest bundle，随后由 Xcode 的 `xcrun xctest` 直接运行固定 suite；另核对精确 `Executed 13 tests, with 0 failures (0 unexpected)` 摘要，避免错误选择器以 0 tests 返回成功。build、执行各有独立 deadline，13 个 case、断言和失败条件未减少。
- **本机验证**：直接启动已构建 bundle 的单 case 与完整 suite 分别通过 1/1、13/13；真实 `KINLOGUE_PRIMARY_TEST_PARTITION=2/3 KINLOGUE_BUILD_JOBS=2 scripts/test.sh` 在 132.56 秒 build-only 后逐项完成 13/13、0 failure，并通过文档门禁。默认 `KINLOGUE_BUILD_JOBS=2 scripts/test.sh` 也完成 derived-artifact 13/1、主账 964/89、storage 33/1、大小写别名 1/0、DICOM 17/1、扫描 12/1、安装 LAN 1/1 与 Socket/RSS 1/1。更新后的远端专用 job 仍须以 PR 新 head 为准。

## [2026-08-24] ci/reliability | derived 断言改走 XCTest-only 专用门禁

- **远端 RED 与已否定假设**：PR #3 的 fresh `2/3` runner 已在同一个 `swift test --filter KinloguePlatformTests.LANDerivedArtifactSinkTests` 调用内完成 273.21 秒 cold build，但随后仍只留下 `swiftpm-testing-helper`，17 分钟没有任何测试事件并最终按 1,200 秒 deadline 返回 124。这否定了上一条“避免 cold inventory 后第二次 SwiftPM 启动即可收敛”的假设；失败边界是 macOS 26 上该 Swift Testing helper 路径，而不是 13 条业务断言的失败结果。
- **proof-first 与修正**：脚本契约先要求专用命令显式包含 `--disable-swift-testing --enable-xctest` 并在旧实现稳定 RED。随后把 `LANDerivedArtifactSinkTests` 的同 13 个行为 case 与断言迁移到 XCTestCase；默认 `0/1` 与远端 `2/3` 都先走 XCTest-only 路径，planner 继续要求该容器存在但不再把它交给 Swift Testing shard。其余两个远端分区仍互斥覆盖主账 25 与 24 个 helper，没有删除断言或放宽 deadline。
- **本机验证**：`2/3` 冷构建在 142.62 秒后直接完成 XCTest 13/13、0 failure，逐项输出全部 case 且未进入 Swift Testing runner；脚本安全回归 11/11 通过。默认 `0/1` 完整链随后通过：主账 964/89、derived XCTest 13/1、storage 33/1、条件别名 1/0、DICOM 17/1、验收扫描 12/1、安装 LAN 1/1 与 Socket/RSS 1/1；文档、隐私、脚本语法和 diff 门禁同时通过。远端 PR checks 与合并后 main 状态仍以后续运行结果为准。

## [2026-08-24] ci/tooling | GitHub 扫描使用固定 SHA 的 ripgrep

- **远端根因修正**：PR #3 新 head 已把验收扫描移到任何 primary/storage helper 前，但 12 项仍在合计约 0.5 秒内统一返回 `KLA_SCAN_ERROR` 70；这推翻了上一条日志对 helper churn 的归因。`scan-acceptance.sh` 在进入扫描循环前明确要求可执行 `rg`，而 GitHub macOS 26 runner 没有预装；该表现与仓库历史中已确认的 Codemagic 缺工具故障一致。
- **供应链边界**：新增通用 CI 引导脚本，下载 ripgrep 14.1.1 的 `aarch64-apple-darwin` archive，核对既有已验证 SHA-256 `24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be` 后才安装到忽略的 `.build/ci-tools/bin`。GitHub quality 与 release package job 在后续门禁前把该目录写入 `GITHUB_PATH`；不使用 Homebrew，不进入 App bundle，下载、摘要、架构或版本不匹配均失败关闭。
- **proof-first 与本机验证**：workflow/release 源码契约先因 installer 缺失得到 5 项 RED；实现后 2/2 GREEN。真实引导下载、摘要和版本检查通过；把该私有工具目录置于 `PATH` 后，完整 `AcceptanceScanScriptTests` 12/12 在 112.314 秒通过。App/bundle 门禁以本次后续验证为准。

## [2026-08-24] ci/reliability | derived 专用分区使用单次 SwiftPM 调用

- **远端 RED**：fresh `2/3` runner 先用 `swift test list` 完成 342.65 秒 cold build，并正确冻结 derived-artifact 13 tests / 1 suite；随后第二个 `swift test --skip-build` 进程在任何测试启动输出前停滞，最终由 175 秒内层上限返回 124。这否定了“仅换成 fresh runner 即可收敛”的假设，并把失败边界收窄为 cold inventory 后的第二次 SwiftPM 前端启动。
- **修正与 proof-first**：保留三个 runner、planner 的全量覆盖/互斥契约和本机 `0/1` 完整路径；只有多 runner 的最后一个专用分区在 inventory/list 前提前分支，以一次 `swift test --filter KinloguePlatformTests.LANDerivedArtifactSinkTests` 同时完成 build 和执行，成功后仍运行文档门禁。源码顺序契约先因旧脚本缺少该直达路径稳定 RED，实现后 GREEN。
- **本机验证**：真实 `KINLOGUE_PRIMARY_TEST_PARTITION=2/3 KINLOGUE_BUILD_JOBS=2 scripts/test.sh` 从构建到 derived 13/1 只启动一次 SwiftPM 测试命令并通过，文档门禁同时通过；完整 `TestScriptSafetyTests` 11/11 通过。更新后远端仍以 PR 新 head 为准，不把本机结果写成公共发布完成。

## [2026-08-24] ci/reliability | 验收扫描在 helper churn 前运行

- **远端 RED**：三 runner 的 PR #3 主 job 已成功完成全部 25 个 primary helper，随后验收扫描的每个合成 match/clean case 都在约 0.02 秒内统一返回安全错误 70；12 项测试累计 63 个期望失败。这不是某项泄漏断言失败，而是扫描子进程在同一 macOS 26 runner 经历 primary/storage helper churn 后无法建立运行条件。
- **修正与验证**：只把现有 `AcceptanceScanScriptTests` 独立门禁移动到 inventory build 之后、Core/primary/storage 之前，并使用已构建 test bundle；skip 清单、12 项扫描内容、`--no-parallel -j 1`、180 秒 deadline 和其他隔离门禁均不变。源码顺序回归先在旧脚本稳定 RED，移动后 1/1 GREEN；真实扫描 12/12 在 66.277 秒通过。更新后远端仍以 PR 新 head 为准。

## [2026-08-24] ci/reliability | derived-artifact suite 使用独立 fresh runner

- **远端 RED**：两 runner 的 PR #3 运行先证明补充分区中的 `LANDeliveryPrerequisiteTests` 独立 helper 在 6 分 22 秒内成功；主分区随后在检查点恢复/发布 20/2 已成功后启动独立 `LANDerivedArtifactSinkTests` 13/1，却在任何测试启动输出前按 175 秒内层上限返回 124。这否定了“只需拆开两个 LAN 容器”的假设，并把不收敛边界收窄为 derived-artifact suite 不能复用已运行多个 helper 的远端 macOS 26 runner。
- **修正与 proof-first**：planner 把 `LANDerivedArtifactSinkTests` 声明为专用 fresh-runner 容器；多 runner 模式保留最后一个分区只执行该容器，其余 shard 仍按确定性模数分配。本机默认 `0/1` 不变，仍覆盖完整清单。回归先让旧 planner 错把第三分区分给 Delivery，并让旧 workflow 因缺失第三 job 得到合计 8 项 RED；实现后 planner/workflow 2/2 GREEN，且证明三个分区互斥、并集精确等于全部 50 个 helper。
- **本机验证**：正常 macOS 权限下 `2/3` 只运行 derived-artifact 13/1 并通过；`0/3` 运行 25 个 primary helper、Core、storage 33/1、条件别名锁 1/0、DICOM 17/1、扫描 12/1、安装 LAN 1/1 与 Socket/RSS 1/1；`1/3` 运行其余 24 个 primary helper。三个命令均为 exit 0。更新后远端 PR checks 仍须以新 head 为准，不把本机结果写成公共发布完成。

## [2026-08-24] ci/reliability | 主测试按容器使用短生命周期串行 helper

- **远端与本机 RED**：PR #3 的第二次 GitHub CI 在普通测试基本完成后仍保留 19 个 `KinlogueStorageProcessFixture` 子进程，主测试最终由 1,200 秒 deadline 以 124 终止。本机先把 storage target 从并发主套件分离并以 `--no-parallel -j 1` 完成 33/33；随后主套件又留下两个 `VaultMutationCoordinatorTests` 的真实 `/usr/bin/lockf` 子进程超过 9 分钟。全局串行后的远端运行不再残留子进程，却让唯一 Swift Testing helper 在检查点发布套件附近持续约 19 分钟；改成 target 级 helper 后，Platform 内检查点发布完整通过，仍在后续 `LANDeliveryPrerequisiteTests` 参数化用例处只剩 helper 并持续到 deadline。容器级分片远端连续两轮都证明该套件 16/16 和成功 summary 已完成，但 SwiftPM helper 随后仍驻留并由 180 秒 deadline 返回 124；第二轮监督器进程仍在而未记录已观察标记，把问题进一步限定为 Actions 原始输出流的 summary 解析。ANSI 规范化后的第三轮远端已记录 16/1 的已观察标记，紧接着 13/1 分片却在任何测试启动输出前超时；进程诊断同时显示 `swiftpm-testing` 已另建 process group。后代身份清理修正后的第四轮仍在相同的第 73 次 helper 启动、相同 13/1 分片、任何测试输出之前按内层 175 秒上限失败，证明剩余根因是重复 SwiftPM 前端启动的确定性累积，而不是该容器中的业务断言或未清理后代。把 88 个 shard 压到 49 后，第五轮远端在前 33 个合并 helper 全部成功后，仍让第 34 个 29/2 helper 在任何测试输出前超时；这否定了“只是 helper 启动次数”的单一因果。第六轮把 49 个 helper 分到两个全新 runner 后，分区 1 仍在更少的前置 helper 后让同一个 29/2 helper 在任何测试输出前超时；真实 planner 清单把它唯一映射到 `LANDeliveryPrerequisiteTests` 与 `LANDerivedArtifactSinkTests` 的组合，最终把边界收窄为这两个 suite 在 macOS 26 上的组合启动，而不是 runner 累积计数或最后可见业务断言的确定性死锁。
- **修正与契约**：全量脚本先从可执行 test inventory 生成非重叠 shard；Core 保持单 helper，Platform/App 每个 helper 最多放入两个不拆分的完整多测试容器，单项容器每批最多 16 项，均保持 `--no-parallel`。planner 对未知 target、缺失隔离门禁、运行标识冲突、遗漏、重复和混合容器把隔离用例重新纳入全部失败关闭，并为每个 shard 冻结精确 tests/suites。监督器从有界二进制输出尾部去除 ANSI 控制序列、统一空白后匹配精确 summary，记录不含内容的期望/已观察计数；helper 存活时持续捕获后代 PID 与启动身份，即使后代另建 process group 或被重新托管，也只清理仍匹配身份的本分片进程。成功 summary 后保留 5 秒宽限；无 summary 的内层上限比外层 deadline 提前 5 秒，以便同一监督器先收敛后代。宽限期内的非零退出优先返回，错配/缺失 summary、超时或清理残留继续失败。target 分片与多 summary 契约先 RED→2/2 GREEN；真实清单随后依次暴露混合容器、单数 summary、顶层函数 target/signature 规范化和条件测试账本问题，每项均先补回归得到 RED 再修至 GREEN。1,042 个 specifier 在本机完整路径生成 50 个 Platform/App shard；GitHub CI 用确定性模数分成互斥的 `0/2` 与 `1/2` 两个全新 runner，各运行 25 个 helper，只由分区 0 承担 Core 和全部独立门禁；已证明不兼容的两个 LAN 容器固定拆成各一个 helper，其余容器配对不变。只在大小写不敏感卷启用的别名锁测试从固定主账分离为独立条件门禁。监督器回归先因脚本缺失 RED，随后证明跨进程组残留被收敛、summary 后即时非零仍返回 42、错配 summary 仍返回 124；ANSI summary 旧解析稳定返回 124 后转为 GREEN；另建 process group 的后代在旧实现上又稳定证明监督器返回成功但进程仍存活，修正后成功与无 summary 超时两条路径都能精确清理。两个完整容器共用 helper 的 planner 契约先在旧实现稳定得到 3 个 shard，再收敛为 2 个且保持所有 specifier 精确覆盖。分区契约的 proof-first 回归先让旧 planner 因额外参数失败，并让旧 workflow 因缺少第二 runner 得到 5 个精确断言 RED；实现后 2/2 GREEN。LAN 组合隔离回归再让旧 planner 精确得到 shard 总数 3、第二分区 1 个 fixture shard和同 pattern 包含两个 suite 的三项 RED；实现后总数 4、两分区各 2 个 fixture shard，且两个 suite 互斥、并集仍等于完整清单。
- **验证**：外层沙箱内的单 helper 串行主套件在约 101 秒完成 974/91，只有依赖 `/bin/ps` 的 deadline tests 按设计失败关闭；同一精确命令在非沙箱权限下于 85.37 秒通过。检查点发布 suite 随后在同一工具链、每轮 15 秒硬截止下连续 30 轮通过。分片监督器聚焦回归和远端失败的 LAN 16/1 production wrapper 已本机通过；ANSI 规范化后的整链先完成 975/90，跨 process-group 后代修正后的 `KINLOGUE_BUILD_JOBS=2 scripts/test.sh` 再以 Core 与 88 个 Platform/App shard 精确汇总 977 tests / 90 suites，并通过关键相邻 16/1→13/1、条件别名锁 1/0、storage 33/1、DICOM 17/1、扫描 12/1、安装 LAN 1/1、Socket/RSS 1/1。49-shard 完整整链随后在正常 macOS 权限下精确汇总 977 tests / 90 suites，并通过条件别名锁 1/0、storage 33/1、DICOM 17/1、扫描 12/1、安装 LAN 1/1 和 Socket/RSS 1/1。最终 50-shard 契约的 `0/2` 与 `1/2` 本机整链均通过各自 25 个主分片；拆出的 Delivery 16/1 与 Derived 13/1 分别独立通过，分区 0 另通过 Core 和全部独立门禁，planner 回归同时证明两分区互斥且并集等于完整清单。更新后的远端 CI/CodeQL 仍以 PR 当前 head 为准，不把本机结果写成公共发布完成。

## [2026-08-23] ci/reliability | 跨进程 fixture 退出观察不再阻塞 worker

- **远端与本机 RED**：公开 baseline 的首个 GitHub Actions CI 在 lint、隐私门禁和全量测试构建完成后没有断言失败，但多个已经开始的跨进程/文件系统用例未收敛，最终由 1,200 秒 deadline 以退出码 124 终止。随后在同一 macOS 26 工具链把并发宽度降为 1，仍于 storage process 测试稳定停住；进程树证明 fixture 子进程已经退出，堆栈采样则精确落在后台 GCD worker 的 `Process.waitUntilExit()`。
- **修正与边界**：fixture 在启动前安装 `Process.terminationHandler`，由锁保护的退出观察器缓存唯一终态并恢复并发或迟到的全部等待者；不再占用 worker 阻塞等待。主套件改用 SwiftPM 支持的 `--parallel --num-workers`，CI 固定两个 worker；DICOM 导入集成 17/1、验收扫描 12/1、安装 LAN 生产 HTTP 1/1 与真实 Socket/RSS 1/1 各自以 `--no-parallel` 独立运行。deadline、job 上限、覆盖和失败条件均未放宽。
- **proof-first 与验证**：源码契约先在旧 fixture 上精确观察到缺少 termination handler 且仍调用 `waitUntilExit()`；真实 fixture 回归再要求并发两个等待者、shutdown 自身等待者和退出后的迟到等待者都取得同一个成功状态。首次本机完整修复通过后，PR #3 远端 RED 又证明实验性宽度变量未阻止小型 runner 在 16 秒内令验收扫描全部资源失败并再次超时；官方 worker CLI 与扫描隔离的契约继续先 RED。两次本机有界 worker 全量又各自只暴露 DICOM 导入集成的 1 个资源时限 issue，而同一 suite 独立复验 17/17、3.48 秒通过，因此将其纳入真实单 worker 门禁。最终 `scripts/test.sh` 通过：主套件 1,007 tests / 92 suites、DICOM 导入集成 17/1、验收扫描 12/1、安装 LAN 探针 1/1、真实 Socket/RSS 1/1；远端最终状态仍以 PR 自身的 CI/CodeQL 和合并后的 main workflow 为准。

## [2026-08-23] release/history | 从净化 tree 建立单根公开候选

- **历史拓扑**：仅导出最终受控 `HEAD` tree，在隔离仓库建立一个 noreply 作者的 root commit；未复制旧 `.git`、branches、tags、PR refs、releases 或原 commit metadata。`git rev-list --count --all` 为 1，唯一根等于候选 HEAD。
- **历史隐私**：隔离候选先通过 `scripts/privacy-guard.sh`、`scripts/verify-docs.sh` 与本地化检查，提交后再通过 `scripts/privacy-history-guard.sh --ref HEAD`。公开推送后仍要求从远端隔离 clone，并对全部公开 refs 复验；远端运行与安全设置只作为 GitHub 实时状态核对，不伪造成源码内永久结论。
- **PR 边界**：baseline 没有可安全继承的公共父提交，因此不伪造初始 PR；旧私有 PR/branch/release 不迁移。初始 root 建立后，后续变更由 `main` 规则集强制经 PR 进入。

## [2026-08-23] release/validation | 绑定最终开源快照的完整源码自动化

- **完整测试清单**：`scripts/test.sh` 在当前净化 source tree 上完成 1035 tests / 94 suites；同一脚本随后以单线程隔离执行 `productionFileQueueStaysBoundedWithTwoStreamsSlowPeersAndDisconnect`，真实双流 slow-peer、断连和 RSS/事件循环上限用例 1 test / 1 suite 通过。
- **静态与构建门禁**：`swift build --disable-sandbox`、`scripts/lint.sh`、`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check`、JavaScript/zsh 语法和 `git diff --check` 通过。第一次完整运行在主测试通过后因候选账本仍为 0/0 而失败关闭；登记真实 1035/94 后整条脚本与隔离用例才通过，随后才把 `automated-gates` 提升为 `passed`。
- **仍未执行**：clean-source App/XPC、Developer ID、公证、macOS 14/15 独立机、真实手机/Powerbox/File Provider、真实私有样本、VoiceOver/键盘与独立密码学安全审计没有被源码自动化替代；整体状态保持 `pendingManual`。

## [2026-08-23] security/backup | 收紧发布序号、跨进程 lease 与单扫描保留围栏

- **#4 sequence 高水位**：`BackupCheckpointPublisher` 在同一 repository lease 内从最新配置读取当前 writer 的 durable full-reader witness，以 `max(visible + 1, witnessed + 1, authorization floor)` 分配序号；删除最新叶、重建 repository/store 实例并随后重新物化旧叶的 production-path 回归先稳定复用 sequence 0 并形成 fork，修正后发布 sequence 1 且历史保持线性。
- **#5 单扫描保留**：保留仍只有一次权威 O(repository) 扫描，30→2 回归继续严格观察到一次；每次 unlink 前新增扫描前后目录 generation 与全部 planned-keep 精确身份/认证围栏。非目标 keep 被移除或同字节换 inode 的两项 proof-first 回归旧实现都继续删除最旧叶，修正后均在目标 unlink 前 defer。
- **#6/#7 真实互斥证据**：publication mutex 从同步 repository 的命名文件迁到 app-private、0700、no-follow 的 configuration-root 目录 inode，并绑定当前 configuration root、repository、set、authorization 与 writer epoch；锁顺序固定为 `repository → configuration`，lease 从权威扫描持续到 durable witness。Storage process fixture 只通过 `KinlogueStorageProcessFixture` SPI 在真实 publisher 已持 lease 且完成权威扫描处暂停，不复制 sequence/scan 算法；第二进程在 repository 命名 lock 被迟到替换后仍确定阻塞，首进程释放并见证后才进入并发布 authorization floor 的后继序号。
- **验证范围**：上述三个 RED 均记录到预期失败；GREEN 覆盖 `BackupRepositoryTests` 7 tests、`BackupRetentionExecutorTests` 9 tests、`EncryptedCheckpointWriterTests` 13 tests、受影响 App 19 tests，以及完整 `KinlogueStorageProcessTests` 31 tests。`swift build --disable-sandbox`、`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/lint.sh` 和 `git diff --check` 通过；安装 App、真实 File Provider、macOS 14/15 独立机与人工恢复未执行。

## [2026-08-23] fix/backup | 状态刷新后仍释放未完成设置的恢复操作

- **恢复码生命周期**：`BackupModel` 在调用异步 resume service 前先复制并清空 SecureField binding；状态刷新即使推进全局 operation generation，迟到失败也不再把已提交恢复码留在界面状态中。
- **操作所有权**：pending enrollment 的忙碌态由启动它的 generation 持有并在 `defer` 中按 owner 释放；旧 resume 只能结束自己的忙碌态，不能清空或解锁更新的 pending 操作。状态刷新抢先完成而 resume 随后失败时，恢复 sheet 保持可重试且不再被永久锁定。
- **proof-first**：新增失败型状态刷新竞态先稳定得到恢复码仍保留且 `isPendingEnrollmentOperation == true` 两项失败；修正后该回归与完整 `BackupModelTests` 14 tests / 1 suite 通过，文档、隐私、本地化、lint 和 diff 门禁通过。既有 [`backup-and-restore.md`](backup-and-restore.md) 与 [`../PRIVACY.md`](../PRIVACY.md) 已拥有“成功、失败、取消或放弃后清空”的用户承诺，无需新增文案或翻译。

## [2026-08-23] fix/lan | 配对成功后拒绝迟到的旧会话恢复

- **会话 epoch**：手机页面成功配对后立即推进浏览器 session generation，取消上一 epoch 的请求与 timer，并重置文件行、上传队列、mutation epoch 和取消 tombstone；配对前发出的 cookie restore 即使迟到，也不能覆盖新 CSRF token、文件列表或连接状态。
- **proof-first**：Node `vm` seam 先挂起 production `restoreSession`，完成 production `pair` 后释放旧 snapshot；旧实现因 generation 未推进而让 stale token 覆盖新 token，以退出码 3 稳定失败，修正后该回归与完整 `LANPhoneAssetSafetyTests` 17/17 通过。既有 stale poll、retry、cancel 与 upload completion 围栏继续通过；完整文档、隐私、语法和 diff 门禁以本次最终验证为准。

## [2026-08-23] test/restore | 收紧安装 crash 终态并覆盖 activation 后损坏回滚

- **#2 安装探针**：`run-backup-capability-probe.sh` 不再按 scenario 接受任意旧/新或无根/新终态，而是与 production process tests 共用同一事实表：existing root 前三 phase 精确回到旧根、后三 phase 精确到新根；absent root 前两 phase 保持无根、后三 phase 精确到新根。每项还独立要求 transaction/preflight receipt、staging、rollback 全部不存在并通过真实语义验证。
- **#8 production activation**：Platform integration 在 `BackupRestoreVerifier.prepare` 成功后定长破坏 committed Vault object，再调用真实 `BackupRestoreTransaction.activate`。existing 与 absent 两种场景都得到 `graphInvalid`；前者恢复逐目录/逐文件相同的旧根，后者保持无根，且 restore artifacts 为空。fixture 没有新增 transaction/rollback 算法，也不需要扩大 `Testing` SPI。
- **proof-first 与验证**：runner 源码门禁先以 17 项 issue 证明缺少 11 个精确 phase 映射、三类工件清理断言和 generic gate 禁止式；修正后，production restore、完整 capability activation process 与 source-safety 共 29 tests / 3 suites 通过，`zsh -n`、docs、privacy、lint 和 diff check 通过。完整安装 capability script 会安装 ad-hoc App 并执行 20,000 对象 / 2 GiB 数据集，本批未运行，因此没有新增已安装工件证据；macOS 14/15、真实目录与人工矩阵同样未执行。

## [2026-08-23] security/release | 补齐已删除凭据路径与恢复码的历史门禁

- **历史路径**：reachable-history 扫描新增 `.env`/`.env.*`、`.key` 与 `.p8` 拒绝；只有叶名精确为 `.env.example` 的环境模板例外，类似 `.env.example.local` 仍失败关闭。
- **内容模式**：凭据扫描新增与生产编码一致的九组大写十六进制恢复码格式；grep 继续只返回状态，所有失败只报告规则类别，不回显命中路径、canary 或恢复码。
- **proof-first**：合成临时 Git 仓库分别提交再删除任意环境 secret、二进制私钥样式 `.p8`/`.key` 和完整格式恢复码，并显式移除 `KINLOGUE_FORBIDDEN_VALUES`；旧 guard 对这些用例稳定误放行，修正后 `ReleaseScriptSafetyTests` 10 tests / 1 suite 通过。完整源码、bundle/安装与远端托管平台历史审计仍由父级公开发布收口执行。

## [2026-08-23] perf/quality | 关闭自动备份不再准备全库 source plan

- **配置路径**：`LiveBackupService` 在关闭自动备份时直接调用 scheduler 的 metadata-only 更新，不再先冻结并枚举 Vault/LAN source graph；启用路径仍准备并验证权威 revision pair，调度语义和备份完整性围栏不变。
- **有界简化**：同批复用 scheduler terminal-failure 判定、备份 repository 构造和 descriptor 同步逻辑；测试辅助代码删除单次使用的异步映射与重复 commit-then-delete fixture。LAN 手机资源的数字/Set 防御分支由聚焦 Node fixture 证明仍有可达契约后完整保留；涉及调度 admission、事件合并、轮询 DOM diff 或历史对象流的更大行为/安全变化不在本批静默改写。
- **审查修正**：目的地曾离线、但当前 revision pair 已由既有恢复点覆盖时，成功解析目的地后的 scheduler handle 只清除 `.repositoryOffline` / `.sourceChanged` 的失败与重试 metadata，保留原 `lastLocalVerificationAt`，不运行备份或伪造新验证；actionable failure 不清除。proof-first 回归修正前稳定留下 failure、attempt 与 retry due，修正后 scheduler/live service/model 聚焦回归通过 30 tests / 2 suites，文档、隐私、lint 与 diff 门禁通过；完整源码与 bundle/安装矩阵仍由父级公开基线收口统一执行。
- **proof-first**：在既有 metadata-only 状态测试中加入 enable 后再 disable 的 source preparation 计数，旧实现稳定得到第二次准备并失败；配置直达实现后同一用例通过。完整聚焦回归、文档/隐私/静态门禁和全量发布矩阵仍由本次公开基线收口统一执行。

## [2026-08-23] security/dependencies | 复核公开公告并保留独立审计缺口

- **点时结论**：锁定的 SwiftNIO `2.101.3` 高于三项 GitHub reviewed 2026 公告的 `2.100.0` 修复线；ZIPFoundation `0.9.20` 包含 `0.9.18` 的 symlink containment/path escape 修复。DICOM-Swift 1.3.3 的公开 advisory 查询没有命中，但这不构成安全审计或漏洞不存在证明。
- **自动化事实**：旧私有仓库的 Dependabot alerts 与 code scanning API 均返回未启用，不能写成零告警。公开 baseline 已配置 Swift/Actions Dependabot 与 macOS Swift CodeQL；只有新仓库真实运行后才能形成远端证据。
- **剩余风险**：DICOM decoder 继续依赖 XPC containment、watchdog 和合成 hostile fixtures；checkpoint 加密格式、密钥分层与恢复事务仍没有独立密码学/安全审计。来源、版本和采用边界记录在 `docs/sources/dependency-security-review-2026-08-23.md`。

## [2026-08-23] test/backup | 补齐 LAN 派生文件与预处理中断的真实恢复图证据

- **真实 source graph**：测试夹具通过 `PlaintextLANInboxStore.startItemUpload` 写入合成 blob，再用 `beginItemDerivedArtifact` 与 production sink 完成 reviewable derived artifact；第二项停在 durable `.preprocessing` 并保留活动 partial。`PlaintextLibraryBackupSource.prepare` 与真实加密容器证明 `.lanInboxDerivedArtifact` 的路径和字节进入 checkpoint，而 preprocessing partial 不在 source plan、manifest 或解密结果中。
- **恢复与篡改边界**：生产 `EncryptedBackupContainerWriter → BackupRestoreVerifier.prepare → BackupRestoreTransaction` 恢复同一图；staging 与 activation 后的 LAN strict validator 均接受完整 derived artifact。测试对已恢复派生叶做定长字节篡改后，真实 digest validator 以完整性错误拒绝，不只验证 path allow-list。
- **启动收敛与验证**：恢复事务先按真实重启顺序 reconcile，随后普通 `PlaintextLANInboxStore.initialize` 把没有 transient partial 的 durable `.preprocessing` 转为可重试 `.failed(.storageFailure)`，保留原 blob、不产生 derived 引用且不伪装为 reviewable。proof-first 先因夹具缺少 derived/preprocessing 字段编译失败，完成纯测试夹具后 `PlaintextLibraryBackupSourceTests|EncryptedCheckpointRestoreTests` 共 8 tests / 2 suites 通过；生产源码无需修改，完整发布矩阵仍由父级开源收口统一执行。

## [2026-08-23] security/governance | 建立公开协作与供应链门禁

- **公开协作边界**：新增贡献、安全报告、行为准则、CODEOWNERS、issue forms 与 PR template；所有公共输入都明确禁止真实医疗资料、身份信息、私有路径、内容日志、凭据、恢复码与备份文件，只接受合成最小复现。漏洞统一进入 GitHub private vulnerability reporting，不在公开 issue/PR 提前披露。
- **供应链与静态分析**：Dependabot 从仅 GitHub Actions 扩展到 SwiftPM git 依赖；新增固定 macOS runner 的 Swift CodeQL manual-build workflow，checkout 与 CodeQL v4 action 均锁定完整 commit SHA，分析写权限只授予 analyze job。`.gitignore` 补齐本机密钥、签名材料、恢复点、archive 与 DerivedData，同时刻意不忽略医疗/报告扩展名，让 privacy guard 继续失败关闭。
- **proof-first 与边界**：治理测试先因 `SECURITY.md` 不存在稳定 RED，再实现文件存在、合成数据规则、Swift/Actions Dependabot、CodeQL 权限/build/SHA pin 与 ignore policy。该单元只证明仓库配置与源码门禁；GitHub 私密漏洞报告、branch protection、远端 CodeQL/Dependabot 实际运行要在新公开仓库创建后复核。

## [2026-08-23] test/restore | 用生产恢复事务完成真实进程 SIGKILL 收敛矩阵

- **生产入口绑定**：`KinlogueStorageProcessFixture` 的 seed 继续生成最小合成 Vault 与 durable LAN inbox，但先经 `PlaintextLibraryBackupSource + EncryptedBackupContainerWriter` 形成真实 checkpoint，再由 production `BackupRestoreVerifier.prepare` 构造 prepared restore；execute 和新进程 reconcile 分别直接调用 `BackupRestoreTransaction.activate` / `reconcile`。fault initializer 与 fault enum 只通过 `Testing` SPI 暴露给 fixture，App composition 不引用该入口。
- **删除重复算法**：fixture 不再声明第二套 activation phase/receipt，也不再复制 rename/swap、rollback、reconcile、cleanup 或 semantic-fault 状态机；该文件 136 行新增、825 行删除，净删 689 行。源码门禁反转为必须绑定生产符号，并显式拒绝旧 `ActivationReceipt`、`ActivationPhase`、`rollbackActivatedRoot` 和自有 cleanup 实现。
- **proof-first 与验证**：源码门禁先以 9 个 expectation 稳定证明 fixture 缺少生产调用且仍含复制状态机。修正后，existing root 在 after-intent、after-writer-reset、after-old-root-move、after-new-root-activation、after-validation、after-commit 六处真实 `SIGKILL`，absent root 在适用的五处强退；新进程均收敛到预期旧根/空根/新根，真实 Vault catalog 与 LAN inbox strict validation 通过且 receipt/staging/rollback 无残留。生产 Platform restore、四项 process/真实 writer、两项源码安全聚焦回归共 11 tests / 3 suites 通过；完整 backup capability process suite 18 tests / 1 suite、完整 capability source-safety 4 tests / 1 suite 也通过。这只证明当前 Mac 源码真实进程自动化，未执行 clean-source bundle、安装恢复、macOS 14/15、真实 Powerbox/File Provider 或人工恢复矩阵。

## [2026-08-23] perf/backup | 移除状态页全库扫描并线性化保留清理成本

- **状态加载成本**：`LiveBackupService.loadStatus` 不再为了可选空间估算调用 `PlaintextLibraryBackupSource.prepare()`；设置页刷新只读配置、scheduler 与目的地授权 metadata，空间估算在没有安全缓存时保持 `nil`。启用自动备份与真实 scheduler 入口仍生成权威 source plan，备份容量与完整性门禁没有下移到缓存。
- **单扫描保留批次**：`BackupRetentionExecutor` 在固定 publication lease 下以一次完整、认证的 repository scan 形成删除批次；每个目标在 `beforeDelete` 后仍通过 `deleteExact` 重开并复核类型、单硬链接、inode、字节、签名 checkpoint 与 repository identity digest。配置锁覆盖最终 revision fence、精确删除和 witness 移除，保留数量或其他配置 revision 并发变化会推迟而不是沿用旧策略；本进程每次 witness CAS 返回的新 revision 作为下一项期望。
- **proof-first 与验证**：状态/source 计数和 30→2 真实 checkpoint instrumentation 先因缺少 seam 编译失败；实现后证明状态加载 prepare 次数为 0、真实自动调度入口为 1，30 个恢复点降到 2 个只做 1 次全库 scan 和 28 次 exact-leaf 删除。叶替换、删除同步失败、history fork、缺 witness、clock continuity、`beforeDelete` 内 retention revision 变化与取消仍失败关闭。聚焦 Platform retention 8 tests / 1 suite、LiveBackup 6 tests、配置存储 8 tests 与 operation coordinator 3 tests 均通过；`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/lint.sh` 和 `git diff --check` 通过。完整源码与 bundle/安装矩阵由父级开源收口统一完成。

## [2026-08-23] fix/lan | 拒绝手机页陈旧轮询回退与取消项复活

- **轮询线性化**：手机页为当前连接新增内存 mutation epoch；选择、reserve、上传进度/终态、重试、取消和移除等本地 mutation 都推进 epoch。`GET /api/session` 发出时冻结 generation 与 epoch，等待期间任一值改变就不再合并整份 snapshot。
- **单项单调性**：远端 `attemptRevision` 低于本地 revision 时拒绝合并，saved/cancelled 终态及正在取消的本地状态不能被活动态覆盖；取消成功的 `remoteFileID` 保留在当前连接 tombstone set，后续 snapshot 不会复活该行，明确清除连接时才释放。
- **proof-first 与验证**：新增 Node `vm` 缝先以退出码 3 稳定证明旧 snapshot 会把已重试文件降回旧 revision/中断态；修正后同一测试真实挂起 `/api/session`，并在响应返回前走生产 retry、cancel、upload completion 与 merge 函数，证明三类状态不回退且 fresh snapshot 也不能复活取消项。完整手机资源安全套件 16 tests / 1 suite 通过；完整源码与 bundle/真机矩阵由父级开源收口统一完成。

## [2026-08-23] fix/backup | 让自动备份在目的地暂时离线后持续重试

- **durable bounded retry**：`BackupScheduler` 把 runner 内明确的 `.repositoryOffline` 与 `.sourceChanged` 一样纳入最多 1/5/15 分钟三次退避；失败、attempt 和 due 持久化，重启不重置等待，目的地到期恢复后成功备份会清除失败元数据。超过上限后停止安排且后续 lifecycle 观察不再改写配置；身份、分叉、认证、容量、publication indeterminate、资源和验证错误仍保持 actionable failure，不进入忙循环。
- **预检断点与 App timer**：`LiveBackupService` 只捕获 scheduler 入口之前 directory resolution 抛出的精确 `BackupDestinationAuthorityError.repositoryOffline`，经 scheduler 记录而不虚构 source revision pair；read-only、bookmark 重选和 identity 错误不被归入瞬时离线。`BackupModel` 对 `.retryScheduled` 使用既有 timer 自动发出到期 mutation；退出只取消内存 timer 和在途 operation，不改变 durable retry。
- **proof-first 与验证**：scheduler runner offline 先稳定得到 `.failed` 且 `retryDueAt == nil`，bookmark 预检 offline 先稳定直接抛错；修正后可控 clock 回归覆盖跨 service 重建保留 due、目录以同 inode 恢复后到期真实发布成功、三次上限、actionable 非重试、Model 无外部事件自动触发及 termination timer 取消。备份 scheduler/model/live-service 聚焦回归通过 26 tests / 2 suites，`scripts/lint.sh`、文档、隐私和 diff 门禁通过；完整源码与 bundle/安装矩阵由父级开源收口统一完成。

## [2026-08-23] fix/backup | 线性化跨进程恢复点发布并稳定 writer 配置 fence

- **repository publication lease**：新增固定 owner-only/no-follow control leaf 和 cancellation-aware `flock` lease；生产 publisher 从权威扫描和 sequence 分配开始持锁，直到排他发布、正式文件完整回读与 durable witness 配置 CAS 完成。control leaf 不进入 repository scan 或候选上限，symlink、hardlink、错误权限、命名 inode 替换和 repository identity 变化均失败关闭。
- **配置与保留**：writer fence 改为比较 enrollment/writer epoch、backup set、device authorization 及 repository/config identity；自动开关、保留数量、scheduler、bookmark refresh、revision 与已有 witness 不再误撤销同一 writer。Witness 在配置跨进程锁内追加到最新同 identity 状态；reset/re-enrollment 仍在发布前拒绝，发布后无法登记则保持 final 并报告 publication indeterminate。Retention 使用相同 repository lease 与锁顺序，避免 scan/delete 和 publish 交错。
- **proof-first 与自动化**：受控 writer 事件先稳定复现合法配置变化在发布前误报 `invalidConfiguration`、发布后误报 `publicationIndeterminate`，以及 reset-after-publication 错误映射；修正后四条通过。`KinlogueStorageProcessFixture` 让两个真实 Swift 进程先同时到达 publication barrier，再调用同一个 Platform publisher，证明 sequence 唯一、history linear、两个正式叶均有 durable witness。最终加入 lock inode 发布前/后替换回归后的 Platform/App/process 聚焦回归 32/32 通过；完整源码、bundle/安装与人工 File Provider/Powerbox 矩阵仍待最终整体验证。

## [2026-08-23] fix/backup | 补齐未完成备份设置的重启恢复与显式放弃

- **生产恢复链**：`BackupServicing` 与 `LiveBackupService` 直接复用 `BackupSetupService.resumePending`，重启后的 `BackupModel` 在没有进程内 setup session 或恢复码时识别 durable pending enrollment，接受用户独立保存的原恢复码并提升同一 descriptor、device authorization、signing seed 与 writer epoch；不会生成第二份 signer 或 recovery seed。
- **显式放弃与秘密生命周期**：设置页同时提供独立的二次确认放弃动作，只有确认后才调用 `abandonPending`；失败保留 pending 状态并显示语义错误，移除原来的 `try?` 静默清理。pending 恢复码只保留在操作 sheet 的模型状态，成功、错误、取消或放弃后清空。
- **proof-first 与回归**：模型、真实 `BackupLocalConfigurationStore → BackupSetupService → relaunch LiveBackupService → BackupModel` 和源码 UX 测试先因缺少 pending 恢复 API 编译失败；实现后包含状态刷新竞态在内的聚焦 20 tests / 2 suites 通过。完整源码测试、bundle/XPC、安装验收和键盘/VoiceOver 人工流程由父级开源收口统一执行。

## [2026-08-23] fix/restore | 收敛报告 OCR 与恢复终端生命周期

- **报告写入 fence**：`LiveAppService` 直接接入共享 `LibraryLifecycleCoordinator`，Finder 报告导入、失败草稿重试和复核页重新 OCR 三条可持久化路径统一使用 active-operation fence。revocation hook 会取消并等待 admitted task；真实 `PlaintextVault + VaultImportDraftStore + ImportWorkflow` 回归冻结 OCR，证明 revoke 未在任务结束前返回，返回后 catalog 不再出现迟到提交。普通只读复核和原件加载不进入 fence。
- **恢复 preparation 所有权**：`LiveRestoreService` 增加 service-level operation generation。较旧 preparation 迟到时只取消自己的 `BackupPreparedRestore`；cancel/activate 都先使在途 generation 失效，activation 期间拒绝新 preparation。受控 A/B 回归证明 B 保持可激活且 A 的 staging 被精确取消。
- **activation 失败终态**：确认替换后的任何 activation error 继续保存语义 `.activation`，但界面变为不可交互关闭、不可取消的 restart-only 状态，只提供“退出续页”，并移除“当前资料库不会替换”的验证失败通用说明；新增中英文文案和源码/UI 回归。
- **验证边界**：聚焦 lifecycle、restore service、RestoreModel、UI 安全和本地化集合通过 37 tests / 6 suites；完整源码测试、clean-source bundle/XPC、安装验收和恢复人工矩阵将在父级开源收口完成后统一执行。

## [2026-08-23] security/release | 净化私密验收记录并增加 Git 历史门禁

- **隐私净化**：把历史日志中来自仓库外私密 MRI、真实资料库和人工备份 UI 的精确库存、大小、Series/切片位置及报告/草稿/附件计数改写为无内容、非精确的人工验收摘要；保留显式授权、仓库外运行、未保存内容工件和结果不能扩大为兼容性承诺的边界。
- **历史门禁**：新增 `scripts/privacy-history-guard.sh`，默认扫描 `HEAD`、本地 heads/tags 和 `origin` remote refs 的 reachable Git objects，也支持用重复 `--ref` 检查临时仓库或精确发布 ref。门禁拒绝历史医疗/报告类附件、备份或签名容器、私钥/常见凭据、精确私密资料库存证据和调用方 forbidden values，错误不回显命中内容。
- **proof-first 与发布边界**：`ReleaseScriptSafetyTests` 的合成临时 Git fixture 先提交 forbidden value、再删除并提交；新增门禁前该测试因脚本不存在按预期失败，完成实现后 clean history 通过且 commit-then-delete 被拒绝。当前私有仓库的旧 reachable commits 仍包含净化前文字，因此全历史门禁按设计失败；父级开源流程必须创建 orphan 净化历史、只迁移审计后的当前快照并删除所有旧 public-bound refs，之后才可把全历史通过记录为发布证据。

## [2026-08-20] fix/backup | 让隐藏恢复点可见并明确手动备份状态

- **根因与现场证据**：设置页只展示用户选择的父目录，但恢复点按设计发布到 Finder 默认隐藏的 `.kinlogue-backup-v1`；一次仓库外、无内容的人工检查确认 repository 中已有完整恢复点，因此“没有产生备份”是隐藏目录与无说明转圈共同造成的可发现性误判，不是 writer 未发布。人工记录不保留真实资料库的恢复点数量、大小或目录内容。
- **交互修复**：已配置状态新增“在访达中显示”，在持久 security scope 内重新验证父目录与 repository identity 后打开精确 repository；手动备份运行时从无文字 spinner 改为明确的加密备份进行中状态。打开失败继续映射为现有本地化备份错误，不记录或持久化用户路径。
- **自动化**：新增 model 路由、真实 destination authority、精确隐藏 repository URL、balanced security scope、stale bookmark 持久化、打开失败与失败后成功重试回归；聚焦测试 12/12、完整源码自动化 993 tests / 94 suites及独立真实 Socket/RSS 门禁通过，`scripts/lint.sh`、本地化、文档、隐私与 diff 检查通过。
- **clean-source 候选**：从 revision `6b2e52923e83698f5d2944d049c5516aeb98f50f` 在 macOS 26.6.1 / arm64 / Xcode 26.6 运行 `scripts/verify-app.sh --require-clean-source`；Release App 与 DICOM XPC 的结构、锁定依赖、隐私、资源、生产 entitlement allow-list 和逐层 ad-hoc 签名通过。App content-manifest、主 executable、Helper executable SHA-256 分别为 `44db9095eb4fad4225456556755fa147aef6dfcaf2e7d75578a0ec2afd5f7288`、`d77672580e8a96875b5fffef27717b4e4a89d950052101510d47b735c5b227ac`、`223dda25e74b91a7a548482ae4349d292c1ee66b8b95dc62945500abfeaf53d0`。
- **安装后人工验证**：正常退出旧 App 并保留时间戳备份后，把同一 verified bundle 安装到当前用户 Applications；安装副本严格验签，主程序与 Helper executable 和构建产物一致，并从正式测试路径成功启动。一次仓库外、无内容的人工烟测确认“在访达中显示”、备份忙碌态、恢复点发布和恢复入口可用；没有记录真实 repository 的路径、恢复点数量、大小或内容。
- **仍未执行**：本轮没有重跑完整隔离 `run-acceptance.sh`、手动恢复、第三方网盘传播、macOS 14/15 独立机器、Developer ID/notarization 或键盘/VoiceOver；整体仍为 `pendingManual`。

## [2026-08-20] integration/backup | rebase 最新 main 并重新闭环源码门禁

- **基线整合**：加密目录备份与整库恢复分支 rebase 到 `origin/main@17b2fb0`，保留 main 删除 LAN feasibility host、启动/打包性能收口和当前 production entitlement 精确列表，同时新增持久化 app-scope 目录 bookmark 权限。
- **完整自动化**：正常 macOS 权限下 `scripts/test.sh` 通过 989 tests / 94 suites，独立真实 Socket/RSS 门禁 1/1 通过；备份专项 116 tests / 14 suites 通过。`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化校验和 `git diff --check` 通过。
- **候选边界**：rebase 后 clean-source App/XPC 候选将在本证据提交后重新构建和验证。真实 Powerbox 目录选择、安装后手动备份/恢复、第三方网盘传播、Developer ID/notarization、macOS 14/15 独立机器、干净 Mac 恢复和键盘/VoiceOver 仍未执行。

## [2026-08-19] acceptance | 完成优化候选的本机构建、安装与启动验证

- **候选绑定**：从 clean revision `10d58e6ee4949c85e297e4cc8b5757eeecd481ea` 在 macOS 26.6.1 / arm64 / Xcode 26.6 / Swift 6.3.3 运行 `scripts/verify-app.sh --require-clean-source`；0.5.0 (5) Release App 与 DICOM XPC Helper 的结构、依赖锁、隐私、生产身份、arm64、entitlement allow-list、资源和逐层 ad-hoc 签名门禁通过。App content-manifest、App executable、Helper executable SHA-256 分别为 `4745f6955d048f39b70e92fff8dd60f5f64263f4e089a2c4a8423f02b5c04c28`、`c5c685976b15c9dbd4061df629071e3acf06660b2d3371100efa9baa705909ea`、`9888b87d5bfe9a6a86db90c30c57d571bb1635d42fd503141773e6e262bcb195`。
- **XPC 与隔离安装**：同一 verified bundle 通过 `scripts/verify-dicom-xpc.sh --use-verified-app` 的签名、raw round-trip、确定性 crash/hang containment、恢复、日志 canary 和零运行时 socket 门禁。`scripts/run-acceptance.sh` 随后以随机隔离身份完成 4 个合成成员、96 条记录/附件、重启、强退、真实 receiver、流式/中断上传、拒绝路径、DICOM 3 Series / 216 viewable objects / 648 rendered slices、资源预算、明文持久化、0 canary 命中和清理；`automatedOverall=passed`。
- **正式路径安装**：先正常退出旧 App 并保留可恢复的时间戳备份，再安装报告绑定的正式 `com.kinlogue.mac` bundle。安装副本与构建产物逐字节一致，strict deep codesign、App/Helper executable 哈希和 0.5.0 (5) 元数据复核通过，并由 Launch Services 成功启动；没有移动、删除或重建用户 Vault。
- **边界**：整体状态仍为 `pendingManual`。本次没有执行真实私有 OCR、100 MiB/200 页 PDF 交互、真实 `NSSavePanel`/外置卷、更多 MRI 厂商、iOS/Android 真机、macOS 14/15 独立机器、键盘/VoiceOver，也没有执行 Developer ID 签名或 notarization；本机 ad-hoc 结果不等价于公共发布通过。

## [2026-08-19] perf(review,pdf) | 单快照复核与按需 PDF 页元数据

- **复核一致性**：新增 Core `ImportDraftReviewSnapshot` 与 `ImportDraftStore.loadReviewSnapshot` 目的型契约；`VaultImportDraftStore` 在一次有界 `readSnapshot` 中读取同一 catalog generation 的 draft、OCR document、成员和首个原件，并复用既有 canonical decode 与来源校验。`LiveAppService` 不再先读原件快照、再从另一 generation 加载 OCR，也不接触 Vault JSON；多来源仍严格使用 `sources.first`。
- **PDF 打开成本**：`OriginalDocumentPDFSession` 从全部页 metadata 数组缩为 `id + pageCount`。renderer open 不再访问任一 `PDFPage`；所选页 metadata 在 actor 内按需校验并最多缓存 200 项，render 继续独立重验页面/media box 与 4,000 px/5 倍上限。SwiftUI 以 `(sessionID, pageIndex)` 管理 loading/loaded/failed，翻页、取消或 release 后的旧结果不能覆盖当前页。
- **测量与回归**：两页 PDF 测试证明 open 的 page access 为 0、首次 metadata 为 1、重复请求命中 cache；真实 Vault 测量证明完整 review snapshot 只触发 1 次 manifest resolution，多来源集成证明返回首个原件。定向回归通过 6 tests / 1 suite 与 45 tests / 2 suites；最终 `scripts/test.sh --quiet` 通过 869 tests / 80 suites及独立真实 Socket/RSS 门禁 1/1，`scripts/lint.sh`、`scripts/verify-docs.sh`、`scripts/privacy-guard.sh` 和 `git diff --check` 通过。
- **运行器抖动记录**：最终绿灯前两次全局并发主套件各出现一项无关随机失败：watchdog 终止耗时 `5.043 s` 略超 `< 5.0 s` 断言、installed-LAN 探针返回 `.dependencyFailure`；两项均未修改代码并分别隔离重跑通过，随后完整门禁单次全绿。未重新执行 clean-source bundle、安装验收、真实长 PDF、macOS 14/15 独立机器或键盘/VoiceOver 人工矩阵。
## [2026-08-20] feat/backup | 实现用户选择目录的加密备份、保留与整库恢复

- **生产链路**：新增 Foundation-only backup contract、无 Keychain recovery-root/device authorization、HPKE + AES-GCM 分块容器、exact Vault + durable LAN inbox 一致 checkpoint、排他目录发布与正式 inode full-reader witness；App 在用户选择父目录下只管理 `.kinlogue-backup-v1` 专用子目录，不接网盘 API 或互联网客户端。
- **用户控制**：设置页新增自动备份开关、默认 5 且范围 2–30 的保留数量、立即备份和恢复入口。自动备份默认关闭，只在 App 运行期间按 5 分钟静默、24 小时最小间隔和启动/唤醒补偿工作；本地验证状态与“网盘同步状态未知”分开显示。
- **恢复与生命周期**：`.kinloguebackup` 可在没有原设备身份和本机配置时仅凭恢复码解密；先在 app-private 同卷 staging strict 验证，再经 destructive fence、lifecycle revoke 和 durable whole-root receipt 明确替换，成功后要求重启。启动先收敛 preflight/activation receipt，外部恢复点不随本机删除或恢复而删除。
- **review 与资源收口**：修复自动开关未启动 timer、LAN-only 变更未触发备份、启动失败后 Retry 绕过恢复协调、dotted entitlement key 未转义，以及恢复与 LAN strict validation 的文件描述符无界增长；durable witnesses 同时按有效仓库点裁剪并设 512 上限。
- **自动化证据**：当前主套件 988 tests / 95 suites 通过；独立真实 Socket/RSS 门禁 1/1 通过。U0 ad-hoc probe 的 20,000 对象/精确 2 GiB 完整写读通过，256 KiB 分块下峰值文件描述符 6、RSS 增量约 2.3 MiB。lint、隐私、本地化、文档检查与 diff 门禁通过。
- **clean-source 与安装验收**：revision `c022007807209f50571b67a92082b3c6c8e73699` 通过 `scripts/verify-app.sh --require-clean-source` 和 `scripts/run-acceptance.sh`。arm64 ad-hoc App/XPC、strict codesign、生产 entitlement、依赖锁、隐私和本地化通过；合成安装流程覆盖启动、重启、强制终止、4 位成员/96 条记录/96 个附件、LAN 拒绝与恢复，以及 216 个 DICOM 实例/648 帧渲染。bundle content manifest/App/Helper executable SHA-256 分别为 `aae1f7f80e4b5ecca463bbe8e3b902f57401c6607c7fcb1b20d8e306bc227d29`、`5d9888e2c003366abc00bd5cfe0700fea931f7282b6b55fa1c00990580acef05`、`490ea0d9beb2acd01fb8f40a559216eaac361f43d001348e79651c6a049dbd89`。
- **本地安装与边界**：已验签 production App 安装到当前用户级 Applications；原 App 保留为可恢复的 pre-`c022007` 副本。安装后 executable 与构建产物哈希一致，普通启动进程来自正确 bundle；没有读取或记录窗口中的医疗内容。通用安装验收仍未驱动真实 Powerbox/手动备份/恢复，因此真实阿里云盘/百度网盘/File Provider/外置盘/NAS、Developer ID/provisioned/notarization、macOS 14/15、干净 Mac 恢复和键盘/VoiceOver 保持未执行。

## [2026-08-13] ideation | 调研云端备份、iCloud 与多设备同步方向

- **仓库事实**：核对当前本机明文 Vault、独立 LAN inbox、固定 revision 原件导出、删除/生命周期、production entitlement allow-list 及 README/PRIVACY 承诺；确认现有 ZIP 不是备份，完整恢复面同时涉及 catalog、对象图、OCR/草稿/DICOM 和可选 inbox 状态。
- **外部约束**：以 Apple 官方资料复核 CloudKit/iCloud Documents、加密字段与 asset、Keychain reset 丢失语义、KVS 限制、security-scoped bookmark 和 Time Machine；App Review Guideline 5.1.3(ii) 当前禁止健康管理 App 把个人健康信息存入 iCloud，因此 iCloud 仅保留为需 Apple 明确澄清的政策研究项，不列为 Mac App Store 生产推荐。
- **候选结论**：从 43 个原始候选去重、组合并做独立依据核验后，保留 7 个方向。首选是 provider-neutral、客户端认证加密、版本化且经过隔离恢复验证的 checkpoint；第一目的地为用户授权的非 iCloud 目录，后续可接 S3/B2/R2。换机/第二台 Mac 先走恢复与显式接管，真正多主同步另立冲突、设备身份与删除墓碑项目。
- **知识产物**：新增 [`ideation/2026-08-13-cloud-backup-and-sync-ideation.html`](ideation/2026-08-13-cloud-backup-and-sync-ideation.html) 并从索引可达。该文档是调研和候选方向，不修改当前产品边界、隐私承诺、entitlement、代码、测试或验收状态。
- **验证边界**：本次只新增/更新文档；外部事实按 2026-08-13 可见官方页面复核。`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/lint.sh`、HTML section/metadata 结构审计和 `git diff --check` 通过；未运行 Swift 测试、bundle/XPC、安装或人工设备矩阵。

## [2026-08-12] perf(storage,lan) | 一致性批量读取与 dirty-generation 刷新

- **Vault 读取**：新增强制一致性语义的 `VaultStore.readSnapshot`；`PlaintextVault` 在一个 root-scoped mutation lease 内解析一次 manifest、同步选择 reference 并按同一代 metadata 校验对象，单次限制为 32 objects / 128 MiB，返回前释放 lease。导入 source/document、精确去重、报告原件、复核页首个原件、多来源重新 OCR 和 DICOM index 已迁移到该 API；协议没有保留逐次 `loadCatalog + readObject` 的生产兼容回退。
- **LAN 刷新**：新增 content-free `LANInboxChangeMonitor`，观察 inbox/blobs/partials/derived 目录与 active partial 文件增长；Mac 保留一秒 receiver liveness 心跳，只在 generation 变化时请求权威 store projection，stop 时仍无条件最终刷新。dirty event 只提示刷新，不绕过 mutation lease、root binding、manifest/引用和物理 accounting 校验；whole-Vault revoke 在删除前停止观察器，既有 UI generation fence 继续拒绝迟到结果。
- **测量与验证**：固定合成工作流的冗余 I/O 指标从 `11` 降到 `3`：Vault manifest resolutions `6 → 3`，LAN 五次空闲心跳的 full refresh `5 → 0`，所有 correctness gates 通过。变基最新 `origin/main@9b26927` 后，正常 macOS 权限下 `scripts/test.sh --quiet` 通过 908 tests / 85 suites及独立真实 Socket/RSS 门禁 1/1；`scripts/lint.sh`、`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、优化 measurement 与 `git diff --check` 通过。正式 bundle、安装验收、macOS 14/15、真实手机/MRI/OCR 和键盘/VoiceOver 人工矩阵未重新执行。

## [2026-08-12] refactor(all) | 未发布候选的行为保持简化

- **代码整理**：合并 LAN 上传与派生附件 sink 重复的 descriptor 校验、溢出检查、分块写入和错误映射，同时保留两条链路不同的 `sync`/`EINTR` 语义；统一 PDF/Vision OCR 的归一化矩形投影；让记录搜索复用单个日期格式器并避免逐记录临时数组；DICOM 默认 Series 从二次排序改为单次最优值扫描。删除未使用的 `RecordSearchResult`/`searchResults`、无来源原件读取入口、空 module sentinel 及对应边界测试，没有改变用户流程、存储格式、网络协议或隐私承诺。
- **兼容边界**：没有删除 catalog v1/v2 migration、旧加密标记拒绝、旧锁名、revision wire 缺省值、DICOM policy-v1 读取或已退役 CLI 拒绝门禁。仓库日志、回滚验收和持久化格式表明它们仍承担真实资料与安全边界，并非仅为未发布 App 保留的源码兼容层。成员/来源单附件便利入口仍有迁移器与合成验收调用，暂不为了减少行数改写所有权语义。
- **验证**：LAN sink 定向回归 40 tests、App/service 88 tests、DICOM Viewer 19 tests、记录查询 8 tests、OCR 矩形 2 tests 均通过；合并本次优化测试并变基最新 main 后，正常 macOS 权限下 `scripts/test.sh --quiet` 通过完整主套件 908 tests / 85 suites及独立真实 Socket/RSS 门禁 1/1。`swift build --disable-sandbox`、`scripts/lint.sh`、`scripts/verify-docs.sh`、`scripts/privacy-guard.sh` 和 `git diff --check` 通过。正式 bundle、安装验收、macOS 14/15、真实手机/MRI/OCR 与键盘/VoiceOver 人工矩阵未因本次代码整理重新执行。

## [2026-08-12] integration | 合并最新 main 并保留有效生命周期回归

- **合并范围**：把 `origin/main@fe4095e` 合入 `codex/fix-review-lifecycle-and-concurrency`。由于 #17 采用 squash，Git 无法识别双方共享的 `3badbfa` 祖先；冲突解析以内容等同于 `origin/main` 的 `de751bf` 作为真实三方基线，避免把已吸收的改动误判成分支独有实现。
- **冲突处理**：record revision CAS、DICOM terminal task、whole-Vault Viewer fence、LAN lifecycle generation、独立 `LiveOriginalExportService`、session-wide deadline cleanup 和单一 release-facts verifier 均采用主分支更新后的契约；恢复自动合并误删的主分支测试与架构文档。保留并迁移兼容的 DICOM catalog projection、staging capacity 和 staged-report generation-exhaustion 回归；删除一项与新终态语义冲突的旧 startup-cancel 断言。
- **验证**：正常 macOS 权限下合并相关定向集合通过 188 tests / 13 suites，保留的 DICOM/Vault 集合通过 35 tests / 2 suites；`scripts/test.sh --quiet` 通过 903 tests / 80 suites及独立真实 Socket/RSS 门禁 1/1。`swift build --disable-sandbox`、`scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/verify-docs.sh` 和 `git diff --check` 通过。
- **未执行**：本次是源码与测试合并，没有重新运行 clean-source bundle/XPC、安装验收、macOS 14/15、真实手机/MRI/OCR 或键盘/VoiceOver 人工矩阵；最近完整安装证据仍绑定 `37bcfca`。

## [2026-08-12] integration | 合并 main 的原件导出服务拆分

- **合并范围**：把最新 `origin/main` 的 `c5d003b` 合入 `codex/final-review-fixes`，同时保留当前分支的 draft/record revision 防并发覆盖、LAN/DICOM lifecycle 收口、异步渲染隔离和时间线选中描边修正。
- **冲突处理**：`LiveOriginalExportService` 与取消门采用 main 的独立文件结构，并把当前分支的 `@unchecked Sendable` 安全依据迁到新文件；`docs/index.md` 保留当前分支 900 tests / 80 suites的最新自动化事实并补上新生产实现链接；追加式日志按日期保留双方既有条目。
- **验证**：`swift test --disable-sandbox --filter OriginalExport` 通过 10 tests / 3 suites；`scripts/test.sh --quiet` 通过 900 tests / 80 suites及独立真实 Socket/RSS 门禁 1/1；`scripts/verify-docs.sh`、`scripts/lint.sh`、`scripts/privacy-guard.sh` 与 staged `git diff --check` 通过。此次结构性合并未新增产品行为或测试；clean-source bundle、安装验收与 macOS 14/15/人工设备矩阵未重新执行。

## [2026-08-12] refactor(app) | 独立原件导出生产服务

- **代码整理**：把 `LiveOriginalExportService` 及其取消门从 1,365 行的 `AppServices.swift` 原样拆到独立文件，保留 `LiveAppServiceEnvironment` 的生产组装、App-owned 契约、`LibraryLifecycleCoordinator` fence、Platform 错误/进度映射和 commit 后拒绝取消语义；本次不改变产品行为、存储格式、用户文案或依赖方向。
- **知识同步**：更新架构页的 App 服务所有权，并从索引中的原件导出状态直接链接到生产适配实现；没有改写既有产品能力或验收状态。
- **验证**：导出 model 与生命周期聚焦回归通过 9 tests / 2 suites；正常 macOS 权限环境下 `scripts/test.sh --quiet` 通过 828 tests / 79 suites及 1 项独立真实 Socket/RSS 门禁。受限外层沙箱中的首次完整运行因禁止 socket bind 及临时文件行为差异失败，不计作产品回归；相同源码脱离该限制后全部通过。`scripts/lint.sh`、`scripts/privacy-guard.sh` 与 `git diff --check` 通过。
- **本机构建**：从干净 revision `f525f0c` 运行 `scripts/build-app.sh`，Swift Release 主程序与 embedded DICOM XPC 均构建成功；`dist/Kinlogue.app` 为 0.5.0 / build 5，两个 executable 均为 arm64，严格 ad-hoc 验签通过。主 executable SHA-256 为 `b293c528c39874974e409197399994d7458d7c0d6062fba6036990c068dcfd44`，Helper executable SHA-256 为 `0bc3c85d98f7ebd836c6e74d6353cab49f04be79e317b2a2c245f18eb7a371d0`。首次受限沙箱构建仅因锁定依赖无法访问 GitHub 而停止，正常 Xcode/网络环境下使用相同锁定版本完成。
- **仍待人工验证**：本次为纯结构整理；普通 release App 已构建，但未重新执行完整 `scripts/verify-app.sh --require-clean-source`、安装后保存面板、macOS 14/15、外置卷或键盘/VoiceOver 矩阵，这些发布门禁保持既有未验证状态。

## [2026-08-11] integration | 合并 main 的 CI 超时与 Codemagic 门禁

- **合并**：把 `origin/main` 的 `324a49b` 合入当前维护分支，保留 GitHub/Codemagic 30 分钟 job 上限、主测试 20 分钟与隔离 Socket/RSS 3 分钟 deadline、固定 SHA-256 的 Codemagic `rg` 以及 Xcode Metal 组件安装；同时保留当前分支更新后的验收 revision、文档漂移门禁和时间线选中描边修正。
- **冲突处理**：`docs/index.md` 与 `docs/testing-and-release.md` 以当前 0.5.0/build 5、clean revision `37bcfca` 的验收事实为准，并纳入 main 已远端验证的 Codemagic 状态；没有把历史 791 项测试或旧候选哈希重新写成当前事实。
- **验证**：CI/deadline 聚焦测试与 `scripts/verify-docs.sh` 通过；合并后 `scripts/test.sh --quiet` 通过 797 tests / 75 suites，真实 Socket/RSS 隔离门禁 1/1 通过，6 项 Vision 保持外层沙箱已知限制。clean-source bundle、安装验收和人工设备矩阵未因本次源码合并自动重跑。

## [2026-08-11] chore(pr) | 合并最新 main 并解决 PR 文档冲突

- **合并范围**：把 `main` 的 GitHub/Codemagic 20/3/30 分钟超时治理、固定 CI-only `rg` 和相关契约测试合入导出分支。三处冲突都位于知识文档；解决时同时保留导出能力/验证证据和 `main` 的 CI 现状，没有改变产品逻辑。
- **验证**：`GitHubActionsWorkflowTests|TestScriptSafetyTests` 聚焦回归通过 11 tests / 2 suites；`scripts/test.sh --quiet` 通过 828 tests / 79 suites 和 1 项独立真实 Socket/RSS 门禁。合并后的 lint、privacy、clean-source bundle 与远程 CI 由后续门禁继续确认。

## [2026-08-11] fix(export) | 修复保存面板导出成功后误报中断

- **根因与修复**：导出器已完成目标 ZIP 文件同步、完整 payload 校验、Vault revision 复核和同卷原子发布后，仍要求打开并同步目标父目录；macOS App Sandbox 的 `NSSavePanel` 文件级 Powerbox 授权不保证父目录可打开，因而可能在有效 ZIP 已写入后把目录权限错误映射成“发布状态不确定”。现在只在上述提交完成后，把 `EACCES`、`EPERM` 及文件系统不支持目录同步的错误视为 best-effort 结果；`EIO` 等真实目录 I/O 故障仍报告发布状态不确定，提交前的写入、校验、取消与清理边界不变。
- **回归与审查**：新增注入式回归覆盖权限错误和不支持错误成功返回，并保留 `EIO` 已发布但状态不确定的测试。13 个真实 Vault 导出集成测试逐项通过；`scripts/lint.sh`、`scripts/privacy-guard.sh`、`git diff --check` 通过，`scripts/test.sh` 通过 825 tests / 79 suites，6 项 Vision 保持外层沙箱已知限制。独立正确性、安全性、可靠性、测试、项目规范和 Swift 审查未发现实现阻断项；审查补齐了全部允许错误码测试和本条知识日志。
- **本机构建与安装**：从当前 dirty source 重建并 strict ad-hoc 验签 `dist/Kinlogue.app`；App 与 embedded DICOM XPC 均为 arm64，bundle 为 0.5.0 / build 5，主 executable SHA-256 为 `407a08e71298809286e916d27b8a01d0b89002c7c60189b1fcc9c787ebf26790`。安装副本与构建产物哈希一致，并已从用户 Applications 路径启动；替换前的 App 另存为带时间戳的可恢复备份，没有移动或重建资料库。
- **仍待执行**：自动化使用注入错误验证分类，不能替代已安装 sandbox App 的真实 Powerbox 行为；新文件与覆盖已有 ZIP 两种 `NSSavePanel` 路径仍需人工复测。父目录同步不可用时，ZIP 本身已经同步、验证和原子发布，但目录项无法获得额外的崩溃耐久性强化。dirty-source 本机构建不替代 clean-source `scripts/verify-app.sh`、macOS 14/15 独立机器、外置卷和完整键盘/VoiceOver 门禁。

## [2026-08-10] feat(export) | 实现按成员与日期导出全部已确认原件

- **交付能力**：设置 → 数据管理新增“导出原始文件…”；风险说明先于系统保存面板，随后把已确认报告与已确认 DICOM 的原始字节整理成一个明文 ZIP。目录只使用可见成员名称、规范日期、稳定序号和安全化展示名；包含已归档成员的已确认报告、未注明日期报告和重复来源行，不包含 OCR、转录、备注、草稿、LAN inbox、catalog、摘要、恢复资料或内部标识。导出副本用于医生交接与打印，不是备份，删除资料库不会删除它。
- **一致性与发布安全**：Core 冻结 eligibility、顺序和跨平台安全路径；Platform 从同一 Vault revision 建立快照，以 64 KiB descriptor-relative `pread` 流式写入 stored ZIP，并逐项校验源长度/SHA 和完整 ZIP payload。取消或 revision 变化会清理不透明的非 `.zip` 工作文件；成功只在同卷原子 move/replace、文件 sync 与父目录 sync 后返回，提交后的 sync 不确定性单独报告。App 生命周期会取消导出并等待清理后再允许整库删除；进度在主线程按 10% 边界合并，不随条目数量堆积任务。
- **依赖与上限证据**：根 Package 显式精确锁定 ZIPFoundation `0.9.20`，包图门禁和源码安全测试同步更新；主 App 同步打包该依赖的 SwiftPM privacy manifest。导出计划总 entry 上限固定为 30,000。当前 Mac 的单 Archive characterization：20,000 entries 为 `1.287 s`、峰值 RSS 增量 `6,193,152 bytes`、取消 `1 ms`、最大 heartbeat gap `15 ms`；30,000-entry manifest-limit 为 `2.745 s`、峰值 RSS 增量 `7,929,856 bytes`、取消 `1 ms`、heartbeat gap `15 ms`，完整性与清理均通过。这些数值只适用于当前机器。
- **自动验证**：当前清单为 824 tests / 79 suites；导出聚焦回归、30,000-entry 写入探针、`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移、包图前置验证和 `git diff --check` 通过。默认 8 路完整运行中 823/824 通过，1 项既有 installed-LAN 探针在全局并发下出现 `.dependencyFailure`，其单独运行和所属套件串行运行均通过；6 项 Vision 保持外层沙箱已知限制。dirty-source `scripts/build-app.sh` 成功构建 arm64 App 与 embedded DICOM XPC，并验证主 App 包含 ZIPFoundation 隐私清单。代码审查确认并修复取消清理竞态、英文单复数、Dynamic Type 滚动、装饰图标 VoiceOver、导出焦点恢复、目标目录换位防护和上限级性能问题。
- **仍待执行**：`scripts/verify-app.sh --require-clean-source` 因当前实现尚未提交而未运行；安装后真实 `NSSavePanel` security scope、外置/FAT 卷、磁盘空间不足、强制终止 residue、超过 4 GiB/ZIP64、大原件、手机/电脑独立解压、PDF/图片打开与打印、中英文窄窗口、键盘/VoiceOver 和 macOS 14/15 独立机器矩阵仍需人工或安装验收。

## [2026-08-10] brainstorm | 冻结全部原始文件导出范围

- **需求决定**：新增 requirements-only 计划，定义“设置 → 数据管理”中的医生交接型导出：一个明文 ZIP 覆盖全部已确认报告和 DICOM 原件，按家庭成员与用户确认日期组织；报告采用日期前缀的扁平文件，DICOM 保留检查子目录，不生成 OCR、摘要或可恢复资料库数据。
- **范围与隐私**：首版只包含已确认内容，但仍覆盖已归档成员及日期不明的已确认报告；待确认报告、待确认 DICOM、LAN inbox、密码保护、云端发送、备份和恢复均不在范围。导出前必须提示明文敏感资料风险；原件导出不承诺重建当前模型未持久化的 DICOM 源目录和文件名。
- **事实复核**：核对设置页、catalog v3、报告来源、DICOM study、PlaintextVault、隐私说明和 DICOM 验收边界。独立复核确认当前设置页只有整库删除、当前文档不提供备份/恢复、DICOM 自动导出仍为 unsupported；同时纠正“所有待确认草稿都没有成员/日期”的过度概括，部分报告草稿可能已暂存这些选择，因此排除它们是确认门产品规则而非 schema 缺失推断。
- **文档同步**：新增 [`plans/2026-08-10-001-feat-export-all-original-files-plan.md`](plans/2026-08-10-001-feat-export-all-original-files-plan.md) 并更新 [`index.md`](index.md)。当前能力文档保持不变，避免把规划中的导出写成已实现功能。
- **验证边界**：本次只修改 Markdown 需求计划、索引和知识日志，未修改 Swift、脚本、本地化资源或打包配置；`scripts/lint.sh`（包含当前源码 debug build）、`scripts/privacy-guard.sh` 和 `git diff --check` 通过，未运行产品测试或安装验收。实施后的 ZIP 兼容性、资源上限、取消/失败清理、手机/电脑解压、打印和可访问性门禁均未执行。
## [2026-08-10] fix(ci) | PR 慢 runner 将主 deadline 校准为 20 分钟

- **PR 远端证据**：PR #14 的 Codemagic Build `6a79d64ba61daef93e703080` 在 M2/Xcode 26.6 上执行完整测试 15 分 24 秒；截止前仍持续输出通过项，`PlaintextVaultCatalogMigrationTests` 单套件耗时 66 秒，没有测试断言失败。
- **watchdog 结果**：15 分钟时打印 `KLT_COMMAND_TIMEOUT seconds=900`，进程树仍为 `swift-package → swiftpm-testing`，步骤返回 124；Build 总计 17 分 15 秒结束，未占满 30/90 分钟。
- **校准与验证**：GitHub/Codemagic 主套件 deadline 从 15 分钟调到 20 分钟；隔离 3 分钟、job 30 分钟不变。配置契约测试先按预期失败，修改后通过 8 tests / 1 suite；`scripts/test.sh --quiet` 通过 791 tests / 75 suites及独立真实 Socket/RSS 门禁，6 项 Vision 保持既有外层沙箱 known issues；lint、隐私门禁和 `git diff --check` 通过。新提交 `ab8e840` 的 Codemagic Build `6a79ddb8a61daef93e70471f` 于 13 分 52 秒完成，完整测试 3 分 25 秒，全部五项门禁通过并向 PR 回传成功。

## [2026-08-10] test(ci) | 补强非法 deadline 的行为回归

- **整理**：`TestScriptSafetyTests` 原先名为“非法时限不会启动命令”的用例只检查了 watchdog 脚本文本；现改为真实传入非法时限，并用随机临时 marker 证明后续命令没有被启动，同时保留进程树 TERM/KILL 与超时退出码 124 的结构契约。
- **验证**：`scripts/test.sh --quiet` 通过 791 tests / 75 suites及独立真实 Socket/RSS 门禁，6 项 Vision 保持既有外层沙箱 known issues；`scripts/lint.sh`、`scripts/privacy-guard.sh` 与 `git diff --check` 通过。该整理只加强测试证据，不改变生产 watchdog、CI 时限或发布能力。

## [2026-08-10] verify(ci) | 15 分钟校准后的 Codemagic 全绿

- **远端结果**：提交 `70bbe9b` 的 Codemagic Build `6a79c29d6172f3008f4ae344` 在 M2/Xcode 26.6 上于 11 分 11 秒完成，GitHub Check 回传 `success`；lint、隐私、完整测试、Metal 组件、clean-source bundle 与真实 DICOM XPC 边界全部通过。
- **分步耗时**：完整测试 2 分 19 秒、Metal 组件安装/检查 13 秒、bundle 构建/验签 5 分 17 秒、真实 XPC 门禁 1 分 49 秒。主测试没有触发 15 分钟 deadline，隔离 3 分钟和 job 30 分钟上限也未触发。
- **结论边界**：当前配置已同时证明快 runner 可全绿、慢 runner 会在命令级 deadline 而非 90 分钟处退出，以及 15 分钟校准后可全绿。该结果仍不等价于 GitHub Actions 计费额度恢复或 macOS 14/15、真实设备和人工验收完成。

## [2026-08-10] fix(ci) | 校准主测试 deadline 以容纳 M2 性能抖动

- **远端证据**：相同代码、仅文档变化的 Codemagic Build `6a79bd843649b26e4d3d118b` 在慢 runner 上让多项重型套件从约 20 秒拉长到约 100 秒；10 分钟时测试仍持续输出通过项且接近尾部，并非 fixture 僵死。
- **watchdog 结果**：命令级截止准确输出 `KLT_COMMAND_TIMEOUT seconds=600`，进程树只剩 `swift-package → swiftpm-testing`，随后返回 124；该构建总计约 13 分钟结束，没有回到历史 90 分钟 job 占用。
- **校准**：GitHub 与 Codemagic 主套件 deadline 从 10 分钟调到 15 分钟，为 hosted M2 性能抖动保留余量；隔离 Socket/RSS 仍为 3 分钟，job 硬上限仍为 30 分钟。15 分钟配置仍待下一次远端复验，不能用前一轮绿灯替代。

## [2026-08-10] verify(ci) | Codemagic M2 五项门禁全绿

- **远端结果**：提交 `d9311a1` 的 Codemagic Build `6a79ba92331bdde99c872cfb` 在 M2/Xcode 26.6 上于 10 分 6 秒完成，并向 GitHub Check 回传 `success`。lint、隐私、完整测试、clean-source bundle 与真实 DICOM XPC 边界全部通过。
- **时限证据**：完整测试 2 分 22 秒，固定 Xcode Metal 组件安装与可见性检查 19 秒，bundle 构建/验签 4 分 1 秒，真实 XPC 门禁 1 分 36 秒；没有触发主测试 10 分钟、隔离门禁 3 分钟或 job 30 分钟上限，也没有重现旧的 90 分钟挂起。
- **验证边界**：该结果证明当前 Codemagic webhook/check 回传与 M2/Xcode 26.6 工作流正确，不代表 GitHub Actions 计费额度已经恢复，也不替代 macOS 14/15 独立机器、真实设备、私密样本或人工可访问性门禁。

## [2026-08-10] fix(ci) | 补齐 Codemagic Xcode Metal 组件

- **远端证据**：固定 ripgrep 提交 `ab34d7c` 的 Codemagic Build `6a79b7a9a8e4eb6698ce5e9a` 已通过工具安装、lint、隐私和 2 分 54 秒的完整测试步骤，确认 791 tests / 75 suites不再出现 acceptance scan 环境错误或进程挂起。
- **新阻断**：clean-source bundle 在编译 DICOM-Swift 的 `WindowingShaders.metal` 时失败；Xcode 明确报告 Metal Toolchain 缺失并退出 65。真实 DICOM XPC 边界因上游 bundle 未生成而未执行，不能写成失败或通过。
- **修复与边界**：Codemagic 在完整测试通过后调用固定 Xcode 26.6 的 `xcodebuild -downloadComponent MetalToolchain`，并通过 `-showComponent` 与 `xcrun --find metal` 核对组件。该 Apple 附加组件仅用于构建，不引入 App 运行时依赖；bundle 与 XPC 完整绿灯仍待下一次远端验证。

## [2026-08-10] fix(ci) | 补齐 Codemagic acceptance 扫描工具链

- **远端证据**：命令树 deadline 提交 `e740aa1` 的 Codemagic Build `6a79b40f3e07835e1893e2d3` 在 M2/Xcode 26.6 上于 2 分 57 秒内结束，证明此前占满 90 分钟的问题已收敛；lint 与隐私通过，全量测试运行到 791 tests / 75 suites 后失败，没有遗留到 job 上限。
- **根因**：失败集中在 `AcceptanceScanScriptTests` 的 63 个断言，全部收到 fail-closed `KLA_SCAN_ERROR`。仓库 scanner 明确要求 `rg`，而 Codemagic 官方 Xcode 26.6 镜像工具清单没有 ripgrep；不是业务测试回归或新 deadline 误杀。
- **修复与边界**：新增 Codemagic-only 工具引导脚本，下载固定的 Apple Silicon ripgrep 14.1.1 并核对 SHA-256 `24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be`，安装到忽略的 `.build/codemagic-tools` 并通过 `CM_ENV` 只提供给后续构建步骤；不执行可漂移的 Homebrew 安装，不进入 App bundle。完整 Codemagic 五项门禁仍待下一次远端运行验证。

## [2026-08-10] fix(ci) | 收敛 macOS CI 超时并接入 Codemagic

- **诊断**：GitHub Actions 在 2026-08-06 的三个旧提交上都进入全量测试并达到 90 分钟 job 上限；日志先记录 `AcceptanceScanScriptTests` 的 host-dependent 失败，随后部分已启动测试和 Swift Testing/fixture 进程没有退出。当前 HEAD 使用 Xcode 26.6、并发宽度 4 的本机完整重跑通过 791 tests / 75 suites和独立真实 socket/RSS 门禁，因此旧挂起在当前源码不可复现。
- **配置变化**：GitHub CI job 上限从 90 分钟降到 30 分钟；新增根目录 `codemagic.yaml`，使用 Personal 计划的 M2、Xcode 26.6、相同并发宽度和相同五项仓库门禁，同样设置 30 分钟上限并取消旧构建。首次 Codemagic 运行 `6a79ab85d77599dfbd50e928` 成功读取配置、拉取 commit `fee7e91` 并通过 lint/隐私，但全量测试已输出多项集成套件通过后仍不退出，复现 hosted runner 挂起。为此新增 owned-process-tree deadline：CI 主测试 10 分钟、隔离 Socket/RSS 3 分钟，超时打印不含内容的最小进程诊断、TERM/KILL 命令树并返回 124。Codemagic 配置不包含 Apple 凭据或发布步骤。
- **验证边界**：新增配置与真实 deadline 回归防止 runner、工具链、时限、命令树终止和门禁漂移。本条仍不把首次挂起写成通过；deadline 修复需要第二次 Codemagic 远端运行验证，GitHub 也要等额度恢复后复验。

## [2026-08-10] merge(main) | 合并删除安全与工具栏改进

- **合并范围**：把 `origin/main` 的 PR #11 合入报告 review 分支；生产代码、本地化资源和测试自动合并，`design-system.md`、`index.md` 与追加式 `log.md` 的冲突按并集解决。最终状态同时保留 OCR extraction version 4、附件图片只读旋转、LAN 删除命令快照、多行编辑器内容 inset、工具栏悬停说明和设置页整库删除安全边界。
- **验证**：受影响聚焦回归通过 135 tests / 12 suites；`scripts/test.sh --quiet` 通过 788 tests / 75 suites及独立真实 LAN socket/RSS 1/1，6 项 Vision 保持外层沙箱已知限制。`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源和 `git diff --check` 通过。
- **构建与剩余门禁**：合并后的 `scripts/build-app.sh` 成功生成 arm64 App 与 DICOM XPC，strict ad-hoc 验签通过。没有启动 App、读取真实资料或执行破坏性删除；真实私密样本 OCR、完整键盘/VoiceOver 和 macOS 14/15 独立机器矩阵仍待人工验收。

## [2026-08-10] feat(ocr) | 扩充常见报告字段标签

- **行为变化**：`ReportCandidateExtractor` extraction version 从 3 升到 4，在现有来源字段内补充成员、机构、科室、报告类型、标题、叙述结果、结论和日期的常见保守别名。新增覆盖包括检查时间、放射学表现/诊断、检查名称、开单科室等影像模板栏目，以及检验、超声、内镜、病理和就诊类常见标签；日期仍按既有语义种类保存，正文与结论仍逐字引用 OCR blocks，不产生医学推断。
- **proof-first 与跨层证据**：先用纯合成 blocks 增加元数据标签、9 类叙述结果标题、10 类结论标题、8 个日期标签样例和放射学表现→诊断段落边界；旧实现按预期得到空候选并失败。实现后 16 个候选抽取测试以及旧 extraction version draft 的真实 App service 刷新链路通过。
- **隐私与兼容边界**：没有读取、复制或固化真实病历内容；旧 draft 只补空候选并保留已有候选、人工修正和 review state。已经保存过空 review state 的待确认项仍需用户在新版 App 中明确选择“重新识别并覆盖”，才会用新规则替换右侧表单字段。
- **当前验证**：补齐图片旋转四状态左右回绕与 270° 尺寸交换测试后，`scripts/test.sh --quiet` 通过 780 tests / 75 suites及独立真实 socket/RSS 1/1，6 项 Vision 保持外层沙箱已知限制；当前状态页同步为该真实总数。代码审查未发现 OCR、异步删除或 SwiftUI 状态阻断项，真实私密样本 OCR 与完整键盘/VoiceOver 仍是人工门禁。
- **本地构建**：当前 dirty source 的 `scripts/build-app.sh` 构建成功，App 与 embedded DICOM XPC 均为 arm64，strict ad-hoc 验签通过；`0.5.0` / build `5` 主 executable SHA-256 为 `be074c1a154191dc5512af91ccd0c607e6c592c9ea00bf89abea1e9fbde041a1`。未强制退出或替换用户正在运行的进程；复测前需退出旧 App 并打开新 bundle。
- **提交前整理**：复用审查应用 0 项，质量审查应用 1 项（移除旋转图片外层无行为的单子视图 `ZStack`），效率审查的 4 项冷路径微优化因会增加分支或匹配器复杂度而跳过。整理后预览布局 12 tests / 1 suite、lint、隐私、本地化资源和 `git diff --check` 通过。

## [2026-08-10] feat(preview/ux) | 为附件图片增加只读旋转

- **交互变化**：统一原件预览中的 raster 图片现在在导入确认、报告详情、已确认记录编辑、报告对比、手机上传页序和独立原图窗口提供向左/向右 90° 按钮；旋转后按新的横竖方向重新计算适配与缩放尺寸，避免横向内容仍被竖向画布裁切。旋转只保存在当前视图状态，不修改附件字节、来源顺序、OCR blocks、候选字段或已归档记录；PDF 保持原始页面方向。
- **proof-first 与质量**：先增加四方向循环、90° 尺寸交换、控件接线、只读边界和中英文文案测试，旧实现因缺少旋转类型按预期编译失败；实现后跨预览、本地化与视图安全聚焦回归 51 tests / 9 suites 通过。简化检查把内嵌与独立查看器重复的旋转绘制链合并为一个私有组件；复用维度应用 1 项，质量与效率维度未发现需修改项。受当前 harness 委派约束影响，未运行独立子代理代码审查；本线程差异扫描未发现剩余阻断问题。
- **完整验证与构建**：默认并发完整套件曾通过 775 tests / 75 suites及独立真实 socket/RSS 1/1，6 项 Vision 保持外层沙箱已知限制。最终私有渲染组件抽取后的聚焦回归、`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源检查和 `git diff --check` 通过；后续默认完整重跑分别只在既有 installed-LAN 探针和 startup-preflight 测试出现一次性并发抖动，两项隔离重跑均通过，非默认并发宽度 1/4 又进入仓库已记录的跨进程长等待并被终止。当前 dirty source 的 `scripts/build-app.sh` 构建成功，App/XPC 均为 arm64 且 strict ad-hoc 验签通过；`0.5.0` / build `5` 主 executable SHA-256 为 `a8bee6fc93571e7c8d1ce4a9a66fe86e3406e6bae6d804ace5763da555c56e93`。
- **未执行门禁**：构建后检测到同一路径已有 Kinlogue 进程在运行，没有强制退出或重启用户进程，也没有操作其中的真实资料；用户需退出并重新打开后才能加载新 executable。真实鼠标点击、完整键盘/VoiceOver、clean-source 正式 bundle、安装验收和 macOS 14/15 独立机器矩阵未执行。

## [2026-08-10] fix(lan/ux) | 修复待确认项删除无响应

- **根因与修复**：删除确认弹窗的 `isPresented` setter 在关闭时先清空 `pendingDeleteItemIDs`，确认按钮启动的 MainActor 异步任务随后再从该集合读取目标，因此得到空列表、没有调用存储删除。界面现在在构造确认操作时冻结当次 item ID 集合，并把不可变值显式传给 ViewModel；弹窗 dismissal 只清展示状态，存储层仍按 item revision 重新验证并保留并发冲突时的重试语义。
- **proof-first 与验证**：新增回归先模拟弹窗关闭后清空展示状态，旧实现稳定保留待确认项并按预期失败；修复后 LAN ViewModel/视图安全聚焦回归 15 tests / 2 suites 通过。`scripts/test.sh --quiet` 通过 772 tests / 75 suites及独立真实 socket/RSS 1/1，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移和 `git diff --check` 通过。
- **范围与未执行门禁**：没有改变 inbox manifest、删除范围、LAN 协议、用户文案或已归档报告原件；没有生成或读取真实病历内容。本轮未重建 clean-source 正式 bundle，也未执行安装后的真实鼠标点击、macOS 14/15、手机设备或完整键盘/VoiceOver 矩阵。

## [2026-08-10] fix(record-edit/ux) | 修复多行输入首行裁切

- **根因与修复**：已确认记录编辑页原先依赖 SwiftUI `TextEditor` 的默认 AppKit 文本容器，首个字形紧贴可见区域上沿，输入中文时会呈现上半部分被遮盖。检查结果、检查结论和我的备注现在统一复用 [`InsetTextEditor`](../Sources/KinlogueApp/Views/RecordEditView.swift)，由原生 `NSTextView` 提供固定 8pt 内容 inset，并继续保留卡片背景、描边、双向 binding 和禁用态；字段名称与帮助文本同时显式同步到原生无障碍属性。
- **回归证据**：[`RecordEditViewLayoutTests`](../Tests/KinlogueAppTests/RecordEditViewLayoutTests.swift) 的 6 个聚焦测试在真实 `NSHostingView` 中覆盖三个多行输入的首字形顶部间距、字段级无障碍元数据、双向文本同步和启用/禁用切换；`scripts/test.sh --quiet` 共 779 个测试、75 个套件通过并保留 6 个已知 Vision 沙箱问题，lint、隐私门禁、本地化资源检查和最新 `.app` 打包均通过。
- **仍待人工验证**：中文输入法组合文本、完整 VoiceOver 操作，以及 macOS 14/15 独立机器矩阵尚未执行；自动布局断言不能替代这些手工与跨系统验收。

## [2026-08-10] fix(toolbar/ux) | 为纯图标操作增加悬停说明

- **交互修复**：主窗口工具栏的搜索、报告导入、医学影像导入、记录比较和手机接收操作现在都使用 SwiftUI 原生 `.help` 提供悬停说明；提示随 App 中英文界面解析，手机接收按钮还会在未开始时说明“从手机接收资料”，接收中改为“查看手机接收状态”。
- **proof-first 与自动化**：先强化工具栏源码契约和英文运行时本地化断言，旧实现按预期得到 5 项工具栏帮助缺失与 1 项英文翻译缺失；实现与资源生成后，两项聚焦回归各 1 test / 1 suite 通过。`scripts/test.sh --quiet` 通过 776 tests / 75 suites，独立真实 socket backpressure 回归 1/1 通过，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移和 `git diff --check` 通过。
- **本机 App 验收**：从最终源码重建并 strict ad-hoc 验签 `dist/Kinlogue.app`，主 executable SHA-256 为 `233e819e1de66e05826a6362da0b5036e82d512be1af8394e5bf48d9c2e6b9dc`；全新进程中工具栏五项操作仍公开正确的本地化可访问名称。当前 Mac UI 控制接口没有不按下按钮的纯鼠标移动动作，未能稳定截取系统延迟 tooltip，因此真实悬停截图仍作为人工验收缺口保留。
- **边界**：没有新增或变更快捷键；`⌘O`、`⌘F`、`⇧⌘C` 继续由 macOS 菜单系统公开，避免悬停文案和命令映射维护两份可能漂移的事实。

## [2026-08-09] fix(settings/ux) | 对齐设置操作列并强化删除警告色

- **视觉修复**：设置页右侧的语言选择器和“删除本机数据…”按钮先固定 intrinsic 尺寸，再共用 220pt 左对齐控制列，消除两个可见操作起始位置不一致；删除按钮继续保留 `role: .destructive`，并显式使用系统红色前景与 tint 强化不可逆操作的警告语义。
- **proof-first 与自动化**：视图源码契约先在旧实现上按预期得到 2 项失败；首版真实界面复核发现单独 tint 不足以让 macOS 默认按钮明确呈红色，且控件仍会在宽框内自行居中，因此强化契约后再次得到 2 项预期失败。最终聚焦回归通过 2 tests / 1 suite。提交前评审发现双语删除测试会在 `await` 期间保留进程级语言偏好，可能与另一并行测试套件互相干扰；相关 token 断言改为无悬挂点的同步作用域，既有精确短语服务调用测试继续覆盖拒绝路径，聚焦回归 11 tests / 1 suite 通过。`scripts/test.sh --quiet` 通过 774 tests / 75 suites，独立真实 socket backpressure 回归 1/1 通过，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移和 `git diff --check` 通过。
- **本机界面验收**：从最终源码重建并 strict ad-hoc 验签 `dist/Kinlogue.app`，主 executable SHA-256 为 `ba888aa5835c774f3e4a94554050ad3068fd4ee282660beb157551794c4e3056`；全新进程进入设置页后，两个右侧控件的可见左边缘一致，删除文字明确呈红色。没有触发删除流程或记录资料内容；完整键盘/VoiceOver 人工矩阵仍未执行。

## [2026-08-09] fix(localization/ux) | 英文整库删除使用英文确认口令

- **确认条件修订**：按用户最新要求，整库删除弹窗继续在中文界面展示并要求精确输入“彻底删除”，英文界面改为展示并要求精确输入“Permanently Delete”；这一修订取代上一条日志中“中英文确认口令保持同值”的阶段性实现。
- **自动化验证**：测试先改为英文期望并观察到 2 个断言按预期失败；更新 String Catalog 并重新生成英文资源后，删除模型与本地化聚焦回归通过 33 tests / 3 suites，其中明确验证英文界面拒绝中文口令、中文界面拒绝英文口令，错误输入不会调用销毁服务。`scripts/test.sh --quiet` 通过 774 tests / 75 suites，独立真实 socket backpressure 回归 1/1 通过，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 通过。
- **仍待执行**：尚未执行安装后 App 人工验收，以及在中英文界面分别输入展示口令的真实运行时 UI 检查；本条自动化结果不替代完整键盘/VoiceOver 门禁。

## [2026-08-09] fix(settings/ux) | 将整库删除入口移入设置

- **交互与安全边界**：整库删除入口从主界面工具栏移到“设置 → 数据管理”的“删除本机数据…”操作，降低破坏性操作的视觉显著度；后续确认继续复用既有整库删除流程，并要求用户精确输入“彻底删除”。该确认口令在中文和英文资源中保持完全一致，不随 App 显示语言翻译。
- **自动化验证**：删除、本地化与视图安全聚焦回归通过 33 tests / 4 suites；`scripts/test.sh --quiet` 通过 772 tests / 75 suites，独立真实 socket backpressure 回归 1/1 通过，6 项 Vision 保持外层沙箱已知限制。`scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 通过。
- **仍待执行**：尚未执行安装后 App 人工验收、真实运行时界面导航，以及完整键盘/VoiceOver 检查；本条自动化结果不替代这些 UI 与无障碍门禁。

## [2026-08-09] fix(dicom/ux) | 导入影像直接打开系统文件夹选择器

- **交互变化**：工具栏“导入医学影像”不再先展示只有“选择文件夹”操作的 App 弹窗，而是直接打开系统文件夹选择器；用户取消时停留在当前页面，选中目录或发生访问错误后才进入既有扫描进度、取消、失败重试和聚合结果弹窗。
- **状态边界**：文件夹选择器提升到根 App presentation，与报告导入、确认页和其他 modal 共用阻塞边界；导入 model 只负责选择后的语义阶段与工作流，不再持有 SwiftUI picker 展示状态。生命周期清理会同时关闭文件夹选择器和导入弹窗。
- **proof-first 与验证**：App model 与视图契约先因缺少根文件夹选择状态和处理入口得到预期编译失败；实现后 DICOM 导入/App/视图安全聚焦回归 17 tests / 3 suites 通过，并覆盖非取消选择器错误、重试模态时序，以及资料库生命周期结束后迟到的选择器回调不会复活导入弹窗。`scripts/test.sh --quiet` 通过 771 tests / 75 suites及独立真实 socket/RSS 1/1，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移与 `git diff --check` 通过。系统选择器的真实点击流程仍待本机人工确认。

## [2026-08-09] refactor/performance | 收口预览栅格与时间线重建热路径

- **提交前整理**：三路 `ce-simplify-code` 审查中，复用与质量维度没有发现应修改项；效率维度发现并修复 2 项。交互式 PDF 预览不再在 SwiftUI `body` 每次失效时重新生成当前页缩略图，而是按页码和渲染尺寸缓存拥有式图像；成员时间线不再先对全部已确认报告做一次随后丢弃的全局排序，改为直接筛选当前成员、一次预计算稳定顺序键并对报告与影像摘要统一排序后分组。
- **文档同步**：README、隐私说明和当前 Wiki 统一说明，只有已确认 DICOM 检查的日期、成员与对象数量等检查级摘要进入成员时间线；DICOM 原件、自由文本和像素不进入报告 OCR、搜索或比较。当前测试基线同步为 767 tests / 75 suites，历史验收记录保持不变。
- **验证**：预览、时间线与 App model 聚焦回归 44 tests / 3 suites 通过；`scripts/test.sh --quiet` 通过 767 tests / 75 suites及独立真实 socket/RSS 1/1，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移和 `git diff --check` 通过。`scripts/build-app.sh` 在正常本机 Xcode/SwiftPM 缓存环境完成 App 与 embedded Helper 的 arm64 Release 构建，`codesign --verify --deep --strict` 通过；命令沙箱内首次构建只因无权写用户缓存而停止，不计为产品构建失败。复用审查应用 0 项、质量审查应用 0 项、效率审查应用 2 项，没有跳过已确认发现。
- **仍待执行**：本条只更新当前源码证据，不改写 clean revision `90de7c2` 的既有正式 bundle/隔离安装验收；macOS 14/15 独立机器、Developer ID/notarization 和完整键盘/VoiceOver 人工矩阵仍未执行。

## [2026-08-09] fix(dicom/ux) | 首次选择立即刷新影像详情

- **根因与修复**：医学影像列表直接观察 `DICOMLibraryModel`，但右侧详情由只观察父 `AppModel` 的 `AppShellView` 读取一次子模型值；`selectedStudyID` 发布后中栏会更新，右栏却只能等待无关的父级刷新。新增窄范围 `DICOMLibraryDetailContainer` 直接观察同一影像库模型，再把当前检查和成员标签传给既有纯展示详情；不扩大整个 AppShell 的重绘范围，也不读取对象、索引或像素。
- **proof-first 与自动化**：视图级回归先因缺少观察容器得到预期编译失败；实现后在同一个离屏 `NSHostingView` 中只调用 `model.select`，不重建父视图即可从空状态切换为与已选择详情一致的渲染；另有 AppShell 源码契约锁定右栏必须接入该观察容器，不能回退为一次性 `selectedStudy` 快照。影像库、选择导航、主题和 DICOM 视图安全聚焦回归通过 17 tests / 5 suites；`scripts/test.sh --quiet` 通过 767 tests / 75 suites及独立真实 socket/RSS 1/1，6 项 Vision 保持外层沙箱已知限制。`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化漂移与 `git diff --check` 通过。
- **本机界面验收**：外层命令沙箱首次拒绝 Xcode/SwiftPM 用户缓存写入；同一 `scripts/build-app.sh` 在正常本机 Xcode 环境成功构建，App 与 embedded Helper strict ad-hoc 验签通过，arm64 主 executable SHA-256 为 `f777e4eff0c44a11e5557243ca5334439a242f71e2fd885a4783c9b50431d49a`。全新进程进入影像库时先显示空详情，第一次点击检查后首次辅助功能采集即出现详情操作，不需要切页或第二次点击；没有输出、保存或记录医疗内容。该 dirty-source 本机结果不替代 clean-source 发布、macOS 14/15 或完整键盘/VoiceOver 门禁。

## [2026-08-09] fix(dicom/ux) | 影像库选中态改为暖灰色

- **根因与修复**：医学影像库把检查 ID 直接绑定给原生 `List(selection:)`，macOS 因而绘制系统蓝色选中层并覆盖应用色板。列表现在只由 `List` 承担滚动与布局，每个检查使用全宽 plain Button 更新原选择模型；选中、悬停、前景色和 2pt 焦点描边复用侧边栏的 Selection/Primary 令牌，同时保留上下方向键相邻选择和 `.isSelected` 无障碍 trait。
- **proof-first 与验证**：新增主题源码契约先在旧实现上得到 8 项预期失败；评审又先以缺少纯导航 helper 的编译失败锁定可见顺序、首尾边界和未知 ID，再实现相邻选择。最终聚焦回归通过 12 tests / 3 suites；简化检查避免重复点击已选中卡片时再次发布同一选择，独立限定范围的正确性、SwiftUI、测试与规范复核没有留下本轮阻断问题。`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化漂移与 `git diff --check` 通过。当前 dirty source 的 `scripts/build-app.sh` 构建成功且 strict ad-hoc 签名有效，主 executable SHA-256 为 `fe71e31fecf643766758d3ee5635c30844ec7b818d1c130607477dc2431581da`。
- **本机界面验收**：新进程切换到全部影像后，点击检查卡片能够显示详情操作；对中栏选中区域做无内容像素统计时有 8,007 个 Selection 邻近像素、没有系统蓝色邻近像素，抽样背景为暖灰 `242/233/228` 与 `244/235/230`。验收后返回手机上传页；没有输出、保存或记录医疗内容。完整多行方向键、Tab 和 VoiceOver 仍待人工矩阵复核，该结果不替代 clean-source 发布门禁。

## [2026-08-09] fix(sidebar) | 扩大侧边栏整行点击区域

- **根因与修复**：侧边栏各类行分别使用内层标签、外层 padding 或复合 HStack 构造，成员与设置的部分视觉留白位于导航按钮标签作用域之外，且各行没有统一的最小命中高度。新增共享 `sidebarRowHitTarget()`，把主要导航、成员、添加成员、待确认动作和设置标签统一撑满可用行宽并设为至少 44pt 高的矩形命中区域；成员尾部管理菜单仍保持独立按钮。
- **proof-first 与自动化**：新增命中区域源码契约先在旧实现上得到 4 项预期失败，修复后 `MemberSidebarViewSourceTests` 8 tests / 1 suite 通过；同步旧主题契约后，侧边栏与主题聚焦回归 16 tests / 2 suites 通过。`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移与 `git diff --check` 通过。
- **本机界面验收**：从当前 dirty source 重建并 strict ad-hoc 签名 `dist/Kinlogue.app`，主 executable SHA-256 为 `faec2e679e3c1b504e66d5e86b8fd5296b94043665cb02ce6c11c4ebf9bdd948`。在新进程中分别点击医学影像、手机上传、成员和设置行靠右的无文字区域，四处均切换到对应页面，随后返回空白手机上传页；未输出或保存医疗内容，该结果不替代 clean-source 发布与人工键盘/VoiceOver 门禁。

## [2026-08-09] fix(sidebar) | 移除医学影像导航数量

- **变化**：侧边栏“医学影像”只保留图标和标题，不再显示已确认检查总数，避免被理解为未处理数量。待确认影像仍在“待确认”分区逐项显示，医学影像库中的检查列表、对象数量和 Viewer 均未改变。
- **验证**：新增源码回归先对旧 `confirmedDICOMStudyCount` 接线得到预期失败，移除 View 参数、数字视图和 AppShell 计数投影后通过；相关 App target 构建通过。
- **本机界面验收**：相关 15 tests / 2 suites、lint、隐私、本地化漂移与 `git diff --check` 通过；从当前 dirty source 重建并 strict ad-hoc 签名 `dist/Kinlogue.app`，主 executable SHA-256 为 `e52c957fe6ee52006097e0b38e262a32306fdaab029e57dd8f9631a93072fbcf`。退出旧进程并启动新 bundle 后，辅助功能树确认“医学影像”导航存在且不带数字；未读取或记录医疗内容，该结果不替代 clean-source 发布与人工键盘/VoiceOver 门禁。

## [2026-08-09] fix(dicom/window) | Viewer 改为可关闭、可缩放的标准 macOS 窗口

- **根因**：影像库入口把 Viewer 作为 `AppShellView` 的 sheet，确认页入口又创建嵌套 sheet；两者都依附主窗口，没有独立标题栏、交通灯或常规拖边缩放能力。截图中唯一的内容内“关闭”按钮又不可见，因而用户没有可靠关闭路径。
- **修复**：App 新增以本机 study UUID 为 typed value 的 `WindowGroup`；确认页、成员时间线和医学影像库统一通过 `openWindow(id:value:)` 打开 Viewer，默认 1120 × 820、最小 760 × 620，并允许按内容下限调整大小。Viewer 不再占用根 modal 状态；原生关闭仍触发既有播放停止、内存压力监听释放和 slice service close。
- **proof-first 与验证**：窗口源码契约先对两个旧 sheet 路由和缺失 WindowGroup 得到 7 项预期失败，修复后通过；DICOM AppModel 聚焦 4 tests / 1 suite 通过。`scripts/test.sh --quiet` 通过 761 tests / 73 suites及独立真实 socket/RSS 1/1，6 项 Vision 保持外层沙箱已知限制。
- **真实窗口验收**：从当前 dirty source 重建并 strict ad-hoc 签名 `dist/Kinlogue.app`，主 executable SHA-256 为 `d08a8a054c1dc0a2c00bf070ff1c0b75f570d391c199cda52894aa9569e19c94`。退出旧进程后启动新 bundle，辅助功能把 Viewer 识别为 `standard window`，并暴露原生关闭、最小化、缩放/全屏控件；实际执行窗口缩放后 Viewer 保持可用，点击原生关闭后返回主影像窗口。没有把身份、路径、像素或截图写入仓库；该 dirty-source 结果不替代 clean-source 发布、macOS 14/15 与人工键盘/VoiceOver 门禁。

## [2026-08-09] fix(dicom/canvas) | 修复连续播放时的主程序崩溃

- **根因证据**：与用户退出时间对应的当前 bundle 崩溃报告为 `EXC_BREAKPOINT / SIGTRAP`；触发线程是 CoreAnimation 的 `CA::CG::Queue`，栈从 `CGDataProvider` 释放回调进入 Swift executor 检查并因预期主线程而终止。另一份较早报告具有相同队列、异常和源码位置；当前 bundle UUID 与报告一致，内存摘要和 Helper 日志均不支持 OOM 或 DICOM 解码损坏假设。
- **修复**：画布不再把同步借用的像素指针交给可能延迟消费的 `CGDataProvider`，也不再声明继承 `@MainActor` 的自定义释放回调。每个新 `renderID` 在借用期内复制为拥有式 `Data/CFData` 快照，由 CoreGraphics 持有；画布只缓存当前一帧，同帧缩放、平移和曝光重绘复用该快照，切换帧或置空时释放。
- **proof-first 与评审**：新增回归先因缺少拥有式图像工厂编译失败，修复后验证原始切片缓冲区失效时 `CGImage` 仍保留原像素。三路简化审查应用 1 项复用、1 项质量和 1 项效率改进；定向人工复核未发现剩余问题。聚焦回归通过 5 tests / 1 suite，`scripts/test.sh --quiet` 通过 760 tests / 73 suites，独立真实 socket/RSS 1/1 通过；lint、隐私、本地化和 `git diff --check` 通过。
- **本机构建边界**：从当前 dirty source 重建并 strict ad-hoc 签名 `dist/Kinlogue.app`，bundle 为 0.5.0 / build 5，主 executable SHA-256 为 `b6f424d4e12cc678e81abe52d7a7f4c87893c7f36c0fee99016d90d2e39e82de`。没有把影像内容、身份信息或私有路径写入仓库；该结果不替代 clean-source 发布、macOS 14/15 和人工键盘/VoiceOver 门禁。

## [2026-08-09] feat(dicom/ux) | 统一使用下拉框选择 Series

- **交互变化**：删除宽窗口左侧 Series 列表与紧凑窗口独立 Picker 两套路由；所有窗口都在 Viewer 控制区使用原生菜单式 Picker，选项显示序列序号和切片数，并保留前后 Series 按钮作为相邻导航快捷入口。切换仍通过既有 `selectSeries` 流程停止播放、作废旧请求并加载所选 Series 首张；重复选择当前 Series 不再触发重新解码。
- **竞态与安全复核**：暂停播放中的解码只有在当前帧成功后才提交切片索引，避免序号领先画面以及恢复时跳片；新增播放中切换 Series 的回归。Viewer 状态提示改为保存语义 case、按当前语言解析；XPC 验证脚本只终止属于当前 probe host 的 Helper，检测到其他 Helper 时 fail closed。
- **proof-first 与验证**：下拉选择器源码契约先得到 5 项预期失败，再实现统一 Picker；评审修复的语义状态测试同样先因缺少接口编译失败。聚焦回归最终通过 45 tests / 4 suites；`scripts/test.sh --quiet` 在允许本机 socket 的环境通过 759 tests / 73 suites，独立真实 socket/RSS 1/1 通过；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移、shell 语法和 `git diff --check` 均通过。
- **本机构建边界**：从当前 dirty source 重建并 strict ad-hoc 签名 `dist/Kinlogue.app`，bundle 为 0.5.0 / build 5，主 executable SHA-256 为 `7670507d3367187a2e907bf5b57a9dc4e33f15d600771dc7fc059f186186f073`。本轮未读取或记录真实影像内容；该本机产物不替代 clean-source 发布、macOS 14/15 与人工键盘/VoiceOver 门禁。

## [2026-08-09] fix(dicom/playback) | 修复连续播放中的间歇中断

- **双重根因**：生产 XPC Helper 在最后一个成功请求回复后空闲 250 ms 就主动退出；真实 Viewer 的下一次请求因此触发 launchd 约 8–9 秒的重启节流，逼近客户端 10 秒超时。取消主动退出后，真实序列恢复快速推进，但仍稳定复现预取交接错误：预取任务被前台 render 接管后，后台观察器可能释放同一份内存租约，前台随后写缓存时得到 `integrityFailure`。手工重试会重新解码并取得新租约，所以表面上能够恢复。
- **修复**：成功解码后的 Helper 生命周期现在交给 macOS 管理；同步 parser 卡死时的 9 秒进程看门狗、独立 sandbox、descriptor 输入和无网络边界保持不变。Slice service 在预取被提升为 foreground 或正在消费时保留唯一所有权，后台观察器只清理真正无人接管的结果。
- **proof-first 与自动化验证**：先新增 Helper 不得正常 `_exit(0)`、跨 600 ms 空闲间隔仍须低于 2 秒返回，以及“预取进行中被前台接管”的回归；后者在修复前稳定得到 `integrityFailure`，修复后 `DICOMSliceServiceTests` 27 tests / 1 suite 与 packaging boundary 单项通过。`scripts/verify-dicom-xpc.sh` 通过真实 embedded XPC round-trip、跨空闲间隔复用、外部崩溃隔离、内部看门狗、日志 canary 和零网络 socket 门禁。默认并发的 `scripts/test.sh --quiet` 通过 756 tests / 74 suites，独立真实 socket/RSS 1/1 通过；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移和 `git diff --check` 通过。一次强制串行尝试在既有跨进程存储 fixture 的 `Process.waitUntilExit()` 处等待不结束，精确子进程已退出且无测试失败输出；该次被终止且不计为通过。
- **私密播放抽检与本机构建**：从当前 dirty source 重建并 strict ad-hoc 签名 `dist/Kinlogue.app` 后，用仅辅助功能文本、不截图的方式完成仓库外播放抽检；播放越过先前稳定失败点并完成循环，始终保持播放状态且没有错误层。bundle 为 0.5.0 / build 5，主 executable SHA-256 为 `7106aa2844e9ad3cf82cac90de76482a3632eecad875bd268828072cbc09687f`。没有记录私有影像的 Series、切片位置、姓名、日期、路径或截图；本机 dirty-source 结果不替代 clean-source 发布、macOS 14/15 与人工键盘/VoiceOver 门禁。

## [2026-08-09] fix(dicom/ux) | 展示全部 Series 并支持空间切片连续播放

- **根因**：Viewer 把按 vault-local digest 排列的第一个 Series 当默认值；该顺序只用于稳定隐私标识，没有临床或展示优先级。一次显式授权、仓库外且无内容记录的只读聚合诊断确认：多 Series 检查可能默认落到较小 Series；紧凑 Picker 又没有检查总数和前后 Series 控件，因此界面会给出导入不完整的错觉。
- **实现**：Viewer 现在按切片数降序、ordinal 升序选择默认 Series，同时保留原始 Series 排列供前后导航；界面显示检查总 Series/切片数与当前 Series 切片数。新增每秒 2/5/10/15 张的循环播放、暂停和 Command-P；每一帧等待隔离 XPC 解码完成，不堆积并发帧，暂停、手工切片/Series 切换、内存压力和关闭都会停止播放。播放 Task 不持续强持有 Viewer，取消中的解码不会误报为切片损坏。
- **医学边界**：连续播放只是按导入时固化的 geometry/Instance Number/stable-content 顺序浏览空间切片，不推断真实时间轴，不构造时间分辨动态影像，也不增加诊断、测量、MPR/MIP 或三维能力。
- **proof-first 与回归**：先复现“单张 Series 被默认选中”、缺少显式 Series/播放入口，以及“暂停正解码帧会误报失败”的 RED；修复后 DICOM Viewer 聚焦回归 16 tests / 3 suites 通过。默认并发宽度 8 的完整套件两次只在既有 installed-LAN 探针出现瞬时 `dependencyFailure`，该单项独立重跑通过；将 Swift Testing 并发宽度设为 1 后，`scripts/test.sh --quiet` 通过 755 tests / 74 suites及独立真实 socket/RSS 门禁。中文硬编码门禁、`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移与 `git diff --check` 通过。
- **本机私密 UI 抽检**：从当前 dirty-source 本机构建启动全新进程后，以无截图无内容的辅助功能文本确认聚合总数、较大 Series 默认选择、播放推进/暂停、速度菜单和前后 Series 导航可用。没有记录私有检查的精确 Series/切片数量、目录、姓名、日期、UID、自由文本、像素或截图；该结果不替代 clean-source 发布门禁、macOS 14/15 与人工键盘/VoiceOver 矩阵。

## [2026-08-09] fix(dicom) | 保留已导入影像并接入家庭时间线

- **根因**：报告草稿写入/丢弃与 LAN 归档在重建 `VaultCatalog` 时没有携带 `dicomStudies`，因此一次看似无关的 catalog 提交会静默丢失已经导入或确认的影像索引，只留下附件对象；存储层又允许调用方省略任意既有 study，未能在真实写入边界阻止该破坏性演进。
- **修复**：所有受影响的 catalog 重建路径显式保留 `dicomStudies`；`VaultCommitRequest` 新增精确的 DICOM 删除授权集合，存储层要求实际移除集合与声明完全一致，普通提交无法再静默删除 study，只有已有删除流程可以显式授权。家庭时间线现在按成员与有效日期合并已确认报告和已确认 DICOM 检查；点击影像卡片进入医学影像列表，搜索和报告比较仍只处理已确认报告。
- **proof-first 回归**：先记录普通 catalog commit 擦除 study、确认后未出现在时间线、报告草稿操作后 study 丢失的 RED，再补存储与 App 跨层实现。修复后聚焦交叉回归通过 238 tests / 27 suites；`scripts/test.sh --quiet` 通过 752 tests / 74 suites，独立真实 socket/RSS 1/1 通过，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移检查与 `git diff --check` 通过。
- **私密资料恢复抽检**：经用户明确授权，先在仓库外建立私有资料库备份并以无内容摘要确认一致性；再通过当前生产 App/XPC 重新导入私有 MRI，确认检查可在对应时间线与医学影像列表访问。App 退出后，使用类型、引用关系和当前 study 状态 guard 清理旧的未引用附件，并复核所有保留附件均可达、非 DICOM 用户资料未改变。临时恢复工具已删除，私有备份保留；没有记录精确库存、目录、姓名、UID、自由文本、像素或截图。
- **本机构建边界**：`scripts/build-app.sh` 从当前未提交源码成功重建并签名 `dist/Kinlogue.app`；App/XPC 均为 arm64、最低 macOS 14.0，bundle 为 0.5.0 / build 5，主 executable SHA-256 为 `b1ac385e4fddd65fd49a7afb10c041f246f6e948f42e148914b5faa6120d8f75`。strict 签名验证通过；`scripts/verify-app.sh` 按设计拒绝把 dirty-source 产物认作 clean-source release 证据，因此正式 clean-source 发布门禁、macOS 14/15 矩阵与人工键盘/VoiceOver 检查仍未执行。

## [2026-08-09] fix(dicom) | 兼容真实 MRI 目录中的 Sequence、厂商标识与非单堆栈 Series

- **根因**：文件夹扫描和 Part 10 envelope 均已识别对象，但 staged-byte allowlist 遇到必要标签之前的合法未定长 SQ 时直接拒绝；设备写入的数字 UID 还包含可规范化前导零，Study identity 使用受限厂商 ASCII token。越过元数据后，部分同 Series 影像具有多个有效方向或重复空间投影，旧 policy 把它们当损坏，因此 App 最初误显示“没有可导入的 DICOM”。
- **实现**：Explicit VR Little Endian allowlist 现在以最多 64 层 container 和固定 element budget 有界跳过未定长 SQ/Item/Delimiter，不读取嵌套值；数字点分 UID 去除组件前导零，受限厂商 token 只允许最长 64 字节的 ASCII 字母数字、点、横线和下划线，并且不把 raw identity 持久化。完整有效单堆栈继续 geometry projection；多方向或重复位置 Series 改用 Instance Number/稳定内容顺序并记录非空间 fallback，部分 geometry、非法向量和像素布局冲突仍 fail closed。
- **用户提示**：`invalidPart10` 不再伪装成空文件夹，改为“文件夹中包含无法读取或暂不支持的 DICOM 文件”，中英文资源同步。
- **验证与隐私**：Sequence、前导零 UID、受限厂商标识、非法字符拒绝、几何回退和错误映射均有无身份合成回归。经用户明确授权，当前源码与本地重建的生产 XPC Helper 把一个仓库外私有 MRI 目录完整导入 mode-0700 临时 Vault，全部 admitted DICOM 对象均被保留且没有非 DICOM/重复排除；临时 Vault、probe host 和结构脚本随后删除。没有把目录、文件名、患者 tag、raw UID、自由文本、像素或截图写入 Git、文档内容、日志或持久构建产物。本次 dirty-source 本机验证不替代 clean-source 发布门禁，也不代表跨厂商兼容矩阵。
- **自动化门禁**：DICOM 聚焦回归 32 tests / 4 suites 通过；`scripts/test.sh --quiet` 通过 751 tests / 74 suites，独立真实 socket/RSS 1/1 通过，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移检查与 `git diff --check` 通过。
- **本机 App 构建与启动**：`scripts/build-app.sh` 从当前未提交源码成功重建 `dist/Kinlogue.app`，App 与生产 DICOM XPC Helper 均为 arm64、最低 macOS 14.0，strict ad-hoc 签名通过；bundle 为 `com.kinlogue.mac` 0.5.0 / build 5，主 executable SHA-256 为 `c67dbdf3f453c00428a073bfcc0afee06097e3353d3ca90870137878ea9e9133`。Launch Services 已启动该工作区 bundle 的新实例，并正常终止同路径的旧后台实例；没有自动打开、截图或改写真实资料。

## [2026-08-09] feat/ux | 已确认记录编辑并排显示原件与表单

- **行为变化**：已确认记录编辑从单列表单改为与导入确认一致的左右分栏；左侧显示不可变原件并支持有序来源切换、宽度适配、60%–240% 框内缩放与双向滚动，右侧继续编辑成员、日期、原文转录和备注，两侧独立滚动，底部取消/保存操作固定可见。
- **数据边界**：编辑器复用详情页已经加载到内存的 `OriginalDocumentPayload`、加载状态与来源选择，不为打开编辑器增加一次 Vault 读取；切换来源只更新当前内存预览，不改变原件、来源顺序、OCR provenance 或保存命令。
- **并发与失败保护**：原件读取完成或失败后重新投影当前 `allRecords` 中的已保存记录，避免“切换原件的晚到结果”把刚保存的字段回写为旧值；PDF 解析和当前页栅格保存在对应预览 View state，切换 LAN 项时显式重建状态，损坏 PDF 显示不可用状态而不残留上一份原件。
- **测试与隐私**：新增双栏根结构、独立滚动、固定操作区、AppShell 原件状态接线、损坏 PDF、来源切换和保存/读取交错回归；布局测试只生成单页空白 PDF 和合成字段，不读取、记录或截图真实医疗资料。`RecordEditViewLayoutTests` 3 tests / 1 suite、`RecordDetailViewLayoutTests` 10 tests / 1 suite、`AppModelTests` 34 tests / 2 suites、`LANInboxViewSafetyTests` 6 tests / 1 suite 通过；`scripts/test.sh --quiet` 通过 744 tests / 74 suites，独立真实 socket/RSS 1/1 通过，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移检查与 `git diff --check` 通过。
- **本机 App 构建与启动**：终止路径精确匹配本工作区 bundle 的旧后台进程后，`scripts/build-app.sh` 从当前未提交源码成功重建 `dist/Kinlogue.app`；bundle 为 `com.kinlogue.mac` 0.5.0 / build 5，最低 macOS 14.0，catalog read `[1,2,3]` / write `3`，App/XPC 构建与 strict ad-hoc 签名通过，主 executable SHA-256 为 `b429b79a569586d0c479fd6117b4acca83a0fb73a572fb4eea4ba76fd512eafa`。Launch Services 启动的新进程路径与该 bundle 一致；为避免读取或截取真实医疗内容，没有自动抓取窗口或执行资料操作。
- **未执行**：dirty-source 本地构建不等同于 clean-source 正式发布门禁；窄窗口、复杂多页 PDF 响应性、键盘/VoiceOver、macOS 14/15、Developer ID/notarization 和真实附件人工复核仍待执行。

## [2026-08-09] fix/ux | 在 catalog v3 主线上增加宽度适配原件预览

- **故障根因与迁移**：先前本机构建来自 `0.3.0` / build `3` 的旧 checkout，只支持 catalog v1/v2；生产资料库已由安装版 `0.5.0` / build `5` 写为 catalog v3，因此旧构建按兼容性契约 fail closed 并显示“无法打开资料库”。本次保留原改动的 stash 备份，从最新 `origin/main` 建立分支，迁移到可读 v1/v2/v3、写 v3 的 `0.5.0` 源码；没有降级、改写或删除真实资料库。
- **行为变化**：报告详情、导入确认、报告对比和手机上传页序中的图片与 PDF 统一按原件预览区宽度等比显示；竖版内容超出可见高度时在原件区域内滚动。内嵌预览工具栏提供宽度适配基线的 60%–240% 缩放；只有宿主提供独立查看器时才显示“查看原图”并允许点击预览打开。
- **实现边界**：图片与 PDF 共用整数百分比缩放控件，避免浮点步进漂移；有序原件组件用显式的内嵌/独立展示角色决定布局，不再由“查看原图”回调是否存在间接推断。PDF 内嵌预览只栅格化当前页一次，缩放复用同一内存图像；独立查看器继续使用窗口适配和动态最大缩放，不改变资料库、OCR、DICOM、LAN 或隐私边界。
- **自动化验证**：`RecordDetailViewLayoutTests` 9/9 通过，并新增跨导入确认、报告对比、报告详情和手机上传入口的展示角色契约；`scripts/test.sh --quiet` 通过 740 tests / 74 suites，独立真实 socket/RSS 门禁 1/1 通过，6 项 Vision 保持外层沙箱已知限制；`scripts/lint.sh`、`scripts/privacy-guard.sh` 与 `git diff --check` 通过。
- **本机 App 构建与启动**：`scripts/build-app.sh` 从当前未提交源码成功生成 `dist/Kinlogue.app`；bundle 为 `com.kinlogue.mac` 0.5.0 / build 5，arm64、ad-hoc strict 签名有效，声明 catalog read `[1,2,3]` / write `3`，executable SHA-256 为 `4ff114f89fd37f20cc62bf6e67f193eba3fe9d46bfdb9bddd5c58785ec6e48f8`。旧测试进程正常退出后通过 Launch Services 启动新 bundle，目标进程保持运行；为避免读取或截取真实医疗内容，没有自动抓取窗口或执行资料操作。
- **未执行**：没有把这次 dirty-source 本地构建记作 clean-source 正式发布门禁；窄窗口、PDF 多页、键盘、VoiceOver、macOS 14/15、Developer ID/notarization 与真实设备矩阵仍待执行。

## [2026-08-08] feat(ocr) | 待确认页允许用户主动重新识别并覆盖字段

- **行为边界**：自动打开旧 draft 时仍只补空候选，不覆盖已保存候选、人工修正或显式清空。新增的“重新识别并覆盖”只在用户明确点击后运行，会从 Vault 已保存原件重新执行 PDF text layer / Vision OCR，并用新候选替换当前字段和来源说明；新识别缺失的字段同样清空。
- **保留与失败语义**：成员、手工日期和用户备注不被 OCR 改写；检测日期仅在新候选能匹配同一来源转录时保留选择。识别期间确认、稍后处理和删除不可用；失败时不保存新 document，页面编辑保持原样；晚到结果不会重新填充已关闭页面。
- **存储与并发**：App service 逐份读取 draft 的有序 Vault 原件并重新归属 OCR blocks，以当前 `needsReview` revision 调用原子 `saveReview`；stale revision、非法成员、unsupported 原件或 OCR 错误均拒绝发布，不改变人工确认门。
- **测试与隐私**：新增合成 ViewModel 和 Live App service 回归，覆盖已有/当前字段被替换、显式清空的自动重开保护、选择与备注保留、失败保护、晚到结果、真实提取器调用、来源归属和 revision 更新。聚焦测试 17 项通过；`scripts/test.sh --quiet` 在非沙箱环境通过 735 tests / 74 suites，独立真实 socket/RSS 门禁 1/1 通过；`scripts/lint.sh`、隐私门禁、本地化资源漂移检查和 `git diff --check` 通过。测试与日志没有使用真实报告内容；正式 App 重建/安装尚未执行。
- **人工边界**：真实私有样本 OCR、macOS 14/15 独立机器、键盘/VoiceOver 和公开分发门禁仍未执行。

## [2026-08-08] fix(ocr) | 补齐影像报告的检查所见、结论与报告时间候选

- **原因**：候选提取器不把半角/全角星号视为标题装饰，也不接受“报告时间”日期标签；reported results 只支持检验表格，不收集叙述型“检查所见”。因此 OCR 即使保留了对应 blocks，待确认页面仍会缺少检查所见、结论和日期候选。
- **实现**：extraction version 从 2 提升到 3；段落提取统一按装饰标题开始，在下一节、报告/审核页脚或查看操作前停止；无检验表格时把“检查所见”逐字保存为 reported results；“报告时间”映射为 report date candidate。既有表格抽取保持优先级。
- **旧草稿**：App service 会从已有 OCR blocks 刷新旧版本 draft，只补充空候选；已有候选、人工修正和 review state 不被覆盖，也不会重新执行 Vision OCR 或绕过人工确认。
- **验证**：回归只使用合成中英文文本，没有把用户截图中的身份或医疗内容写入测试、日志或文档。Core 候选提取聚焦测试 11 项与旧版本 App service 刷新测试 1 项通过；`scripts/test.sh --quiet` 通过 731 tests / 74 suites，独立真实 socket/RSS 门禁 1/1 通过；lint、隐私门禁、本地化资源漂移检查与 `git diff --check` 通过。
- **仍待人工验证**：尚未重新构建/安装正式 App，也未用用户的真实报告复核 Vision 是否稳定输出这些标题与正文 blocks；本次自动测试只证明一旦 blocks 存在，待确认候选会按新规则补齐。

## [2026-08-08] correction/fix(localization) | 移除不受 App 语言控制的系统日历覆盖层

- **再次更正**：安装版与 revision `f3a411d` 一致且偏好为 `zh-Hans`，但用户截图仍显示 `2026 Aug`、英文星期和 `July 18, 2026`。这证明 `NSDatePicker.presentsCalendarOverlay` 创建的系统私有弹层没有继承父控件显式设置的 locale/calendar；报告确认 sheet 的日期候选又从 SwiftUI `@Environment(\.locale)` 取值并回退到系统英文。问题仍是代码缺口，不是安装了旧版本。
- **实现**：`LocalizedDatePicker` 不再开启私有 overlay，改为本地化日期按钮和 App 自己管理的 SwiftUI popover；popover 内嵌 `.clockAndCalendar` `NSDatePicker`，直接使用当前 `AppLanguage` 的 locale 与 Gregorian calendar，选择后回写 binding 并关闭。`ReportDateSemantics` 新增按 `AppLanguage` 格式化入口，报告确认/编辑、时间线、详情、比较和 DICOM 列表/Viewer 的用户可见日期全部移除 SwiftUI locale 或 `.autoupdatingCurrent` 回退。
- **回归与渲染**：proof-first 测试先因缺少 `language:` 日期格式化接口而编译失败；实现后日期与编辑器布局聚焦回归 6 tests / 2 suites 通过。无资料 AppKit 离屏渲染直接显示“2026年8月”和“日一二三四五六”，不是只检查 formatter 元数据。
- **已验证**：`scripts/test.sh --quiet` 在允许本机 socket 的环境通过 729 tests / 74 suites，独立真实 Socket/RSS 门禁 1/1 通过；沙箱内首轮除预期 socket bind 拒绝外还发现并修正了手动日期按钮使编辑器键盘代理从 2 个增加到 3 个的布局测试假设。
- **仍待执行**：本条记录时 clean-source 正式 bundle、隔离安装验收、最终重装和空白/合成资料的安装后弹窗复核尚未执行；真实医疗资料不会用于自动截图或交互。

## [2026-08-08] correction/fix(localization) | 显式本地化紧凑型原生日历

- **更正**：上一条本地化修复把所选语言的 Gregorian calendar 注入 SwiftUI 环境，但当前 macOS 的紧凑型 SwiftUI `DatePicker` 弹窗仍按系统 `en_CN@calendar=iso8601` 显示英文月份和星期；已安装候选 executable 与 revision `1b59088` 的已验证构建一致，且偏好确认为 `zh-Hans`，因此问题属于实现缺口，不是装错版本。
- **实现**：新增共享 `LocalizedDatePicker` AppKit bridge，显式设置 `NSDatePicker.locale`、Gregorian calendar、时区、calendar overlay、启用态和无障碍标签，并通过 coordinator 回写 SwiftUI binding；报告 review、记录编辑、LAN 归档和 DICOM review 的五个生产日期入口全部改用该控件。生产 View 不再直接使用 SwiftUI `DatePicker`。
- **proof-first 与回归**：首轮 bridge 测试先因实现类型不存在而编译失败；补充 calendar overlay 契约后又按预期观察到默认值为 `false`，显式开启后转绿。3 项专用测试直接固定中文“八月 / 日一二三四五六”、英文系统 region 隔离、Gregorian/时区/周规则、弹窗 overlay、无障碍标签、binding 回写和五个生产入口。
- **已验证**：专用回归通过 3 tests / 1 suite；`scripts/test.sh --quiet` 在允许本机 socket 的环境通过 728 tests / 74 suites，独立真实 Socket/RSS 门禁 1/1 通过；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移检查与 `git diff --check` 通过。沙箱内首轮完整测试因 socket bind 被拒绝而失败，不计为产品结果。
- **人工边界**：安装版已确认语言偏好、主界面中文、待确认报告可打开，且新的日期输入暴露中文无障碍标签；自动化在真实医疗资料窗口中被隐私交互门禁阻止，没有继续点击、保存或输出截图。clean-source bundle、最终重装以及用户亲自展开真实日期弹窗确认中文月份/星期仍待本次提交后完成。

## [2026-08-08] fix(localization) | 让原生日历跟随 App 语言

- **原因与实现**：App 语言原先只注入 SwiftUI `locale`；macOS 紧凑型 `DatePicker` 弹窗仍从环境 `calendar` 取得月份与星期符号，导致中文界面出现 `Aug` 和英文星期缩写。`AppLocalization` 现在为所选语言生成 Gregorian calendar，保留本机时区、每周起始日与首周规则；App 根视图同时注入 locale 和 calendar，覆盖报告 review、记录编辑、LAN 归档和 DICOM review 的全部日期选择器。
- **回归**：新增测试固定简体中文的“八月 / 日一二三四五六”、英文的 `August / S M T W T F S`，并锁定 GUI 根视图必须注入所选语言日历。proof-first 首轮按预期因缺少 `AppLocalization.calendar(for:)` 编译失败，实现后本地化聚焦回归通过 21 tests / 2 suites。
- **已验证**：`scripts/test.sh --quiet` 通过 725 tests / 73 suites，独立真实 Socket/RSS 门禁 1/1 通过；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源漂移检查与 `git diff --check` 通过。正式 clean-source bundle、重新安装和日期弹窗人工复核在本条记录时仍待执行。

## [2026-08-08] fix(lan/ui) | 恢复 LAN 归档与侧边栏待确认入口

- **归档原因与修复**：真实 UI 的 DatePicker 值可能包含亚毫秒精度，而 durable archive intent 使用 `millisecondsSince1970`；写盘重读后的极小浮点差异会让严格 intent 相等校验误报 `staleRevision`，随后取消 intent 并保留队列。App 现在先应用既有 UTC 正午报告日期语义，Platform 再投影到持久化稳定值，文档与 intent 使用同一日期。
- **恢复队列回归**：新增合成集成用例覆盖 reviewable item 在会话结束后没有 transport receipt、且选择日期含亚毫秒精度的历史形态；完整 coordinator → staging → Vault commit → inbox terminal 链路创建 `.needsReview` draft 并只移除所选 item。receipt 继续不是归档前置条件。
- **侧边栏原因与修复**：按钮式导航重构后，待确认报告/影像仍沿用了原生选择列表的 `.selectionDisabled()` 行形态。添加成员、待确认报告和待确认影像现在共用独立全宽动作按钮与矩形命中区域；这些命令不进入侧边栏导航选择域。
- **已验证**：LAN archive、LAN inbox model 和侧边栏 focused 回归共 20 tests / 3 suites 通过；`scripts/test.sh --quiet` 通过 723 tests / 73 suites，独立真实 Socket/RSS 门禁 1/1 通过；`scripts/lint.sh`、`scripts/privacy-guard.sh`、本地化资源检查与 `git diff --check` 通过。正式 bundle、安装后合成验收和只读人工点击复核见下一条。

## [2026-08-08] verification/install | 补跑正式 bundle 与当前 Mac 隔离安装验收

- **正式产物**：clean revision `90de7c208a1173f84d12acf18e955dd6c98ab68e` 通过 `scripts/verify-app.sh --require-clean-source`，生成 arm64 `0.5.0` / build `5` ad-hoc production bundle。release build、生产 entitlement、依赖锁、本地化资源、隐私、bundle 结构、App/XPC 逐层签名和生产身份门禁均通过；完成安装验收后的最终 App content-manifest/App executable/Helper executable SHA-256 分别为 `23286157b3d7baaaff489377e9f6e066915b3b95d08d9793e2d816dcbfaa790b`、`b3f98198eaaf0024f884651d2bbe14ec529f4fda5280c704a65c017db1b60a5d`、`56dbe77fc49c3ce6aa7c4ff0e4f1563163e55f0f1d36788385badcfe4ebe5148`。
- **隔离安装验收**：`scripts/run-acceptance.sh` 使用随机隔离身份在用户 Applications 目录临时安装并通过真实 App/XPC composition、4 个合成成员、96 条记录/附件、LAN receiver 安全与重启、DICOM 3 Series/216 个可查看实例/1 个惰性对象、648 次 render、重启后 3 次 render、删除、普通 Vault 重启、强制终止恢复、canary 扫描和清理；扫描命中为 `0`，临时 App 与合成资料均无残留。
- **资源观测**：DICOM cached W/L p95 `1 ms`、foreground slice p95 `61 ms`、RSS peak delta `18,825,216 bytes`；2 workers、queue depth 2、最多 6 个 managed live descriptors，每对象最多 3 次 managed full read/2 次写，peak added disk `4,026,608 bytes`。这些只是当前 macOS 26.6/arm64/Xcode 26.6 合成负载观测。
- **本机安装与只读点击复核**：已验证 production bundle 逐文件复制到用户 Applications 目录并再次通过版本、bundle ID、可执行文件哈希和 strict codesign 检查；被替换的 `0.5.0` / build `5` 候选与更早的 `0.3.0` / build `3` App 均保留为可恢复备份。生产 identity 启动后，待确认报告行可打开完整确认窗口，原件预览与表单完成加载；没有执行归档、确认、稍后处理或删除，也没有改写真实 Vault，随后停止测试进程。侧边栏点击复核不替代真实资料归档验证，归档行为由合成集成与安装验收覆盖。
- **仍未执行**：Developer ID、notarization、macOS 14/15 独立机器、真实手机、私有 MRI、真实 OCR、100 MiB 最坏情况 UI RSS、PDF 多页操作和完整键盘/VoiceOver/触控板人工矩阵仍为 `notExecuted`；报告保持 `overall=pendingManual`。

## [2026-08-08] rescue/refine(ui) | 迁移并收口侧边栏与 LAN 原件预览

- **分支迁移**：把 detached `b82b99e` 上未提交的 16 文件 UI 修改保护到 `codex/lan-ui-preview-polish`，再把基线迁到 `codex/app-service-contracts` 的 `e492e53`。冲突整合保留 DICOM 医学影像/待确认影像入口、App service 契约拆分和 `0.5.0` 文档事实；没有把旧 `0.3.0` 状态覆盖回当前 Wiki。
- **导航收口**：侧边栏继续用 Container/Primary 自定义选中层和 plain Button 消除系统蓝色叠层，同时新增 2pt Primary 可见焦点描边与可测试的上下方向键顺序；全部记录、医学影像、手机上传、活跃成员和设置均在同一导航序列，选中项保留 `.isSelected` 语义。LAN 原生多选行继续显式使用 On Surface/On Variant/Primary/destructive 前景色。
- **预览收口**：页序文件名切换当前图片/PDF 内联预览；独立原图初始按窗口适配，动态缩放上限至少达到有界解码图像或 PDF 页的实际尺寸。内联预览只保留当前原件的一份 payload，打开独立窗口时直接复用，不再次读取同一份最大 100 MiB 原件。
- **验证**：受影响的主题、侧边栏、LAN Model/视图和原件布局聚焦测试通过 33 tests / 5 suites；`scripts/test.sh --quiet` 通过 722 tests / 73 suites，独立真实 Socket/RSS 门禁 1/1 通过。`scripts/lint.sh`、本地化资源漂移检查、`scripts/privacy-guard.sh` 和 `git diff --check` 通过。
- **未执行**：没有重跑正式 bundle、安装验收、100 MiB 最坏情况 UI RSS、PDF 多页人工操作、完整 Tab/方向键/VoiceOver、macOS 14/15、真实手机或私有 MRI 门禁；既有 clean bundle/XPC/DICOM 安装证据不因本次源码测试而更新。

## [2026-08-08] refactor | 分离 App 服务契约与运行时实现

- **代码整理**：把 `AppServices.swift` 中的 App service error、DTO、command、projection 和 protocol 原样抽到 `AppServiceContracts.swift`；`LiveAppServiceEnvironment`、startup preflight、Vault destroy adapter 与 `LiveAppService` 继续留在运行时实现文件。SwiftPM target、访问级别和依赖方向不变。
- **测试稳定性**：首次全量运行复现 DICOM 画布离屏测试把逻辑 2×2 固定当作物理 2×2 的 backing-scale 假设；Retina bitmap 下四个固定坐标会落在同一源像素。测试现在按实际 `pixelsWide` / `pixelsHigh` 采样四个象限中心，继续验证持久像素的 top-to-bottom 行序，生产绘制代码不变。
- **行为边界**：本次不修改产品流程、持久 schema、网络/OCR/DICOM 行为、隐私承诺或用户可见文案，因此不新增行为测试；使用既有跨层 service 回归证明结构移动后的契约与实现仍完整链接。
- **验证**：`scripts/test.sh --filter LiveAppServiceTests` 通过 36 tests / 1 suite；修正 backing-scale 采样后，`scripts/test.sh --quiet` 通过 716 tests / 73 suites，独立 real Socket/RSS gate 1/1 通过。`scripts/lint.sh`、本地化资源漂移检查、`scripts/privacy-guard.sh` 和 `git diff --check` 均通过。
- **未执行**：本次结构整理不重新执行正式 bundle、安装验收、macOS 14/15、真实手机/MRI 或人工键盘/VoiceOver 门禁，不改变这些门禁的既有状态。

## [2026-08-07] verification | 完成 DICOM Viewer 当前 Mac 生成式安装验收

- **安装链路**：从 clean revision `c662e3263a6e68446a6cae6925197e4b83ee0dc1` 通过 Launch Services 运行 report-bound App composition 与 embedded XPC。生成式无身份检查包含 3 Series、216 个可查看 classic single-frame MR 和 1 个惰性 SR；完成导入、648 次 render、重启后 3 次 render、删除、post-DICOM generation baseline、普通 Vault 强制终止恢复和清理。没有读取私有 MRI。
- **资源/性能观测**：cached W/L p95 `1 ms`、foreground slice p95 `55 ms`、RSS peak delta `18,644,992 bytes`；import 使用 2 workers、queue depth 2、最多 6 个 managed live descriptors，每对象最多 3 次 managed full read/2 次写，peak added disk `4,026,608 bytes`。这些是当前 macOS 26.6/arm64/Xcode 26.6 合成负载观测，不是跨设备保证。
- **报告与门禁**：`dist/verification-report.json` 记录 `automatedOverall=passed`、`dicomInstalledAcceptance=passed`、`overall=pendingManual`；App content-manifest/App executable/Helper executable SHA-256 分别为 `4810594638ab3884821bbb5fb5fac7d8a7207e62bc0e80457c7a80f4e61051f5`、`fdcf84ed6ce342ac7958e469bfbbcb00cdd1e19b22aedfc1177c0e032cdb4937`、`9af8643ffcb0412fdfb83d832dfc485a2f9014b607ab666e2c8780e098942605`。最终源码全量通过 716 tests / 73 suites与独立 real-socket/RSS gate，6 项 Vision 为既有 outer-sandbox known issues；lint、privacy 和 package graph 通过。
- **范围**：当前支持边界仍是本机 classic single-frame Explicit VR Little Endian 灰度 MR；不含诊断、测量、压缩/多帧/彩色、PACS/DICOMweb、OCR/时间线/搜索/比较或持久预览。macOS 14/15 独立机器、私有真实 MRI、人工键盘/VoiceOver/触控板、Developer ID/notarization 仍为 `notExecuted`。详见 [`acceptance/dicom-mri-viewer-matrix.md`](acceptance/dicom-mri-viewer-matrix.md)。

## [2026-08-07] implementation | 落地本机二维 DICOM Series Viewer

- **proof-first RED**：首批 model tests 先因缺少 `DICOMStudyViewerModel`、Series summary 和 App-owned slice-service seam 编译失败；随后 layout/source-safety tests 又因三份 Viewer View 与布局策略不存在而失败。实现后新增的 offscreen canvas test 首轮因测试直接读取不兼容的 RGB `NSColor.whiteComponent` 触发 test-process exception，改为显式转 device-gray 后验证生产行序，未改生产绘制语义。
- **实现**：`LiveAppService` 只投影 opaque Series ordinal/count/dimensions/order provenance，MR 标签来自冻结的受支持对象契约；独立 Viewer metadata seam 让 Review 复用已加载摘要，Library 才按需读取同一窄契约。composition 每次 presentation 创建新的 `DICOMSliceService`。`@MainActor` Viewer model 用 generation 阻止迟到 Series/切片重绘；切换先清旧像素，支持当前 open/slice 重试、fallback warning、memory pressure 和 close fencing。连续 W/L 只保留 active + newest pending，slice endpoint 不重复 render/prefetch；AppKit canvas 在同步 pixel borrow 内直接画临时 grayscale `CGImage`，并只在 render identity/transform 变化时重绘，不复制/持久化/导出像素。
- **交互与无障碍**：提供 Series list/compact picker、slice slider/方向键/滚动、primary-drag W/L、Space/辅助拖动平移、pinch/Command-scroll zoom、Fit/Reset 与键盘调整菜单；loading/failure 有 announcement，Retry 可聚焦，画布只给非诊断描述。Viewer 只显示用户确认成员/日期、MR、尺寸、ordinal/count 和 aggregate warning，不显示路径、文件名、UID 或 DICOM 自由文本。
- **实现收敛**：`ce-simplify-code` 的复用 lens 未发现应替换的重复抽象；应用 3 项质量与 5 项效率修正，移除断开的 canvas 几何脚手架和冗余 modality 字段，拆分 Review/Viewer metadata，补 metadata 复用、W/L 合帧、endpoint no-op、prefetch 去重和 canvas 精确 invalidation。
- **GREEN**：Viewer model/layout/input/canvas/source-safety 17 tests / 4 suites通过；DICOM/App/本地化比例回归 187 tests / 24 suites通过。`scripts/test.sh --quiet` 通过 708 tests / 72 suites与独立 real Socket/RSS gate，6 项 Vision 保持既有 outer-sandbox known issues；lint、privacy、localization、package graph 与 diff check 通过。当前 Mac main-thread pan/zoom test 断言 p95 `< 8 ms`，offscreen 2×2 render 验证 top-to-bottom grayscale row order。详见 [`sources/2026-08-07-dicom-viewer-ui-contract.md`](sources/2026-08-07-dicom-viewer-ui-contract.md)。
- **范围/未执行**：仍只使用运行时生成的无身份 fixture，没有读取私有 MRI。cached W/L/uncached decode p95、三次滚动 RSS、clean bundle/installed Viewer、macOS 14/15、真实 MRI 私密检查和人工键盘/VoiceOver/触控板仍待 U7 或人工门禁。

## [2026-08-07] implementation | 接入 DICOM 文件夹导入、确认与独立影像库

- **proof-first RED**：U5 首批 App tests 先因 DICOM App service/model/view 不存在而编译失败；随后 UI source safety、真实 Vault integration 和刷新 stale review 分别暴露缺失入口/导航、跨层链路和被其他 mutation 删除后仍保留 review presentation。简化审查又固定了关闭界面后晚到 import 结果、DICOM 操作未完整受 lifecycle fence 保护及重复确认无意义增加 generation 的风险。
- **实现**：`LiveAppServiceEnvironment` 组装既有 `DICOMImportWorkflow`；独立 folder picker 提供无文件名/路径/UID 的聚合进度与取消。完整 study 进入 review 后必须由用户选择活跃成员与日期，confirmed study 只进入独立医学影像库，exact re-import 复用既有 destination；成员依赖和 study 删除沿 catalog v3 事务处理。App snapshot 只投影 summary，报告 timeline/OCR/search/comparison 与 OriginalDocument 查询不接收 DICOM。
- **生命周期与收敛**：import、最终 catalog load、review read、save 和 delete 均在共享 `LibraryLifecycleCoordinator` active-operation fence 内；revoke 后四类入口 fail closed。ViewModel operation generation 丢弃 dismiss 后晚到结果；重复确认不提交新 generation。三路 simplify 审查还缓存 library 排序/成员 label、复用 `RecordQuery.selectableMembers`、收敛 runtime 参数和 review dismiss callback，未放宽 XPC/Vault 边界。
- **GREEN**：U5 定向 22 tests / 7 suites、DICOM/App/本地化/package 比例回归 188 tests / 21 suites通过；lint、privacy、localization、package graph、diff check 通过。最终 `scripts/test.sh --quiet` 通过 690 tests / 68 suites与独立 real-socket/RSS gate，6 项 Vision 保持既有 outer-sandbox known issues。
- **范围/未执行**：仍只使用运行时生成的无身份 DICOM；没有读取用户私有 MRI。slice Viewer、正式 bundle/安装后 DICOM UI、macOS 14/15、真实 MRI、人工键盘/VoiceOver 和 Developer ID/notarization 仍未执行。详见 [`sources/2026-08-07-dicom-app-flow-contract.md`](sources/2026-08-07-dicom-app-flow-contract.md)。

## [2026-08-07] release preparation | 建立 DICOM ordering-policy-v2 回滚契约

- **proof-first RED**：把当前候选身份、安装 request/event 与归档脚本测试升级到 policy v2 后，编译先因 request 缺少 `orderingPolicyVersion`、runner 无法绑定该字段而失败；旧打包身份和脚本字面量也不满足新契约。
- **实现**：候选升级为 `0.5.0` / build `5`、role `dicom-policy-v2-preparatory`；App Info、clean verification report、archive metadata、durable binding/state、固定安装事件和实际 DICOM index 都精确绑定 ordering policy `2`。受限 successor 固定为 `0.5.1` / build `6`。portable verifier 同时保留 exact `0.4.0-4` policy-v1 archive 的只读验证能力，但 publisher/installed runner 只接受新的 `0.5.0-5` contract。
- **GREEN**：23 项 runtime/script/packaging focused tests 与相关 zsh syntax 通过；当前 verifier 再次独立验证历史 `0.4.0-4` archive 及其既有 SHA-256 通过。提交后的 current source 又通过 `scripts/test.sh --quiet`：673 tests / 62 suites、isolated real-socket/RSS 门禁通过，6 项 Vision 仍是既有 outer-sandbox known issues。
- **耐久归档**：从 clean revision `efdda04a71d4ba4edbab42a806a8a343cc68e86a` 在仓库/临时树之外发布不可变 `Kinlogue-0.5.0-5`；publisher clean bundle gate 与独立 portable verifier 均通过。ZIP SHA-256 为 `a908b483ecbfe0b4df54fede8b3477c154a19edf85fabbbd4587af109a533806`，App bundle-manifest/App executable/Helper executable SHA-256 分别为 `002cb68c4edd273ab5508eda7459b53fc84c4205da71e5b653bc35895a13402e`、`060cc444fc6dd5f0dabc88344e8df4fad797aa20d0ba8c56d9ee37ad43d9f6f4`、`e8dc065ed27abf9994376d5dc19d0511de457e8dd2efca6299174c9e6b4c2d1c`。
- **真实安装复演**：installed driver 首次调用发现另一个 Codex worktree 的 Kinlogue 正在运行，按设计在安装、启动 phase 和 acceptance Vault mutation 前停止；所属任务确认无未保存操作并优雅退出后，以同一 archive 完成 predecessor seed/reopen-write、`0.5.1` / build `6` successor write、fresh exact predecessor rollback/reopen-write 与 cleanup。最终 generation `5`、ordering policy `2`、1 study、2 retained objects（1 viewable + 1 inert）、1 series，graph SHA-256 为 `b5935be33d06a45e890d307af307144e2d300099498eb45a407546a44428e6a5`，inventory SHA-256 为 `a1188c409f90373508c7cf7cc4615668a291fe827fa516a9bfd050c80e690874`，`cleanup=true`；临时 App、acceptance Vault 和进程均无残留。可选 exact 历史 v2 downgrade probe 仍为 `notExecuted`。

## [2026-08-07] hardening | 收口 DICOM slice 全局调度、所有权与资源计费

- **proof-first RED**：临界预算先证明缺失 W/L 的 percentile sort scratch 与主进程 XPC reply/raw frame 双 buffer 未计费；controlled decoder 证明取消旧 foreground 后新 decode 会并行；service drop/prefetch watcher、跨 service close/switch cache、Window Width `0.5`、非 LINEAR VOI source contract 与 oversized canonical 又分别暴露 reservation 泄漏、强持有、全局误清、校验不一致和 lease 转移后的未计费 storage。
- **实现**：scheduler 现在让 newest pending 等 active 真正 finish；active/render 改为 deinit-safe RAII lease，decode/watcher 不继承 service actor；close/switch/lifecycle failure 按 session token 清 cache，memory pressure 才全局 clear。预算用 checked arithmetic 覆盖 object、两份主进程 raw、canonical、render/upload 与可选 sort scratch；persisted geometry 改为线性验证，display 预计算窗口常量，Vault 每次仍全图 fail-closed 验证但复用本次 requested index。IPC/Core/display 统一拒绝 Width < 1；Helper 只读取 VOI LUT Function 单 tag，非 `LINEAR` 固定拒绝而不展开全 tag。
- **GREEN**：U4 focused 60 tests / 6 suites，DICOM/PlaintextVault/StorageProcess 比例回归 158 tests / 12 suites；最终 source 的 `scripts/test.sh --quiet` 通过 673 tests / 62 suites及 isolated real-socket/RSS 门禁，6 个 Vision 检查仍是既有 outer-sandbox known issues；lint、privacy、package graph 与 diff check 通过。clean revision `04449b0092051fc10e6bd37c9199d17074f6995b` 的正式 bundle 和针对同一 report-bound App 的真实 XPC 门禁也通过；App content-manifest SHA-256 为 `efdaf6b1bf709aa241c7e4cb9c874b23d0f735a1f00fd18faddb46897b96905a`，Helper executable SHA-256 为 `1f7c8c7c955118893268bf1aa4f7c6292113b14b9f627c97b5cb6dc8f6a70578`。
- **回滚边界**：exact `0.4.0` / build `4` 归档只接受 ordering policy v1，U4 source 接受 v1/v2 并写 v2。当前尚无 App 流程能发布 v2 index；U5 暴露导入前必须生成新的 exact predecessor 并完成 policy-v2 predecessor -> successor -> rollback 安装复演，旧的 policy-v1 rehearsal 不得冒充该证明。
- **范围**：仍只用运行时生成的无身份 fixture；没有访问用户资料，也没有进入 U5/App UI。三次滚动 benchmark、installed user flow、真实 MRI、macOS 14/15 和人工可访问性仍未执行。

## [2026-08-07] implementation | 落地 DICOM geometry 与按需切片服务

- **实现**：ordering policy 升级到 v2，在导入时按 orientation normal projection 固化 geometry order；完整 geometry 缺失时才使用 Instance Number/content identity fallback，v2 reopen 验证顺序，历史 v1 不静默重排。Kinlogue transformer 覆盖 High Bit/Bits Stored、signedness、rescale、W/L fallback 和 MONOCHROME1/2。
- **Vault/lifecycle**：`DICOMSliceService` 只通过 `PlaintextVault` 的 revision-bound opaque descriptor 读取 managed object，decode 前后复核 digest/inode/length/attributes，decoder 仍只走 sandboxed XPC adapter。短 descriptor lease 后释放 catalog coordination；destroy-start lifecycle generation 在最终 pixel publish 前重验，late result 清 cache/reservation 而不返回 stale image。
- **资源/所有权**：production service 共享进程级 384 MiB budget、32 slices/192 MiB LRU 和单 foreground + 单 prefetch scheduler；active→cache/current-render reservation 同步原子转移。canonical/current render 使用引用型单一 storage，避免 COW 伪清零；旧 `DICOMSliceImage` handle 在 switch/pressure/close 后不可读。
- **proof-first 与验证**：geometry 测试先观察 oblique order 仍走 content fallback、inconsistent orientation 未失败的 RED；retained render 未计入下一 decode、close 后外部 Data 保留旧 pixels、caller cancellation 仍发布也分别先 RED。实现后 U4 focused regression 通过 47 tests / 6 suites，覆盖 v1 reopen、High Bit 14、两 service 全局预算、dedupe/preemption/caller 与 shared-waiter cancellation、tamper、pressure/close 和 destroy fence；`scripts/test.sh --quiet` 通过 659 tests / 62 suites及其 isolated real-socket/RSS 门禁，6 个 Vision 检查为外层沙箱 known issues，lint、privacy guard 与 diff check 通过。
- **范围/未执行**：全部证据使用运行时生成的无身份 fixture；没有读取私有 MRI。App import/review/Viewer UI、三次完整 DICOM 滚动 RSS/p95 benchmark、clean bundle、installed flow、macOS 14/15、真实 MRI 和人工可访问性门禁仍待执行或在后续日志追加。
- **文档**：同步 architecture、domain、import、storage、privacy、testing 和 index，并新增 [`sources/2026-08-07-dicom-slice-service-contract.md`](sources/2026-08-07-dicom-slice-service-contract.md)。计划正文保持决策记录。

## [2026-08-07] implementation | 落地独立 DICOM 解码 XPC 基础

- **实现**：root 与 checked-in Xcode project 同时锁定官方 DICOM-Swift exact 1.3.3；只有 non-published `KinlogueDICOMDecoderHelper` 链接 `DicomCore`。主进程通过 Foundation-only `KinlogueDICOMIPC` 传只读 descriptor 和有界 DTO，Helper 复制到 opaque 私有临时文件后解码，不提供进程内 fallback。Helper 返回 `getFrame(0)` 原始字节而不调用带 signed/MONOCHROME1 展示变换的 `getPixels*`，并独立核对 Pixel Data VR/VL；九秒硬 watchdog 约束同步上游解析。
- **打包与权限**：`scripts/build-app.sh` 使用 Xcode 原生 XPC target 生成标准 `Contents/XPCServices` 布局，把 DicomCore/ZIPFoundation resource bundles 只放在 Helper `Contents/Resources`，依次显式签资源、Helper 和 outer App。Helper entitlement 精确为 App Sandbox，无 network/inherit/用户文件/Vault-root 权限；主 executable 没有 DicomCore/DICOM 网络实现符号。
- **验证**：先观察缺失 Xcode project、缺失真实 probe、未配置 `FileHandle` allowed classes 及 DTO/Part 10 边界的预期 RED；真实变异 probe 又证明 exact upstream 会忽略被篡改的 Pixel Data VL，独立核对后转绿。DICOM adapter 7 项、packaging 5 项、package graph 8 项、LAN resource/notice 10 项及相关脚本安全 focused suites 通过；`scripts/lint.sh`、全量 `scripts/test.sh`（564 tests / 53 suites，另有真实 Socket/RSS 门禁；6 项 Vision 为外层沙箱已知限制）、`scripts/privacy-guard.sh`、package graph、`scripts/build-app.sh`、`scripts/verify-app.sh --lan-prerequisites-only` 通过。允许 launchd/XPC 的本机环境中，`scripts/verify-dicom-xpc.sh` 已通过 raw unsigned/signed+MONOCHROME1 字节、畸形 VL、生产 Helper SIGKILL、compile-time-only hang/watchdog、strict signing、unified-log canary 和零 socket 门禁。
- **实现收敛**：独立复用/质量/效率审查后，统一 fixture/Part 10 的受支持 UID 常量与失败编码；成功响应立即取消客户端 timeout，完成请求立即取消 Helper watchdog；临时请求副本不再执行无持久化意义的 `fsync`。DICOM prerequisite 从 LAN 检查体拆出；CI/release 只复用 `verify-app` 产出且重新核对 source revision 与 bundle hash 的同一 App，避免重复构建及报告漂移。
- **clean-source 证据**：U1 revision `5567f1c` 随后通过完整 `scripts/verify-app.sh --require-clean-source`；生成报告绑定同一 source revision，App 内容哈希为 `7701a33240396ef704da7c66f6f6b84e0d0ecf58a54b8db7327d8f8e0b6d3ce3`，Helper executable 哈希为 `f3762b710c541dbcc7d89cbf27eb3408a526375ffdd888ca8e644faa4013cc6e`。`scripts/verify-dicom-xpc.sh --use-verified-app` 又对报告中同一 bundle 完成真实 XPC 复验。
- **范围与未执行**：这只是 Viewer 计划 U1 的依赖/隔离/打包基础；catalog v3、导入、缩略图和 Viewer UI 未实现。安装验收、macOS 14/15、可访问性和私有 MRI 兼容矩阵未执行；没有读取用户提供的 MRI。
- **文档**：同步架构、隐私、测试发布、索引，并新增 [`sources/2026-08-07-dicom-xpc-xcode-build-evidence.md`](sources/2026-08-07-dicom-xpc-xcode-build-evidence.md)。计划正文保持决策记录，不写执行进度。

## [2026-08-07] plan revision | 选择 DICOM-Swift 独立沙箱 Helper

- **用户决定**：继续直接引用官方 exact DICOM-Swift 1.3.3，但仅允许独立 `KinlogueDICOMDecoderHelper` XPC service 依赖 `DicomCore`；不维护裁剪 fork，也不把完整 package 链接进主 App 进程。
- **隔离边界**：主 App 只通过 Foundation-only IPC contract 传递一个只读 descriptor 与有界请求；Helper 使用单独签名/App Sandbox profile，不继承或声明网络 entitlement，不获得 Vault 根权限，只在私有 opaque request file 上调用逐文件 decoder。
- **验证变化**：主 App 必须没有 `DicomCore`/DICOM 网络实现；Helper 因 exact upstream 可含惰性网络符号，但 source/call allowlist 不得构造对应对象，entitlement 必须无网络能力，运行时 socket canary 必须为零。Helper crash/hang/oversized reply 不能使主 App 崩溃或触发 in-process fallback。
- **同步页面**：更新 DICOM Viewer 计划、`decisions.md` 和 `index.md`；当前仍是计划目标，不写成已实现能力。

## [2026-08-07] feasibility | DICOM-Swift 1.3.3 触发 release 边界停止门禁

- **动作**：在合并最新 `origin/main` 后，从已评审计划开始 U1；用仓库外无身份最小 SwiftPM consumer 精确依赖 DICOM-Swift 1.3.3，仅调用逐文件 decoder，并构建 release arm64 executable。
- **依赖事实**：tag `1.3.3` 解析到源码 revision `9ae0851e134af274651b646519b8a7aaeee05f05`，传递依赖为 ZIPFoundation `0.9.20` 和 swift-argument-parser `1.8.2`。
- **停止证据**：最终 Mach-O 链接 `Network.framework`/`CFNetwork.framework`，并保留 `DicomStorageSCPServer`、`NWListener`、DIMSE、DICOMweb transport/server 实现或类型元数据；因此触发计划 R22/KTD2 的明确停止条件。
- **处置**：未修改生产 `Package.swift`、adapter、target、测试或 bundle，未读取私有 MRI。catalog v3 与 Viewer 实现保持未开始，等待明确选择隔离 helper、最小审计 package，或修订 executable 边界。
- **来源**：[`sources/2026-08-07-dicom-swift-1.3.3-release-boundary.md`](sources/2026-08-07-dicom-swift-1.3.3-release-boundary.md)。
## [2026-08-07] feat(ui) | 为待确认页序增加完整预览并让原图默认适配窗口

- **调整**：报告页序中的文件名可切换右侧当前原件；右栏在页序下方复用已有安全预览组件展示整张图片/PDF 页，点击预览图或“查看原图”仍进入独立查看窗口。
- **交互**：独立查看窗口初始以窗口可容纳的完整尺寸显示原件，放大/缩小控件从该适配尺寸继续调整；不会再以原始像素尺寸直接裁切视图。
- **验证**：新增页序内联预览、预览 payload 和适配缩放回归测试；聚焦测试 20 项通过，`scripts/build-app.sh` 生成 `dist/Kinlogue.app`。本机实际选择两个待确认原件，确认右栏预览随页序切换；打开原图确认初始完整显示，放大后出现滚动范围。`scripts/test.sh --quiet` 通过 555 项 / 51 个套件和 1 项真实 Socket/RSS 门禁，6 项 Vision 保持外层沙箱已知限制；lint、隐私门禁和差异检查随后通过。完整键盘/VoiceOver、PDF 多页人工检查与 macOS 14/15 矩阵仍待执行。

## [2026-08-07] polish(ui) | 扩大侧边栏选中容器的上下留白

- **调整**：参考用户给出的整行圆角容器效果，为“全部记录”“手机上传”和家庭成员导航项增加 8pt 上下内边距；选中块仍使用 Warm Sanctuary 的 Container/Primary 令牌，不增加突兀的投影或改变横向占用。
- **验证**：新增的视觉源代码断言先按预期失败，随后侧栏与主题聚焦测试 13 项通过；重新构建 `dist/Kinlogue.app`，本机截图确认选中背景已从薄胶囊变为完整行高的圆角块。`scripts/test.sh` 通过主测试 552 项 / 51 个套件和 1 项真实 Socket/RSS 门禁，6 项 Vision 保持外层沙箱已知限制；lint、隐私和差异门禁通过。仍需人工完成完整键盘/VoiceOver 与 macOS 14/15 矩阵。

## [2026-08-07] fix(ui) | 移除侧栏蓝色焦点层并修复队列选中文字

- **根因**：侧边栏同时使用原生 `List(selection:)` 与自定义 Container 选中背景，macOS 会在其外继续叠加蓝色选择/焦点效果；手机上传队列则保留原生选择白字，但行背景被固定为浅色 Surface，导致文件名、辅助信息和操作图标在选中后失去对比度。
- **修复**：侧边栏改为非选择型 `List` 中的 plain Button 导航，显式维护选择模型、选中背景/前景和无障碍选中 trait，并关闭导航按钮的系统蓝色 focus effect；手机上传队列保留原生单选/多选，选中行改用 Container，文件名、辅助信息、预览/重试和删除分别显式使用 On Surface、On Variant、Primary 和 destructive red。
- **验证**：新增源码回归断言，并先确认旧实现按预期失败；聚焦的侧栏、主题和 LAN 收件箱测试共 18 项通过，`scripts/build-app.sh` 生成最新 `dist/Kinlogue.app`。本机实际点选“全部记录”“手机上传”和队列首行，确认侧栏无蓝色填充/边框，队列选中文件名、状态、大小、日期及操作图标保持可读。`scripts/test.sh` 通过主测试 552 项 / 51 个套件和 1 项真实 Socket/RSS 门禁，6 项 Vision 保持外层沙箱已知限制；lint、隐私和差异门禁通过。完整键盘/VoiceOver 与 macOS 14/15 人工矩阵仍未执行。

## [2026-08-07] refine(ui) | 侧边栏选中 Tab 改为 Surface/Container 柔和层级

- **动作**：按最新视觉规范，侧边栏大背景使用 Surface，选中 Tab 使用 `surface-container` 对应的 `KinlogueTheme.container` 浅米灰背景，文字和图标使用 `KinlogueTheme.primary` 深玉绿；未选中保持透明并使用 `KinlogueTheme.onVariant`，悬停保留轻微底色。移除固定的全列表图标 tint，避免未选中图标被错误染成 Primary；设置行也复用同一前景色规则。
- **范围**：只调整侧边栏大背景与选中/悬停令牌，不改变成员、全部记录、手机上传、设置的选择模型、键盘导航或 VoiceOver 语义；本条 supersedes 上一条深玉绿白字选中态的当前视觉约定。
- **依据**：用户明确指定浅灰/米灰 surface-container 背景和 Primary 前景；实现通过语义化 `Selection` 令牌复用现有 Surface/Container/Primary 色板，不在 View 中复制 RGB 常量。
- **验证**：修正后源码契约测试、完整测试（551 项 / 51 个套件，另 1 项真实 Socket/RSS 门禁）、App 构建、lint、隐私门禁和差异检查均通过；实际窗口检查确认全部记录、手机上传和设置选中行使用浅米灰 Container、文字/图标使用深玉绿 Primary，未选中行保持透明且不受固定全列表 tint 影响。Vision 相关 6 项仍为外层沙箱已知问题。

## [2026-08-07] refine(ui) | 将侧边栏选中 Tab 调整为深玉绿高对比样式

- **动作**：在上一版浅玉绿色选中背景基础上，按用户反馈将选中 Tab 背景调整为 `#1E6254` Deep Jade，文字和图标调整为白色；未选中 Tab 使用透明背景与 `#3F4946`，悬停只显示深玉绿 8% 的轻微底色。
- **范围**：只改变侧边栏选中/悬停的视觉令牌和前景色，不改变成员、全部记录、手机上传、设置的选择模型、键盘导航或 VoiceOver 语义；本条 supersedes 上一条浅玉绿选中态的当前视觉约定。
- **依据**：用户明确给出 `#1E6254`、白色前景和 `#3F4946` 未选中前景规范；实现继续复用 `KinlogueTheme`，不在 View 中复制 RGB 常量。
- **验证**：源码契约测试、完整测试（551 项 / 51 个套件，另 1 项真实 Socket/RSS 门禁）、App 构建、lint、隐私门禁和差异检查均通过；实际窗口检查确认全部记录、手机上传和成员 Tab 均显示深玉绿背景与白色前景，未选中行保持透明。Vision 相关 6 项仍为外层沙箱已知问题。

## [2026-08-07] fix(ui) | 将侧边栏选中态调整为 Warm Sanctuary 浅玉绿

- **动作**：侧边栏原生 `List` 的选中背景从系统蓝/灰调整为 `KinlogueTheme.selection` 浅玉绿，文字和图标继续使用深玉绿；列表标签图标同步使用同一主题 tint。
- **范围**：只改变侧边栏选择强调色，不改变成员/全部记录/手机上传/设置的选择模型、键盘导航或 VoiceOver 选中状态；选中背景不随窗口失焦改回灰色。
- **依据**：用户反馈系统蓝与暖象牙/深玉绿色板不一致；实现使用语义化 `Selection` 令牌、SwiftUI `tint` 与 `listItemTint`，避免在页面中复制 RGB 常量。
- **验证**：新增 Warm Sanctuary 侧边栏选择背景/tint 源码契约测试；聚焦测试、lint、隐私门禁和 `scripts/build-app.sh` 均通过；实际窗口检查确认全部记录、手机上传和成员行均显示浅玉绿色选中背景。完整测试与 macOS/真实设备验收仍待执行。
## [2026-08-06] merge | 同步 main 中英本地化与 ad-hoc 候选分发

- **动作**：把 `origin/main` 的 Mac App 简体中文/英文资源、语言设置、正式 bundle 本地化修复和工具栏主题修复合入 GitHub Actions/ad-hoc 候选发布分支。
- **冲突处理**：`index.md`、`project-overview.md`、`sources/README.md`、`testing-and-release.md` 和本日志均保留双方事实；发布说明继续覆盖 CI/CD、private 仓库访问限制与未来 Developer ID 路径，同时纳入本地化资源漂移和 bundle 语言门禁。
- **审查修正**：为无 checkout 的发布 job 显式绑定 GitHub 仓库；发布前重新把远端 tag 解引用到已验证 commit；使用 workflow 独占 draft 上传并复核精确六项资产，成功后才转为 Pre-release，失败时只删除 ID、tag 和 draft 状态均匹配的本次 draft。workflow tests 改为按 job/具名 executable step 提取，并用 decoy 覆盖阻止保护命令仅出现在错误位置时假绿；来源笔记同步 private 仓库下载边界。
- **边界**：合并没有把 ad-hoc、unnotarized 的 arm64 Pre-release 改称正式发布，也没有把 Mac App 的语言选择扩展为手机上传页语言契约；macOS 14/15、真实手机、人工 OCR 和可访问性门禁仍未执行。
- **验证**：本地化资源漂移检查、`scripts/lint.sh`、`scripts/privacy-guard.sh`、actionlint 1.7.12、26 项本地化/打包/Actions 聚焦测试与 `scripts/test.sh --quiet` 通过；主测试为 550 项 / 51 个套件，另有 1 项真实 Socket/RSS 门禁通过，6 项 Vision 保持外层沙箱已知限制。clean-source 正式 bundle 门禁需在审查修复提交后重新运行；真实 GitHub Release API 发布演练仍未执行。

## [2026-08-06] merge | 同步 main 品牌入口、无分组队列与 ad-hoc 候选分发说明

- **动作**：把 `main` 的新版品牌 README、设计系统补充、项目总览、来源笔记，以及随后合入的无分组 LAN 待确认队列实现同步进 GitHub Actions/ad-hoc 候选发布分支。
- **冲突处理**：README 保留当前无分组队列和品牌叙事，同时保留独立的 CI/CD 与候选分发章节；知识库索引保留两边入口；追加日志完整保留两边历史。
- **边界**：候选包继续明确为 arm64、ad-hoc signed、unnotarized，仅供具备 private 仓库读取权限的知情测试者手动下载；没有把品牌文案改写成公开正式发布承诺。无仓库权限的公众用户仍需要仓库公开或独立公开下载位置。
- **验证**：冲突标记、Markdown 相对链接、隐私措辞、workflow tests、lint、全量测试和正式 bundle 门禁按本次合并结果重新检查。

## [2026-08-06] ci | 对齐 GitHub runner 与当前 Xcode 26 工具链

- **动作**：把 CI、ad-hoc package 和 publish job 从固定 `macos-15` 调整为固定 arm64 `macos-26`；继续避免 `macos-latest` 漂移，并由 workflow tests 锁定 runner label。
- **依据**：GitHub run `31076517030` 的 `macos-15` / Xcode 16.4 环境先出现 `RecordEditViewLayoutTests` 对 SwiftUI 私有 `KeyViewProxy` 的跨工具链差异，随后全量测试在 90 分钟上限被取消；同一分支在当前 Xcode 26.6 证据机、相同并行度下 648 项测试约 51 秒通过。
- **边界**：runner 升级是 CI 工具链对齐，不是 macOS 14/15 兼容性证据；独立系统、真实手机、人工 OCR 和可访问性门禁仍保持未完成。
- **同步页面**：`testing-and-release.md`、`index.md` 和 `sources/github-actions-macos-ci-cd-2026-08-05.md`。

## [2026-08-06] plan | 规划 DICOM MRI 本机二维查看能力

- **动作**：新增 DICOM MRI Viewer 实施计划，采用检查级目录导入、独立 `DICOMStudy` aggregate、catalog v3、文件级暂存/原子发布、按需切片解码和独立影像资料库；首版交互包括 Series/切片导航、窗宽窗位、缩放、平移、Fit 与 Reset。
- **依赖决定**：按用户确认以 DICOM-Swift 1.3.3 为基础；在任何 schema/UI 接入前先验证依赖日志、非目标网络协议表面、传递依赖、资源 bundle、许可和正式 executable。该门禁失败时停止并重新决策，不静默引入 fork 或削弱隐私承诺。
- **范围边界**：只查看经典单帧 MR Image Storage 的 Explicit VR Little Endian 图像；有效 SR 等非图像对象惰性保留但不展示。压缩、多帧、MPR/MIP、测量、tag inspector、PACS/DICOMweb、医学解释以及报告时间线/OCR/搜索/比较集成均不在首版范围。
- **隐私与验收**：自动测试只生成无身份 fixture。用户提供的私有 MRI 只做仓库外人工兼容比对，其路径、名称、UID、标签、像素、截图、精确清单和派生结果不进入仓库、日志或验收产物。
- **文档评审**：完成一致性、可行性、产品、交互、安全、范围和对抗性评审；直接补齐可恢复切片失败交互、崩溃后明文 orphan 的持久清理账本，以及验收 fixture executable 对 `Package.swift` 的显式修改清单。其余涉及兼容策略、隔离边界、信息架构和范围取舍的问题保留在计划交接中等待确认。
- **同步页面**：新增 [`plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md`](plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md) 与 [`sources/2026-08-06-dicom-mri-viewer-research.md`](sources/2026-08-06-dicom-mri-viewer-research.md)，并从 `index.md` 建立入口。
- **验证状态**：本次只新增/更新 Markdown 规划与来源文档，未修改 Swift、Package、脚本或打包配置，因此未运行构建/测试。依赖硬化、catalog v3、合成像素、安装 bundle、macOS 14/15、VoiceOver/trackpad 和私有样本门禁均待实施。

## [2026-08-05] docs | 更新续页品牌叙事与 GitHub 项目入口

- **动作**：按“续页 / Kinlogue（KIN-log）”品牌定义重写根 README，增加中英文标语、一句话定位、品牌来源、图标意象、核心体验、隐私/医疗边界、当前版本和开发入口。
- **GitHub 元数据**：为 `renyijiu/kinlogue` 设置中英双语仓库简介，并添加 `macos`、`swift`、`swiftui`、`local-first`、`privacy-first`、`family-health`、`health-records`、`medical-records` 和 `on-device-ocr` topics；仓库仍为 private，homepage 仍为空。
- **信息结构依据**：GitHub 官方 README 指引及 LocalSend、CotEditor、Immich、Ente 的公开 README；来源和采用范围记录在 [`sources/2026-08-05-github-readme-patterns.md`](sources/2026-08-05-github-readme-patterns.md)。
- **项目事实依据**：当前代码、`Package.swift`、`packaging/Info.plist`、`PRIVACY.md`、设计系统、项目总览和 `0.3.0` 验收矩阵；没有把品牌愿景写成尚未实现的功能。
- **同步页面**：`README.md`、`project-overview.md`、`design-system.md` 和 `index.md`。
- **验证**：本次只修改 Markdown，不改变 Swift 代码、脚本、打包配置或运行时行为；检查相对链接、品牌色与当前 UI 色阶的关系，以及明文存储、普通 HTTP、非诊断和未公开发布措辞。
- **待办**：产品界面截图、公开下载页、已 notarize 安装包和正式商店信息仍不存在；README 不添加对应入口或发布承诺。

## [2026-08-04] docs | 建立 Kinlogue 项目 Wiki 与 Agent schema

- **动作**：参考 Karpathy 的 LLM Wiki 模式，为仓库建立“原始事实 → 编译 Wiki → schema”三层文档结构。
- **新增入口**：根目录 `AGENTS.md`、`docs/index.md`、`docs/log.md`、`docs/sources/`。
- **新增专题**：产品总览、架构、领域/数据模型、存储、LAN upload、导入/OCR、隐私与安全、测试与发布、决策登记。
- **事实依据**：当前代码、SwiftPM manifest、脚本、README/隐私说明、当前验收矩阵与有效实施计划；早期加密 Vault 计划被明确标记为历史背景。
- **验证**：完成只读仓库盘点；本次变更只新增/更新 Markdown 文档，不改变 Swift 代码、脚本或打包配置。
- **待办**：真实手机与 macOS 14/15 发布矩阵、部分人工生命周期/可访问性检查以及未来应用层加密仍保持未验证或未实现，不因本次文档建设而改变状态。

## [2026-08-05] code/docs | 合入 P1 生命周期审计修复与 Warm Sanctuary 界面

- **动作**：把审计修复分支叠加到当前 macOS MVP 分支，统一 Mac 导航、LAN 接收/inbox 与手机上传页的视觉和窄窗口行为。
- **生命周期修复**：Vault 销毁前撤销接收能力并等待活动 inbox 工作退出；合并并发删除请求；让手机退出登录由服务端会话状态决定，并传播恢复失败。
- **界面与性能**：引入 Warm Sanctuary 语义令牌和组件样式，修复 split view 与窄栏操作布局，并复用派生的成员选择项。
- **知识库**：纳入 [`design-system.md`](design-system.md) 和 [`concurrency-safety-audit.md`](concurrency-safety-audit.md)，并从项目索引建立入口。
- **验证**：`scripts/test.sh --quiet -j 4` 在当前 Mac 通过 642 个测试、53 个套件；6 项 Vision 检查仍记录为外层沙箱已知限制。真实 LAN socket 压力测试通过；`scripts/privacy-guard.sh` 通过。
- **未执行门禁**：本次集成没有重新运行正式 bundle 的 `scripts/verify-app.sh` 或安装验收 `scripts/run-acceptance.sh`；真实手机、macOS 14/15、键盘/VoiceOver 与私有样本 OCR 门禁仍保持未执行。

## [2026-08-05] ci | 增加 GitHub lint CI 与受保护的 draft distribution CD

- **动作**：新增 PR/main CI、版本 tag/manual release workflow、GitHub Actions Dependabot、统一 lint 脚本和 Developer ID/notarization distribution packaging 脚本。
- **安全边界**：外部 Actions 固定完整 commit SHA；CI token 只读；release checkout 不持久化仓库写凭据。lint、隐私、全量测试和 clean-source unsigned bundle 验证先在无 Apple 私钥的阶段完成；凭据阶段校验 report/HEAD/bundle hash 后才签名、公证，并对最终 ZIP 解包后的 exact app 重做签名、ticket、Gatekeeper、identity/team 和 entitlement 检查。临时 keychain 的 `always()` 清理使用固定安全路径，不依赖成功写入 `GITHUB_ENV`。workflow 仍只创建 draft Release，metadata 明确保留安装验收与 KTD13 同分发级别回滚包等人工门禁。
- **测试依据**：新增 `GitHubActionsWorkflowTests`，先观察 4 个缺失文件导致的预期失败，再实现 workflow/script；focused tests、shell/YAML 语法、actionlint 1.7.12、`scripts/lint.sh`、隐私门禁和 LAN prerequisite gate 通过。`scripts/test.sh --quiet` 单进程运行超过约 15 分钟仍无终态，人工停止后退出 130，不能记录为全量通过。
- **文档**：更新 `README.md`、`docs/index.md`、`docs/testing-and-release.md` 和外部来源笔记。
- **待办**：本次未配置 Apple/GitHub secrets，未执行 Developer ID 签名、公证或 GitHub Release；macOS 14/15、真实手机和可访问性人工门禁仍保持未执行。

## [2026-08-05] release | 支持无 Apple 账号的 ad-hoc GitHub 候选发布

- **动作**：把 tag/manual distribution workflow 从依赖 Apple Secrets 的 Developer ID draft 改为公开 GitHub Pre-release；新增 `scripts/package-adhoc-candidate.sh` 和候选安装说明。产物显式命名为 `arm64-adhoc`，普通用户可以手动下载。
- **安全边界**：workflow 仍先执行 lint、隐私、全量测试和 clean-source bundle 验证；仓库代码只在 `contents: read` 的 `package` job 中运行，独立 `publish` job 不 checkout 或执行仓库脚本，并在取得 Release 写权限后复验固定六项文件、SHA-256 和 metadata。打包脚本在 ZIP 前后核验 ad-hoc 签名、无 Authority/Team ID、arm64、精确 entitlement、bundle hash、单一 App 根和无符号链接。Release、INSTALL 和 metadata 均声明 Developer ID/notarization/Apple 恶意软件检查未执行；不提供关闭 Gatekeeper 或递归清除 quarantine 的命令。
- **测试依据**：先强化 `GitHubActionsWorkflowTests` 并观察旧 workflow/缺失脚本导致的预期失败，再实现为 6 项 focused tests 通过；shell/YAML 语法、actionlint 1.7.12、`scripts/lint.sh` 和 `git diff --check` 通过。
- **待办**：尚未在 GitHub runner 上实际发布 Pre-release；macOS 14/15 独立机器、安装后验收、真实手机、可访问性和正式回滚门禁仍未执行。Developer ID/notarization 脚本仅作为未来升级路径保留。

## [2026-08-05] feat | Mac App 改为简体中文/英文双语

- **动作**：按 Apple String Catalog 与 Swift package localization 指南，将 `KinlogueApp` 的用户可见静态文案、动态插值、错误和无障碍标签迁入 `Localizable.xcstrings`；当前 catalog 有 321 个 source keys，语言限定为 `zh-Hans`/`en`。
- **运行时与打包**：新增 `AppLocalization`，跟随 main app bundle 的 preferred localization，并在 SwiftPM 测试环境回退到 `Bundle.module`；新增 catalog 编译/漂移守卫、中英 `InfoPlist.strings`、release `.lproj` 复制与精确资源验证。
- **数据边界**：OCR 中文关键词和用户内容保持原文；新收到的无效 LAN 文件名改用语言无关占位值和 `displayNameWasGenerated` 字段，Mac/手机分别显示本地可读名称，提交到 `ReportSource` 时不保存生成占位名；旧 manifest 缺少字段时保守保留原名称，避免误翻译用户真实文件名。
- **文档**：新增 `localization.md` 和 Apple 官方来源笔记，并同步总览、架构、数据模型、存储、LAN、测试发布、README 与索引。
- **已验证**：`scripts/compile-localizations.sh --check`、`scripts/test.sh`、本地化/兼容性 focused tests（含 catalog 完整性、旧 manifest、手机 DTO 和 `ReportSource` 端到端路径）、`scripts/privacy-guard.sh`、`git diff --check` 均通过；`scripts/build-app.sh` 构建出 ad-hoc signed arm64 `dist/Kinlogue.app`，人工命令确认 bundle 只声明并包含中英资源、两种应用名和两种局域网用途说明。
- **未执行**：`scripts/verify-app.sh` 的 clean-source release gate 未在当前未提交工作树运行；真实 macOS 14/15 的中英文布局、键盘和 VoiceOver 人工矩阵未执行；手机浏览器页面仍是本轮明确排除的独立中文资源。

## [2026-08-05] feat | 增加 App 内语言设置入口

- **动作**：在家庭成员侧栏底部增加固定“设置”入口；设置态使用“侧栏 + 设置详情”两栏布局，首版只展示 Warm Sanctuary 风格的语言卡片，不引入账号、通知、隐私或其他未实现能力。
- **语言行为**：新增“跟随系统 / 简体中文 / English”三种选择状态；选择通过 `@AppStorage` 持久化，显式中英文优先于系统 preferred localization，并向 SwiftUI environment 注入解析后的 locale，当前窗口即时刷新；报告日期显式使用该 locale，删除资料库的确认短语按当前选择动态解析，不缓存旧语言。
- **证据**：`AppLocalizationTests` 覆盖偏好持久化、无效值回退、显式语言覆盖、系统语言解析和设置文案；`MemberSidebarViewSourceTests` 覆盖专用设置导航状态与入口；`ReportDateSemanticsTests` 与 `VaultDeletionModelTests` 覆盖运行时语言切换容易遗漏的日期和确认短语路径。
- **仍待人工验证**：需要在真实 App 中检查菜单和窗口标题即时刷新、设置页窄窗口布局、键盘/VoiceOver，以及重启后的选择保留；手机浏览器页面仍不跟随 Mac App 的语言选择。

## [2026-08-06] fix | 修复正式 App 的本地化资源启动崩溃

- **现象与根因**：当前 `dist/Kinlogue.app` 启动时在窗口标题本地化阶段触发 `SIGTRAP`；系统报告和标准错误都指向 SwiftPM `resource_bundle_accessor.swift`。发布脚本只把中英 `.lproj` 复制到 main bundle，没有打包 SwiftPM 的 App target resource bundle，但 `AppLocalization` 仍无条件求值 `Bundle.module`，其 accessor 找不到 bundle 后执行 `fatalError`。
- **修复**：正式 `.app` 只使用 main bundle 中已校验的本地化资源；非 App 的 SwiftPM 开发/测试目标才惰性使用 `Bundle.module`。新增回归测试，分别证明 `.app` 路径不会求值 package bundle provider、命令行路径仍会使用它。
- **已验证**：回归测试在修复前按预期编译失败、修复后本地化 15 项测试通过；`scripts/test.sh` 共 662 项测试、55 个 suite 通过并保留 6 个已知问题；`scripts/build-app.sh` 重建并签名正式包；实际启动后进程持续存活、stdout/stderr 为空且没有新系统崩溃报告；`scripts/privacy-guard.sh`、严格 codesign 验证、双语 bundle 声明和 `git diff --check` 均通过。
- **仍待人工验证**：设置页的中英文切换、重启持久化、窄窗口、键盘与 VoiceOver 仍需真实用户交互矩阵；本次启动检查不替代 macOS 14/15 独立机器发布验收。

## [2026-08-06] fix | 统一窗口工具栏与 Warm Sanctuary 画布

- **现象与根因**：SwiftUI 根视图和三栏内容已使用 Surface/Container，但原生 window toolbar 位于内容背景之外，未设置主题背景；亮色系统外观因此在窗口顶部保留大块白色，与暖象牙画布形成断层。
- **修复**：在 App 根视图为 `.windowToolbar` 显式设置并显示 `KinlogueTheme.surface`，继续保留 macOS 原生交通灯、工具栏按钮、焦点和键盘语义；设计系统补充窗口标题栏/工具栏映射。
- **验证**：主题契约测试在修复前按预期失败，修复后 `KinlogueThemeSourceTests` 6 项通过；`scripts/test.sh` 共 663 项测试、55 个 suite 通过并保留 6 个已知问题；`scripts/build-app.sh` 重建并签名正式包；本机界面检查确认顶部背景与主画布保持暖色连续，原生窗口和工具栏控件仍存在；隐私守卫、localization 漂移检查、严格 codesign 验证与 `git diff --check` 均通过。
- **仍待人工验证**：macOS 14/15 独立机器、提高对比度、完整键盘与 VoiceOver 矩阵仍未执行。

## [2026-08-05] plan | 将手机上传改写为无批次待处理队列

- **动作**：按用户确认直接重写 `docs/plans/2026-08-02-001-feat-lan-upload-inbox-plan.md`，废止手机和 Mac 的产品级 batch 模型，规划为手机逐文件上传、Mac 单选/多选文件后按成员和日期组成一份 `.needsReview` draft，成功后移除所选待处理项。
- **事实依据**：核对当前 Core/Platform/App、LAN phone assets、存储与跨进程测试、README/隐私说明和 LAN 验收矩阵；当前 `0.3.0 / lan-upload-v1` 已真实使用 batch，因此计划从显式 v1→v2 迁移、旧提交 lineage 恢复和 v2-aware 回滚检查点开始，不把目标写成当前能力。
- **关键边界**：新生产领域、HTTP 路由和 UI 不以“一文件一批次”保留旧概念；`batch` 只允许存在于隔离的 v1 迁移解码器、合成 fixture 和历史记录。归档仍进入人工待确认门，不直接创建时间线记录。
- **索引**：更新 `docs/index.md` 的计划说明，明确计划目标与当前已实现能力的区别。
- **文档评审**：完成一致性、可行性、产品、交互、安全、范围和对抗性只读评审；已直接修正“每次必建 draft”与 exact duplicate 的冲突，以及 U14/U15 文档更新时间冲突。其余需要确认的技术补强和产品取舍保留在本次计划交接中，不伪装成已解决事实。
- **验证**：本次仅修改 Markdown 计划、索引和知识日志，未修改 Swift、脚本或打包配置，因此未运行构建/测试；计划落地后的自动、安装和真实设备门禁仍未执行。

## [2026-08-05] plan revision | 收敛重复文件与未发布版本切换策略

- **动作**：再次改写同一实施计划。手机选择列表对重复选择做有界逐块比对，确认相等后只保留一项；手机端删除所有排序交互。Mac 在原子发布时按 SHA-256 和长度合并相同内容，只保留一个 canonical pending item。
- **产品决定**：相同原件不会因成员或日期不同而需要复制，报告 exact dedup 继续以来源内容为权威；成员和日期不进入冲突分支。报告页序只在 Mac 归档确认面调整。
- **切换边界**：App 尚未发布，因此废止上一版计划的 v1→v2 migration、legacy decoder、dual-read、rollback checkpoint 和兼容验收。新 schema 直接替换旧实现；unsupported 旧开发 inbox 只 fail closed 且零 mutation，App/package 不提供 reset 入口，旧开发数据处置不属于产品实现。
- **可靠性与安全补强**：手机比较增加候选数、累计读取量、单调耗时和并发预算，超限回退到上传；Mac 增加 active-session content terminal，避免已 admitted 的晚到 body 在归档/删除后重新入队。失败 attempt 与可重放 terminal 分离，publish/merge/terminal 命中对手机返回完全同形的通用成功结果，receipt/terminal 不持有 blob。
- **实施约束**：U16–U19 作为 compile-atomic cutover wave，不引入临时兼容层或将中间状态作为发布点；U19 完成依赖图切换后运行聚焦门禁，U20 清理并运行完整验收。
- **文档评审**：第二轮产品、范围、一致性、交互、可行性、对抗性和安全评审后，补齐 tentative report-dedup winner 的失败重选、delete terminal 的 admission cutoff、用户取消与 comparison budget abort 的区分，以及 U19 的 production composition 所有权。普通 HTTP、系统 decoder 暴露和无文件字节上限仍是已接受但必须在验收中明确的残余风险。
- **索引**：更新 `docs/index.md`，把计划说明从“迁移”改为“直接替换当前未发布实现”。
- **验证**：本次仍只修改 Markdown 计划、索引和知识日志；未运行 Swift 构建或测试。实施后的并发去重、响应重放、跨存储故障、安装验收和真实设备门禁仍未执行。

## [2026-08-05] implementation | 落地无分组待确认队列

- **动作**：直接替换未发布的 LAN 分组领域、HTTP 路由、手机页面和 Mac 双栏界面。手机现在反复追加独立文件；Mac 展示稳定的待确认 item 队列，支持单选/多选、页序、成员和日期后归档为一份 `.needsReview` draft 或复用 exact duplicate。
- **去重**：手机只在有界逐块比较确认字节完全相同后抑制本地重复选择，超限或读取失败回退上传；Mac 以 SHA-256 + byte count 原子合并相同原件。已经保存到 Mac 的手机条目不阻止之后重新选择同一文件，最终仍由 Mac 权威判定。
- **可靠性**：补齐接收停止后的最终队列刷新、删除跨会话 receipt 收敛、上传取消与 durable publish 竞态、持久化 archive intent 恢复、终态 staging 清理恢复、轮询投影缓存和手机进度合帧。归档只在 Vault 结果持久化或验证存在后清空所选项。
- **测试**：新增文件级 receiver 生命周期、真实 Socket/RSS、canonical item store、预处理失败隔离、归档恢复/清理和 Mac 选择模型覆盖。`scripts/test.sh` 通过：主测试 520 项 / 48 个套件，另有 1 项真实 Socket/RSS 隔离门禁通过；6 项 Vision 为外层沙箱已知限制。
- **门禁**：`scripts/privacy-guard.sh` 与 `scripts/verify-app.sh --lan-prerequisites-only` 通过；`git diff --check` 通过。`scripts/build-acceptance-app.sh` 因工作树不干净按设计拒绝，因此本次 bundle、安装验收和真实手机矩阵仍未执行，不沿用旧 `dist/` 结果。

## [2026-08-06] implementation review | 整理无分组队列并修正跨实例 partial 投影

- **代码整理**：把预览与 OCR 预处理重复的受限 regular-file descriptor 读取收敛为同一内部实现；保留两条调用链原有的超限错误映射和取消语义。
- **竞态修正**：全量并发测试复现了观察 store 在 manifest 未变化时缓存中断上传 partial 统计的问题。屏幕投影缓存现在同时校验受控目录变更与 partial 文件 identity，可在不重新扫描全部稳定对象的前提下识别跨实例 partial 创建、增长和删除。
- **测试证据**：新增跨 store 的 partial 创建、字节增长、取消清理和后续 manifest 变化覆盖；聚焦生产 HTTP 安装探针与缓存测试通过。最终 `scripts/test.sh` 通过主测试 520 项 / 48 个套件及 1 项真实 Socket/RSS 隔离门禁；6 项 Vision 仍是外层沙箱已知限制。`swift build --disable-sandbox`、`scripts/privacy-guard.sh` 与 `git diff --check` 通过。
- **尚未执行**：本条仍是提交前源码证据；正式 bundle 和隔离安装验收需在干净提交后运行，真实手机与人工 OCR/可访问性门禁不因本次结果改变。

## [2026-08-06] acceptance | 完成无分组队列的干净源码本机验收

- **候选构建**：从干净源码 revision `0a66f78` 运行完整 `scripts/verify-app.sh`，release bundle、生产身份、资源、依赖锁、隐私、entitlement allow-list 与 ad-hoc 签名门禁通过；正式 bundle SHA-256 为 `9f0e832f3f18349799c0dd7dd32ade956b17b9db73ee7707344bc469bfd4a60d`。
- **安装验收**：`scripts/run-acceptance.sh` 临时安装随机隔离身份，使用 4 个合成成员和 96 条记录/附件验证生产 executable probe、真实 receiver、流式与中断上传、去重、进程重启、强制终止恢复、检索、canary 扫描和清理；最终 `KLA_ACCEPTANCE_COMPLETE`，扫描命中为 0。
- **签名边界**：正式包仍是 ad-hoc 签名，没有 Developer ID 或 notarization；隔离身份因测试所需的额外 `network.client` entitlement 重新签名，不将其 executable 哈希写成正式包哈希。
- **仍未执行**：正式 `com.kinlogue.mac` App 的人工安装/Launch Services 启动、macOS 14/15 独立机器、iOS Safari/Android Chrome 真实设备、真实 OCR 样本和键盘/VoiceOver 可访问性门禁仍保持未验证。

## [2026-08-06] code/docs | 合并无分组队列重构并恢复中英文覆盖

- **合并**：把 `origin/main` 的无分组待确认队列重构合入本地化分支，保留新的 pending item、单选/多选归档和接收生命周期实现，不恢复已删除的 batch 页面或领域模型。
- **本地化适配**：重新扫描重构后的 `Sources/KinlogueApp`，将待确认队列、报告顺序、接收弹窗、状态/错误分支和无障碍文案接入 `AppLocalization`；补齐中英文静态与类型化插值资源，用户文件名、成员名和局域网地址保持原值。
- **清理**：从 catalog 移除只服务于旧 batch/投递箱界面的翻译和过时的“未命名文件”展示词条；LAN 无效 display name 继续使用平台层语言无关的 `_` 安全回退，不把翻译写入持久化模型。
- **开发规范**：在 `localization.md` 和 `AGENTS.md` 增加重构/合并复扫、ViewModel 错误与无障碍覆盖、动态文案测试、旧 key 清理及 catalog 生成物门禁；`AppLocalizationTests` 新增 App Swift 中文裸字符串扫描和 pending queue 参数化文案回归。
- **审查修正**：源码门禁改为逐个字面量判断，覆盖普通、raw、多行和同一行混合字符串，并把“简体中文”例外收紧为精确匹配；待确认队列错误保存语义状态、读取时按当前语言解析；计数文案补齐英文单复数 variation，单项删除/重复提示改用数量中性措辞。
- **已验证**：本地化、打包与待确认队列 focused tests 共 26 项通过；`scripts/test.sh` 最终通过主测试 543 项 / 50 个套件及 1 项真实 Socket/RSS 隔离门禁，6 项 Vision 为外层沙箱已知限制；首次全量运行中安装 LAN 探针曾因并行依赖启动返回一次 `dependencyFailure`，隔离重跑和随后完整重跑均通过。`scripts/privacy-guard.sh`、catalog 生成物漂移检查和 `git diff --check` 通过。
- **仍待人工验证**：设置页中英文切换、重构后的待确认队列布局、键盘/VoiceOver，以及真实 macOS 14/15 和手机浏览器矩阵仍未执行。

## [2026-08-07] implementation | catalog v3 DICOM 持久化基础

- **动作**：新增独立 DICOM study/fingerprint/index 领域模型与 catalog v3 根；raw UID、日期和自由文本不进入持久 schema。index 区分所有 retained DICOM originals 与可查看 image instances，关闭 attachment/series/instance 图，并在 Vault reopen 时读取并校验 index。
- **安全/兼容**：自定义解码使用 unconstrained coding key 拒绝未知字段，数组在元素解码前限长；UID digest 为 vault-local、domain/version/scope 定义；fingerprint 使用固定 domain/version、unique count 与排序 length-framed canonical identity bytes。历史 v1/v2 迁移到 v3，当前 v3 writer 对 v2 manifest fail-closed 且不修改文件。
- **发布前置**：`Info.plist` 现在声明读 `[1,2,3]` / 写 `3` / `catalog-v3-preparatory`。新增独立的 v3 immutable archive publisher、portable verifier 和真实安装 driver；runtime gate 只接受 exact predecessor 或 archive-bound restricted successor，并用无身份 graph 验证 1 个 viewable + 1 个 inert original、index/fingerprint/opaque UID digests 在普通写入和 rollback 后保持闭合。历史 catalog-v2 公共入口及 archive evidence 不被复用。
- **验证**：主线聚焦回归通过 130 tests / 7 suites；`scripts/test.sh` 通过 601 tests / 55 suites 与 1 项真实 Socket/RSS 门禁，6 项 Vision 为外层沙箱 known issues。`ce-simplify-code` 应用了 2 项复用、3 项质量和 2 项效率改进，并保留了每次从当前 index 字节重新解码的 fail-closed 边界。lint、privacy guard、package graph、脚本语法、plist、LAN prerequisites 和 `git diff --check` 通过。完整 clean-source Xcode bundle、仓库外耐久 archive、基于 exact archive 的 predecessor/successor/rollback Launch Services rehearsal、可选历史 v2 installed fail-closed 探针、真实设备和人工可访问性门禁尚未执行。

## [2026-08-07] acceptance | 完成 catalog v3 exact archive 回滚复演

- **不可变归档**：从 clean revision `17e6c0bacabe3c6d2d236c3341c5cd9f4dbcc2a3` 在仓库和临时树之外发布 `Kinlogue-0.4.0-4`；ZIP SHA-256 为 `7205988a4b6a29ca4fb4b4aef3fe59b13bf58901c11d5b6a82b0cbf8ca70aeb8`。portable verifier 独立复核 `0555` 目录、`0444` payload、metadata/hash、App/Helper entitlement 与逐层签名通过。
- **真实安装链路**：Launch Services 先运行 exact 前驱 seed/reopen-write，再运行 archive-bound `0.4.1` / build `5` 受限后继写入，最后从归档 fresh extract exact 前驱回滚、重开并再次写入。最终 generation 为 `5`，1 study、2 retained objects（1 viewable + 1 inert）、1 series，graph SHA-256 为 `6eafe00fc47a02e165d24877877fd0483fc3d4e79d79f0966f8b16bfa0cda7ea`，清理为 `true`；临时安装、合成资料和进程均无残留。
- **门禁修正**：首次归档在 File Provider 管理目录中被系统把 committed mode 从 `0555` 改回 `0700`，独立 verifier 按设计拒绝。归档器现在只有在发布后 portable verification 通过才报告成功，verifier 在完整验签前后都复核 committed directory 权限；真实 installed runner 又暴露并修复 zsh 同一 `local` 声明求值和只读 `status` 特殊变量问题，均有先红后绿的脚本安全回归。
- **仍未执行**：可选 exact 历史 v2 installed downgrade probe、Developer ID/notarization、macOS 14/15 独立机器、真实 MRI 兼容矩阵和键盘/VoiceOver 人工门禁保持 `notExecuted`；本次只使用无身份合成 DICOM graph。

## [2026-08-07] implementation | 落地 DICOM 文件夹导入与整 study 原子发布

- **实现**：新增固定 `DICOMImportPolicy`/transient state、security-scoped descriptor-relative scanner、同卷 opaque read-only staging、只读 staged-byte allowlist/indexer 和 `DICOMImportWorkflow`。classic single-frame Explicit VR Little Endian MR 经既有隔离 decoder；允许的 SR/encapsulated-document object 只惰性保留。mixed study、unsupported image、同 SOP 不同 bytes、容量或资源超限在 manifest publication 前失败；exact re-import 复用原 study。
- **原子性/恢复**：一个进程内/跨进程 Vault mutation lease 覆盖 receipt→staging→index→objects/index→manifest。durable opaque receipt 在首个 staged byte 前同步，并在扫描前绑定 operation directory device/inode；reopen/pre-import reconciliation 先读取 catalog reachability，保留已采用对象，只回收不可达 journal ownership。staging 清理使用 `openat`/`fstatat`/`unlinkat` 和 identity recheck，symlink/替换时拒绝删除并保留 receipt 重试。
- **测试证据**：先得到缺少 U3 policy/scanner/indexer/workflow/journal 类型的预期 RED；补 hard-crash ownership 测试后又得到缺少 lifecycle import API/ownership parameter 的预期 RED；bounded execution 补强再次先在缺少 control/metrics/duplicate aggregate seam 处 RED。主线程审查又先复现了自定义 frame policy 未执行、惰性对象非法 UID 被接受、cleanup debt 可继续累积 receipt 三项 RED。生成式 220-file stress 与 depth-16 tree 现证明两名 worker、两项 queue、全部 import-owned descriptor ≤ 8 且结束归零、unique-byte I/O、每对象最多三次 managed full read/两次写、peak disk ≤ `2 × uniqueBytes + 256 MiB` 和 queued cancellation < 1s；rename/delete/growth/truncation/replacement、scope denial、held-root rename/symlink replacement、即时重复回收、undefined-length SR 惰性保留均通过。DICOM/PlaintextVault/migration/StorageProcess/package graph 比例回归 113 tests / 7 suites 通过；`scripts/test.sh` 通过 628 tests / 58 suites（6 个既有 Vision outer-sandbox known issues），随后真实 socket/RSS gate 1/1 通过。真实 fixture process 证明 importer 被强制终止后 kernel lease 释放且 successor 回收 staging，并证明 Vault destroy 等待 active import。fault matrix 覆盖 journal/attachment/index/object/manifest，重开仅见完整旧代或完整新代。
- **阶段简化**：`ce-simplify-code` 审查后，索引器改为逐片释放 raw sample、只保留 bounded attributes；Series UID digest 只计算一次；完整 promotion set 在首个 object write 前只同步登记一次，避免每对象重写/fsync 整份 receipt；状态机不再静默吞非法 transition，metrics 不再掩盖重复 close，异常 cleanup 的 operation descriptor 也已闭合。
- **隐私/范围**：所有 fixture 均为运行时生成且无身份；没有读取私有 MRI，没有记录 source path、raw UID、patient/device/free text 或 pixels。README/PRIVACY 的用户可见能力不变：App composition、文件夹 picker、确认 UI、Viewer、正式 bundle/安装验收、macOS 14/15、真实 MRI 和人工可访问性仍未执行。
- **文档**：同步 architecture、domain、storage、import/privacy/testing/index，并新增 [`sources/2026-08-07-dicom-folder-import-contract.md`](sources/2026-08-07-dicom-folder-import-contract.md)。计划正文保持决策记录。

## [2026-08-07] acceptance | 完成 U3 干净源码 bundle 与真实 XPC 复验

- **候选绑定**：从 clean revision `f3d7d17d38d9e8189c1d8657e05b9b9cbae34441` 执行 `scripts/verify-app.sh --require-clean-source`，release build、正式 App/Helper 结构、逐层 ad-hoc 签名、生产 entitlement、主进程 DicomCore 隔离、依赖锁、隐私和 bundle 门禁通过。报告中的 App 内容哈希为 `7effed6a6d3f557fc4d37e3f2c2bf0f393d8816d92c50a8002abc020adacd081`，Helper executable 哈希为 `535c4f1fb3dcf157846ce29c54a3368c858f9257e0b9809cc733c3755d110f82`。
- **真实隔离链路**：`scripts/verify-dicom-xpc.sh --use-verified-app` 复用报告绑定的同一 bundle，通过 raw 无身份合成 fixture 往返、畸形输入拒绝、production Helper SIGKILL、compile-time-only hang watchdog、unified-log canary、strict signatures 和零 runtime socket 检查。
- **执行环境说明**：第一次在 Codex 外层 command sandbox 内构建 Helper 时因其拒绝 Xcode 写用户 cache 而停止；随后在正常 macOS Xcode/launchd 环境对同一 clean revision 完整执行并通过。前一次是执行环境拒绝，不计作产品门禁失败。
- **范围边界**：本次证明 U3 Platform/storage 导入实现可进入正式 bundle，未证明 App picker/review UI 或 Viewer。安装后的用户导入流程、Developer ID/notarization、macOS 14/15、真实 MRI 与键盘/VoiceOver 人工门禁保持 `notExecuted`。
## [2026-08-10] code/docs | 收敛并发说明、回归覆盖与知识库漂移门禁

- **发布边界**：保留无需 Apple Developer ID 的 arm64 ad-hoc GitHub Pre-release 测试分发；没有引入 Developer ID、notarization 凭据或 Apple 账号依赖，也没有删除未来正式分发脚本。
- **回归覆盖**：补充 OCR 日期页脚后的伪表格行隔离、LAN 待确认项删除失败与 stale revision、以及原件预览旋转 90°/270° 后实际 SwiftUI 滚动范围测试；删除失败仍保留条目并显示可恢复错误，确认弹窗只删除快照中的稳定 item ID。
- **并发审计**：为生产代码中的 `@unchecked Sendable` 和 `nonisolated(unsafe)` 邻近记录可复核的锁、actor、event-loop、操作所有权或不可变值不变量；重写并发安全审计，并用机器可校验 inventory 防止声明数量和审计事实漂移。
- **文档维护**：新增 `scripts/verify-docs.sh` 并接入 `scripts/lint.sh`，检查本地 Markdown 链接、从知识入口不可达的孤儿页、发布版本事实、计划状态、过时断言和并发注解；同步 README、项目总览、架构与测试发布页，把已完成的 LAN/DICOM 计划标记为 `implemented`，并修正 DICOM helper 成功生命周期说明。当前测试分发不把 Developer ID/notarization 作为门禁。
- **验证**：文档门禁以临时仓库夹具证明 clean success，以及断链、版本事实漂移、缺少 `SAFETY:` 和符号链接越界四类失败均 fail closed；`scripts/verify-docs.sh`、`zsh -n scripts/verify-docs.sh scripts/lint.sh`、`scripts/lint.sh`、`scripts/privacy-guard.sh` 和 `git diff --check` 通过。最终 `scripts/test.sh --quiet` 通过 793 tests / 75 suites，真实 Socket/RSS 隔离门禁 1/1 通过；较早一次并行全量运行中既有安装 LAN 探针出现一次 `dependencyFailure`，该测试隔离重跑及随后两次完整重跑均通过。6 项 Vision outer-sandbox known issues 保持不变。
- **未执行**：当前工作树不是 clean revision，且本轮没有改变正式 bundle 行为，因此未重跑 `scripts/verify-app.sh --require-clean-source` 或安装验收；macOS 14/15 独立机器、真实手机、真实 OCR/MRI、键盘与 VoiceOver 人工矩阵仍待执行。

## [2026-08-10] acceptance | 完成文档与并发维护后的 clean-source 安装验收

- **候选绑定**：从 clean revision `37bcfcab200d149b7485d7a8d649bbb2081a40d6` 运行 `scripts/verify-app.sh --require-clean-source`；Release App 与 DICOM XPC Helper 构建、bundle/资源、依赖锁、隐私、生产身份、arm64、entitlement allow-list 和逐层 ad-hoc 签名门禁通过。App content-manifest/App executable/Helper executable SHA-256 分别为 `5b7d474a5b7c17d6f7a22e3bc90cb99f046948c8610380f6bb97de0d38b74913`、`91b8384ee7958e610da53934601908d8ca8c0c82c11547779f58db04f1328f18`、`675dfdf5339ce1e65cb082e597ff7e8a9b759bd7de5d4ef30f60f83a07dd911d`。
- **安装链路**：`scripts/run-acceptance.sh` 使用随机隔离身份和无身份合成资料完成 4 个成员、96 条普通记录/附件、真实 LAN receiver、流式/中断上传、重启、强制终止恢复和清理；DICOM fixture 包含 3 个 Series、216 个可查看实例和 1 个惰性对象，完成 648 次 render 与重启后 3 次 render。扫描命中为 0。
- **资源观测**：DICOM cached W/L p95 为 1 ms、foreground p95 为 67 ms、RSS peak delta 为 19,283,968 bytes；最大 2 workers、queue depth 2、6 个 managed live descriptors，每对象最多 3 次 managed full read/2 次写，peak added disk 为 4,026,608 bytes。上述值只代表当前 Mac 与生成式 workload。
- **门禁结果**：报告记录 `automatedOverall=passed`、`installedAcceptance=passed`、`dicomInstalledAcceptance=passed`、`overall=pendingManual`。第一次在受限命令沙箱运行时因无权写 SwiftPM/Xcode 用户缓存而在 Helper 依赖解析阶段停止；正常 macOS/Xcode 环境的同一 clean revision 完整通过，前者不计为产品失败。
- **分发与人工边界**：App 仍为 ad-hoc 签名，Developer ID/notarization 保持 `notExecuted`；macOS 14/15 独立机器、真实 iOS/Android 浏览器、真实 OCR/MRI 和键盘/VoiceOver 人工门禁仍未执行。

## [2026-08-10] fix | 修正时间线选中卡片下边界被相邻记录覆盖

- **根因与修正**：时间线以零间距排列记录卡，原共享卡片样式使用居中描边，2pt 选中描边有 1pt 超出组件边界并被随后绘制的相邻卡片覆盖。共享卡片改用组件内描边，保留原有间距、圆角、颜色、悬停和按压行为。
- **回归覆盖**：`KinlogueThemeSourceTests.cardOutlineStaysInsideAdjacentTimelineRows` 固定时间线零间距与共享卡片内描边契约；测试在修正前按预期失败，修正后通过。
- **验证**：聚焦回归与 `KinlogueThemeSourceTests` 套件通过；`scripts/lint.sh` 通过，`scripts/test.sh --quiet` 通过 794 tests / 75 suites及真实 Socket/RSS 隔离门禁 1/1，6 项 Vision 保持外层沙箱已知限制。`scripts/build-app.sh` 从当前未提交源码成功生成 arm64、strict ad-hoc 验签有效的本机测试 App；该产物不替代 clean-source 发布证据。最终视觉仍由本机安装包人工点击相邻时间线记录确认，键盘与 VoiceOver 门禁不因本修正改变。

## [2026-08-11] fix | 拒绝 stale review 的确认与放弃

- **行为修正**：确认和放弃命令现在携带 review 界面加载或重新识别后冻结的 draft revision；`VaultImportDraftStore` 在同一 catalog mutation 中验证 expected revision。另一 Vault 实例已经把 N 保存为 N+1 时，N 的确认或放弃会返回 stale error，不能删除较新的 review。
- **响应丢失边界**：提交响应丢失后的确认只在 catalog 中存在与本次已构造记录完全相等的 confirmed record、且原 draft 已移除时收敛成功；record ID 继承 draft ID，OCR object ID 在每次 review save 时更新，因而 exact record equality 同时绑定本次预期 draft 的来源、document identity 和最终内容。放弃继续只在 draft 与同 ID record 都不存在时收敛。
- **验证**：两个独立 `PlaintextVault`/`VaultImportDraftStore` 的 stale confirm/discard 聚焦回归 2/2 通过；ImportReviewModel、AppModel 与 LiveAppService revision 传播和响应丢失聚焦回归 23/23 通过。完整测试、安装验收和人工门禁未执行。

## [2026-08-11] fix | 拒绝被日期 API 归一化的无效 OCR 日期

- **行为修正**：`ReportCandidateExtractor` 在 UTC 公历构造日期后精确核对年、月、日；非闰年 2 月 29 日、2 月 30 日和 0/13 月不再被折算为相邻月份或年份的日期候选，合法闰日保持可提取。
- **回归证据**：边界测试在旧实现上分别复现 4 个无效日期被接受，修正后无效日期与合法闰日定向测试通过。完整测试、安装验收、真实 OCR 与人工门禁未执行。

## [2026-08-11] fix | 隔离手机页面旧会话的异步尾部

- **轮询恢复**：失败轮询清除浏览器连接状态时同步释放 `polling` guard；重新输入验证码后，新 session 可以再次发起轮询，不会被旧 generation 的 `finally` 路径永久阻塞。
- **picker 隔离**：文件选择任务在入队时冻结当前 generation，并在开始、逐块重复比较返回、reserve 返回和所有相关状态写入前 fail closed；清除或重新配对后，旧任务及其 catch 不能向新 session 的文件列表、待上传队列或状态提示写入，也不能刷新新 UI 或重置新轮询 timer。
- **回归证据**：三个可执行 Node `vm` 行为测试在旧实现上分别以退出码 4、5 和 3 复现 poll guard、旧 picker 写队列及旧 reserve abort 刷新新 UI；修正后 `LANPhoneAssetSafetyTests` 13/13 通过。完整测试、bundle、安装验收和真实手机矩阵未执行。

## [2026-08-11] performance/fix | 将 DICOM 画布快照移出主 actor

- **主线程边界**：进程共享的 `DICOMCanvasImageRenderer` actor 串行执行拥有式像素复制和 `CGImage` 构造；画布主 actor 只清空或发布快照，缩放、平移等变换继续复用已发布图像。
- **迟到结果隔离**：切片切换、空状态或视图销毁会取消旧任务并推进本地 generation；只有 generation 和 `renderID` 同时匹配的结果可以回填，已取消的同步复制即使完成也不能覆盖新图或空画布。
- **生命周期与验证**：CoreGraphics provider 继续拥有不可变 `CFData`，没有恢复 borrowed provider callback 或新增 unchecked Sendable。旧实现先在缺少异步 renderer/发布 fence 的测试契约处 RED；修正后 7 项 `DICOMViewerInteractionTests`、相关 layout tests、`swift build --disable-sandbox` 和 `git diff --check` 通过。完整测试、bundle、安装验收、真实 MRI 和人工门禁未执行。

## [2026-08-11] performance/fix | 将 PDFKit 打开和当前页栅格移出主 actor

- **主线程边界**：`OriginalDocumentPDFRenderer` 作为进程共享的串行 actor 持有 session 对应的 `PDFDocument`，并在 actor 内完成文档打开、逐页 media box 读取、`PDFPage.thumbnail` 和 PDFKit `NSImage` 到 `CGImage` 的转换；SwiftUI 只接收 `UUID`、页尺寸和不可变 `CGImage`，不再持有 PDFKit 对象。
- **取消与资源边界**：切页或渲染尺寸变化通过 `.task(id:)` 取消旧请求，发布前同时核对 cancellation 与 render key；已经开始的同步 PDFKit 操作不能被强制中断，但完成后会丢弃取消结果，不能覆盖新页。关闭预览会释放 actor session；当前页栅格继续保持最长边 4,000 px 和页缩放最多 5 倍。
- **回归证据**：旧实现先因缺少 async renderer/layout 类型得到预期编译 RED；修正后 valid/invalid PDF、页元数据、当前页 raster、越界页、session release、预取消和像素上限 6/6 通过，`RecordDetailViewLayoutTests` 13/13 通过。完整测试、bundle、安装验收、多页/100 MiB 人工操作和键盘/VoiceOver 门禁未执行。

## [2026-08-11] quality | 完成并发与显示准备优化的全量门禁

- **简化复核**：三路 diff 范围审查未发现可复用替代；将失败草稿确认缓存从可累积字典收敛为单个待确认命令，并合并两条 PDF raster 到 `NSImage` 的重复转换路径。新命令仍跨 confirmation dialog 消失保留冻结 revision，后续 dialog 会原子替换旧命令。
- **全量回归**：首轮 `scripts/test.sh --quiet` 暴露 `RecordEditViewLayoutTests` 在 MainActor 上同步等待异步 PDF 预览的测试假失败；改为异步 layout/yield 等待后，定向编辑器布局 6/6 通过，第二轮完整运行通过 813 tests / 76 suites，6 项 Vision 保持外层沙箱已知限制，独立真实 Socket/RSS 门禁 1/1 通过。
- **静态门禁**：`swift build --disable-sandbox --quiet`、`scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check`、`scripts/verify-docs.sh` 和 `git diff --check` 通过。clean-source bundle、安装验收、真实手机、100 MiB/200 页 PDF、真实 MRI、键盘和 VoiceOver 人工门禁未执行；既有 ad-hoc 测试发布路径保持不变。

## [2026-08-11] integration/review | 合并原始文件导出并恢复并发优化

- **合并与恢复**：把 `origin/main@2a78d38` 合入恢复分支，纳入“导出全部已确认原始文件”能力；随后恢复旧会话中尚未提交的 draft revision、OCR 日期、LAN session generation、DICOM 画布和 PDF 后台渲染优化。代码与测试自动合并，四份当前状态文档按双方事实并集解决。
- **验证**：`swift build --disable-sandbox --quiet` 通过；正常 macOS 权限下 `scripts/test.sh --quiet` 通过 853 tests / 80 suites，独立真实 Socket/RSS 门禁 1/1 通过，6 项 Vision 保持外层沙箱已知限制。`scripts/privacy-guard.sh`、本地化资源检查和 `git diff --check` 通过。
- **待修门禁**：`scripts/verify-docs.sh` / `scripts/lint.sh` 拒绝 6 个来自导出功能的 `@unchecked Sendable` 缺少邻近 `SAFETY:` 不变量、并发审计 inventory 仍是旧值，以及导出计划缺少 `status` frontmatter；本轮 review 不把该失败改写成通过。clean-source bundle、安装验收、macOS 14/15、真实手机、真实 Powerbox/外置卷、100 MiB/200 页 PDF、真实 MRI、键盘和 VoiceOver 人工门禁未执行。

## [2026-08-11] fix/review | 收敛存储路径、LAN 终态与 DICOM 窗口生命周期

- **文件系统边界**：Vault 删除通过已绑定 quarantine descriptor 和 `openat` / `fstatat` / `unlinkat` 清理，不递归进入替换目录。原始文件导出在普通 authority 下绑定目标/work 父目录并用 `renameat` 发布；父目录替换失败会按 inode 清除 work ZIP、item-replacement directory 和新目标 placeholder，同时保留已有目标字节。Powerbox 路径继续使用 `NSFileCoordinator` 的协调 URL 与 Foundation replace/move，避免要求未授权父目录；真实安装后的新建/覆盖保存面板仍需人工验收。
- **LAN 一致性**：归档 durable terminal 只在 staging 清理成功后按 intent/receipt identity acknowledgement；失败 terminal 留到启动恢复，成功 terminal 不再无界累积。删除确认冻结 `(itemID, expectedRevision)`，preview 以 generation + revision 实现 latest-request-wins，切换、关闭、刷新 revision 变化和 whole-Vault lifecycle 都拒绝迟到 payload。
- **DICOM 生命周期**：App-owned Viewer registry 按 study 管理所有独立窗口。单 study 删除、外部 refresh 删除和整库生命周期都先同步清空全部相关窗口像素与请求，再等待 slice service close，最后 dismiss。Review 在 loading/saving/deleting 和仍待确认的稳定状态统一阻止 Escape/交互式关闭；失败加载与稳定已确认 review 仍有关闭路径。
- **门禁与文档**：为导出相关 6 个 `@unchecked Sendable` 补充可复核 `SAFETY:` 不变量，并发 inventory 更新为 `unchecked=49 files=24 dicom=10 core=0 unsafe=2`；导出计划状态、私有 MRI 证据、private-repo ad-hoc 分发边界及隐私附件扩展门禁同步修正。`privacy-guard.sh` 默认拒绝 PDF/JPEG/PNG/HEIC/TIFF，只精确放行 11 个既有 AppIcon 路径。
- **验证**：App 专项通过 LAN 12/12、DICOM Review 5/5、Viewer 17/17、DICOM AppModel 10/10、AppModel 41、VaultDeletion 11、DICOM View Safety 3 和 OriginalExportModel 9；quarantine swap、export parent swap、LAN terminal acknowledgement/recovery 4/4 通过，导出其余故障/取消/同步 case 分组通过。正常 macOS 权限下 `scripts/test.sh --quiet` 通过 863 tests / 80 suites，独立真实 Socket/RSS 门禁 1/1 通过；外层沙箱因禁止 socket bind 的一次失败不计为产品失败，6 项 Vision 保持既有 known issue。`scripts/lint.sh`、`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 通过。
- **未执行**：当前工作树仍有恢复修改且不是 clean revision，未运行 `scripts/verify-app.sh --require-clean-source` 或安装验收。真实 `NSSavePanel` 新建/覆盖、外置卷、macOS 14/15 独立机器、真实手机、100 MiB/200 页 PDF、更多真实 MRI、键盘和 VoiceOver 人工矩阵仍待执行；最近完整 clean-source 安装证据仍绑定 `37bcfca`。

## [2026-08-11] fix/review | 完成全项目 review 修复与终态门禁

- **报告一致性**：`HealthRecord` 增加向后兼容 revision；编辑页冻结 expected revision，真实双 service 竞争下陈旧保存返回 `recordChanged`，不能覆盖其他实例的新内容。所有持久化 catalog generation 统一通过 checked successor，`UInt64.max` 时失败关闭。
- **导入终态**：启动只自动恢复 `.staging` / `.processing` 草稿，`.failed` 仅由用户显式重试。DICOM 取消等待 workflow 的真实终态；manifest commit 后返回成功 study，abort/reconciliation 失败明确报错。可用空间改按 `2S - alreadyStaged + headroom` 计算，最终 publication 不重复计算 staging 已占空间。
- **App 生命周期**：refresh 失败先撤销全部 DICOM Viewer；study 删除、外部移除或成员/日期改变均在发布新 snapshot 前清像素并等待 close。整库删除为 LAN UI 建立不可逆 lifecycle lock + generation fence，拒绝所有已进入异步链路的迟到队列、receiver、预览和 catalog 回写。
- **语言与脚本**：比较页错误和 VoiceOver announcement 保存语义 case，语言切换时重新解析。`run-with-deadline.sh` 在 TERM 前冻结完整 owned PID 集合，并 KILL 其中仍存活、即使已 reparent 的后代；文档门禁同时校验当前测试数量、suite 数和 gate 状态跨页面一致。
- **验证**：定向本地化/比较/deadline 回归通过 21 tests / 3 suites；正常 macOS 权限下 `scripts/test.sh --quiet` 通过 879 tests / 80 suites，独立真实 Socket/RSS 门禁 1/1 通过，6 项 Vision 保持外层沙箱已知限制。`scripts/lint.sh`（warnings-as-errors 完整 debug build）、`scripts/privacy-guard.sh`、`scripts/verify-docs.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 均通过。
- **未执行**：当前工作树不是 clean revision，未运行 `scripts/verify-app.sh --require-clean-source`、正式 XPC/bundle 复验或安装验收。macOS 14/15 独立机器、真实手机、真实 Powerbox/外置卷、100 MiB/200 页 PDF、更多真实 MRI、动态语言下 AppKit canvas VoiceOver 和完整键盘/可访问性人工矩阵仍待执行；最近完整 clean-source 安装证据仍绑定 `37bcfca`。

## [2026-08-11] fix/review | 落实独立终审的兼容性与竞态修正

- **存储与导入终态**：revision 为零的 `HealthRecord` 继续省略 wire key，历史 catalog digest 不漂移；DICOM commit 报错后先释放 lease 并重读 exact proposal，manifest 已发布时收敛为成功。App service 共享 import 终局 task，取消和导入观察者不会在 workflow 完成、catalog projection 未完成的窗口得到矛盾结果。
- **Viewer 与编辑冲突**：registry 在撤销期间拒绝逃逸注册，所有较新 catalog generation 在 snapshot 发布前撤销全部 Viewer；refresh 先锁交互再等待 close。记录 CAS 冲突改为结构化 `.recordChanged`，编辑器保留本地表单并要求关闭后重新打开。
- **脚本与 LAN 证据**：deadline 改用专属 session/process group 和有界 reap，覆盖 TERM handler 晚 fork 与无关进程不误伤；文档数量会绑定完整主测试的真实 summary。LAN lifecycle 增加地址、start、archive 和 multi-delete 四类可控交错回归。
- **最终验证**：测试清单为 893 项，其中正常 macOS 权限下 `scripts/test.sh --quiet` 的默认主套件通过 892 tests / 80 suites，另 1 项真实 Socket/RSS 隔离门禁通过；新增定向回归 137/137 通过。`scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check`、`scripts/verify-docs.sh` 和 `git diff --check` 均通过，release fact 更新为 `passed`。
- **未执行**：当前工作树在提交前有预期修改，未运行 `scripts/verify-app.sh --require-clean-source`、正式 XPC/bundle 复验或安装验收。macOS 14/15 独立机器、真实手机、真实 Powerbox/外置卷、100 MiB/200 页 PDF、更多真实 MRI、动态语言下 AppKit canvas VoiceOver 和完整键盘/可访问性人工矩阵仍待执行；最近完整 clean-source 安装证据仍绑定 `37bcfca`。

## [2026-08-12] fix/review | 拆分文档结构 lint 与测试后证据校验

- **门禁修正**：测试前的 `scripts/lint.sh` 使用结构模式检查 release marker、跨页事实、链接和安全约束；完整 `scripts/test.sh` 在主套件成功后显式启用 evidence mode，并把权限为 `0600` 的真实 summary 交给 verifier。该模式缺少结果文件或 tests/suites 不匹配都会 fail closed，同时避免 `gates=passed` 让 CI 在产生测试证据前自锁。
- **回归覆盖**：verifier fixture 覆盖普通结构模式、evidence mode 无文件拒绝、匹配观测结果通过和数量不匹配失败。deadline 已有独立 session/process group、TERM handler 晚 fork、重分组后代、无关进程不误伤和有界退出回归；LAN 已有 late address/start/archive callback/multi-delete generation 回归，本轮不重复改动。
- **当前状态**：当前源码清单为 900 tests / 80 suites。受限完整运行只因 socket bind、deadline 进程组探测及其依赖的 LAN 验收被外层沙箱拒绝；正常 macOS 权限下的标准主套件和独立 Socket/RSS 门禁尚待执行，因此 release gate 保持 `not-verified`。

## [2026-08-12] fix/dicom | 收敛 manifest 后恢复与 App 取消终态

- **Platform 终态**：DICOM commit 报错后先在本次 mutation lease 仍有效时读取经过 manifest/object/index 验证且跳过 journal cleanup 的终态 catalog，再执行 abort/reconciliation；study ID、fingerprint、index object 与 attachment graph 精确匹配时返回已提交成功，即使 cleanup receipt 仍待重试。未证明提交时保留 cleanup 或 commit 原错误，任务的取消标记不再覆盖独立 I/O 失败。
- **App 终态**：`LiveAppService` 一次性保留刚结束 operation 的 terminal task，覆盖 import API 已返回但 UI 尚未发布结果的取消窗口；新 import、首次消费和后续无关取消按 operation ID 隔离。文件夹选择阶段取消只更新本地模型状态，不消费上一 operation 终态。
- **记录与 Viewer**：记录 CAS 冲突会刷新并返回最新 revision；编辑页保留本地表单、阻止旧 revision 重复保存，并由用户显式 reload 后用最新 revision 生成下一次命令。whole-Vault Viewer fence 贯穿撤销、snapshot publication 和最终 close drain，operation 窗口内出现的新注册也会立即清像素并关闭。
- **回归状态**：manifest 后 cleanup debt、immutable graph、App late cancel、selection cancel、记录 conflict/reload、英文文案和 Viewer operation-window fence 均已覆盖；DICOM/Vault/App/Viewer/本地化/docs 相关集合 136 tests / 10 suites 通过。`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check`、shell 语法和 `git diff --check` 通过。
- **最终验证**：正常 macOS 权限下 `scripts/test.sh --quiet` 通过主套件 900 tests / 80 suites及独立真实 Socket/RSS 门禁 1/1；文档 release fact 更新为 `passed`。当前 working tree 不是 clean revision，正式 XPC/bundle、安装验收、真实手机/MRI/OCR 及键盘/VoiceOver 人工门禁未执行。

## [2026-08-12] docs/review | 收口当前事实、验收账本与 DICOM 文档

- **当前事实所有权**：`docs/index.md` 收缩为路由页，`project-overview.md` 成为产品契约，`acceptance/current-release.md` 成为版本、测试数量、候选身份和发布状态的唯一账本。`scripts/verify-docs.sh` 与 fixture 改为校验这一份 marker，并继续在 evidence mode 对照真实 Swift Testing summary。
- **验收与历史导航**：新增 `acceptance/README.md`、`plans/README.md`，补全 `sources/README.md`；当前 LAN/DICOM 矩阵与历史 feasibility/catalog-v2 记录分区展示。计划、来源和追加日志均保留，没有以精简为名删除原始证据。
- **产品与 DICOM 边界**：产品总览新增核心用户、成功结果和未验证假设；`dicom.md` 统一拥有产品定位、导入、XPC、Viewer 生命周期和支持范围。DICOM 明确为受限辅助能力，不是诊断或通用影像工作站。
- **首发前兼容决策**：记录 current-only 方针：后续代码清理可删除开发期 catalog v1/v2、ordering policy v1 和 rollback 生产路径，但未知版本、未知非空目录与损坏布局仍须非破坏性 fail closed。当前代码尚未完成该清理，文档继续如实记录现状。
- **隐私修正**：用户声明和工程威胁模型统一说明 SHA-256 用于意外损坏检测与本机精确去重，不提供保密、认证、防篡改或防回滚；修正明文保护范围的双重否定。
- **验证范围**：`scripts/lint.sh`、`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、文档 verifier fail-closed 定向测试 1/1 和 `git diff --check` 通过。未重跑完整 App suite、bundle/XPC 或安装/人工矩阵，因此当前账本保持 `automated-gates=not-verified`、`overall=pendingManual`。

## [2026-08-12] refactor/review | 合并 main 并落地首发前 current-only 清理

- **基线合并**：工作分支已 fast-forward 到 `origin/main@2070da9`，纳入 Vault/LAN 冗余工作收敛；既有文档修改在可恢复 stash 保护下重新应用，未覆盖工作树中的用户改动。
- **review 修正**：DICOM 导入取消竞态改用 actor 内部可等待的 cancellation-claim 测试同步点，不再依赖 `Task.yield()` 的调度偶然性；Vault staged report generation exhaustion 回归移入独立测试文件，保持主测试文件规模可读。
- **current-only 存储**：删除 catalog v1/v2 migrator、启动 preflight、旧 fixture 和迁移测试；当前 Vault 只接受 catalog v3，DICOM index 只接受 ordering policy v2。旧开发格式、未知版本、未知非空目录和损坏布局继续非破坏性失败关闭，不自动迁移、覆盖或删除原有字节。
- **发布路径收口**：删除 predecessor/successor/rollback 生产入口、操作脚本和对应脚本安全/安装验收代码；Info.plist 不再复制 catalog、DICOM policy、Vault envelope、LAN enabled 或 release-role 私有标记，bundle 验证改为检查当前真实用途说明、entitlement、composition、资源、XPC、签名、依赖和隐私边界。
- **已执行验证**：DICOM late-cancel 定向回归 1/1、Vault generation exhaustion 定向回归 1/1 通过；文档静态门禁在本条记录后执行。完整 `scripts/test.sh`、clean-source bundle/XPC、安装验收、真实设备/样本、Powerbox 与键盘/VoiceOver 人工矩阵尚未执行，因此当前候选账本保持 `automated-gates=not-verified`、`overall=pendingManual`。

## [2026-08-12] refactor/review | 完成 current-only 清理、终审与源码门禁

- **终审修正**：全量并发暴露的 LAN idle、DICOM transaction gate、编辑页布局和 deadline 脚本用例均确认为测试时序问题；测试改为等待真实失活状态、事件驱动且有界的 transaction 通知、同步验证双栏与表单滚动，以及串行执行会扫描系统进程表的 deadline 套件。`ce-code-review` 唯一验证成立的 finding 是 transaction gate 缺少局部超时，已加入 30 秒取消安全上限和 20ms 失败路径回归。
- **完整自动化**：正常 macOS 权限下 `scripts/test.sh --quiet` 通过当前主套件 864 tests / 81 suites，独立真实 Socket/RSS 门禁 1/1 通过；release fact 更新为 `automated-gates=passed`，整体仍因人工门禁保持 `pendingManual`。
- **静态门禁**：`scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/verify-docs.sh`、`plutil -lint packaging/Info.plist`、改动 shell 脚本语法和 `git diff --check` 均通过；生产源码、脚本和当前文档中已无被删除 migrator、rollback runner、release-role 或 catalog marker 残留。
- **仍未执行**：工作树包含本次未提交修改，clean-source `verify-app`、同一 bundle 的真实 DICOM XPC、安装验收、macOS 14/15 独立机器、真实手机/OCR/MRI/Powerbox、键盘与 VoiceOver 人工矩阵未执行；最近完整安装证据仍不绑定当前源码。

## [2026-08-12] fix/review | 落实独立代码与文档复审意见

- **损坏布局保持不变**：`PlaintextVault` 的完整 inspect 先验证全部对象与 OCR provenance，再恢复 DICOM import journal。可达对象损坏时不会先删除 journal、staging 或其已提升对象；健康 Vault 仍在验证后回收未提交的 DICOM promotion。两条回归分别冻结损坏前后 regular-file snapshot，并证明健康恢复继续执行。
- **测试同步有界**：启动并发测试复用 cancellation-aware `AsyncOperationGate`，移除会无界保留 continuation 的专用 gate；等待 inspect 未开始时在五秒内失败并释放 bootstrap，另以 20ms 用例证明 timeout 路径。
- **文档事实收口**：current-only 非破坏性承诺明确排除先前由用户发起且已持久化有效 deletion receipt 的删除恢复，并由 catalog v2 characterization 证明该 receipt 在版本探测前完成；同时修正 catalog v3 revision、历史 LAN entitlement、架构术语/编号、README 重复与 CI 锚点。
- **验证**：PlaintextVault 31/31、DICOM import 17/17、Live DICOM App 4/4、LiveAppService 41/41 通过；正常 macOS 权限下 `scripts/test.sh --quiet` 通过主套件 868 tests / 81 suites及独立真实 Socket/RSS 门禁 1/1。文档、隐私和本地化门禁通过；最终 lint、diff 与复审在本条后执行。
- **未执行**：提交前工作树不是 clean revision，未运行 clean-source `verify-app`、同一 bundle 的真实 DICOM XPC 或安装验收。macOS 14/15 独立机器、真实手机/OCR/MRI/Powerbox、键盘和 VoiceOver 人工矩阵仍待执行。

## [2026-08-13] fix/review | 完成复审整改与验证闭环

- **复审整改**：最终代码 review 的独立 validator 保留两项可验证 finding。current-release 与 DICOM 当前版本页已补齐 durable deletion receipt 例外；两条共享 startup 并发测试改用 `DEBUG`-only waiter-entry observer 和 cancellation-aware `AsyncOperationGate`，在断言或取消前证明 refresh 已进入 `requireStartup()`，不再依赖固定 `Task.yield()`。Vault 删除并发回归同时接受 lifecycle 在 receiver 启动前后撤销所产生的 `.revoked` / `.sessionEnded` 两种合法终态，仍要求删除等待启动清理且 receiver 最终失活。
- **排除误报**：validator 判定三项不属于本次 diff 的缺陷：非完整读取路径的既有 journal 语义、journal 后续临时项清理顺序和 timeout 分支在打开 inspect gate 后的 bootstrap await。它们未作为本轮修复扩张生产范围。
- **最终验证**：整改后 `LiveAppServiceTests` 41/41 通过；完整 868 tests / 81 suites、独立真实 Socket/RSS 1/1、lint、文档、隐私、本地化、Info.plist 与 diff 门禁在最终提交前重新确认。
- **仍未执行**：clean-source `verify-app`、同一 bundle 的真实 DICOM XPC、安装验收、macOS 14/15 独立机器、真实手机/OCR/MRI/Powerbox、键盘和 VoiceOver 人工矩阵仍待执行。

## [2026-08-13] fix/storage | 在旧格式判定前恢复已授权的整库删除

- **恢复顺序**：Vault 启动访问先核验并恢复 durable whole-Vault deletion receipt，再检查 `vault.marker` 或 catalog 版本；因此用户已授权且绑定 exact inode 的中断删除不会被旧格式分类提前截断。没有有效 receipt 时，旧加密 marker、未知布局和损坏内容仍保持非破坏性失败关闭。
- **回归证据**：marker 专项通过真实 `destroy()` 路径在 durable receipt 后注入中断，再在同一已授权 inode 上放置 `vault.marker`；成对的 fail-closed 回归证明 malformed receipt 会被安全清理，但不会授权删除旧格式根目录或改变 marker 字节。两条定向测试 2/2 通过。
- **验证**：`scripts/test.sh --quiet` 通过当前主套件 870 tests / 81 suites，独立真实 Socket/RSS 门禁 1/1 通过；本次未重跑 bundle/XPC、安装验收或人工门禁。

## [2026-08-13] test/release | 完成当前源码本机构建与隔离安装验收

- **候选身份**：从 clean revision `cdf5268b38747016f5a73ac622a3807a1dd31a81` 在 macOS 26.6.1 / arm64 / Xcode 26.6 / Swift 6.3.3 构建 0.5.0 (5) ad-hoc bundle；content-manifest SHA-256 为 `6c71faf18eb63be8486f9c5651f6ae402f6a530f78fd52d9eae9e66b7978537e`，正式 executable SHA-256 为 `bd95ca79d6f706cbd458b8cbb0b4d10e4caf83f1bbcc5308f3c63cc40c231a62`。release build、bundle、App/XPC 签名、entitlement、资源、依赖锁和隐私门禁通过。
- **安装验收**：随机隔离身份短暂安装到当前用户 Applications 后，4 个合成成员、96 条记录/附件、LAN receiver/拒绝路径/重启/强退、DICOM 3 Series/216 可视对象/648 slice workload、删除与清理全部通过；安装 App 已按 run ID 与 directory identity 删除。报告 OCR、真实样本、真实手机、macOS 14/15 独立机器、键盘与 VoiceOver 未执行。
- **XPC 阻断**：同一最终 bundle 的 standalone `verify-dicom-xpc.sh --use-verified-app` 连续三次在 crash case 返回 `expectedFaultDidNotOccur`。round-trip 可以启动，但 probe 的 512 次 decode 在监控进程的外部 SIGKILL 影响请求前完成，因此本候选不能宣称 crash containment 门禁通过；安装 DICOM workload 通过不覆盖此失败。

## [2026-08-13] fix/test | 将 standalone DICOM XPC crash 门禁改为确定性握手

- **根因与 RED**：旧门禁以 10ms 轮询 Helper PID，再试图在 512 次短解码期间发出外部 `SIGKILL`；快速机器会先完成全部解码，连续三次得到 `expectedFaultDidNotOccur`。新增打包边界契约先证明旧实现没有 crash control、请求提交 observer、test-only 连接复用和原子 marker 创建。
- **确定性修正**：probe 先在仅由 `KINLOGUE_DICOM_XPC_CRASH_PROBE` 编译条件启用的复用连接上完成 warm-up；脚本确认 exact host-owned Helper 后 `SIGSTOP`，以 `noclobber + umask 077` 原子发布 `crash-armed`，并只在同一连接第二次请求已经调用 XPC API 后接收 `crash-request-started`。脚本随后向相同 PID 发 `SIGKILL`；客户端必须在两秒内归一为 interrupted/unavailable，最后用默认生产 transport 的新连接完成真实像素解码。默认 App 构建不包含 observer 或复用连接行为。
- **安全与失败路径**：控制目录必须位于私有 `/private/tmp/kinlogue-dicom-xpc-probe.*`，目录和 marker 均校验当前 uid、权限、类型与链接数；脚本只终止 executable identity 精确属于该 probe host 的 Helper，trap 会清理仍处于 STOP 的测试进程。任何握手、身份、恢复、日志、签名或 socket 检查失败都会 fail closed，并输出 probe 诊断。
- **验证**：最终实现的完整 `scripts/verify-dicom-xpc.sh` 连续三次通过 signatures、raw round-trip、外部 crash containment、恢复解码、compile-time hang watchdog、unified-log canary 和 zero runtime sockets；`DICOMPackagingBoundaryTests` 7/7、普通非 probe `KinlogueDICOMXPCProbe` build 和脚本语法通过。最终代码在 Swift Testing 并行宽度 4 下通过源码主套件 870 tests / 81 suites与独立真实 Socket/RSS 1/1；lint、文档、隐私、本地化和 diff 门禁再次通过。当前工作树未提交，故这些通过尚未替代 `cdf5268` 的 clean-source 候选身份。

## [2026-08-19] refactor/performance | 全仓 current-only 精简与启动/OCR 去重

- **同步与审计**：工作树从 `origin/main` fast-forward 到 `3828945` 后，按复用、质量和效率三个维度复核全部生产源码、测试、脚本、打包与 CI，并对照 Swift.org / Apple 官方 API、并发、SwiftUI 状态、性能和 App Sandbox 指南。没有把语义不同的 LAN sink、流式 digest、DICOM 小端读取或 crash gate 强行抽象为共享 helper。
- **运行时优化**：Vault 启动新增一次性“全对象验证并返回同一 catalog”入口，自动恢复直接消费该 catalog，只在恢复后读取一次最新 UI 快照；非空资料库不再先 `inspect` 丢弃 catalog、再由恢复枚举重复解析。PDF 扫描页在一次 extraction 内只查询一次 Vision revision 的受支持语言，保留原有双语、单语与默认 fallback 顺序。
- **状态与 API**：导入确认和资料库删除错误改为语义 case，语言切换后不残留旧语言；来源字段由字符串 key 改为 enum；删除 `LiveAppService` 与协议默认实现重复的 DICOM viewer 方法。
- **current-only 结构**：SwiftPM 只发布 `Kinlogue` App product，Core/Platform 继续作为内部 target；删除已被生产 LAN 替代的 feasibility host、专用 entitlement、构建分支与测试，以及和 GitHub Actions 重复的 Codemagic 配置/安装脚本。历史 LAN/CI 证据保留并标记为 archive。
- **验证**：`scripts/test.sh --quiet` 通过 868 tests / 80 suites和独立真实 Socket/RSS 1/1；`scripts/lint.sh`、`scripts/privacy-guard.sh`、package 图、LAN prerequisites、shell syntax 与 diff 检查通过；dirty-source `scripts/build-app.sh` 成功生成并签名包含 DICOM XPC Helper 的 Release `.app`。clean-source `verify-app`、standalone DICOM XPC、安装验收以及真实手机/OCR/MRI/Powerbox、macOS 14/15、键盘/VoiceOver 人工矩阵未执行。
## [2026-08-19] plan/backup | 确定同步目录加密备份与整库恢复计划

- **产品边界**：首版由用户选择普通目录、网盘客户端同步目录、外置盘或已挂载 NAS 的父目录，Kinlogue 在其中创建专用 repository；不接阿里云盘/百度网盘 API，不新增网络客户端、iCloud、CloudKit、账号或多设备同步。UI 只证明目标目录中的本地恢复点已经回读验证，不声称云端上传或远端保留数量。
- **用户控制**：Settings 规划自动备份开关、默认 5 且可调 2–30 的保留数量、立即备份和恢复入口。自动备份默认关闭，仅 App 运行期间按 5 分钟静默与 24 小时最小间隔执行；清理晚于新点验证并增加 24 小时安全宽限。
- **恢复与安全**：每个恢复点规划为自包含、不可变、分块认证加密文件，覆盖 exact Vault + durable LAN inbox 状态；恢复密钥独立于原 Mac，Keychain 只作本机便利。恢复先在私有同卷 staging 完整验证，再以 durable receipt 保护 whole-root activation，并要求重启。
- **当前状态**：新增实施计划与导航，不代表代码、bundle entitlement、隐私声明或发布能力已经改变。Keychain signing、bookmark、directory exchange、真实 File Provider 和 clean-Mac restore 仍是实施前/发布前门禁；本次未运行代码或安装验收。

## [2026-08-19] probe/backup | 完成备份能力 U0 探针并命中 Keychain 停止条件

- **隔离实现**：storage process fixture 新增仅测试可达的备份能力入口，复用现有 Vault mutation process lock，覆盖 Data Protection Keychain、security-scoped bookmark、whole-root activation fault matrix、真实并发 writer fencing 与 2 GiB 分块测量；production App composition 和 entitlement 未改变。
- **实装结果**：当前 macOS 26.6.1 ad-hoc sandbox App 的签名 entitlement、whole-root activation 和 64/256/1024 KiB 分块均通过；选择 256 KiB，固定 golden SHA-256 为 `25d744f5f364f17b6985f761a89fd3b21ad5b25895a3c231037115f9dafd6bbd`。Data Protection Keychain `SecItemAdd` 返回 `errSecMissingEntitlement`，因此 overall 为 `blocked`，按计划停止 U1–U8，未采用 legacy Keychain 降级。
- **审查修正**：补齐 committed cleanup 内部崩溃幂等、真实取消 request-to-exit 测量、固定 golden vector、当前 OS 状态语义、Keychain/upgrade 残留清理、并发 safety inventory 与真实 writer 激活门禁；独立验证驳回了仅按文件行数强制拆分的偏好性建议。
- **自动化证据**：完整 Swift 主套件通过 877 tests / 83 suites，`swift build --disable-sandbox`、`scripts/privacy-guard.sh`、focused backup/package graph tests 与 `git diff --check` 通过。`scripts/lint.sh` 和 `scripts/test.sh` 的文档收尾仍被未跟踪统一计划与旧版 verifier 要求 `status:` 的契约冲突阻断；没有以进度字段污染统一计划。
- **仍未执行**：交互式 Powerbox bookmark/stale refresh、Keychain locked、Developer ID/provisioned signing、macOS 14/15、真实阿里云盘/百度网盘目录与生产备份/恢复均未执行或未实现。

## [2026-08-19] plan/backup | 将备份密钥架构改为无 Keychain 方案

- **用户决策**：在 U0 的 Data Protection Keychain 路线命中停止条件后，用户选择不使用 legacy Keychain 或每次启动输入恢复密钥。自动备份改为只持有固定的恢复公钥和 app-private 设备签名身份；恢复 seed、恢复私钥和 checkpoint DEK 不落盘。
- **密码与身份计划**：最低 macOS 14 使用系统 CryptoKit HPKE 封装每个 checkpoint 的 fresh DEK，bulk payload 使用 256 KiB AES-GCM frame；恢复 seed 以域分离 HKDF 派生恢复签名根和 HPKE 接收根，由恢复根签发 backup-set descriptor 与 device authorization。同步目录中的公钥不能覆盖本机 pinned descriptor，设备签名私钥可导出且不能远程撤销的威胁边界已明确写入计划。
- **恢复与保留计划**：checkpoint 创建期用临时 DEK 完整解密验证并写入不含秘密的本机 witness；重启后的公开扫描只能验证 trust chain、签名 footer 与完整 ciphertext commitment，无当前 writer epoch witness 的文件不能支撑删除。真正恢复始终重新执行 HPKE/AEAD 和图验证；恢复/删除以 typed intent、stable fence/epoch 和 forward/rollback receipt 先撤销旧 writer，再交换或删除 Vault，恢复后保持备份未配置。
- **深挖边界**：序列号只作排序与 history-fork 检测，重新注册看到的 `max+1` 不是全局新鲜度证明；seed-only restore 只能选择当前可见点。复制的设备 signer 可制作内容任意但授权签名有效的新 checkpoint，因此疑似泄露只能用全新 seed/set 隔离，不能把 re-enrollment/reset 写成撤销。敌对目录叶类型/父目录替换、pre-auth parser 预算、pending enrollment CAS、candidate-bound release evidence 与无远端 kill switch 的 fail-safe disable 均已进入计划门禁。
- **当前状态**：本次只原地修订统一实施计划、导航和计划日志，不代表生产备份/恢复、entitlement 或隐私承诺已经实现。现有 U0 Keychain probe 仅是带 provenance 的历史 architecture evidence，需先改写为 bookmark、严格 0700/0600 本机 identity、public-only/seed-only crypto profile 与 whole-root activation 四项门禁；Developer ID/provisioned、macOS 14/15、真实网盘双端传播和 clean-Mac restore 仍未执行，任何 release-blocking `notExecuted` 均为 public release NO-GO。

## [2026-08-19] plan/backup | 收敛文档审查开放项

- **状态与恢复准备度**：用户确认“本地恢复点已验证”不升级为异机防丢失承诺；同机普通目录持续提示本机丢失风险，第三方目录显示网盘同步未知。用户可见秘密统一称恢复码，它编码原始 256-bit recovery seed；首次配置要求独立保存确认，并提供不激活、不改 Vault 的恢复码验证入口。
- **自动化与容量**：自动备份持久化 first-observed/due 和最近覆盖时间，短会话或退出不重置 quiet period，后续启动必须 catch-up 或显示可操作失败。Settings 规划单份/N份/额外 work 空间估算；U0 在实现格式前冻结代表性普通目录/File Provider 发布语义、最大 bytes/objects、wall-clock 和 target/staging 空间公式，失败即修订架构或收窄目标。
- **恢复与门禁**：restore 在首个明文 staging byte 前持久化 root-external preflight receipt，取消、失败和启动只清理 exact identity，歧义时隔离。生产与非验收组件继续禁止 `network.client`，现有 run-scoped acceptance App 的 loopback test-only 例外单独记证且不能充当 production evidence。
- **复核机械修正**：恢复状态图补齐认证、staging 和 strict validation 三个确认前取消路径，并统一进入 receipt-bound cleanup/隔离终态；U0 sequencing改为明确列出五项门禁，2 GiB证据改称DICOM/object seam，256 KiB保持唯一bulk chunk上限。
- **当前状态**：本次只更新统一实施计划、计划目录与追加日志，没有实现生产备份/恢复或改变正式 bundle；代码和安装验收未运行，原 U0 结果仍仅为历史 architecture evidence。

## [2026-08-19] probe/backup | 完成无 Keychain U0 改写并按证据停止

- **隔离实现**：测试 fixture 移除 Security/Keychain 依赖，增加严格 0700/0600 的 app-private 设备身份、CryptoKit HPKE/AES-GCM 合成路径、目录 publication/capacity preflight、security-scoped bookmark、whole-root activation fault matrix、真实 writer fencing 与 2 GiB 分块探针。production App composition 与 entitlement 未改变。
- **失败关闭修正**：设备身份在生成私钥前检查父目录权限，并拒绝 pinned recovery public key 替换；目录 `fsync` 返回不支持时不再当作成功。installed runner 对子进程和 fixture 响应增加上限，证据绑定升级后的最终 bundle，并停止输出完整本机报告路径。
- **证据语义**：报告把底层 mechanics/preflight 与完整 proof 分开。当前身份、crypto、private-directory publication、capacity preflight、activation mechanics 和 256 KiB chunk 通过；public-only/seed-only 独立进程隔离、敌对目标 identity binding、exact Vault + durable inbox reopen、真实普通目录/File Provider、最坏数据集与恢复容量仍为 `blocked` / `notExecuted`，不会被合并成绿色 overall。
- **自动化结果**：`BackupCapabilityProbeSourceSafetyTests` 4/4、`BackupCapabilityActivationProbeTests` 9/9、`PackageGraphVerifierTests` 10/10、shell syntax 和 `git diff --check` 通过。macOS 26.6.1 ad-hoc installed probe 生成 `architectureEvidence`，`overall=blocked`；证据 JSON 未发现完整用户、Library、Applications 或临时目录路径。
- **停止条件**：U0 五项门禁尚未全部证明，按统一计划停止 U1–U8。交互 Powerbox/bookmark、真实阿里云盘/百度网盘等 File Provider、20,000 objects / 2 GiB 的备份与恢复耗时、Developer ID/provisioned、macOS 14/15 和 clean-Mac restore 均未执行；生产端没有新增备份、自动备份、保留数量或恢复入口。

## [2026-08-20] fix/app | 修复设置操作列与恢复文件选择器

- **设置布局**：备份目录按钮加入与语言、原始文件导出和删除操作相同的 220pt 左对齐控制列，宽卡片中的右侧操作不再因标签 intrinsic width 而错位。
- **恢复入口**：`.kinloguebackup` 文件选择器从正在呈现恢复 sheet 的外层 `AppShellView` 移到 `RestoreBackupView` 自身；恢复码校验、security-scoped access、完整验证和二次替换确认链路保持不变。
- **回归证据**：现有设置/视图安全测试先在控制列数量和恢复 importer presentation owner 上失败，修复后 2/2 通过；相关 App/恢复/本地化回归 35/35、SwiftPM build、文档、本地化、隐私与 diff 门禁通过。完整 Xcode Release `.app` 和 DICOM XPC Helper 构建、ad-hoc 签名及 bundle plist 验证通过；实际指针点击、Developer ID、notarization、macOS 14/15 和真实网盘传播仍未执行。

## [2026-08-20] fix/ui | 将设置操作统一到右侧基线

- **设置布局**：语言、备份目录、原始文件导出和删除继续使用 220pt 操作列，但由列内左对齐改为右对齐；立即备份、在访达中显示、重新选择目录和恢复入口沿卡片右内边距排列，按钮仍按文案使用 intrinsic 宽度。
- **回归证据**：布局源码契约先证明旧实现的控制列与备份/恢复动作仍偏左，随后验证四个固定操作列和两个动作区域均使用 trailing alignment；设置/本地化回归 28/28、warnings-as-errors build、文档、本地化、隐私和 diff 门禁通过。完整并行源码运行通过 992/993，唯一失败为安装式 LAN 探针的一次 `.dependencyFailure`，该项隔离复跑 1/1 通过；本条不把两次运行合并宣称为一次完整全绿，clean-source bundle 与实际界面证据单列如下。
- **本机安装验收**：clean revision `8c7f381` 的 Release App、DICOM XPC Helper、ad-hoc 签名、bundle、entitlement、依赖与隐私验证通过，安装 executable SHA-256 为 `8c6169e0006ec8e66e5b2aecbbbed8960dd26b428b46ad2674b8d9d208b48414`。实际打开当前用户安装包进入设置页，语言、保留数量、立即备份/访达、恢复、导出和删除控件的右边缘一致；私密界面截图不进入仓库。Developer ID、notarization、macOS 14/15 与键盘/VoiceOver 人工矩阵仍未执行。

## [2026-08-29] docs/readme | 在项目首页加入合成数据产品预览

- **首页预览**：README 标题区新增一张中文产品截图，直接展示家庭成员、健康记录时间线、已确认字段和原件预览，并以图注和替代文本明确说明内容全部为合成示例。
- **隐私边界**：截图来自随机隔离的 acceptance bundle；可见成员、记录字段和所选 PDF 原件均替换为无身份、无医学事实的示例内容，没有读取或复制正式资料库、真实病历、私有路径或凭据。隐私门禁仅按精确路径与固定 SHA-256 放行这一个已复核图片，替换同名文件仍会失败关闭。
- **验证范围**：基础源码的 Release App、DICOM XPC Helper、ad-hoc 签名与 bundle verification 在截图前通过；隔离资料库成功加载 4 个合成成员与 96 条合成记录。README 改动不改变产品行为；精确媒体白名单的定向回归 1/1、文档、隐私与 diff 门禁通过。完整源码套件未因本次文档改动重跑，真实设备、真实样本、键盘和 VoiceOver 人工矩阵未执行。

## [2026-09-08] fix/architecture | 全项目审查与状态交接修复

- **范围与基线**：以公开 `main@9b4f2194a3c0b80b5926b79c45bc417eeaeceaa5` 为基线分域审查 Core、Vault/OCR、备份恢复、LAN/手机页面、App、DICOM/XPC 和发布脚本。上游已解决的问题不重复计入；14 项核实缺陷及外部一手实践见 [架构审查](architecture-review-2026-09-08.md) 与[来源笔记](sources/architecture-review-practices-2026-09-08.md)。保留现有分层、不可变对象和独立 XPC，不新增依赖或持久化格式。
- **数据与生命周期**：归档最终清理前复核目标原件与 OCR，损坏副本不授权移除完好 inbox；整库恢复复用 App/LAN/Viewer 撤销并等待实际 preparation 取消；备份以 writer 回读验证完成时间评估保留和成功状态，暂停后的时钟检查不使用过期事件时间。
- **资源与交互**：重新识别逐来源快照，继续检查草稿 revision；并发 LAN admission 包含在途预留；手机去重在异步比较后重验候选；刷新同步选中详情，OCR/确认时禁用核对表单。
- **DICOM 与发布**：非阻塞 descriptor 打开拒绝 FIFO 替换；接受合法奇数像素 padding；Helper 的有界独立副本写入前 unlink，异常退出由内核回收。正式分发脚本按内到外重签和验证嵌套代码，打包器不再自行宣称全 workflow 门禁通过。同步修正具名临时副本、仓库 private 和发布证据字段的过时文档。
- **已验证**：聚焦回归 191 tests / 22 suites 通过；真实 `scripts/verify-dicom-xpc.sh` 通过当前未提交工作树的 Release 构建、ad-hoc 签名、像素 fixture、外部 SIGKILL、hang watchdog、日志 canary 与零 runtime socket。新归档、大文件 OCR 和预留上限回归已核对旧实现红灯、修复后绿灯。
- **完整门禁**：macOS 26.6.2 / arm64、Xcode 26.6 / Swift 6.3.3 上 `scripts/test.sh` 退出码 0，主清单 994 tests / 91 suites 与账本匹配；13 项独立 XCTest、验收扫描、33 项跨进程存储、大小写别名锁、18 项 DICOM 导入、安装式 LAN HTTP 探针与真实双流 RSS/背压隔离门禁均通过。`scripts/lint.sh`（warnings-as-errors 和 package graph）、`scripts/privacy-guard.sh`、`scripts/verify-docs.sh`、本地化检查与 `git diff --check` 通过。
- **证据边界**：上述验证在提交、push 和创建 PR 前完成；本机工作树的通过不升级为 clean-source 发布候选。`verify-app` 的 clean-source 绑定、安装验收、真实手机与私有样本、macOS 14/15 独立机器、Powerbox/网盘/外置卷、键盘/VoiceOver、独立密码学审计以及真实 Developer ID/notarization 在本次审查中未执行。
- **交付整理**：按用户要求将修复整理为数据与异步状态、DICOM、发布校验与审查记录三个提交组；收紧 staging 清理措辞，移除索引中残留的 private 候选包描述。提交不自动改变候选验收状态。

## [2026-09-11] fix/readme | 同步公开 main 并补齐截图历史校验

- **合并**：产品预览分支合并公开 `main@5a5e32d`，保留双方追加日志与上游实现；不更新 private 仓库。
- **历史门禁**：将已审查的合成截图精确路径与 SHA-256 加入历史媒体清单，修复仅当前树放行、reachable history 仍拒绝的问题；复用现有回归覆盖截图被替换后恢复仍拒绝，不扩大目录白名单。
- **验证**：当前 Mac 编译与定向脚本安全回归 8/8 通过；当前树和两侧公开历史隐私、文档、shell 语法与 diff 检查通过。完整 CI 待推送后执行；完整本机套件、发布 bundle 和人工设备矩阵未重跑。

## [2026-09-16] compatibility | 最低系统提高到 macOS 26

- **决策与范围**：用户明确以个人自用为主要场景，停止支持 macOS 26 以下版本。SwiftPM 使用 `.macOS("26.0")`，保持 Swift tools 6.1 声明；主 App/Helper plist、Helper 四个 Xcode build configuration、bundle verifier 和 XPC probe host 均统一为 26.0。资料库与备份格式不变。
- **验收与文档**：安装、候选打包、正式分发和 backup capability probe 的当前系统字段改为 macOS 26/27；同步既有 source-safety 测试。README、Agent 环境说明、当前专题/候选矩阵、索引和决策页同步。历史计划、来源笔记、已绑定旧工件的说明和旧日志保留原值，不将旧证据转记为当前构建已通过；当前版本事实仍由候选账本维护。
- **验证**：macOS 27.0 / Xcode 27.0 上，设置可写临时缓存后 `swift build --disable-sandbox --build-system native --product Kinlogue` 成功；`xcrun vtool -show-build` 确认可执行文件 `minos 26.0`、SDK 27.0。`swift package dump-package`、`zsh scripts/verify-package-graph.sh`、`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`git diff --check` 通过；额外核对两个 plist、四个 Helper deployment target、SwiftPM 平台和相关脚本语法一致。纯平台配置不新增业务单元测试，以配置与 Mach-O 验证作为替代证据。
- **阻塞与未执行**：`swift test --disable-sandbox --build-system native --filter BackupCapabilityProbeSourceSafetyTests` 在现有 `EncryptedBackupContainerTests.swift` 的边界参数 `@Test(arguments:)` 宏类型检查超时，尚未执行目标用例。主程序仍有先前发现的 `OriginalExportModel` 捕获警告；native build system 已被工具链标记弃用，本轮仅用作诊断构建。此前默认构建因本机缺少 Metal Toolchain 失败，因此完整默认构建、warnings-as-errors lint、正式 bundle/XPC、完整测试、macOS 26/27 安装和人工流程均未在本轮通过，候选状态不提升。


## [2026-09-16] compatibility | 完成 Xcode 27 构建与运行链路适配

- **实现范围**：延续 macOS 26+ 决策，修复 `OriginalExportModel` 的隐式强捕获警告及备份边界测试参数宏的类型推断超时；报告复核和记录多行编辑器关闭系统写作工具，手动编辑、撤销与来源确认门保持不变。布局回归允许系统 Picker 增加内部代理控件，仍检查所有观测控件非空且完整可见；该观测不替代键盘/VoiceOver 人工验收。
- **工具链与打包**：安装本机缺失的官方 Metal Toolchain，清理 xcrun 旧定位缓存；构建脚本在参数校验后检查 Metal，不自行安装。Swift Build 的 target 级 XCTest bundle 和独立测试进程需要两处适配：选择已知 bundle 布局，且每个主测试分片只包含一个 target。精确数量、无遗漏/重复和超时监督均保留。资源打包接受平铺与 `Contents/Resources` 两种已知布局，拒绝符号链接，将 Platform metadata、LAN 页面、ZIPFoundation 隐私清单和本地化整理成既有最终包布局，未放宽资源白名单。
- **CI 与文档**：三个测试分区均加入 `xcode-27` public-preview runner，macOS 26 继续作为阻塞基线，27 预览 job 暂不阻塞；远端 CI 尚未运行。同步测试与发布、转录、设计、索引和当前候选证据页；资料库、备份格式和隐私承诺不变。
- **回归证据**：写作工具、按 target 分片与资源目录夹具均先观察旧实现失败，再验证修复通过。macOS 27.0 / arm64、Xcode 27.0 上完整 `scripts/test.sh` 退出码 0，主账 994 tests / 91 suites 与实际汇总一致，另行隔离的 13 项 XCTest、验收扫描、33 项跨进程存储、大小写别名锁、18 项 DICOM 导入、安装式 LAN HTTP 和真实双流 RSS/背压门禁通过。此后新增的资源布局适配以 51 tests / 5 suites 的发布、本地化、LAN/DICOM 包边界回归及真实 Release/XPC 验证覆盖，未将前一轮完整测试冒充最终打包改动后的完整复跑。
- **构建与产物**：`scripts/lint.sh` 的默认 Swift Build、warnings-as-errors 和 package graph 通过；`scripts/verify-dicom-xpc.sh` 在最终工作树通过 Release App/Helper、ad-hoc 签名、raw fixture、外部崩溃、hang watchdog、日志 canary 和零 runtime socket。独立核对最终资源精确白名单、`codesign --verify --deep --strict`、App/Helper plist 与 Mach-O 的最低系统 26.0，并用 Foundation 实际加载包内 LAN 页面资源。文档、本地化、当前树隐私和 diff 门禁通过。Xcode 报告本机 iOS CoreDevice/CoreSimulator 组件版本旧，但 macOS 构建与 XPC 验证成功；未额外修改模拟器组件。
- **证据边界**：所有改动未提交、未 push，未发布或覆盖用户安装。`verify-app.sh` 按设计拒绝 dirty-source，不绕过 clean-source 门禁；候选仍为 `not-verified` / `pendingManual`。macOS 26 独立机器、26/27 安装与重启、真实手机/OCR/DICOM 私有样本、Powerbox/网盘、键盘/VoiceOver、Developer ID 和 notarization 未在本轮验证。历史日志中的旧阻塞保留为点时记录，由本条后续证据说明已解决范围。
- **交付整理**：后续按用户要求复核本轮代码、测试、配置和文档，作为一个 macOS 26+ / Xcode 27 适配提交保存；没有新增行为修改。上述未提交状态描述验证发生时的工作树，提交本身不提升发布候选状态，也不触发 push、安装或分发。


## [2026-09-16] dependencies | 同步升级 DICOM-Swift 1.5.0 并复验隔离边界

- **范围**：在 macOS 26+ 适配提交之后，按用户授权处理 PR #9 的完整依赖链。Root manifest、Helper Xcode project 与双方锁文件同步为 exact DICOM-Swift 1.5.0 / `8f3605a33ed070160b4e023eacd87f32eae8e913`；新增 J2KSwift 11.0.2、JLSwift 0.9.0、JXLSwift 1.4.0、CompressionFamily 1.0.1，已有其他 pin 不变。最低可用编译工具链说明同步为 Swift 6.2+；主 Package language mode 仍为 Swift 6。
- **锁定与打包**：发布前置校验把 Helper 七项依赖的 URL、version、revision、唯一性、总数和 root 一致性作为明确白名单。回归执行真实校验片段，覆盖 revision、URL、root 漂移、缺失、重复、额外和畸形条目。上游 package 更名导致资源变为 `DICOMSwift_DicomCore.bundle`，新增 `J2KSwift_J2KMetal.bundle`；构建、正式分发和 XPC 探针全部逐项签名并验证三个明确的嵌套资源，未用任意目录扫描放行新代码。主 App 链接门禁新增 codec 模块拒绝项。
- **许可证**：MIT 的 J2KSwift/JXLSwift 与 Apache-2.0 的 CompressionFamily 均按锁定 revision 核对。JLSwift 0.9.0 缺少 LICENSE；上游随后明确采用 Apache-2.0，许可提交与标签的完整生产 Sources tree 哈希相同，按该不可变依据保留 LICENSE 条款、NOTICE 和来源说明。未把上游第三方 CharLS 测试夹具带入生产包。详情见[固定来源核对](sources/dicom-swift-1.5.0-dependency-review-2026-09-16.md)与 [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)，声明哈希校验同步更新。
- **兼容性与范围**：没有修改应用层解码算法、IPC、资料库或现有 DICOM 可接受范围；仍只允许 classic single-frame、Explicit VR Little Endian、灰度 MR。压缩、多帧、PACS/JPIP、网络查询与 daemon 没有启用。macOS 27 / Xcode 27 / arm64 上定向回归 214 tests / 26 suites 通过；最终 `scripts/test.sh` 退出码 0，994 tests / 91 suites 主账和 13 项独立 XCTest、验收扫描、33 项跨进程存储、条件式别名锁、18 项 DICOM 导入、安装式 LAN HTTP 与真实双流 RSS/背压门禁均通过。
- **产物证据**：`scripts/lint.sh`、`scripts/verify-app.sh --lan-prerequisites-only` 和最终 `scripts/verify-dicom-xpc.sh` 通过。Release App/Helper 签名、raw 像素夹具、外部崩溃、hang watchdog、日志 canary、零运行时 socket 通过；另核对真实主 App link map 没有新增 codec、Helper 精确资源清单、两处声明副本和 `codesign --verify --deep --strict`。App 磁盘占用从 33,208 KiB 到 43,884 KiB；Helper 从 6,216 KiB 到 16,892 KiB，约增加 10.4 MiB。首次优化构建新增了 codec 编译工作，未做冷热缓存计时对照，不声称运行性能提升。最终文档、隐私、本地化和 diff 检查通过，独立静态复核无实质问题。
- **交付边界**：本轮改动留在本地工作树，未提交、push、合并或评论 PR #9，未替换用户安装。完整 clean-source 发布验证、macOS 26 独立机器与安装/真实私有样本/键盘/VoiceOver 等人工矩阵未执行；当前候选继续 `not-verified` / `pendingManual`。前一轮 1.3.3 的验证记录保留为历史，不替代本条 1.5.0 的新证据。

## [2026-09-16] build | 统一最低 Swift tools 6.2 声明

- **范围**：`Package.swift` 的 tools 声明从 6.1 提高为 6.2，与已升级 DICOM 依赖的工具链要求及 README 一致；同步 `verify-app.sh` 的精确声明门禁、环境说明和知识库索引。保留 Swift 6 language mode 与 macOS 26 最低运行版本，本机继续使用 Xcode 27 / Apple Swift 6.4。
- **验证**：纯配置调整不新增业务测试，以实际默认 Swift Build 和门禁作为替代验证。`scripts/lint.sh`（warnings-as-errors build、manifest 解析和 package graph）及 `scripts/verify-app.sh --lan-prerequisites-only` 通过；shell 语法、文档与 diff 检查通过。
- **边界**：本轮未重跑完整业务测试或 Release/XPC；前一条完整结果属于调整前的依赖升级工作树。未独立验证 Swift 6.2 编译器、macOS 26 机器或安装/人工矩阵，不提升发布候选状态；改动保留本地，未提交或 push。

- **提交整理**：按用户要求将 DICOM-Swift 1.5.0、双构建依赖锁定、许可证与资源签名、回归覆盖和最低 Swift tools 6.2 声明合并为一个逻辑提交；没有额外业务行为修改。上述未提交描述保留为验证发生时的状态，提交不提升候选验收状态。

- **PR 前文档复核**：修正贡献指南中遗留的 macOS 14+ / Swift 6 环境说明，统一为 macOS 26+ / Swift 6.2+；这是当前索引与构建专题已记录要求的同步，不改变运行行为。

## [2026-09-16] ci | 准备 Xcode 27 runner 的 Metal Toolchain

- **原因**：PR #13 的 Xcode 27 三个分区在工具链检查阶段失败，runner 日志明确报告缺少 Metal Toolchain，编译和测试尚未执行。
- **修正**：各分区先探测 Metal，仅缺失时通过 Xcode 下载官方组件并清理定位缓存，再强制复验；保留下载失败、组件不可执行时的非零退出。补充现有 workflow 断言及环境文档。CI 修正的远端结果待新提交执行，不将本机结果当作 runner 通过。
- **本机验证**：`scripts/test.sh --filter GitHubActionsWorkflowTests` 的 11 tests / 1 suite 通过；直接执行 workflow 的 shell 片段，以合成命令覆盖组件已存在、缺失后成功安装、下载失败、安装后仍缺失四种路径；文档、隐私与 diff 检查通过。

## [2026-09-16] ci | 保持矩阵基线的必需检查名称

- **证据**：PR #13 在 `ded7488` 上六个 CI 分区及 CodeQL 均已通过，但仓库 ruleset 仍要求三个无系统后缀的原有检查名，矩阵默认命名导致 GitHub 保持 BLOCKED。
- **修正**：三个 macOS 26 job 显式保留原名，仅 Xcode 27 使用后缀；不修改远端保护规则、不降低检查范围。更新现有 workflow 回归及构建文档，远端名称匹配由后续 CI 验证。
- **验证**：`scripts/test.sh --filter GitHubActionsWorkflowTests` 的 11 tests / 1 suite、文档与 diff 检查通过；此前 `ded7488` 的本机 clean-source bundle/真实 XPC 及远端双系统完整 CI、CodeQL 成功不冒充新提交已经通过。

## [2026-09-20] ci | 为 DICOM 崩溃探针的恢复请求保留重启余量

- **证据与判断**：PR #13 的 [macOS 26 失败日志](https://github.com/renyijiu/kinlogue/actions/runs/35070491037/job/104710615643) 在正式 bundle 验证后输出 `KLD_DICOM_XPC_FAILED:helperTimedOut`。控制握手及崩溃错误校验已完成，因此该错误来自随后的恢复 decode；若崩溃请求超时，探针会输出 `unexpectedFailureCode`。本机 `launchd.plist(5)` 说明默认重启节流为 10 秒，与原恢复请求 10 秒超时重合；据此判断恢复预算缺少重启余量，远端日志没有单独记录 launchd 的实际调度时刻。
- **修正**：只把独立 XPC 探针的恢复请求预算设为 30 秒；崩溃收敛仍要求 2 秒内失败，恢复仍必须返回精确像素，生产 transport 的 10 秒超时、Helper 的 9 秒硬 watchdog 和 hang 探针不变。不增加重试，不修改依赖或系统节流策略。扩展已有包装边界测试，检查恢复预算与原有时限；不新增测试计数。
- **验证**：恢复预算断言已在旧源码上观察失败；`scripts/test.sh --filter DICOMPackagingBoundaryTests` 的 7 tests / 1 suite 通过。当前 Mac 的 `scripts/verify-dicom-xpc.sh` 通过真实 Release App/Helper 构建、签名、像素夹具、外部崩溃及恢复、hang watchdog、日志 canary 和零运行时 socket；文档、隐私与 diff 检查通过。本次是工作树验证；新提交远端 CI、clean-source bundle、独立系统安装、真实私有样本及人工矩阵尚未验证。


## [2026-10-10] import | 把 Go 预览的字段建议规则移回 Swift

- **背景与依据**：评估后 Swift 版继续作为发布线，Go 预览（分支 `codex/go-native-rewrite`）冻结。本条只移植其 `internal/candidate/candidate.go` 在提交 `cc95d6e` 中按两份版式调整、Swift 尚不具备的规则；参考实现只读，没有新增 Go 代码，也没有改动 Vault 存储格式或备份格式。
- **规则**：`ReportCandidateExtractor` 的标签后必须有冒号或空白才取值（日期标签除外）；机构、科室、报告类型和标题的标签独占一个 block 时取同行右侧相邻块或正下方左对齐块，遇到另一个标签、段落标题或按钮则不取；医院抬头兜底从 80 个字符收紧到 40 个字符并排除说明句；不超过 24 个字符、以“报告单”结尾的表单名称作为报告类型；标题标签增加“医疗名称”，结果标题增加“检查结果描述”，停止行增加“查看影像/图像”“下载影像/图像/报告”。成员名、检验表格重建、异常标记和日期类别全部保留。完整契约见 [`import-and-ocr.md`](import-and-ocr.md)。
- **与 Go 的差异**：一是异体字。Go 直接在提案里把“査”写成“查”；Swift 只在匹配副本上还原，`originalTranscription` 保留 OCR 实际读到的文字，还原结果作为待确认的 `correctedTranscription`，OCR block 与来源引用不变，[`domain-and-data-model.md`](domain-and-data-model.md) 同步了这一含义。二是检验表格。标题标签含“检验项目”“项目名称”，它们也常是表格列标题；标签与“结果”类表头同行时不取相邻或下方的值，避免把表头或首行项目读成标题。三是标签后的分隔符接受任意空白，避免全角空格分隔的旧输入失效。
- **版本**：`extractionVersion` 从 4 升到 5。它只在打开、保存、重新识别或确认 `needsReview` 草稿时触发重新抽取，并且只填充原先为空的候选字段；已保存候选、review state 和已确认记录都不改写，旧规则留下的错误候选也不会因此消失。
- **未移植**：Go 提交 `c6184a8` 的“低置信度来源提示”与 Swift 复核页已有的逐字段识别置信度说明重复，未移植；两者口径不同，Swift 显示来源 block 的平均置信度，Go 在最低置信度不高于 0.3 时提示。
- **验证**：先写测试并观察其在旧规则下失败，再改实现。`swift test --disable-sandbox --filter KinlogueCoreTests` 的 142 tests / 2 suites 通过；`LiveAppServiceTests`、报告识别快照、`ImportDraftTests`、导入 workflow 与 LAN 归档的定向运行通过，其中新增一条经真实 `LiveAppService` 的链路：旧版本草稿刷新后提出还原文字，确认后的记录仍保留 OCR 原文与同一来源 block。确定性主测试清单变为 1009 tests / 91 suites，已同步[候选账本](acceptance/current-release.md)。完整门禁在后续交互改进完成后对同一工作树统一执行，结果见下一条。
- **边界**：测试只使用合成文字，版式坐标沿用 Go 预览的合成夹具。规则依据的真实样本只有两份，真实报告上的命中率、误取率和“査”以外的异体字都没有在本仓库验证；改动未提交、未 push。

## [2026-10-10] ux | 把 Go 预览的交互改进移回 Swift 并复验两部分

- **背景与依据**：对照 Go 预览提交 `c628414`（易用性调整）和 `2e8c6c4`（首次识别等待说明）逐项核实 Swift 现状，只移植确认存在且改动小的差距。参考实现只读。界面规则写入 [`design-system.md`](design-system.md) 第 20–25 条，等待说明的事实边界写入 [`import-and-ocr.md`](import-and-ocr.md)。
- **已做**：报告时间线出现且没有打开记录时自动打开最新一条，自动打开失败不弹提示；某位成员的时间线不再在每张卡片重复成员 Chip；侧边栏“待确认”显示数量和每份草稿第一份原件的文件名；导入或重试期间在侧边栏显示识别状态，超过 4 秒后说明首次识别需要准备模型，复核页“重新识别并覆盖”共用这段说明；报告复核页的确认可用 Command-Return 触发，输入法有未上屏文字时不执行；sheet 内联错误补齐警示符号。`DraftSummary` 新增只读的文件名投影，没有改动存储格式。
- **核实后未做**：Command-F 聚焦搜索已由“查找”菜单提供；手机归档的 `LANInboxModel.selectedMemberID` 本来没有默认值。短暂浮层提示没有做：Swift 没有会滞留的成功状态行，成功结果已由 sheet 关闭、时间线更新或页面内说明表达，新增一层浮层不属于小改动。已确认记录编辑页没有加 Command-Return：保存按钮已绑定 Return 默认动作，SwiftUI 的一个按钮只能有一个快捷键，再加一个需要不可见控件或放弃 Return。侧边栏没有显示草稿标题：标题在草稿文档里，为此逐份读取文档不属于小改动。日期点选和“更多操作”菜单在任务开始前已核实为不需要。
- **本地化**：新增 5 条中英文案并移除不再使用的“待确认”键，`scripts/compile-localizations.sh --write` 后 `--check` 通过；带插值的文案有中英运行时断言。待确认数量使用括号内数字，英文没有随数量变化的词形。
- **验证**：环境为 macOS 27.0.1 (26A434) / Xcode 27.0 (27A266a) / Apple Swift 6.4，工作树未提交。`swift build --disable-sandbox`、`scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/verify-docs.sh` 和 `git diff --check` 通过。`scripts/test.sh` 第一次在没有设置 locale 的 agent shell 中以退出码 1 结束：`documentationLintFailsClosedForFactSafetyLinkAndSymlinkDrift` 调用的文档校验报 `invalid multibyte char (US-ASCII)`，其后的分片没有执行；同一棵树上该测试在 `LC_ALL=en_US.UTF-8` 下通过，判断为 shell locale 而不是本次改动。随后以 `LC_ALL=en_US.UTF-8 scripts/test.sh` 完整重跑，退出码 0：主账 1030 tests / 93 suites 与[候选账本](acceptance/current-release.md)一致，13 项动态发现的 derived-artifact XCTest、验收扫描、33 项跨进程存储、条件式别名锁、18 项 DICOM 导入、安装式 LAN HTTP 与真实双流 RSS/背压门禁均通过。新增测试中，复核页 Command-Return 在宿主窗口内发送键等价并观察到确认命令，去掉快捷键后该测试失败；其余界面断言沿用仓库既有的源码结构断言。本条日志和设计文档的一处措辞是在完整重跑之后追加的，之后只重跑了文档、隐私与 diff 检查。
- **未执行**：实际窗口中的操作（自动打开、识别状态出现与消失、侧边栏文件名截断、Command-Return 与输入法、错误图标）没有人工走查；VoiceOver 朗读没有检查；首次识别的实际耗时没有在 Swift 上计时；字段规则在真实报告样本上的命中率没有验证。`scripts/verify-app.sh`、安装验收和 macOS 26 独立机器没有执行，候选状态保持 `not-verified` / `pendingManual`。
- **合并提示**：两部分留在同一工作树，未提交、未 push。第一部分单独提交时账本应为 1009 tests / 91 suites，两部分合计为 1030 / 93。主检出的 `docs/log.md` 和 `docs/index.md` 有未提交改动，合并本分支时这两个文件需要人工对照。
- **交付整理**：之后按用户要求把两部分整理为两个提交并推送以发起 PR，没有新增行为修改。上面两条里的“未提交、未 push”描述的是验证发生时的工作树；提交和 PR 不提升候选状态，远端 CI 结果以实际运行为准。

## [2026-10-11] brand/docs | 定位改为以人为单位、一人管全家，并从矢量母版重画应用图标

- **依据**：用户 2026-10-11 决策：产品按“个人维度，但可以管理整个家庭”定位，并计划延伸为健康助手（运动数据、模型问答）。助手能力未实现，本次只调整品牌表述和图标，取舍见 [`decisions.md`](decisions.md)。
- **文档**：README 的标语、简介、核心体验首条和“品牌”一节改为以人为单位的表述，`Kin` 的释义改为“自己和家人”；项目总览同步一句话定位。新增 [`brand.md`](brand.md) 维护名称、定位、标语、文案规则、图标母版与生成方式，并把健康助手写成明确标注为未实现的方向；索引与设计系统增加入口。`PRIVACY.md`、App 内文案、本地化资源和 Info.plist 未改。
- **图标**：新增 `packaging/AppIcon.svg` 与小尺寸母版 `packaging/AppIcon-small.svg`，由 `scripts/render-app-icon.swift` 渲染 `AppIcon.png` 和 iconset 的 10 个表示；16、32 像素使用小尺寸母版。底板、纸页和节点使用精确的品牌母色。旧图标只有位图，颜色偏离母色，线条在底板右下角被裁掉。
- **历史隐私门禁**：`scripts/privacy-history-guard.sh` 原先每个路径只接受一条摘要，而被替换的图标仍在可达历史中，新旧位图无法同时通过。现改为同一路径可登记多条已审查摘要，每个历史版本必须命中其中一条；完全重复的行、未知路径和缺少摘要的路径仍然失败。摘要清单为 11 个图标路径各追加一条新摘要，旧摘要保留。当前树门禁未改。
- **验证**：当前 Mac（macOS 27.0.1 / Xcode 27.0）未提交工作树上，完整 `scripts/test.sh` 通过，主测试清单经脚本核对为 995 tests / 91 suites，新增 1 项历史门禁回归；`scripts/lint.sh`、`scripts/verify-docs.sh`、当前树 `scripts/privacy-guard.sh` 和 `git diff --check` 通过。连续两次渲染的 11 个位图摘要一致，PNG 只含像素尺寸元数据；新 iconset 经 `scripts/generate-icns.swift` 打包后由 `iconutil` 展开为 10 个尺寸正确的表示。在一次性克隆中把新图标提交到真实历史之上：旧门禁失败，新门禁配新清单通过，新门禁配只含新摘要的清单失败。
- **未执行**：`scripts/verify-app.sh` 要求干净的已提交工作树，替换图标后的 Release bundle 未构建或验证；新提交的远端 CI 未运行。图标在 macOS 26/27 的 Dock、Finder 中的实际显示，以及深色或着色外观，未人工核对。
- **合并 main**：首次推送的 `9d99f9b` 上，远端 CI 的 lint、隐私、完整测试和 clean-source bundle 验证在 macOS 26 与 Xcode 27 两个环境均通过；macOS 26 基线任务随后在 DICOM XPC 步骤达到 30 分钟任务上限被取消，Xcode 27 的同一步骤通过。之后合并 `main` 的 `12dbc93`，账本与日志的冲突按保留两边内容解决，主测试清单为 1031 tests / 93 suites。合并后的工作树在当前 Mac 上重新通过完整 `scripts/test.sh`、`scripts/lint.sh`、`scripts/verify-docs.sh` 和当前树 `scripts/privacy-guard.sh`；合并提交的远端 CI 尚未运行。

## [2026-10-11] ui | 统一配色令牌、按钮与列表行交互状态

- **范围**：按用户确认的三项决定处理全 App 的配色与交互状态不一致：内容区和 sheet 的取消、关闭与普通操作改用自定义次要按钮，系统样式只留给窗口工具栏、系统确认框、菜单和原生表单控件；列表行使用选中 13% / 悬停 5% / 按下 18% 的 Primary 交互层；继续只支持亮色，并让每个窗口与 sheet 各自声明。改动限于 `Sources/KinlogueApp/Views`，不涉及 ViewModel、服务、存储、LAN 或手机上传页，也没有新增或删除用户可见文案。
- **修正**：[`KinlogueTheme`](../Sources/KinlogueApp/Views/KinlogueTheme.swift) 新增 Selection Pressed、Success/Warning/Danger 及其容器色、三档圆角，以及破坏性按钮、Ghost 图标按钮、上报按下状态的行按钮、`KinlogueRowInteraction`、`kinloguePanel`、`kinlogueInputFrame`、`KinlogueStatusLabel`、`KinlogueWarningNotice`、`kinlogueAppearance` 和 `kinlogueSheetCanvas`。Warning 与 Danger 取自手机上传页已有的 `.warning` 和 `button.destructive` 配色。23 个页面文件替换了系统 `.secondary` / `.tertiary`、`.red` / `.orange` / `.green`、`.borderless`、`Color(nsColor:)`、`regularMaterial` 和圆角数值；14 个 sheet 根视图统一为 Surface 画布；DICOM Viewer 窗口声明亮色与 Primary，叠在黑色影像画布上的状态浮层固定为深色；侧边栏命令行补齐悬停、按下与焦点描边；删除资料库弹窗由 grouped Form 改为与其他 sheet 相同的布局，取消在左、破坏性操作在右；原件预览在加载、失败和已加载状态使用同一个 Container 底色。图标调整三处：工具栏“导入医学影像”改用 `square.and.arrow.down.on.square`，不再与“医学影像”导航共用符号；侧边栏“手机上传”与工具栏、收件箱页眉同用 `iphone.and.arrow.forward.inward`；重试统一为 `arrow.clockwise`。
- **规范变更**：[`design-system.md`](design-system.md) 已同步。其中两条是对旧规范的有意修改：原“取消、删除、工具栏按钮继续使用系统样式”收窄为上述范围；原“手机接收弹窗使用白色画布”改为 Surface 画布，说明卡与二维码使用 Card + Outline。DICOM Viewer 的页眉与控制条包含无法套用自定义按钮样式的 Menu 和 Picker，整条保留系统控件，作为明确例外记录。
- **测试**：改写 `KinlogueThemeSourceTests`、`MemberSidebarViewSourceTests` 和 `ImportReviewViewSafetyTests` 中锁定旧写法的断言，并新增 4 项：窗口、sheet 与 popover 的外观声明覆盖；`Views` 目录的令牌门禁；行交互层的优先级与明度顺序；文字和状态前景在各画布上的对比度不低于 4.5。主测试清单由 994 变为 998 tests / 91 suites，[`acceptance/current-release.md`](acceptance/current-release.md) 已同步。
- **验证**：当前 Mac（macOS 27.0 / Xcode 27.0）。完整 `scripts/test.sh` 退出码 0，覆盖 998 tests / 91 suites 主清单、13 项独立 XCTest、18 项 DICOM 导入、安装式 LAN HTTP 和真实双流背压门禁。该次完整运行之后只调整了两处视图细节（禁用的命令行不显示悬停底色、归档提示改为居中对齐），随后重跑视图相关的 99 tests / 16 suites 和 `scripts/lint.sh`（warnings-as-errors build 与文档门禁）通过；`scripts/verify-docs.sh` 与 `scripts/privacy-guard.sh` 通过。另用临时测试文件以 `NSHostingView` 和合成数据离屏渲染了组件、记录详情、成员编辑、删除资料库、影像详情和设置页三种备份状态用于目视核对；该文件与图片未进入仓库。
- **后续调整**：用户运行本地构建后指出日期选择 popover 的日历带蓝色外框。原因是原生 `NSDatePicker` 成为第一响应者后绘制系统强调色焦点环，外加控件自带的内层底框。[`LocalizedDatePickerConfiguration`](../Sources/KinlogueApp/Views/LocalizedDatePicker.swift) 关闭 bezel、border、背景和焦点环；在现有配置测试中补充四项断言，不新增测试计数。`LocalizedDatePickerTests` 的 4 tests 通过，并以离屏渲染对比了有无底框的日历。选中日的蓝色来自系统强调色，本次未改。
- **边界**：没有启动真实 App。sheet 是否继承主窗口 tint 仍是源码推断，逐根声明不依赖这一结论。悬停与按下的实际动效、系统深色模式下的 sheet 与 Viewer、键盘 Tab/方向键、VoiceOver、提高对比度和窄窗口均未人工验证；键盘焦点环、文本选区和原生日期选择器仍跟随系统强调色。README 预览图 `docs/assets/kinlogue-overview.jpg` 受固定 SHA 门禁保护，本轮未更新，与当前按钮和选中态外观存在差异。改动留在本地工作树，未提交、未 push；候选状态保持 `not-verified` / `pendingManual`。

## [2026-10-11] packaging | App 包加入与 Primary 同值的强调色资源

- **原因**：上一条记录把“原生控件的焦点环、文本选区和日历选中日跟随系统强调色”列为已知限制。用户在本地构建中确认日期选择器的选中日仍是系统蓝，并要求一并处理。SwiftUI 的 tint 到达不了 AppKit 自绘的这些部分，只有主包里的强调色资源可以。
- **修正**：新增 [`packaging/Assets.xcassets`](../packaging/Assets.xcassets)，只含一个 sRGB `AccentColor`（`#1E6254`）；`packaging/Info.plist` 声明 `NSAccentColorName`。`build-app.sh` 在签名前用 Xcode 自带的 `actool` 编译目录，核对编译结果与 `Info.plist` 的名称一致后复制为 `Contents/Resources/Assets.car`；目录缺失、含符号链接或名称不一致都会终止构建。`verify-app.sh` 把该文件加入精确资源清单，检查源码和 bundle 两处 `NSAccentColorName`，并用 `assetutil --info` 确认归档只有这一个不透明 sRGB 颜色且通道值为 30/98/84。归档内嵌构建时间戳，所以按内容而不是固定哈希校验。验收 App 由已验证 bundle 整体复制而来，随之带上同一资源。没有新增依赖、entitlement 或运行时代码。
- **生效范围**：只在用户的系统强调色保持默认“多色”时生效；用户选了具体强调色时，原生控件按 macOS 规则跟随用户选择。`swift build` 直接产出的可执行文件和测试进程没有主包资源，不体现这一颜色。规则见 [`design-system.md`](design-system.md)，构建说明见 [`testing-and-release.md`](testing-and-release.md)。
- **测试**：`KinlogueThemeSourceTests` 新增 1 项，核对 colorset 与 `KinlogueTheme.primary` 同值、`Info.plist` 声明、构建脚本在签名前复制归档，以及校验脚本的清单和内容检查；`LANPhoneAssetSafetyTests` 的精确清单断言加入该文件。主测试清单由 998 变为 999 tests / 91 suites。
- **验证**：当前 Mac（macOS 27.0 / Xcode 27.0，系统强调色为默认多色）。用临时目录里一个不含任何资料、使用独立标识的最小探针 App 对照：带该资源时 `NSColor.controlAccentColor` 为 `#1E6254`，焦点环与选区色同步变为玉绿系；不带时为系统蓝 `#007AFF`。把两个脚本中新增的片段原样抽出，对临时 bundle 运行：正向通过；颜色偏差一个色阶、多出一个颜色、空文件、目录缺少 colorset、`Info.plist` 缺少声明、目录为符号链接六种情形全部按预期拒绝。`scripts/verify-app.sh --lan-prerequisites-only` 通过。完整 `scripts/test.sh` 在最终代码上退出码 0（999 tests / 91 suites 主清单与各独立门禁），`scripts/lint.sh`、`scripts/verify-docs.sh` 和 `scripts/privacy-guard.sh` 通过。
- **边界**：完整的 `scripts/verify-app.sh` 没有运行，因为它会重建 `dist/Kinlogue.app`，而用户当时正在运行该构建；新增校验只以抽出的片段验证过，尚未在一次真实的整包校验中执行。远端 CI 上的 `actool` 行为、macOS 26 独立机器、用户选了具体系统强调色时的表现以及 Developer ID 分发流程均未验证。改动留在本地工作树，未提交、未 push；候选状态保持 `not-verified` / `pendingManual`。

- **提交整理**：强调色资源编入本地构建后，资源清单与 `verify-app.sh` 的精确清单一致，抽出的颜色内容校验对该构建的 `Assets.car` 通过，签名有效。用户运行该构建后确认日期选择器、焦点环等效果没有问题，并要求提交。配色统一、日期选择器调整和强调色资源按用户“一起做”的要求合并为一个逻辑提交；上两条中的“未提交”描述保留为验证发生时的状态。提交不提升候选验收状态，完整 `verify-app.sh`、远端 CI 和人工矩阵仍未执行。

## [2026-10-11] docs | 更新 README 预览图并统一侧边栏图标颜色

- **原因**：上一提交之后 README 预览图与实际界面不一致。用户询问能否去掉预览图的固定摘要门禁。结论是保留：它是公开仓库里唯一保证入库截图为已审查合成图的机制，去掉后该路径上的任意图片都会通过；更新预览图只需要登记新图，不需要放宽门禁。
- **生成方式**：用一个临时测试文件在测试进程里构造假数据服务（四个带“合成示例”标注的成员、九条合成记录和一页由代码绘制的合成 PDF），把真实的 `AppShellView` 放进屏幕外的窗口，等数据、选中记录和原件预览就绪后，读取本进程这一个窗口的合成结果并导出为 2724×1600 的 JPEG。没有启动 App，没有读取资料库，也没有截取屏幕上的其他内容；临时文件已删除，未进入仓库。导出的文件只带 JFIF、像素尺寸和空的 IPTC 段，不含日期、设备或位置信息。
- **门禁**：历史门禁对每个路径只认一个摘要，原路径上替换必然被拒绝。新图使用 `docs/assets/kinlogue-overview-2026-10.jpg`，在两个门禁脚本和摘要清单中登记；旧图从当前树删除，旧路径只为历史保留登记，当前树门禁不再接受该路径。门禁逻辑没有改动。`ReleaseScriptSafetyTests` 改用新路径，并补充“旧路径即使放入当前已审查的图片也被拒绝”的断言。流程写入 [`privacy-and-security.md`](privacy-and-security.md)。
- **顺带修正**：渲染时发现侧边栏的“全部记录”“医学影像”“手机上传”“设置”和各命令行图标不跟随行颜色：侧边栏样式的 `List` 把普通 `Label` 图标染成强调色，窗口不活跃时置灰，而成员行图标显式着色、表现正常。对照实验确认这与按钮样式无关，上一提交之前同样如此。新增 `SidebarRowLabel` 在符号上显式设置颜色，九处调用全部替换；`KinlogueThemeSourceTests` 的现有侧边栏测试补充断言，不新增测试计数。规则写入 [`design-system.md`](design-system.md)。
- **验证**：当前 Mac（macOS 27.0 / Xcode 27.0）。完整 `scripts/test.sh` 在最终代码上退出码 0（主清单仍为 999 tests / 91 suites，另含各独立门禁），`scripts/lint.sh`、`scripts/verify-docs.sh` 和 `scripts/privacy-guard.sh` 通过。历史门禁以一个不挂在任何分支上的演练提交验证：该提交的历史同时包含旧路径上的原图和新路径上的新图，`scripts/privacy-history-guard.sh --ref <演练提交>` 通过；分支和工作树未因演练改变。新图逐像素目视检查过，只有合成成员、合成记录和合成 PDF。
- **边界**：预览图是窗口不活跃时的外观，交通灯和工具栏图标为灰色。侧边栏图标的修正只通过离屏渲染和预览图确认，尚未在运行中的 App 里由人确认。完整 `verify-app.sh`、远端 CI 和人工矩阵仍未执行；候选状态保持 `not-verified` / `pendingManual`。改动在本地工作树，写入本条时尚未提交。
- **提交整理**：用户查看新预览图后要求把预览图更新、门禁登记和侧边栏图标修正一起提交，作为上一提交之后的第二个提交保存；没有额外行为修改。上面的“尚未提交”保留为写入时的状态，提交不提升候选验收状态。

## [2026-10-11] merge | 把 main 的字段建议、交互改进与品牌更新并入配色统一分支

- **原因**：PR #18 与 `main` 冲突。`main` 新合入 #16（字段建议规则与交互改进）和 #17（定位与应用图标），与本分支在五个视图文件和三份文档上冲突。按“保留两边意图”合并，不 rebase、不强推。
- **视图**：`main` 给 sheet 内联错误补了三角图标和红色前景，本分支把同一批错误换成了 `KinlogueStatusLabel`。两边的目的都是“错误不只靠颜色表达”，合并后保留状态标签。导入确认页同时保留 `main` 新增的慢识别说明和本分支的 On Variant 前景；侧边栏“待确认”行同时保留 `main` 的文件名显示、截断规则和本分支的 `SidebarRowLabel`。`main` 新增的 `SlowRecognitionNotice` 原本使用系统 `.secondary`，改为 On Variant，以满足 `Views` 目录的令牌门禁。
- **规则调和**：`main` 新增的设计规范第 25 条写的是“带 `exclamationmark.triangle` 的 `Label` 加红色前景”，改写为使用 `KinlogueStatusLabel(_:tone: .danger)`，符号为 `exclamationmark.octagon`，以便与警告的三角符号区分。这是对 `main` 上刚合入规则的文字修改，意图未变。`ImportReviewViewSafetyTests.inlineErrorsCarryAWarningSymbolAndNotOnlyColour` 原先按 `.foregroundStyle(.red)` 与三角符号的出现次数断言，改为断言五个文件的错误都经过状态标签、不存在裸的危险色文字或系统红。第 1 条取本分支收窄后的系统样式范围，第 2 条取 `main` 关于 Command-Return 的补充。
- **媒体门禁**：`main` 把历史门禁改为同一路径可登记多条已审查摘要，本分支此前“每个路径只认一个摘要”的说明不再成立，[`privacy-and-security.md`](privacy-and-security.md) 已改写。预览图的带日期文件名已经进入本分支的可达历史，因此保留该路径及其登记；今后更新可以在同一路径追加摘要。两边对摘要清单、路径清单和 `ReleaseScriptSafetyTests` 的修改自动合并后一致。
- **账本**：`main` 为 1031 tests / 93 suites，本分支新增 5 项，合并后实测为 1036 tests / 93 suites。`current-release.md` 的其余措辞取 `main`。
- **验证**：当前 Mac（macOS 27.0 / Xcode 27.0）。合并后的树上完整 `scripts/test.sh` 退出码 0；`scripts/lint.sh`、`scripts/verify-docs.sh`、`scripts/privacy-guard.sh` 通过。
- **边界**：README 预览图在合并前渲染，没有重新生成；`main` 的界面改动不影响图中展示的状态（“全部记录”下仍显示成员标签，图中没有待确认草稿和识别状态）。完整 `verify-app.sh`、远端 CI 和人工矩阵仍未执行；候选状态保持 `not-verified` / `pendingManual`。

## [2026-10-11] feat(ux/dicom) | 已确认医学影像合入成员时间线

- **决策与变化**：用户决定去掉侧边栏“医学影像”顶级入口。已确认检查此前已经按日期进入成员时间线，独立影像库只是把同一批检查再平铺一遍；点击时间线卡片还会跳到影像库并丢失时间线位置。现在检查卡片原地选中，右栏由直接观察影像选择模型的 `TimelineDetailContainer` 显示检查摘要、“查看影像”和“编辑归属与日期”；选中报告与选中检查互斥，切换家庭成员清除两者。
- **类型筛选**：时间线新增“全部 / 报告 / 影像”功能标签筛选，只在资料库存在已确认检查时显示，否则回到“全部”。筛选会清除被隐藏类型的选中项；搜索仍只覆盖已确认报告，筛选为“影像”时结果恒为空并提示切换。比较选择进行中检查卡片禁用。精确重复导入命中已确认检查时回到时间线并选中该检查，必要时先解除成员、筛选和搜索词的遮挡。
- **顺带消除的状态**：从源码读出（未运行复现），旧影像库入口不会清除上一次选中的家庭成员，列表按该成员隐性过滤而侧边栏只高亮“医学影像”；入口移除后这一状态不再存在。
- **命名与文案**：删除 `DICOMLibraryView` 列表与 `DICOMLibrarySelectionNavigation`，详情更名为 `DICOMStudyDetailView`；`DICOMStudyDestination.library` 改为 `.timeline`。“确认并加入医学影像库”“这项检查已在医学影像库中”改为时间线措辞；移除只服务旧界面的 `医学影像`、`选择一项医学影像检查` 两个 catalog key，新增筛选与搜索提示共五个中英 key，并重新生成英文运行时资源。
- **未改变的边界**：catalog、Vault 布局、fingerprint、导入 workflow、XPC 解码和 Viewer 生命周期均未改动；影像仍不进入 OCR、搜索或比较，`needsReview` 检查仍只出现在“待确认影像”。筛选和选中项是 App 层查看态，不持久化。
- **回归**：[`DICOMAppModelTests`](../Tests/KinlogueAppTests/DICOMAppModelTests.swift) 新增选中互斥与成员切换、筛选对时间线/搜索/选中的影响、无已确认检查时回退“全部”、重复导入后的定位共 4 项；[`DICOMStudyDetailViewTests`](../Tests/KinlogueAppTests/DICOMStudyDetailViewTests.swift) 用离屏渲染证明右栏随影像选择即时切换，并锁定 AppShell 必须把同一选择模型交给时间线与详情容器；[`MemberSidebarViewSourceTests`](../Tests/KinlogueAppTests/MemberSidebarViewSourceTests.swift) 与 [`KinlogueThemeSourceTests`](../Tests/KinlogueAppTests/KinlogueThemeSourceTests.swift) 锁定侧边栏不再含影像导航项、键盘顺序为全部记录 → 手机上传，以及筛选使用功能标签而非系统分段控件。随列表删除的 `DICOMLibrarySelectionNavigationTests` 不再存在。测试与实现在同一轮完成，没有单独记录先失败的运行。
- **目检**：按合成数据在离屏 `NSHostingView` 渲染时间线三种筛选、检查选中态、“影像”筛选下的搜索空状态和右栏详情并逐张查看，未启动 App、未读取真实资料库，截图只写入会话临时目录后未进入仓库。离屏渲染不呈现悬停、按压和焦点状态。
- **验证**：当前 Mac（macOS 27.0.1 / Xcode 27 / Swift 6.4）未提交工作树上，`scripts/lint.sh`（warnings-as-errors 构建、依赖图和文档）与完整 `scripts/test.sh --quiet` 均以 0 退出，日志中没有失败项；当时的主测试清单经 `primary-test-shards.rb --inventory-summary` 核对为 997 tests / 90 suites（并入 `main` 之前的数字，当前数字见下一条与[候选账本](acceptance/current-release.md)），derived XCTest 13/13、验收扫描 14/1、storage process 33/1、DICOM 导入集成 18/1、安装 LAN 生产 HTTP 1/1 与真实双流 LAN RSS/背压 1/1 通过。`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 通过。这是 dirty-source 本机结果，不绑定不可变 source ref。
- **仍未执行**：README 预览图 [`docs/assets/kinlogue-overview-2026-10.jpg`](assets/kinlogue-overview-2026-10.jpg) 仍显示旧侧边栏的“医学影像”项；该文件受固定 SHA-256 的媒体门禁约束，本次没有替换，需用合成数据重新截图并经媒体审查后更新。clean-source bundle、安装后验收、真实 MRI，以及筛选标签与检查卡片的键盘/VoiceOver 人工矩阵均未执行。

## [2026-10-11] merge | 把 main 的配色统一、品牌更新与字段建议并入影像时间线分支

- **来源**：`main` 新增 #16（字段建议与交互改进）、#17（定位与应用图标）、#18（配色令牌、按钮与列表行交互状态）。七个文件冲突：`DICOMLibraryView.swift`、`MemberSidebarView.swift`、`TimelineView.swift`、两份源码契约测试、`design-system.md` 和候选账本。
- **取舍**：影像库列表在本分支已删除，`main` 对它的行交互改动随之不保留；`main` 对同文件详情文字的 On Variant 配色移到 `DICOMStudyDetailView`。侧边栏保留 `main` 的 `SidebarRowLabel` 与行交互，只去掉“医学影像”一行。时间线同时保留 `main` 的“单成员时间线不重复成员标签”和本分支的选中、筛选。`design-system.md` 取 `main` 的色板与规则文字，再去掉对影像库的引用并保留第 11 条的时间线写法。
- **语义冲突**：`main` 新增“进入时间线且没有打开任何内容时自动打开最新报告”，它只检查报告选中。文本上不冲突，但从其他分区回到时间线时会在已选中影像检查的情况下再打开一份报告，破坏两者互斥。`openNewestRecordIfNothingIsOpen` 现在把选中的影像检查也算作“已打开”；筛选为“影像”时时间线没有报告，本来就不会自动打开。回归见 [`DICOMAppModelTests`](../Tests/KinlogueAppTests/DICOMAppModelTests.swift)。
- **随合并修正的断言**：`KinlogueThemeSourceTests` 中四个按侧边栏行数计数的断言各减一；本分支日志里的 README 预览图链接改指 `main` 更新后的文件名。
- **账本**：`main` 为 1036 tests / 93 suites；本分支净增 4 项并删除一个随列表消失的 suite，合并后实测为 1040 tests / 92 suites。`current-release.md` 的其余措辞取 `main`。
- **验证**：当前 Mac（macOS 27.0.1 / Xcode 27 / Swift 6.4）。在已解决冲突、尚未提交的合并树上，`scripts/lint.sh` 与完整 `scripts/test.sh --quiet` 均以 0 退出，日志中没有失败项；derived XCTest 13/13、验收扫描 14/1、storage process 33/1、DICOM 导入集成 18/1、安装 LAN 生产 HTTP 1/1 与真实双流 LAN RSS/背压 1/1 通过。`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 通过。没有重新做离屏目检，也没有启动 App。
- **仍未执行**：`main` 更新后的 README 预览图同样显示旧侧边栏的“医学影像”项，本次没有重新生成。筛选标签沿用静态的 Selected / Neutral 功能标签，没有悬停与按下反馈，是否纳入 `main` 的统一交互状态留待后续决定。

## [2026-10-11] ui | 时间线类型筛选标签补齐悬停与按下状态

- **变化**：上一条合并记录里留待决定的筛选标签交互状态，用户决定在同一个 PR 内补上。`KinlogueTheme` 新增 `chipHover`（Primary 10%）与 `chipPressed`（Primary 20%）两个令牌、纯函数 `chipFill` / `chipLayer` 和 `.buttonStyle(.kinlogueChip(isSelected:))`。未选中项在 Chip 上叠加悬停或按下层，选中项沿用主按钮的悬停与按下色；静止外观不变，仍带对勾。样式遵循 `Reduce Motion`、`Increase Contrast` 和禁用态。`TimelineFilterBar` 不再使用 `.buttonStyle(.plain)`。
- **回归**：[`KinlogueThemeSourceTests`](../Tests/KinlogueAppTests/KinlogueThemeSourceTests.swift) 新增一项，断言中性标签从静止到悬停再到按下逐级变深、按下时 On Variant 文字对比度不低于 4.5、选中项三种底色上的白字对比度不低于 4.5，以及两个纯函数的状态优先级；色板契约和时间线源码契约同步。这项测试先于实现写入，首次运行因缺少令牌与函数编译失败，实现后通过。
- **目检**：离屏渲染真实筛选条的静止态（与改动前一致），并用同一组主题函数渲染未选中与选中各三种状态的色样逐一查看。离屏渲染无法触发真实悬停与按下，所以没有在运行中的 App 里看到这两个状态。
- **账本**：主测试清单经脚本核对为 1041 tests / 92 suites。
- **验证**：当前 Mac（macOS 27.0.1 / Xcode 27 / Swift 6.4）未提交工作树上，`scripts/lint.sh` 与完整 `scripts/test.sh --quiet` 均以 0 退出，日志中没有失败项；derived XCTest 13/13、验收扫描 14/1、storage process 33/1、DICOM 导入集成 18/1、安装 LAN 生产 HTTP 1/1 与真实双流 LAN RSS/背压 1/1 通过。`scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 通过。

## [2026-10-11] ci | PR 只跑 macOS 26 基线，bundle 验证独立并行，CodeQL 只追踪第一方源码

- **依据**：用 `gh` 读取最近 30 次 CI 与 12 次 CodeQL 运行的 job 与 step 时间。加入 Xcode 27 矩阵后的 17 次 CI 运行里，原质量 job 在 macOS 26 上成功时中位 24.5 分钟、最长 27.5 分钟，另有 5 次撞到 30 分钟 job 上限被取消（macOS 26 三次、Xcode 27 两次）；每次触发启动 7 个 macOS job，96 个 job 中 43 个排队超过 5 分钟，最长 31 分钟。CodeQL 成功运行中位 31.4 分钟，其中 tracer 下的 `swift build` 中位 28.8 分钟；抽样运行 38115425342 里同一命令在 lint 中不带 tracer 只用 165 秒，tracer 下的时间主要花在 JXLSwift、J2KCodec、DicomCore 和 SwiftNIO 等第三方模块。
- **CI**：三个测试分区和新的 bundle job 的矩阵改为按事件取值，pull request 只用 `macos-26`，main push 与手工触发仍同时使用 `macos-26` 和 `xcode-27`。原质量 job 拆成两个并行 job：`quality` 保留 lint、隐私门禁和分区 `0/3`，检查名改为 `Lint and test`；新 `bundle` job 在自己的 checkout 上运行 `verify-app.sh --require-clean-source` 与 `verify-dicom-xpc.sh --use-verified-app`，检查名为 `Verify bundle and DICOM XPC`。各脚本、分区划分、deadline 和 30 分钟 job 上限未改。
- **CodeQL**：在 `codeql-action/init` 之前增加一次不被追踪的 `swift build`，tracer 启动后对 `Sources/` 下的 Swift 源码执行 `touch` 再编译。第三方依赖不再被提取，这是有意缩小的范围：依赖内部的问题不由这一门禁发现。
- **测试**：[`GitHubActionsWorkflowTests.swift`](../Tests/KinlogueAppTests/GitHubActionsWorkflowTests.swift) 的两项既有测试改为断言四个 job 的检查名、按事件取值的矩阵、bundle 与 XPC 只出现在 `bundle` job 且顺序固定，以及 CodeQL 的预编译、tracer 启动、源码失效、追踪编译和分析的先后顺序。没有新增测试，主测试清单计数不变。
- **本机验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4。冷编译后对 `Sources/` 执行 `touch` 再 `swift build -v`，只有本仓库十个非测试 target 出现编译调用，第三方模块没有重编。`xcodebuild -clonedSourcePackagesDirPath` 指向不存在的多级目录时会自行创建，新 bundle job 没有先行的 `.build/` 不构成障碍。`scripts/test.sh --filter GitHubActionsWorkflowTests --filter ReleaseScriptSafetyTests` 通过 27 tests / 2 suites；临时把一个 job 的矩阵改回固定双 runner、把 bundle 验证放回质量 job、删掉 CodeQL 的 `touch` 后，同一命令按预期出现 3 处失败，随后逐字节恢复。`scripts/lint.sh`、`scripts/verify-docs.sh` 和 `scripts/privacy-guard.sh` 通过。
- **未执行**：完整 `scripts/test.sh`、`verify-app.sh` 和远端 CI 没有运行。tracer 下的 CodeQL 耗时、Xcode 26.6 原生构建引擎上 `touch` 的重编范围，以及缩小提取范围后告警是否变化，都要等远端运行核对。写入本条时托管端 `Protect main` 规则仍要求旧检查名 `Lint, test, and verify bundle`；合并前须换成 `Lint and test` 与 `Verify bundle and DICOM XPC`，否则该必需检查不会出现。
- **未采纳**：同一分析中发现的另外三处重复编译没有处理：`verify-dicom-xpc.sh` 为切换 hang 开关从零重编 Helper、lint 与测试因编译参数不同各自全量编译、三个测试分区各自冷编译。

## [2026-10-11] ci | 撤回 CodeQL 预编译：tracer 下仍然全量重编

- **远端结果**：PR #20 首轮运行（CI 38136501062、CodeQL 38136501205）里，新布局的四个 macOS 26 job 全部通过：`Lint and test` 10.0 分钟、`Verify bundle and DICOM XPC` 17.8 分钟、`Complementary test partition` 7.5 分钟、`Dedicated LAN derived-artifact tests` 7.7 分钟，pull request 没有启动 `xcode-27` job。CodeQL 也通过，但用时 38.9 分钟，比改动前 31.4 分钟的中位数更慢。
- **原因**：日志显示 tracer 下的第二次 `swift build` 从 `[42/94] Write swift-version-…` 起把整个构建重新执行了一遍，JXLSwift、J2KCodec、SwiftNIO 和 DicomCore 等第三方模块全部重编，用时 1374.67 秒；此前不带 tracer 的 265.82 秒预编译没有被复用。tracer 给后续步骤注入了 `DYLD_INSERT_LIBRARIES` 和 `SEMMLE_COPY_EXECUTABLES_ROOT` 等环境变量。推断是环境或工具路径的变化让 SwiftPM 判定全部产物失效，具体机制没有核实。另外，从 tracer 下的 `swift build` 启动到第一条编译输出之间约有 11 分钟没有构建输出，而这时已经没有依赖需要拉取。
- **处理**：[`codeql.yml`](../.github/workflows/codeql.yml) 恢复为 init 之后单次 `swift build`，对应的测试断言和 [`testing-and-release.md`](testing-and-release.md) 里的说明一并恢复。上一条目中“CodeQL 只追踪第一方源码”的做法没有在远端成立，以本条为准；本机 `touch` 只重编第一方 target 的结论仅适用于不带 tracer 的构建。CI 矩阵调整和 bundle job 拆分保留。
- **未执行**：撤回后的 workflow 还没有在远端运行；完整 `scripts/test.sh` 和 `verify-app.sh` 没有在本机运行。托管端 `Protect main` 规则写入本条时仍要求旧检查名。CodeQL 的耗时问题没有解决。

## [2026-10-11] refactor | 首批存储修复、任务归属与 SQLite 内核

- **基线与范围**：按用户授权开始实施修订后的 [统一计划](plans/2026-10-10-2322-refactor-sqlite-architecture-plan.md)，从 `origin/main@09f57b11143e05aa944c1b716e05737ccd813a12` 建立独立 `codex/sqlite-refactor` 工作树，保留原检出与已有文档改动。先落实 U1、U11–U13、U2 和 U3 的可独立验证部分；本记录不把后续领域事务、按需查询、逻辑备份与生产切换记为完成。
- **生产链路修复**：备份 source 在准备与最终发布校验完整快照，逐项读取改用绑定根、目录头和文件身份的 token，加上流式摘要，消除逐条重解整库；恢复点增加 1.1 容量格式，联动 writer、reader、trust、repository、restore，保留 1.0 读取和版本化信任 transcript。导入去重在一次调用内共用附件索引，保持指纹、稳定 ID 与记录优先规则。
- **任务归属**：App 级 processing coordinator 持有中断导入恢复及 LAN 预处理任务；JSON 完整校验通过后先进入 Ready，再恢复 OCR。页面销毁不取消 App 任务；失败等待显式重试，资料库撤销时取消、排空并拒绝迟到回调。现有 lifecycle 与 durable 状态继续作为依据。
- **开发中内核**：新增 Platform-only 的 GRDB exact 7.11.1 / 系统 SQLite、连接防御配置、15 张 STRICT 表、库身份与格式检查、生命周期排他锁、可恢复初始化、staged/live/deleting 原件和 reader pin。真实进程测试覆盖第二 owner、持锁替换、SIGKILL、初始化及原件操作中断。`AppComposition` 仍使用 JSON；只有 library_state / originals 语义摘要已接通，其余 codec、领域命令和完整巡检属于后续单元。长原件 I/O 的 admission 边界与 macOS 26 engine 验收尚须补齐，U3 不标记整体完成。
- **依赖与包边界**：锁定 GRDB revision、MIT 声明、privacy bundle 与资源白名单；Core、App、DICOM Helper 不直接依赖 GRDB，Helper 链接检查拒绝 SQLite。既有 DICOM 和 codec pin 不变。[依赖核查](sources/2026-10-11-grdb-engine-review.md) 保留官方来源和本机 engine 点时配置结果。
- **规模实测**：复用独立 probe，报告近上限 stage 中位数从 48.707 s 降至 12.567 s，detector 8.841 ms；500 份报告完整发布从 243 s 降至 1.866 s，近上限完整发布 40.310 s。另完成 20,004 条目、10,485,760,000 bytes 原件组合的真实加密发布 86.707 s、严格恢复与激活 371.984 s。采样口径、容量命令成功及首次组合命令主动中止的边界见 [实测记录](storage-refactor-measurement-2026-10-11.md)。JSON 保存、启动和内存仍未达到最终 SQLite 目标；不把这些前置收益说成全部重构完成。
- **审查与收尾修复**：完成独立代码审查（`20261011-011851-df45d60c`）及五项局部简化；唯一确认的 P2 为后台恢复失败后草稿无重试入口。先以真实 Vault / workflow / AppModel 链路复现，再把 processing 转换改为同一 mutation lease 内合并当前目录，保留完整原草稿与 attempt 校验；OCR 在提交前准备一次。App 提供绑定 attempt 的临时重试状态，失败不自动循环，discard 仍限既有 failed 状态。再次失败刷新后检查生命周期，拒绝撤销后的晚到提示。对应红绿回归及独立修复复核通过，未留本批审查阻塞项。跨模型审查因本机进程权限错误在发送代码前失败，采用 skill 规定的本地独立审查，不声称获得外部模型或安全审计结论。
- **最终自动化**：macOS 27.0.1（26A434）/ M1 Max / Xcode 27 / Swift 6.4 上，收尾修复后的 `scripts/test.sh` 退出码 0；主清单与实际汇总为 1039 tests / 91 suites（Core 131/2，其余主分片 908/89）。另行隔离的 13 项 derived XCTest、14 项验收扫描、36 项跨进程存储、1 项大小写别名锁、18 项 DICOM 集成、安装式 LAN HTTP 和真实双流 RSS/背压均通过。最后一项的 RSS 增量 770,048 bytes、事件循环 p99 688,083 ns、停止监听 11.152 ms；不把这项 RSS 与规模 probe 的 footprint 混用。`scripts/lint.sh` 的 warnings-as-errors 构建与 package graph、LAN prerequisite、本地化、当前树隐私、文档及 diff 门禁通过。
- **Release 包**：最终 `scripts/verify-dicom-xpc.sh` 退出码 0，实际 App / Helper 构建与 ad-hoc 签名、raw 像素、外部崩溃与恢复、hang watchdog、日志 canary 和零运行时 socket 全通过。另以实际包断言精确资源清单（App 13 文件、Helper 4 个顶层资源）、GRDB / ZIPFoundation privacy plist、两份许可副本、`codesign --verify --deep --strict`、arm64 及 plist / Mach-O 最低系统 26.0；Helper 无 GRDB / SQLite 符号或 libsqlite3 链接，主 App 无 DICOM codec。Xcode 输出已有 iOS Simulator 组件过旧提示，未阻止 macOS 构建与探针；没有修改系统组件。
- **未执行与交付边界**：当前为未提交工作树，未运行要求 clean-source 的完整 `verify-app.sh`，不为通过门禁自动提交。未 push、创建 PR、发布或替换用户安装，原主检出与用户改动保留。macOS 26 engine / 独立系统安装、真实手机 / 私有 OCR 与 DICOM 样本、Powerbox / 网盘、键盘 / VoiceOver、独立安全审计和 Developer ID / notarization 未执行；当前候选仍为 `not-verified` / `pendingManual`。U3 的长 I/O admission、其余业务 codec 和后续 U4–U10 仍按计划继续，生产 SQLite 尚未切换。


## [2026-10-11] refactor/sqlite | 继续拆开原件长 I/O 与数据库操作

- **实际变化**：`SQLiteLibraryStore`/`SQLiteOriginalLifecycle` 按 original ID 登记活动操作，copy/hash/fsync 在 admission 外执行；重入核对 root、完整语义行、operation/lifecycle、named path 和取消。其他数据库操作继续，同原件竞争、关闭与整库替换返回固定语义错误；取消后的 owned staged 文件由现有恢复流程回收。生产仍使用 JSON，尚未切换报告、LAN 或 DICOM。
- **行为证据**：修改前新增测试复现两处无关写入被阻塞及 rename 后取消仍提交，共 5 个预期失败；修正后同时验证根、行或路径在 I/O 期间改变均被拒绝。阻塞测试沿用独立 OS Thread + continuation，取消使用真实当前 Swift task，避免曾在 macOS 26 出现的 cooperative executor 饥饿。
- **父级验证**：当前 Mac `scripts/test.sh --filter 'sqliteKernel|sqliteRealProcesses|sqliteOriginalsRecover|sqliteInitializationRecovers'` 通过 22 个内核声明和 3 个真实进程声明；测试线程调整后再次执行 `--filter 'sqliteKernelOriginalIO|sqliteKernelCancelledOriginalIO'`，3 个声明/10 个 case 通过。实际已构建 inventory 为 1042 tests / 91 suites；参数化 case 不重复计入主清单。文档/账本只更新当前证据，计划保留决策记录。
- **待完成**：macOS 26 engine 与完整后续重构验收未执行；U4/U5 领域 codec、U8 按需 App 查询和 U6 逻辑备份仍须完成，不能把本次并发正确性证据当成数据库切换或性能目标通过。


## [2026-10-11] refactor/sqlite | 报告、OCR 与窄查询事务

- **范围与当前行为**：新增 `LibraryReportQuery`、`SQLiteReportRepository`、`SQLiteReportRows` 和真实数据库集成测试。成员、报告/详情、草稿、来源和完整 OCR/reviewState 已有局部数据库读写；`ImportDraftStore.confirm/discard` 改为无 catalog 返回值，同步所有旧实现、App、测试与规模探针调用者。生产 composition 仍使用 JSON，App 全量快照尚待 U8 替换，不把平台仓库完成写成统一切换。
- **完整性与查询**：schema 增加独立 `report_search`，现有 16 张 STRICT 表；报告/草稿绑定来源数量/摘要和 OCR 摘要，详情复核查询投影与来源归属。OCR report/lanSource 分 kind、限制 16/32 MiB，报告 extraction version 可空。报告日期按 REAL 保留持久化精度。每页最多 100 个有界摘要，完整确认字段仍按原 Foundation 语义搜索；分页返回明确坏项 ID，每页身份与游标绑定 library/open epoch/commit，末页也保留完整 revision。严格备份仍须逐项校验，不能把普通分页的损坏隔离当成完整性通过。
- **真实缺陷及修复**：新红测分别复现 actor 导入阻塞无关成员读写、带 pin 删除遗留 live 孤儿、取消后的搜索仍返回成功。仓库保留串行 stage，其余入口使用 `nonisolated @concurrent`；领域删除在同一事务登记 deleting，已有 pin 可消费，新 pin 拒绝，释放或恢复后回收。搜索通过跨 GRDB queue 的锁保护取消标志退出，不中断随后查询。每次开库更换 epoch，拒绝同库同 revision 重开后的旧游标/读取。原件发布统一保留语义错误、清除底层数据库参数信息。
- **验证**：13 个新增报告测试和 118 个受影响回归通过，覆盖工作流、CAS/回滚、来源多重集、完整字段搜索与摘要上限、损坏候选不吞掉新原件、取消、epoch、无关操作并发和 pinned GC。父级独立运行 `scripts/test.sh --filter 'sqliteReport|sqliteKernel|sqliteRealProcesses|sqliteOriginalsRecover|sqliteInitializationRecovers'`，35 个 Platform 声明及 3 个真实进程声明通过；随后加强同一测试，明确断言 nullable extraction version 与完整用户 review document 在保存、确认及重开后保留，定向复验通过。warnings-as-errors 构建通过。实际已构建主 inventory 为 **1055 tests / 91 suites**，参数化 case 与隔离进程不重复计入。 使用该 inventory 的文档门禁、当前树隐私门禁及 diff 检查通过。
- **后续边界**：U5 LAN/规范化 DICOM、U8 App 按需查询和提交观察、U6 逻辑快照/严格恢复/导出尚待完成；数据库规模性能、完整后续回归、macOS 26 engine、真机/人工与 clean-source 发布门禁尚未通过本单元验证。没有 commit、push、PR 或替换用户安装。


## [2026-10-11] refactor/sqlite | LAN 上传、OCR 与单事务归档

- **范围**：新增 SQLite LAN store、typed row codec、上传归属和归档事务；Receiver、Mac pending workflow、预处理与 LiveLANInboxService 共用注入的 owner/admission policy。schema 现为 18 张 STRICT 表，新增 inbox_uploads 与 inbox_archive_receipts。同步旧 JSON 调用者，生产 composition 尚未切换。
- **持久化**：上传先登记 ownership，再接收字节；完成后校验、同 inode rename，在一事务中发布 original/item/receipt。sink 真正关闭 descriptor 后释放活动登记；响应丢失查询 durable receipt。OCR/source 文档与队列状态同事务，归档不复制原件；完整 command/intent/outcome 保留最近 5,000 个完成命令。LAN source 32 MiB、报告 16 MiB、组合读取 128 MiB 分别保持，上传不新增 100 MiB cap。
- **红绿修复**：真实回归复现并修复缺失/硬链接原件未隔离、归档 session/content 笛卡尔积，以及 scope 撤销先于已经通过 token 检查的 SQL 提交返回。最后一项用现有 GRDB trace 暂停真实 receipt INSERT，无新增生产 hook；scope 创建/撤销与提交共用 admission，并通过 @concurrent 避免阻塞调用方执行器。局部原件 descriptor 错误映射不吞掉 owner/root/DB 全局身份错误。
- **验证**：worker 定向回归 Process 1 个声明/5 个真实 crash case、Platform 76/8 suites、App 1 全过，含 JSON/SQLite 两条真实 HTTP 回压链路；后续局部原件错误映射及 scope 修复各有定向绿测。父级运行 `scripts/test.sh --filter 'sqliteLAN|sqliteKernel|sqliteOriginal|sqliteReport|LANReceiverFileLifecycleTests|LANReportArchiveTests'`：Process 2 个声明/12 个 case、Platform 59/2 suites、App 1 通过。SQLite socket 测得 RSS 增量 212,992 bytes、event-loop p99 390,917 ns、stop 4,054,667 ns；仅为当前 Mac 定向证据，不冒充 footprint、队列规模或真实手机验收。
- **测试账本**：实际 executable inventory 派生为 1069 tests / 91 suites。首次派生因既有 socket 测试改为 `(sqlite:)` 参数后精确隔离选择器未同步而失败；同步分片脚本及其现有安全测试 fixture，保留精确选择与隔离规则；13 项 TestScriptSafetyTests 通过。使用实际 inventory 的文档门禁、当前树隐私与 diff 检查通过。参数化 case 与独立 storage-process 声明不重复计入主账。
- **边界**：普通 LAN snapshot 仍读取有界全队列并严格处理关系错误，U8 须进一步验收按需 UI、单项损坏隔离、通知及近上限耗时；DICOM、逻辑备份/恢复、统一切换和全部性能门槛仍待完成。未跑全量后续回归、安装或 macOS 26/真机/人工矩阵；未 commit、push、PR 或触碰真实资料。


## [2026-10-11] refactor/sqlite | 规范化 DICOM 图与目标序列读取

- **范围**：新增 DICOMStudyHeader、SQLite DICOM repository/row codec、scanner 原件接管和 slice source；导入 workflow 与 Viewer 共用既有 scanner/indexer/decoder/scheduler。study、retained object、series、instance 的关系和图摘要写入既有 18 张 STRICT 表，不保存 index JSON/BLOB。生产 composition 仍为 JSON，尚未统一切换。
- **原件与事务**：活动 operation 覆盖 scanner 到最终发布的全部间隙，恢复跳过活动操作，关闭/替换拒绝未结束导入。同卷接管沿真实 inode 登记、rename、同步目录；完整原件校验在 admission 外执行，提交前核对身份、大小和时间戳，一个事务发布完整图及一次 revision。响应丢失按 operation 和严格图收敛；替换 inode 保留并报告。真实 SIGKILL 覆盖 scanner、登记、接管、data rename 和最终 live commit 五个交接窗口。
- **查询与完整性**：库头最多 256 个 study，详情只加载 series；Viewer 按目标 series 读取实例，以库 epoch、study revision、series ID/语义摘要围栏，原件 pin 跨异步 decode 保留。严格图验证覆盖连续 ordinal、引用闭合、指纹、UID 域、尺寸和几何顺序。局部坏图/原件只隔离目标，owner/root/DB 全局错误继续透传。
- **红绿修复**：真实红测分别发现确认绕过严格图、同 revision 篡改 series 未使缓存失效、FIFO 阻塞、原件哈希后同 inode 改写仍提交、ordinal 缺口、非有限元数据错误分类和 cached hardlink 被误判全局错误；均有修复及定向绿测。异步 descriptor 在验证 closure 内立即交给 FileHandle 持有，避免后置校验抛错泄漏；没有新增 unchecked Sendable。
- **验证**：worker 完整定向回归 Process 1 个声明/5 个真实 crash case、Platform 79 个声明/104 个 case、App 4 通过，之后 cached hardlink 微修复的 4 个声明/5 个 case 通过。父级独立组合回归 `scripts/test.sh --filter 'sqlite|DICOMImportWorkflowIntegrationTests|DICOMSliceVaultIntegrationTests|DICOMStudyIndexerTests|LiveDICOMAppServiceIntegrationTests'` 通过 Process 5 个声明、Platform 108/5 suites、App 5/1 suite；微修复后同 4 个声明/5 个 case 再次独立通过。
- **资源证据与边界**：220 个合成原件导入测得最多 3 次受管读取、2 次写入，worker/队列各不超过 2，source/staging FD 不超过 8 且最终归零，磁盘峰值不超过 2S + 256 MiB。此口径仅覆盖导入；未缓存 Viewer 仍有 4 次 pin 哈希及 decoder 读取，首次切片/连续浏览延迟尚未规模实测。逻辑备份、App 按需查询、统一切换及完整后续回归继续推进；macOS 26、安装、真机和人工门禁未执行，未 commit、push、PR 或触碰真实资料。

- **账本收口**：实际已构建 executable inventory 为 1093 tests / 91 suites；参数化 case 与隔离进程不重复计入主账。使用该 inventory 的文档门禁、当前树隐私与 diff 检查通过。


## [2026-10-11] refactor/sqlite | 逻辑备份、严格恢复与原件导出

- **范围**：新增版本化 logical-v1、严格领域流与冻结格式夹具、SQLite backup/ZIP source、共享 owner 的恢复服务链路；外部恢复点不保存 SQLite 文件或 schema。生产 composition 仍为 JSON；没有自动迁移或替换用户安装。
- **一致性与资源**：同次 admission 获取 revision/可达原件 pin 并复制应用自有数据库，随后在副本上逐项校验逻辑图。该调整依据原实现在近上限的 5 秒超时，保留外部逻辑格式决策。临时副本 receipt 在 payload 前持久化，按确切 inode 清理；未知工件保留。spool 立即 unlink，分段读取，原件按需打开。恢复根据实际认证记录和关系数量计算空间预算，在本应用创建的新数据库中写入，准备与激活后都严格验证。
- **错误与生命周期**：真实旧 JSON checkpoint 在 SQL reader 返回 unsupportedFormat，保持输入与当前库；取消/超时 progress guard 只作用于当前连接读取并保留语义，随后查询可用。恢复先排空真实 lifecycle，再关闭数据库，owner 持续保护 root transaction；启动先事务收敛，再清理 capture/preflight。捕获后的合法编辑/删除保留快照旧版本，释放时批量归还 pin。
- **验证**：worker 先记录格式拒绝与缓存预算的实际红测并修复；最终定向回归 118 个声明通过。父级独立执行同组 `scripts/test.sh --filter`，Process 3、Platform 93、Core 16、App 6 全过；真实 process 包含 13 个 root 恢复/损坏场景、6 个内部 capture 崩溃/身份场景及第二 owner 拒绝。覆盖真实加密 publisher/readback/witness、恢复后继续编辑/DICOM/ZIP、两个独立冻结 wire 夹具、容量不足与取消。
- **测量**：Release 近上限最终 capture 持锁 1.302 s、完整逻辑准备 22.598 s、进程峰值 24,183,480 bytes、增量 18.42 MiB、采样 FD 峰值 10。先前超内存来自系统 engine 的 dirty spill 阈值；修复只限临时副本，源码与点时证据见 [实测](storage-refactor-measurement-2026-10-11.md#sqlite-逻辑捕获)。单次 capture 不等于完整备份、p95 或最大理论资料库保证。
- **账本与待办**：实际已构建 inventory 为 1116 tests / 91 suites，参数化 case 和隔离进程不重复计主账。继续补齐原件提交/失败清理、实体编码预算，随后 U8 按需 App 查询和 U7 统一切换；完整大规模备份/恢复、全量后续回归、macOS 26、安装与人工门禁待完成。用户确认当前没有可提供的 macOS 26 连接，本机为 macOS 27.0.1；未 commit、push 或创建 PR。


## [2026-10-11] refactor/sqlite | 原件提交围栏与精确操作清理

- **实证缺陷**：新增真实红测 5 个声明 / 9 个参数化场景，记录 22 个断言失败：报告/LAN 可以在完整 hash 后发布改写原件，stage 返回值未拒绝 fsync 后改写，pin 未发现消费中改写再恢复，以及 DICOM 成功/取消清理会删除另一项报告的 staged 原件。
- **修复**：复用一个 stat snapshot，完整 hash 前后、rename 前后、live 提交前和 pin 消费前后保持身份/大小/时间戳一致；仅 rename 允许 ctime 改变，不增加完整 hash 次数。DICOM 运行期改为 exact operation 非 live 清理，启动仍全库恢复；活动、引用、pin 或未知 inode 保留并显式报告。
- **验证**：worker SQLite 全域及真实进程定向回归共 111 个声明通过，含新增 5 个声明和强化的 active/unknown 清理断言。父级已检查实际共享 helper、报告/LAN/DICOM 调用方及保留 U6 owner/strict-open/batch-pin 契约，独立组合回归结果按本段后续账本记录。
- **简化**：通过 ce-simplify-code 三个只读视角复核 U6，应用 1 项 quality 简化：普通捕获直接调用冻结副本路径，strict 恢复路径移除恒真的参数分支；不改变任何有效校验或错误语义。reuse 无建议；3 项效率建议暂不采用，避免为未证实瓶颈新增 rolling hash/metadata cache 状态或改变写后回读边界。另修复 2 处测试 warning；验证使用上述组合回归。
- **边界**：本单元不切换生产，不自动迁移、不删除未知文件。U4 将复用精确清理入口处理失败报告导入；U8 与 U7 继续推进。macOS 26、完整规模和最终发布门禁仍未执行，无 commit/push/PR。

- **父级收口**：独立组合命令 `scripts/test.sh --filter 'sqlite|SQLiteLogical|EncryptedCheckpointRestoreTests|BackupRestoreServiceTests'` 全部通过：Process 7、Platform 109 / 4 suites、App 7 / 1 suite，共 123 个声明。实际 executable inventory 为 1121 tests / 91 suites。简化后正常 capture 的 5 秒围栏和 strict 恢复的完整验证路径分别保留，没有扩宽时间或格式门槛。
- **质量门禁**：父级 `scripts/lint.sh`（传入实际 inventory）通过，包含文档、全项目 warnings-as-errors 构建及 package graph；privacy guard 与 diff check 通过。ce-simplify-code 本阶段验证完成，后续 App/切换修改仍需最终全量审查。


## 2026-10-11 — SQLite 实体预算与失败报告导入清理

- **事实与范围**：新增 Core 的 16 MiB 单实体编码预算及 Platform 的实际转义字节预检；成员、草稿和完整来源集合的写入、读取和逻辑恢复共用 codec。Core 构造语义、存储内容和 logical-v1 数值上限不变；这是新 SQLite 格式约束，不冒充旧 JSON 清单规则。
- **有界读取**：成员搜索使用 cursor，只保留匹配 ID；来源先 COUNT/SUM 字节预检再逐行验证。完整成员列表暂受已有 128 MiB 快照读取预算限制，合法更大资料库仍能按 ID 读取、搜索和逐项备份；U8 将接入 App 摘要，当前不声称已通过整机内存目标。
- **导入清理**：捕获 staging 尚未返回 ID 的失败，按 operation 精确回收非 live 原件；已提交响应丢失先核实来源身份，即使草稿状态已前进也返回已创建。其他操作、live 引用和未知 inode 保留。
- **proof-first**：原实现的实体超限和失败清理有 4 个声明、16 个断言的真实红测；另一真实红测证明已提交且进入 processing 的草稿曾被误报失败。修复后 worker 跨域回归 115 个声明、最终实体边界 12 个声明通过，含精确 16 MiB 逻辑恢复、135 MiB 成员库和失败清理；warnings-as-errors 构建、隐私与 diff 检查通过。
- **未完成**：生产仍选择 JSON；U8 按需 App 查询、U7 统一接入、最终完整规模/全量回归与 macOS 26 门禁待完成。无 Git 提交或发布。

- **父级收口**：独立运行 `scripts/test.sh --filter 'sqlite|SQLiteLogical|EncryptedCheckpointRestoreTests|BackupRestoreServiceTests'` 通过 Process 7、Platform 121 / 4 suites、App 7 / 1 suite，共 135 个声明；actual executable inventory 为 1133 tests / 91 suites。实体边界、原件故障和既有逻辑备份/恢复、LAN、DICOM 链路均在这次回归内。


## 2026-10-11 — U8 按需 App 查询与文本保真集成

- App 使用 header、混合时间线/草稿分页、按 ID 复核/详情及最多两项比较；补齐请求/epoch 围栏、取消排空、提交流重建和 Viewer 目标失效。生产仍选 JSON 临时适配器，未进行 U7 selector 切换。
- SQL 热投影在返回前检查字节预算，搜索保持完整 Foundation 语义与 confirmed-only。近上限 20 次采样的完整搜索 p50 为 64–121 ms，LAN 4,990 项热队列 p95 为 157 ms，均有未通过门槛；原始口径和边界见 [实测](storage-refactor-measurement-2026-10-11.md#sqlite-按需查询)。这些采样早于下述文本修复，不能作为最终源码复测。
- 固定 GRDB 的 C 字符串绑定/行拷贝导致合法 NUL 文本被截断，成员、摘要和真实加密恢复三项回归先失败。现以完整 UTF-8 字节绑定并在 cursor 内复制，保留 NULL/空串、Unicode 和 NUL；原件 metadata、来源、编辑、搜索、导出与 logical-v1 恢复使用相同边界。非法 UTF-8 在实体 codec 中拒绝，正常项不被隐藏，未变更 schema/hash/wire。
- 强化已有 active partial inode 替换测试，先复现整屏 integrityCheckFailed；随后在物理检查中隔离该 upload，返回前重新验证 root/epoch，未知文件保留。该回归不等于最大活动上传队列性能验证。
- 父级 `scripts/test.sh -Xswiftc -warnings-as-errors --filter 'sqlite|SQLite|LibraryQuery|ComparisonModelTests|AppModelTests|LiveAppServiceTests|ImportReviewModelTests|DICOMAppModelTests|DICOMLibraryModelTests|DICOMStudyReviewModelTests|LANInboxModelTests|BackupCompositionTests|BackupRestoreServiceTests|AppLocalizationTests'` 通过：Process 7、Platform 128 / 4 suites、App 203 / 17 suites，共 338 个测试声明，参数化 case 另计。实际 executable inventory 为 1160 tests / 93 suites，账本保持 not-verified / pendingManual。
- SQLite 开库、整库替换写操作排空和后台完整巡检的最终组装仍由 U7 完成；macOS 26 当前没有可用连接，未获得替代验收豁免。安装、真实手机、人工 OCR/VoiceOver 和完整 SQLite 容量/性能矩阵未据本次回归判定通过。

- 本阶段简化采用 ce-simplify-code 的复用、质量和效率三个只读检查，应用两处等价复用（既有原件 payload 映射、成员字节表达式）；不改写完整性验证、匹配语义或刷新时序。简化后定向回归 Platform 6、App 57 / 3 suites 通过，完整 lint（含 warnings-as-errors、文档及 package graph）通过；privacy guard、文档链接和 diff 检查通过。最终全分支审查仍待余下单元完成。

### U8 文本保真后规模复测

- 独立 Release fixture warnings-as-errors 构建通过；同一合成 SQLite 报告库与 LAN 库按预热一次、20 次采样串行复测，完整有序搜索结果保持 Core 原谓词一致。
- 搜索稀有词完整结果 p50 / p95 为 118.965 / 134.626 ms，LAN 屏幕快照 p50 / p95 为 196.265 / 207.082 ms，均仍未满足计划门槛；全部词集、最大值及测量边界见 [规模报告](storage-refactor-measurement-2026-10-11.md#文本保真修复后复测)。不以本机正确性回归替代性能、macOS 26 或安装验收。
- U8 简化后 63 项相关测试通过，完整 lint 通过；生产仍为 JSON。后续仅推进可测试的统一启动、恢复和生命周期候选，实际生产选择切换仍受计划门禁约束。


## 2026-10-11 — U7 SQLite 候选启动与完整性链路

- 构造保持惰性，接受明文说明后依次取得单 owner、收敛恢复/capture/preflight/删除 receipt、打开 SQLite，再组装全部角色。占用可重试；未知库保留字节并提供同 owner 的恢复入口，未知 receipt 不作为破坏性操作授权。默认生产入口仍为 JSON。
- 普通命令和按需读取纳入共享 lifecycle，撤销后拒绝新任务并等待真实终态；已持久提交的响应不因随后 revoke 被误报失败。空闲巡检可取消，前台操作与并发等待者均等待同一任务排空；巡检按实体检查，局部损坏隔离目标，结构/owner 失败撤销全局活动。
- 已发现的原件损坏传播到相关报告/草稿/inbox/study，覆盖预览、DICOM 缓存命中、ZIP 与加密备份。真实 RED 证明备份外层摘要失败曾未隔离记录；小型 reader 回调复用现有完整 hash，writer 和 strict 两条参数均验证只读一次原件。
- Worker 最后串行 warnings-as-errors 定向回归 Process 3、Platform 69、App 65，共 137 个测试声明通过；新增 25 个声明、3 suites，实际 executable inventory 为 1185 / 96。先前未显式串行的 DICOM 共享运行时测试失败保留在原始证据中，未修改生产调度来掩盖；最终串行重跑通过。父级独立跨域回归另行登记。
- 合成单报告 Debug 实际 App candidate Ready 25.6095 ms、此前原件读取 0 bytes；该入口还覆盖 service DTO、ZIP 与删除。不是 Release、安装或规模门槛，不能推广到近 5,000 项 LAN 冷启动。并发账本更新为 82 个 unchecked / 45 files，新项仅为加锁的原件读取计数。
- 生产 selector、搜索/队列性能、完整规模备份与恢复、macOS 26、安装、真实设备及人工门禁未据此通过；未 commit、push、创建 PR 或操作真实资料库。

- 父级独立跨域运行：Process 7、App 241 / 23 suites 通过；Platform 154 / 4 suites 中，既有 LAN 缺失原件/异常硬链接的两个参数失败。根因是 pin 先隔离目标，随后持久写入 integrityFailed 又被普通读取禁令拦截。仅该损坏状态转换改用严格行 codec，保留 epoch/目标相等检查及所有正常读取禁令；原测试加强为真实关闭/重开。强化测试先 RED，修复后 Process 1、Platform 17、App 35 / 2 suites，共 53 个声明通过。未将首次失败命令登记为全绿。
- 父级检查实际源代码与共享调用方，文档链接、privacy guard、本地化资源和 diff 检查通过；实际库存与严格 lint 的结果另行登记。

- U7 父级收口：实际 executable inventory 1185 tests / 96 suites；传入该库存的 `scripts/lint.sh` 通过（含 warnings-as-errors 构建、文档与 package graph）。本机证据仍未绑定不可变发布 source ref，账本保持 not-verified / pendingManual。


## 2026-10-11 — U8 LAN 分页与真实调用链

- 新增独立队列页/游标，SQL 首批最多 100 项，全队列 metadata 数量和内容字节独立聚合；损坏行推进游标，原件/冷 OCR 保持按需验证，活动 partial 继续在 admission 外检查物理身份。初始化、预览和删除避开丢弃的全量快照。
- App 可跨页保留选择，32 项限制仅约束单次严格查询与归档来源，不缩减原有批量删除。后台处理独立遍历工作页，未显示项仍会执行，完整扫描后才清理尝试记录。真实 SQL/service/model 测试覆盖隐藏第 201 项只处理一次、页外选择、陈旧 revision 与迟到页面。
- 强化坏邻居预览测试先得到两参数 RED；父级另发现临时 JSON 适配器将 lastWriter 标识误用为 open epoch，真实双 writer/service/model 测试先得到列表不刷新与 staleCursor RED，再以读取实例稳定标识修复。未削弱 SQLite 的 root/epoch 围栏。
- Worker 最终显式串行 warnings-as-errors 回归通过：Process 1、Platform 78、Core 8、App 75，共 162 个声明。实际 executable inventory 为 1190 / 96，非完整主账运行；并发库存仍为 82 / 45 files。父级独立回归与 lint 收口另行记录。
- 最终 Release 同库预热一次、20 次采样，Platform 首批 100 项 p50 / p95 / max 为 7.151 / 7.648 / 7.705 ms，峰值 footprint 14,910,160 bytes；精确边界和原始样本见[规模报告](storage-refactor-measurement-2026-10-11.md#lan-首批-100-项分页复测)。生产仍为 JSON，搜索、完整规模备份/恢复、macOS 26 与安装/人工门禁未据此通过。
- U7 的三类只读简化复核没有复用/质量必改项；两项效率提议（原件二次 admission、UI 巡检进度合并）尚无性能和行为证据，本轮未改变它们的验证与通知时序。完整分支审查仍待余下单元完成。

- 父级独立串行回归通过：Process 1、Platform 78、Core 8、App 92 / 11 suites，共 179 个声明；实际重新发现库存 1190 / 96，并以该库存运行严格 lint 通过。privacy、本地化、文档和 diff 检查通过。
- 父级另强化既有分页测试：刷新失败后“重试载入”曾误取下一页（201 项而非刷新后的 100 项），真实 RED 后改为按语义错误重试初始化/刷新/翻页，仅读取错误显示该按钮；没有添加自动重试。修复后相关模型、界面、本地化与真实 SQL/JSON 服务链路 60 个声明 / 4 suites 通过，测试库存不变。

- 上述重试修复后的最终严格 lint 再次通过（实际库存 1190 / 96，warnings-as-errors、文档和 package graph）；Platform 性能路径未改变，不重复运行已完成的 20 次测量。


## 2026-10-11：SQLite 独立规模闭环复核

- 扩展独立 `StorageScaleProbe` 的四个 logical 模式，没有加入主测试清单或更改生产存储。真实仓库生成、加密发布及严格恢复覆盖近上限报告、实际约 9.76 GiB 原件，以及 20,001 原件 / 容器条目推导下界 20,002；完整数值和不确定性见 [测量页](storage-refactor-measurement-2026-10-11.md#sqlite-完整规模闭环)。搜索 RED 保留，生产 selector 仍为 JSON。
- 父级复核实现差异、原始样本及独立统计后，在新的私有临时目录重新执行 50 报告生成、启动、20 次短操作、完整发布/恢复及 20 草稿加 LAN 容量闭环，五个命令均退出 0。首次受工具 sandbox 限制的容量属性查询未取得可用值，探针保守退出 75；获得本机执行权限后同一源码/二进制通过，未放宽空间门禁。
- 单元最终 Release warnings-as-errors 构建、七项 CLI 边界检查、严格 lint、privacy、文档与 diff 检查通过。完整主测试、安装 App Ready/可见更新/交互内存、混合 OCR/LAN/备份、macOS 26 和人工矩阵未由本探针覆盖。保存计时证明 reviewState 持久化；探针确认用原 candidates，不替代 App 采纳用户修订的真实 service 测试。


## 2026-10-11：LAN 分页简化与验收指标命名

- 按三路静态审查，采用两项等价简化：`LANInboxModel` 从已发布 page 推导游标/hasMore；`SQLiteLANInboxStore` 共享相同的有界 upload SQL/codec。原件身份检查、取消、损坏隔离和读取 epoch 围栏保持原位置。复用既有行为测试，没有添加镜像实现的单元测试。
- 父级串行 warnings-as-errors 定向回归通过，覆盖 LAN 数据库/Receiver/真实 service、分页选择、失败重试、隐藏队列、生命周期及本地化；测试声明库存不变。未采用会改变处理任务再唤醒语义的建议，也未因已达标的首屏查询引入额外批处理；仅由测试使用的旧快照 helper 留待统一清理时连同调用方处理。
- 候选验收探针的 `lanFullSnapshotMilliseconds` 更名为 `lanFirstPageMilliseconds`，对应实际首屏服务调用。这是内部尚未发布的测量字段更名，没有改变载入范围或用户界面。


## 2026-10-11：共享 OCR 来源归属与候选验证同步

- 将本地重新识别、LAN 预处理和 Core 单来源 fallback 的同一 `OCRBlock` 构造收敛到一个方法，生产代码净减少 15 行；保留各入口的来源权威、ID 分配顺序、文件页码及已有归属的严格校验。复用既有校验、抽取和候选机制，没有新增通用 pipeline 或未经测量的 Data lease。
- 先补真实 SQLite 本地/LAN 对照与失败重试的两项声明，并强化已有 Core 来源测试，在改动生产代码前观察到 GREEN；修改后 worker 的 52 项定向声明执行通过。父级独立复核实际五个文件后，串行 warnings-as-errors 再验 Platform 10、Core 12、App 6 个声明，全部通过；覆盖大于 128 MiB 的逐原件识别、途中 revision 变化、取消、LAN 缓存/重排及保存边界。
- 实际已构建 executable 清单经主测试 planner 得到 1192 tests / 97 suites，验收账本按观察值更新；没有把参数化 case 重复计为声明。修正 storage 专题仍把已接通的按需查询、逻辑备份与导出写成待实现的旧句子。生产仍使用 JSON，macOS 26、安装 App 及混合 OCR/LAN/备份资源门禁未完成。
- 额外搜索 scratch 在完整摘要和行摘要都实际比较、完整 ID 对照一致的条件下，测试预先解码/native UTF-16 与流式行摘要；稀有词/日期的纯 CPU 成本仍约 41–48 ms，未含 SQL/copy/cold cache，三次样本不作为门禁证据。没有据此加入永久缓存、索引或并发流水线，原正式搜索 RED 保留。


- 完整候选回归首次运行在主题源码测试发现两条过期断言：共享存储说明已移到 `StorageDisclosureView`，测试仍在 `AppShellView` 搜索主/次按钮样式。保留失败日志，核实组件仍有原样式后，将断言对齐实际组件，并检查 JSON/SQLite 两个启动入口都使用它；保留禁止默认样式的旧入口扫描。定向主题、启动与本地化 45 项声明通过，库存不变；随后重新运行完整套件，不把此前已通过分片冒充全量成功。


- 修复共享组件断言后的完整 `scripts/test.sh --no-parallel -Xswiftc -warnings-as-errors` 退出 0：主清单 1192 tests / 97 suites，另有 13 个独立 derived-artifact XCTest、14 个验收扫描测试、40 个 storage process 测试、1 个本卷别名锁、18 个 DICOM 导入集成测试、安装身份 LAN HTTP 测试及真实双流 LAN 测试通过。Swift Testing 的 target platform 字串不是运行系统证明；本次环境仍为 macOS 27。
- 本次双流 socket 校准，SQLite 路径 RSS 增量 278,528 bytes、event-loop p99 530,167 ns、listener stop 5,266,542 ns；JSON 对照也通过。数字仅属于 socket fixture，不替代 App 512 MiB 或混合 OCR/LAN/备份 608 MiB 门槛。完整重构的源代码检查通过不自动成为绑定 clean-source 的发布验收。


## 2026-10-11：候选复核与故障链路收口

- 完成整个未提交候选（含未跟踪源码）的独立审查，确认三项必改：损坏目标仍有已打开的缓存页面、数据库基础设施错误未撤销 LAN/lifecycle，以及 DICOM study 的不受限 domain 字段先复制后验证。文件长度类建议没有可复现后果，未据此重写模块。
- DICOM 复用 SQL 有界投影，列表/详情/逻辑备份/导出共用。现有损坏测试增加超长字段参数及连接长度上限，真实 RED 曾使整个列表返回 databaseUnavailable；修复后 98 项关联声明通过，坏项 ID 保留而健康邻居可读。
- App 回归先复现已打开报告、比较和草稿残留，以及巡检已完成后报告表失效仍能接收 LAN。修复将基础设施错误接入独立持有的停机任务，先关闭任务 admission，再并行排空 UI/服务，等待 Viewer 释放后要求重启；局部损坏只关闭相应页面并保留语义错误。详情、提交观察、巡检三条真实链路回归通过。测试中 Viewer 的关闭通知发生在 drain 之后，相关断言放在 gate 释放后，未改变生产时序来满足测试。
- 既有命令撤销测试改用已注册 revocation hook 的信号，去掉依赖 30 ms 调度间隔的假设。页面重开补充请求身份和同一复核实例检查；最终完整回归和 lint 单独登记。
- 复核前的本机 dirty-source Release/XPC 构建、deep/strict 签名、精确资源、GRDB privacy、最低系统及 helper/main 依赖隔离通过；复核修复后的工件另行验证。未执行要求 clean-source 的完整 verify-app，也未安装、启动或操作真实资料库。生产仍为 JSON；搜索、macOS 26、安装和混合负载门禁继续保留。

- 复核后已构建 executable 的主测试 planner 实测 1194 tests / 97 suites，比前一轮增加两项集成声明；参数化故障入口不重复计数。最终完整重跑前发现复核实例 ID 仍为 private 的编译错误，改为模块内只读 let 后重新构建，未将编译失败记作行为 RED。privacy guard 与 diff 检查通过。

- 复核修复后的完整 `scripts/test.sh --no-parallel -Xswiftc -warnings-as-errors` 退出 0：1194 tests / 97 suites，13 derived XCTest、14 验收扫描、40 storage process、本卷别名锁、18 DICOM 导入、安装身份 LAN HTTP 与真实双流 LAN 全部通过。本次 SQLite socket fixture RSS 增量 344,064 bytes、event-loop p99 698,250 ns、listener stop 5,212,583 ns，仍只代表该 socket fixture。
- 全量通过后额外核对取消语义：刷新抛 CancellationError 曾触发一次全局停机，参数化旧测试得到实际 RED；补充取消分支后，App/SQLite 启动、查询、比较、复核及故障链路 109 tests / 9 suites 通过。全局故障参数另覆盖比较错误回调所创建的受跟踪任务，证明不会等待自身；该参数最初漏启比较选择模式，已修正测试前置条件并断言选中 ID，不将它记为产品缺陷。主声明库存仍为 1194 / 97。

- 最终严格 `scripts/lint.sh` 传入实际主清单后通过；随后 `scripts/build-app.sh` 重建 App/XPC 成功，构建期间 206 个变更文件 hash 保持一致。对最终工件额外检查 deep/strict 签名、13 项精确资源、GRDB privacy/许可、arm64 与最低 macOS 26.0、Helper 不链接 GRDB/SQLite、主程序不含 DICOM codec，全部通过。上述是 dirty-source 本机静态证据，未执行 clean-source verify-app、安装或运行候选 App；生产仍 JSON，搜索与系统/安装/混合负载门禁仍未通过。

## [2026-10-12] merge | 把 main 的时间线、配色、品牌与 CI 更新并入 SQLite 重构分支

- **范围**：先把此前只存在于工作树的 206 个文件固定为 `8aec3f5`，再把 `origin/main@7b41ced`（PR #16–#20）合入 `codex/sqlite-refactor`。16 个文件、30 处文本冲突；另有不产生冲突标记的语义差异，按下列方式处理。生产 composition 在本次合并后仍选择 JSON。
- **时间线筛选接到分页查询**：main 的“全部 / 报告 / 影像”原先在内存里过滤整份目录。现在“全部”走混合时间线分页，“报告”走空查询的报告分页（两条存储路径都按时间线次序返回全部已确认报告），“影像”直接使用库头里已有的已确认检查，不发起分页读取；影像筛选下的搜索结果为空。筛选变化与成员、搜索词一样重置游标和请求身份。
- **进入时间线自动打开最新记录**：分页是异步的，[`AppModel.openNewestRecordIfNothingIsOpen`](../Sources/KinlogueApp/App/AppModel.swift) 先等当前页，再按 ID 读取记录；自动打开失败不弹提示，手动打开同一条仍会提示。
- **切换成员清空已打开的记录**：重构分支曾把这一行为改成保留，main 及重构前都是清空，自动打开最新记录也依赖它。按 main 恢复，并把对应断言改回。
- **待确认草稿显示文件名**：`LibraryDraftSummary` 增加首个来源的文件名。SQLite 草稿分页读取 `report_sources` 中 position 0 的一行并校验该行摘要；超过 1,024 字节的合法名称不进入列表投影，草稿仍然列出；该行摘要不符时只把这一份草稿记为损坏。旧 JSON 适配器取同一字段。
- **侧栏计数**：草稿队列按页载入，“待确认（N）”只在整个队列载入完成后显示数量，载入中、失败或还有下一页时显示不带数量的标题。
- **其余**：main 删除的影像侧栏分区和 `DICOMLibraryView` 不再保留；`verify-app.sh` 的精确资源清单同时包含 `Assets.car` 与 GRDB privacy manifest；String Catalog 按 key 合并（采用 main 的 11 个新增和 4 个删除，保留仍在使用的“待确认”），英文运行时资源由 `compile-localizations.sh --write` 重新生成；重构新增的载入更多 / 重试按钮改用共享按钮样式。
- **测试**：main 新增的 App 测试改用只携带库头的 `AppSnapshot` 加完整合成状态的测试替身，并在筛选、成员或搜索变化后等待当前页。新增 [`sqliteDraftPagesNameAWaitingDraftAfterItsFirstOriginal`](../Tests/KinloguePlatformTests/SQLiteLANInboxTests.swift)，用真实数据库覆盖有文件名、无文件名、名称过长和来源行被改四种情况。
- **验证**：macOS 27.0.1 / Xcode 27 上，合并后的完整 `scripts/test.sh` 退出码 0，主清单 1242 tests / 98 suites，隔离的 derived XCTest、验收扫描、storage process、本卷别名锁、DICOM 导入集成、安装身份 LAN HTTP 与真实双流 LAN 用例全部通过。传入实际清单的 `scripts/lint.sh`（warnings-as-errors 构建、文档、package graph）、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 通过。
- **未执行**：合并后没有重新构建或验证 App bundle（`verify-app.sh`、`verify-dicom-xpc.sh`），因此新图标资源与 GRDB 资源同时存在的精确清单只有源码断言，没有实际包证据；没有重跑规模探针；macOS 26、安装验收、真实手机和人工门禁未执行。搜索门槛未通过、生产 selector 未切换的状态不变。

## [2026-10-12] perf/sqlite | 搜索改用不漏结果的预筛键并按摘要缓存解码结果

- **基线与定位**：在合并 main 之后的源码上重新生成近上限合成库（9,990 份报告 / 9,791 条已确认），旧实现的完整结果为稀有词 119.2 / 137.7 ms、无匹配 91.5 / 158.2 ms、中文短词 58.7 / 61.3 ms，与此前记录一致。其中约 34 ms 是按时间线次序连接两张表的 SQL 读取，其余主要是每次查询对全部行做 JSON 解码和 Core Foundation 子串查找。
- **实现**：[扫描](../Sources/KinloguePlatform/Storage/SQLiteReportSearch.swift) 改为按存储顺序读报告目录并在内存排序，再顺序读全部搜索行；每行字节仍然每次重算两个摘要。新增 [预筛键](../Sources/KinloguePlatform/Storage/SQLiteReportSearchKey.swift)：逐标量兼容分解、大写再小写映射到稳定、只保留字母与数字，用来跳过不可能命中的字段，命中仍只由 Foundation 谓词决定。解码后的字段和键按行缓存在打开的数据库对象上，只有本次读到的字节摘要相同才使用，预算 64 MiB，关闭或替换数据库时清空。连接页缓存设为 32 MiB。没有改 schema、行摘要或 logical-v1。
- **不漏结果的证据**：[`SQLiteReportSearchKeyTests`](../Tests/KinloguePlatformTests/SQLiteReportSearchKeyTests.swift) 对照运行系统上的真实 Foundation：穷举全部标量的大小写与规范等价变体，要求键完全相同，并要求 Foundation 能匹配的变体对键也能匹配；另有多文字、九个 locale 的语料和固定种子的生成文本。把键里的大小写映射故意改成只转小写后，两个穷举测试都失败并报出 ß、ı、ς、U+0345 等字符，恢复后通过。设计依据记在 [实现核对](sources/2026-10-12-corefoundation-find-implementation.md)，它不替代上述测试。
- **顺带修复的 Foundation 缺陷**：搜索词以 NUL 结尾时，带 locale 的 Foundation 搜索越过文本末尾读取；macOS 27.0.1 上 `"ungla"` 被报告包含 `"A\0"`，`"合成"` 搜索 `"成\0"` 会以 `String index is out of bounds` 终止进程。main 上的 JSON 搜索同样受影响。[`RecordQuery.localizedContains`](../Sources/KinlogueCore/Domain/RecordQuery.swift) 在这种词下给被搜索文本补一个非 NUL 单元，两条存储路径共用，并有 Core 测试。
- **测量**：同一资料库、Release warnings-as-errors 探针、预热一次后 20 次采样：完整结果 p50 / p95 为无匹配 28.8 / 30.5 ms、稀有词 28.2 / 28.9 ms、日期 28.5 / 29.3 ms、中文短词 28.1 / 29.2 ms、成员 27.8 / 28.6 ms；首页 p50 不超过 35.2 ms、p95 不超过 36.5 ms。另一轮无匹配查询的 p95 为 41.7 ms（首页 44.2 ms）。全部低于计划的 p50 50 ms / p95 100 ms，完整有序 ID 与不使用键和缓存的参考路径相同。新进程第一次搜索约 50 ms，峰值 footprint 从 23.1 MB 升到 79.8 MB。口径、基线和未测范围见 [搜索复测](storage-search-measurement-2026-10-12.md)。
- **行为变化**：搜索首页不再提前结束扫描，命中很多的查询首页从约 12 ms 变为约 35 ms。报告缺少搜索行、字节与摘要不符时仍作为损坏项返回。
- **测试**：新增 9 项声明（预筛键 5 项、Core 的 NUL 结尾词 1 项、缓存有效性 / 结果次序 / 缓存预算 3 项），既有取消测试改为在新的搜索行语句上暂停。主清单 1251 tests / 98 suites；改动后的完整 `scripts/test.sh` 在 macOS 27.0.1 上退出码 0，隔离的 derived XCTest、验收扫描、storage process、DICOM 导入集成和两条 LAN 用例全部通过。传入实际清单的 `scripts/lint.sh`（warnings-as-errors 构建、文档、package graph）、`scripts/privacy-guard.sh` 与 `git diff --check` 通过。
- **未执行**：macOS 26、安装后的 App 计时、OS 冷缓存、不含字母或数字的搜索词、超过缓存预算的资料库都没有测量。生产 composition 在本条记录时仍选择 JSON。

## [2026-10-12] feat/sqlite | 正式界面入口切换到 SQLite 资料库

- **用户决定与范围**：用户要求在固定提交、合入 main 和解决搜索性能之后切换 selector。本次只切换界面入口：[`KinlogueApp`](../Sources/KinlogueApp/App/KinlogueApp.swift) 持有 `AppStartupCoordinator.makeDefault()`，主窗口以 [`SQLiteAppLaunchView`](../Sources/KinlogueApp/Views/SQLiteAppLaunchView.swift) 为根，影像查看窗口从同一协调器取模型。界面不再构造 JSON composition；`AppComposition` 里解析当前用户身份的无参 JSON 入口已删除，只留给定身份的版本供测试和验收阶段使用。没有改 schema、存储格式或 entitlement。
- **启动行为**：接受存储说明之前不访问资料库；之后取得单实例 owner、收敛恢复与删除 receipt、打开数据库并发布 composition。取不到可信运行时身份时协调器报告资料库不可用，不解析其他位置。启动页补上共享外观、背景和按钮样式。
- **对已有资料的影响**：已有的 JSON 资料库不会被转换、清空或写入，启动页显示“资料库格式不受支持或已损坏”，旧格式恢复点也被新 reader 拒绝。这是计划里 current-only 的既定取舍；本分支没有离线转换，已有 JSON 资料只能由切换前的构建读取。
- **没有随入口一起切换的部分**：`SyntheticAcceptanceRunner` 的 seed、restart、强制终止和 cleanup，以及安装 LAN 探针和 DICOM 安装验收，仍然运行 JSON 服务；`run-acceptance.sh` 没有调用 SQLite 验收入口。因此安装验收目前不覆盖界面实际使用的存储。JSON 生产代码、旧 manifest 路径和临时查询适配器也没有删除。计划中 U7 的这部分和 U10 仍未完成。
- **测试**：新增三项声明：两次启动之间 SQLite 资料库持久存在且根目录只有 `library.sqlite` 与 `originals`；没有运行时身份时报告不可用且不创建任何东西；源码断言界面入口只经由启动协调器、不引用 JSON composition，并且存储说明先于任何打开动作。既有测试继续覆盖第二实例被拒后重试、坏数据库保留字节并提供同 owner 恢复、旧 JSON 原样保留。用临时测试把存储说明、旧资料库失败页、不可用页和空资料库主界面离屏渲染后目视检查，随后删除该测试。
- **验证**：macOS 27.0.1 / Xcode 27 上，切换后的完整 `scripts/test.sh` 退出码 0，主清单 1254 tests / 98 suites，隔离的 derived XCTest、验收扫描、storage process、DICOM 导入集成和两条 LAN 用例全部通过。传入实际清单的 `scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 通过。
- **未执行**：切换后的 App bundle 没有重新构建、安装或运行；界面只做了离屏渲染，没有真实窗口、键盘或 VoiceOver 检查；macOS 26 的 SQLite engine、安装后的 Ready 时间与内存、真实手机和人工 OCR 门禁都没有执行。计划把这些列为切换的前置门禁，本次是在它们缺失的情况下按用户要求完成代码切换，验收账本保持 `not-verified` / `pendingManual`。

## [2026-10-12] release-check | 切换后的 App bundle 在干净源码上通过静态验证

- **命令与结果**：在提交 `a595f8234c23a3455cfcfbdf149ce8506b1c5f3a` 的干净工作树上运行 `scripts/verify-app.sh --require-clean-source`，退出码 0。报告记录 `source.dirty = false`、macOS 27.0.1、Xcode 27.0（27A266a）、Swift 6.4、arm64、最低系统 26.0，bundle 内容摘要 `44b1c86a4e062c3edef8b70a0afc211401fc95dc6904f67d69da0026af3c1b1e`。
- **通过的门禁**：Release 构建、ad-hoc 签名与签名完整性、bundle metadata 与 Info.plist、应用图标、精确资源清单（这是合并 main 之后 `Assets.car` 与 GRDB privacy manifest 第一次一起出现在实际包里）、第三方声明、依赖锁定、entitlement 白名单、LAN composition、DICOM Helper 结构 / 签名 / entitlement 与主进程隔离、无 Security framework、Keychain 或旧加密运行时依赖。
- **未执行**：报告中的 `installedAcceptance`、`syntheticSmoke`、`canaryScan` 和 `overall` 仍是 `notExecuted`；`verify-dicom-xpc.sh` 的真实 XPC 探针没有在该提交上重跑；App 没有安装或启动；Developer ID 与 notarization 未执行。该提交尚未推送，产物在被忽略的 `dist/` 下，不进入 Git。此前切换记录里“bundle 没有重新构建”的说法由本条更新，其余未执行项不变。

## [2026-10-12] review/app | 刷新不再清空列表，并修复评审发现的四处问题

- **起因**：用户要求以技术栈重构为目标评审当前实现。对 `origin/main...HEAD` 的生产代码做了一轮评审，发现 12 项，本条记录其中已修的 6 项；其余是结构性问题，列在本条末尾，未改代码。
- **刷新清空列表**：重构后每次刷新都先清空时间线、搜索结果和草稿队列再从第一页重载，而刷新在每次提交通知、切回应用和唤醒时都会发生，旧 JSON 实现是原地重建。现在 [`AppModel`](../Sources/KinlogueApp/App/AppModel.swift) 刷新时保留已显示的行，按原来已加载的行数读完再一次替换；草稿各状态在新一页到达后才替换，四个状态并行读取。只有切换成员、筛选或搜索词才清空列表。
- **重复刷新**：界面自己发起的修改会收到两次相同的 revision（服务返回的 header 和同一次提交的通知），各触发一轮完整重载。提交通知、激活、唤醒以及修改返回的 header 现在遇到已显示的 revision 时不重载列表，只重新核对已打开的记录和草稿；这一步保留下来，是因为没有改变 revision 的数据库故障原本靠它在激活时被发现，对应的既有测试继续通过。显式刷新仍然总是重载，因为草稿的重试资格可以不经提交而变化。
- **陈旧游标**：游标绑定 commitID，任何提交都会让“载入更多”失败，原实现随即清空并回到第一页。现在按“已显示行数加一页”的深度重读一次；提交持续到来时退回只读第一页。游标与 commitID 的绑定没有改。
- **搜索缓存**：某一行的新条目放不进预算时，旧条目原先留在缓存里，摘要已不匹配却一直占着预算。现在先移除旧条目。
- **LAN 预处理调度**：读取队列页出错时循环直接返回，期间到达的调度请求被丢掉。现在这种请求会得到一次自己的扫描；没有新请求时仍然结束，不会对同一个错误空转。
- **测试**：新增 4 项声明并强化 1 项，主清单 1258 tests / 98 suites。把这几处临时改回原行为后，5 项测试全部失败（列表被清空、深度回到 100、队列出现空值、未变化的 revision 仍触发分页读取、调度请求丢失、陈旧条目残留），恢复后通过。测试替身的 revision 现在随内容变化，与真实提交一致。
- **验证**：macOS 27.0.1 上，修改后的完整 `scripts/test.sh` 退出码 0，主清单 1258 tests / 98 suites，隔离门禁全部通过；传入实际清单的 `scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 和 `git diff --check` 通过。界面行为只由模型测试证明，没有在真实窗口里检查滚动位置；macOS 26、安装与人工门禁未执行。
- **已提出、未修改的结构性问题**：空闲完整性巡检在任何提交后都从头重跑，包括重新计算全部原件的摘要；存储内核的 read / write 是持锁的同步调用，却在并发线程池上的 async 函数里执行；JSON 存储栈和临时查询适配器在界面入口切换后只剩验收阶段和测试使用；本机导入把原件先写临时文件再复制一次；`AppStartupCoordinator` 一个类型承担两个角色且仍沿用 candidate 命名；`AppModel` 用八个字典分别跟踪读取任务。这些需要单独决定方案，本次没有动。

## [2026-10-12] review/storage | 处理评审留下的结构性问题，并把安装验收迁到 SQLite

- **起因**：用户要求按上一条记录末尾的建议处理六项结构性问题。五项已完成；第六项（删除 JSON 存储栈）完成了前置部分，JSON 实现本身没有删除，原因见本条末尾。
- **本机导入写盘一次**：[`SQLiteReportRepository.stage`](../Sources/KinloguePlatform/Storage/SQLiteReportRepository.swift) 原先把导入字节先写进临时文件，再由内核从临时文件复制到 staged 原件。内核现在可以直接暂存内存中的字节，登记、同步、回读校验和提交前复核与从 descriptor 复制的入口共用。
- **空闲巡检续跑**：巡检原先在任何提交、切回应用和唤醒之后都从头重做，每个原件每轮读两遍。现在一次打开期间保留[进度记录](../Sources/KinloguePlatform/Storage/SQLiteIntegrityProgress.swift)：资料库状态与 SQLite `data_version` 未变时从断点继续，已完成的同一 revision 只重新核对原件的文件身份；提交后行检查从头开始，但字节校验通过的原件在行内容哈希与文件的设备、inode、长度、修改和状态变更时间都未变时不再重读，每次校验只读一遍。行检查仍绑定单一 revision，“revision 变化只算未完成”的语义没有改。身份信息不变而字节损坏的情况要到下次读取该原件或重新打开资料库后才发现；读原件时的校验不受影响。
- **读取登记表**：`AppModel` 的九个任务字典和 `ComparisonModel` 的两个字典合并为 [`LibraryReadRegistry`](../Sources/KinlogueApp/ViewModels/LibraryReadRegistry.swift)，取消与排空各只有一处实现。行为不变。
- **启动协调器拆分**：原先一个 `AppStartupCoordinator` 靠布尔标志兼任“持有本次启动的资料库”和“排定 composition 内各服务的启动次序”。前者现在是 [`LibraryLaunchCoordinator`](../Sources/KinlogueApp/App/LibraryLaunchCoordinator.swift)，后者保留原名；相关成员不再叫 candidate。
- **阻塞调用离开并发线程池**：存储内核是持锁的同步调用，原先在 Swift 并发线程池的线程上执行，admission 被长时间持有时等待的读取会把线程池占满。现在存储层的异步入口经 [`LibraryStorageExecutor`](../Sources/KinloguePlatform/Storage/LibraryStorageExecutor.swift) 移到允许阻塞的专用线程，四个会等存储的 actor 各用自己的串行队列，备份、恢复激活、恢复收敛和原件导出在任务根部切换；细节见 [SQLite 存储专题](sqlite-storage.md#阻塞调用所在的线程)。内核的同步 API 没有改成异步。排查时给 admission 临时加了调用栈记录并跑了一遍全量测试，据此补上了批量改造没有覆盖的路径；该记录工具已删除。
- **安装验收迁到 SQLite**：[`SyntheticAcceptanceRunner`](../Sources/KinlogueApp/App/SyntheticAcceptanceRunner.swift) 的 seed、restart、强制终止和 cleanup，以及 LAN 与 DICOM 安装验收，都改为经 `LibraryLaunchCoordinator` 打开 SQLite 资料库并走数据服务；事件的字段和 `run-acceptance.sh` 没有改。场景不再预先决定记录和原件的 ID（由资料库在暂存时分配），报告靠原件摘要对应，`summarySHA256` 改为资料库身份加各报告原件摘要。强制终止阶段现在让进程带着 owner 和打开的数据库等待被杀。单独的 `sqlite-candidate` 阶段与探针已并入这些阶段并删除。
- **App 不再能组装 JSON 资料库**：删除了 `AppComposition.makeDefault(identity:)`、`LiveAppServiceEnvironment.makeDefault`、JSON 的备份运行时组装、`PlaintextVaultDestroyService` 和导出服务的 JSON 构造入口。对应的五项测试所验证的性质（构造不触碰磁盘、父目录权限、首次启动、不创建备份身份、旧格式原样拒绝）已由 SQLite 启动测试覆盖，其中父目录权限、恢复状态和备份身份三处是这次补上的断言。
- **未完成：JSON 实现的删除**。`PlaintextVault`、`PlaintextLANInboxStore`、JSON 备份源与恢复事务、`LegacyLibraryQueryAdapter` 以及 `LiveAppService`、`LiveLANInboxService`、`LiveBackupService` 的 JSON 构造入口仍在，现在只被测试和跨进程 fixture 使用。删除它们需要先处置约 130 项以 JSON 资料库或 `VaultStore` 替身为夹具的测试（`LiveAppServiceTests`、`ImportWorkflowIntegrationTests`、`DICOMImportWorkflowIntegrationTests`、LAN 归档与 inbox、加密恢复点的写入与恢复、跨进程协调等），逐项判断移植到 SQLite 夹具还是随实现删除；计划的 U10 把这一步估为 3–5 人日，并要求保留第二实例、crash、根替换和备份 repository 竞争的测试。本次没有在未提交的大改动之上继续做这一步。
- **测试**：新增 11 项声明（内存字节暂存 1、巡检续跑 3、读取登记表 4、存储执行器 3），删除 7 项（candidate 阶段 2、JSON 组装 5），改写验收场景、进程内全阶段运行和 LAN 探针 3 项。主清单 1262 tests / 100 suites。反向验证：去掉 `data_version` 围栏后“其他连接提交”一项失败；去掉执行器切换后线程池在 admission 被持有的 5 秒内无法运行其他任务，两项测试失败；恢复后通过。
- **验证**：macOS 27.0.1 上，全部改动完成后的完整 `scripts/test.sh` 退出码 0，主清单 1262 tests / 100 suites，隔离的 derived XCTest、验收扫描、storage process、DICOM 导入集成和 LAN 用例通过；传入实际清单摘要的 `scripts/lint.sh`（含 warnings-as-errors 构建与文档校验）、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：迁移后的 `run-acceptance.sh` 没有运行，DICOM 验收阶段因此没有任何执行证据；App 没有安装或启动；提交后行检查在大库上的耗时、专用线程上的调用开销都没有测量；macOS 26、真实手机和人工门禁未执行。

## [2026-10-13] storage/cleanup | 删除 JSON 清单存储，资料库只剩 SQLite 一种实现

- **起因**：上一条记录末尾留下的第六项。用户同意继续，按“先把测试移植到 SQLite、再删实现”的次序执行。决策登记见 [`decisions.md`](decisions.md)。
- **删除的实现**：Platform 的 `PlaintextVault` 及其初始化事务、`VaultMutationCoordinator`、`VaultMutationCapabilityLock`、`VaultRootBinding`、`VaultImportDraftStore`、`VaultReportSelectionStaging`、`PlaintextLANInboxStore`、`LANInboxChangeMonitor`、`LANDerivedArtifactSink`、`PlaintextLibraryBackupSource`、`CheckpointLibrarySource` 和 `LegacyLibraryQueryAdapter`；Core 的 `VaultCatalog`、`VaultStore` 协议及其请求/快照类型、`DuplicateDetector` 和 `OriginalArchivePlan.make(catalog:)`。`Sources/` 净减约一万一千行。
- **收敛为单一后端的共享类型**：恢复事务（文件改名为 [`BackupRestoreTransaction.swift`](../Sources/KinloguePlatform/Backup/BackupRestoreTransaction.swift)）和 [恢复校验器](../Sources/KinloguePlatform/Backup/EncryptedCheckpointRestore.swift) 现在必须由资料库的 owner 构造：原先叠加在上面的 JSON 跨进程写锁删除，跨进程互斥只靠 owner 锁，同一进程内对同一根目录的事务另由一个小的门闩串行；文件树格式的恢复点在写入任何暂存之前以“格式不受支持”拒绝。`EncryptedCheckpointWriter`、`PlaintextOriginalArchiveExporter`、`LANReceiver`、`LANItemPreprocessor`、`LANPendingQueueWorkflow`、`LANReportArchiveCoordinator`、`DICOMImportWorkflow`、`DICOMSliceService` 以及 App 的 `LiveAppService`、`LiveLANInboxService`、`LiveBackupService` 各自去掉了 JSON 的构造入口和分支。锁文件类型不再带 `fcntl` 租约，只剩命名和安全打开。
- **仍沿用旧名字的共享基础设施**：`PlaintextVaultDeletionTransaction`、`PlaintextVaultLayout`、`VaultDICOMImportJournal`、`VaultDICOMStudyStaging`、`VaultProcessLock`、`VaultCanonicalRootPath`、`VaultError`、`VaultRevision` 和 `PlaintextOriginalArchiveExporter` 都被 SQLite 资料库使用，这次没有改名；其中只删掉了确认无人调用的成员。Core 的 `DICOMStudy` 结构现在只剩它的 ID 类型和指纹还在用，也没有处理。
- **移植测试时发现并修复的两处行为**：一、重新识别进行中草稿被别处改动时，仓库抛出的“尝试已过期”没有被 App 服务映射，界面得到的是一般性错误；现在映射为“复核内容已过期”。二、被取消的处理会把“失败”写进草稿，使一次中断的导入变成需要手动重试的失败项；[`failProcessing`](../Sources/KinloguePlatform/Storage/SQLiteReportRepository.swift) 现在先检查取消，草稿留在处理中，由下次启动继续。两处都有回归测试。另外记录一个与 JSON 实现不同、但没有改动的行为：自动恢复按草稿 ID 的顺序进行，不按导入的先后。
- **跨进程夹具与探针**：[`KinlogueStorageProcessFixture`](../Sources/KinlogueStorageProcessFixture/KinlogueStorageProcessFixture.swift) 去掉了全部 JSON 命令。备份仓库并发发布的测试改为两个进程各持一个资料库、争用同一个仓库，因为一个资料库只能有一个 owner。[`BackupCapabilityProbe`](../Sources/KinlogueStorageProcessFixture/BackupCapabilityProbe.swift) 的整根激活探针改用 SQLite 资料库作种子和校验；原先“激活等待另一个进程的写入完成”的用例在单 owner 下不再成立，改为“另一个进程持有资料库时激活在准备任何暂存之前被拒绝，对方放手后同一次激活成功”。[`StorageScaleProbe`](../Sources/KinlogueStorageProcessFixture/StorageScaleProbe.swift) 只保留 SQLite 的各项命令。
- **测试基础设施**：`LANDerivedArtifactSinkTests` 是仓库里唯一的 XCTest 套件，`scripts/test.sh` 为它单独构建 bundle 并逐 case 启动；随该类型删除后，这条通道、`discover-derived-xctest-cases.rb` 和 CI 的专用 job 一并移除，测试分区由 `0/3`、`1/3`、`2/3` 改为 `0/2`、`1/2`。隔离运行的 `DICOMImportWorkflowIntegrationTests` 门禁随该套件删除；仅在大小写不敏感卷上运行的别名锁门禁改指向新的 SQLite owner 测试。删除专用 job 时核对过 `main` 没有分支保护规则；托管平台若另有要求该检查的规则，需要在那里移除。
- **测试的移植与退役**：
  - 移植到 SQLite 资料库：`LiveAppServiceTests`（重写为 37 项）、`LiveBackupServiceTests`、`LiveAppServiceRecognitionIntegrationTests`、`LiveDICOMAppServiceIntegrationTests`、`ImportWorkflowIntegrationTests`、`PlaintextOriginalArchiveExporterTests`、`EncryptedCheckpointWriterTests`、`EncryptedCheckpointRestoreTests`（重写为 6 项：文件树格式拒绝、错误恢复码、整根替换、旧根移走后中断的回滚、截断的事务收据、只清理有收据的废弃预检）、`LANPendingItemStoreTests` 的 5 项通用用例、LAN Receiver 的三个套件、`BackupPublicationProcessCoordinationTests`、`BackupCapabilityActivationProbeTests` 的激活用例和 `OriginalArchivePlanTests`。
  - 新增：SQLite owner 经符号链接父目录和大小写别名到达同一个库时争用同一把锁、锁路径被替换成符号链接时失败关闭；排队中的数百文件 DICOM 导入在一秒内取消；验收清理拒绝不属于资料库 owner 的锁文件。
  - 随实现退役：`PlaintextVaultTests`、`PlaintextVaultCurrentFormatTests`、`PlaintextVaultStagedReportGenerationTests`、`VaultMutationCoordinatorTests`、`VaultRootBindingTests`、`VaultReadOptimizationMeasurementTests`、`PlaintextLibraryBackupSourceTests`、`LANInboxChangeMonitorTests`、`LANDerivedArtifactSinkTests`、`CatalogProcessCoordinationTests`、`DICOMSliceVaultIntegrationTests`、`VaultCatalogDeletionTests`，以及 `DICOMImportWorkflowIntegrationTests`、`LANReportArchiveTests` 和若干 Core 套件里针对 catalog 的用例。DICOM 导入、切片读取和 LAN 归档的对应性质由 `SQLiteDICOMTests`、`SQLiteLANInboxTests` 和真实进程测试覆盖。
  - 没有找到 SQLite 对等测试的性质：资料库级的 DICOM 数量上限（256 个 study、10,000 个对象、4,096 个 Series）由 [`SQLiteDICOMRepository`](../Sources/KinloguePlatform/Storage/SQLiteDICOMRepository.swift) 的提交前检查执行，但原先 catalog 层的边界测试没有对应物。
- **账本核对脚本的缺陷**：[`verify-docs.sh`](../scripts/verify-docs.sh) 汇总实测结果的正则只匹配复数的 “tests”，恰好只含一个测试的分片输出的是 “1 test”，不被计入。分片组成变化后第一次出现这样的分片，完整运行在全部分片通过之后因合计少 1 而失败。正则改为同时接受单数，并在文档校验器的测试里补了这一情形。
- **测试计数**：`@Test` 声明由 1337 个减为 1194 个，XCTest 用例由 13 个减为 0；主清单由 1262 tests / 100 suites 变为 1146 tests / 96 suites。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，全部源码和测试改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1146 tests / 96 suites，隔离运行的验收扫描（14 项）、storage process（31 项）、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此后只改了文档。传入实际清单摘要的 `scripts/lint.sh`（含 warnings-as-errors 构建与文档校验）、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。改写后的 `run-storage-scale-probe.sh --tier reports-100` 实跑退出码 0，生成、三次启动、搜索、短操作、逻辑捕获和备份/严格恢复各阶段都有输出；其余档位没有重跑。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：`run-acceptance.sh` 仍没有运行，DICOM 验收阶段因此仍没有任何执行证据；`run-backup-capability-probe.sh` 里改写的“资料库被占用时拒绝激活”用例只做过脚本语法检查，同一性质由源码层的真实进程测试覆盖，安装探针需要已签名并安装的工件；App 没有安装或启动；CI 工作流的改动没有在托管平台上运行过；macOS 26、真实手机和人工门禁未执行。

## [2026-10-13] review/follow-up | 评审后续：草稿按导入先后排列，清掉删除后的残留

- **起因**：删除 JSON 存储之后，用户要求再评审一遍当前实现并按建议修复。评审列出七项和一个待确认事项；本条处理其中六项。备份可行性探针是否继续作为发布门禁保留，等用户决定；用户本机的真实资料库是否仍是 JSON 格式，也待用户确认。
- **草稿顺序**：草稿表没有排序列，待确认列表、导入状态和启动时的自动恢复都按 `draft_id` 翻页，而 ID 原先是随机 UUID，新导入的文件会出现在列表的任意位置，超过一页时可能不在第一页。新草稿的 ID 现在由 [`LibraryOrderedIDGenerator`](../Sources/KinloguePlatform/Storage/LibraryOrderedID.swift) 分配，按创建时刻递增（UUID 第 7 版的布局）；表结构、已冻结的逻辑备份格式和游标都没有变。本机导入和 LAN 归档创建的草稿都使用它。此前用随机 ID 创建的草稿不重排。
- **取消规则回到 workflow**：上一条在仓库的 `failProcessing` 里加了取消检查，而 [`ImportWorkflow`](../Sources/KinlogueCore/Import/ImportWorkflow.swift) 仍写着“取消时记一条失败”，两层说法不一致。规则现在只写在 workflow 里：处理所在的任务被取消时不记录失败，草稿留在处理中；识别服务自己放弃而任务仍在运行时，记为“已取消”的失败。仓库不再检查取消，对外行为与上一条相同。
- **文件树格式的恢复点更早被拒绝**：[`BackupContainerReader`](../Sources/KinloguePlatform/Backup/BackupContainerReader.swift) 的 `read` 增加一个在清单通过认证之后、解密任何条目之前调用的检查，恢复校验器用它拒绝文件树格式，不再先把全部条目解密一遍。容器解析和公钥侧校验仍在这之前进行。
- **残留清理**：上次删除之后变成无人引用的 `LANPendingWriteAdmission.swift`（整个文件，含 3 处 `@unchecked Sendable`）、`LANArchivePreparationOutcome`、`AtomicFileStore` 的两个方法及其临时文件名判断、`DICOMImportMetrics` 的两个 promotion 计数、`DICOMStudy.reassigning`，以及启动时已不可达的 `catch is VaultError`。另外删除了早于本分支就没有引用的声明：`startupIsReady`、`chooseParentDirectory`、`LocalDirectoryCheckpointCreator`、`BackupOperationKind`、`BackupOperationPhase`、两个 `…IfPresent` 解码辅助、`LANItemPreprocessor.currentItem`、`recordSourceDescriptorsOpened` 和 `LANInboxSnapshot` 的四个查找方法。并发审计清单随之变为 67 处 / 36 个文件。
- **LAN 存储协议**：删除只有一个实现的 `LANPendingItemStoring`、Core 的 `LANInboxRepository` 与 `LANInboxAccessState`，以及无人调用的 `inspect()`；`LANUploadStoring` 去掉返回整份快照的 `initialize()`，只剩 Receiver 实际使用的方法。预处理、队列 workflow 和 App 服务直接持有 `SQLiteLANInboxStore`。没有处理的部分：`loadSnapshot`、`initialize`、`deleteItem`、`snapshotAndStorageSummary` 这些返回整份快照的方法仍被测试和安装探针使用，留在具体类型上；Core 的 `LANInboxSnapshot` 里在 SQLite 下永远为空的 `archiveIntents` / `archiveTerminals` 及其校验没有删除。
- **脚本安全测试**：`TestScriptSafetyTests` 和 `GitHubActionsWorkflowTests` 里“某个字符串恰好出现 N 次”的断言改为结构断言：每条运行测试的命令都串行并受期限约束；CI 中运行测试的各个 job 恰好覆盖全部分区。
- **测试**：新增 6 项声明（有序 ID 3、草稿按导入先后列出与恢复 1、识别服务自行放弃时记为失败 1、清单被拒时不解密任何条目 1）；“被取消的处理留在处理中”一项改为经 workflow 驱动。反向验证：把本机导入的 ID 换回随机 UUID 后，排序测试的两处断言都失败，恢复后通过。`@Test` 声明 1200 个，主清单 1152 tests / 96 suites。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，源码和测试改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1152 tests / 96 suites，隔离运行的验收扫描、storage process、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此后只改了文档。传入实际清单摘要的 `scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：与上一条相同——`run-acceptance.sh`、`run-backup-capability-probe.sh`、安装或启动 App、托管平台上的 CI、macOS 26、真实手机和人工门禁都没有执行。按导入先后排列只有仓库和 workflow 层的测试，没有在界面上看过。

## [2026-10-13] storage/verification | 旧格式目录上的恢复有了端到端测试；一次性转换工具放在独立的本地分支

- **起因**：用户确认按上一条之后的建议处理。只核对文件名、没有读取任何内容之后确认：用户本机现有的资料库仍是 JSON 清单格式，目录里有 `library.json`，没有 `library.sqlite`。本分支的 App 打不开它，只会在启动页提供从恢复点恢复的入口。
- **本分支的改动**：只有一项测试和文档。[`SQLiteAppStartupTests`](../Tests/KinlogueAppTests/SQLiteAppStartupTests.swift) 新增 `restoringOverAnOldFormatLibraryReplacesItAndTheNextLaunchOpensTheRestoredOne`：资料库目录是旧格式时，启动以“格式不受支持”失败；经启动页的恢复服务校验一个逻辑格式的恢复点不改动目录，确认恢复后旧目录被整根替换，下一次启动打开恢复后的资料库。此前这条路径只有“旧目录被保留、恢复入口存在”的测试，没有执行过恢复本身。
- **测试确认的行为**：被替换的旧目录在恢复提交后仍以 `.kinlogue-restore-rollback-…` 留在资料库旁，下一次启动收敛这笔恢复时删除，此后不再保留。[`storage.md`](storage.md) 和 [`backup-and-restore.md`](backup-and-restore.md) 已补上这一点。
- **转换工具（不在本分支）**：写在本地分支 `codex/json-library-converter` 上，基于同时保有两套实现的提交 `32bbb18`；没有提交和推送，也不打算合入，本分支“不提供迁移”的说法不变。它用旧实现打开 JSON 资料库的副本并逐个对象核对摘要，用恢复所用的行编解码写入一个临时 SQLite 资料库并做严格校验，再写出一个逻辑格式的恢复点，随后用生产的恢复校验器和恢复事务把它恢复到第二个临时资料库，与源逐项比对。恢复码写入仅所有者可读的文件，不输出到终端；失败时只报告所在阶段和错误类型。三类内容按设计不原样带过去：处理中的草稿变成可重试的失败草稿；手机 inbox 里已做过机器识别的条目回到“已接收”，由新版重新识别；手机会话期间的回执和终态记录不带过去，因为会话随旧 App 结束，而新表结构要求“已归档/已删除”的回执有同一会话的终态记录。
- **转换工具的验证**：只用合成数据。该分支上的测试建立一个含成员、已确认报告、待确认草稿、两个中断草稿、三个手机文件和一个已确认影像检查的 JSON 资料库，在它的副本上执行完整流程，再把恢复点恢复一次并逐项核对；另有目标非空、归档未完成和原件损坏三种拒绝情形。命令行在一份合成资料库的副本上实跑退出码 0，并拒绝了已存在的输出目录和位于 App 容器内的源路径。**没有在用户的真实资料库或它的副本上运行过。**
- **测试计数**：本分支新增 1 项声明，`@Test` 声明 1201 个，主清单 1153 tests / 96 suites。转换分支上的 4 项测试不计入本分支。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，测试改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1153 tests / 96 suites，隔离运行的验收扫描、storage process、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此后只追加了本条日志。传入实际清单摘要的 `scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：真实资料库的转换和随后的恢复都还没有做，需要用户确认后在副本上进行；新测试在源码层驱动启动协调器和恢复服务，没有经过界面，也没有安装或启动 App。其余与上一条相同：`run-acceptance.sh`、`run-backup-capability-probe.sh`、托管平台上的 CI、macOS 26、真实手机和人工门禁都没有执行。

## [2026-10-13] storage/fix | 真实迁移暴露的三处缺陷：失效的备份配置挡住恢复、原件身份依赖设备号、“退出续页”无效

- **起因**：用户在自己资料库的副本上运行了转换工具并得到恢复点，随后在本分支构建的 App 启动页执行恢复。界面停在“资料库替换未完成”，“退出续页”按钮没有反应。只读核对了目录里的文件名、大小和收据的 `phase` 字段，没有读取任何资料内容：旧资料库原样未动，恢复事务的收据停在 `intent`，暂存目录完整。应用户要求结束了那个进程。
- **缺陷一，恢复被旧备份配置挡住**：恢复在替换资料库之前要移除本机备份配置，[`removeForDestructiveReset`](../Sources/KinloguePlatform/Backup/BackupLocalConfigurationStore.swift) 原先先完整读取并校验这份配置。用户机器上的配置写于八月，记录的目录 inode 与现在一致，设备号不同（当时 1,18，现在 1,15）；macOS 不保证卷的设备号跨重启或系统更新不变。校验失败使移除失败，恢复停在登记意向之后。现在移除时不读取内容，只确认同名位置是当前用户私有的普通文件。
- **缺陷二，原件身份依赖设备号**：同一原因会让迁移后的资料库在卷被重新编号后把每个原件判为无效——原件行记录设备号和 inode，读取、备份捕获和回收都要求两者一致。现在记录下来的身份只比较 inode（`SQLiteFileIdentity.isFile(recordedAs:)`），用于原件的打开校验、回收、逻辑备份来源和进行中上传的取消与恢复；同一进程内刚取得的身份之间仍比较设备号。决策与没有处理的同类依赖登记在 [`decisions.md`](decisions.md)。
- **缺陷三，“退出续页”无效**：恢复面板在“正在替换”“需要重启”“替换未完成”三种状态下不允许关闭，而 AppKit 在窗口挂着模态面板时直接拒绝 `terminate`，不询问任何代理。恢复成功之后的同一个按钮也有这个问题。新增 [`RestartRequiredQuit`](../Sources/KinlogueApp/App/RestartRequiredQuit.swift)：先解除窗口对退出的拦截，再走正常终止；仍被拒绝时结束进程。
- **测试**：新增 5 项声明，并把上一条的启动恢复测试扩成三种情形。配置存储：设备号被改写的配置可以被移除（先断言它确实读不出来）、同名位置权限不对时仍拒绝。资料库内核与逻辑捕获：把行里记录的设备号改成另一个值后重新打开，核对读取、捕获、删除回收和中断导入的清理。启动恢复：旧格式目录上没有其他情况、留有失效的备份配置、留有一次停在 `intent` 的恢复，三种情形都要恢复成功，第三种还要求启动先撤销旧事务并保持旧目录不变。退出：解除拦截发生在终止之前，终止返回后才结束进程。一处读取视图源码的断言随按钮的调用改了写法。
- **反向验证**：把身份比较改回连设备号一起比，两项重新编号测试分别以“原件无效”和“来源已变化”失败；把配置移除改回先校验，配置存储测试和启动恢复的第二种情形以“记录无效”失败，与用户遇到的现象一致。两处都已恢复为修复后的写法。
- **退出修法的依据**：用一个与本项目数据无关的临时小程序实测：带 `interactiveDismissDisabled` 的面板挂着时 `terminate` 直接返回；清除窗口的 `preventsApplicationTerminationWhenModal` 后 `terminate` 正常进行并发出将要终止的通知。小程序用完即删，不在仓库里。Kinlogue 自己的界面上还没有点过这个按钮。
- **测试计数**：`@Test` 声明 1206 个，主清单 1158 tests / 96 suites。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，全部源码和测试改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1158 tests / 96 suites，隔离运行的验收扫描、storage process、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此前一次完整运行因那处读取视图源码的断言没有同步而失败，改正后重跑通过。此后只追加了本条日志。传入实际清单摘要的 `scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。`scripts/build-app.sh` 用修复后的源码重新构建了本机的 `dist/Kinlogue.app`（ad-hoc 签名，未提交）。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：修复后的恢复还没有在用户的真实资料库上重做；真实的卷重新编号没有在重启前后实测，只通过改写记录的设备号模拟；“退出续页”没有在 Kinlogue 界面上点过。备份配置自身、备份目标目录以及恢复和删除收据对设备号的依赖没有处理，已另行登记为后续任务。其余与上一条相同：`run-acceptance.sh`、`run-backup-capability-probe.sh`、托管平台上的 CI、macOS 26、真实手机和人工门禁都没有执行。

## [2026-10-13] migration/result | 修复后的恢复在用户的资料库上完成

- **经过**：上一条的三处修复构建进本机的 `dist/Kinlogue.app` 之后，用户重新启动它并再次从转换得到的恢复点恢复。启动先撤销了此前停在 `intent` 的恢复：核对时暂存目录和收据已经清掉，旧格式资料库仍在原位。随后的恢复完成，用户退出并重新打开了 App。
- **核对到的状态**（只看文件名、数量和进程启动时间，没有读取资料内容）：资料库目录现在是 `library.sqlite` 加 `originals`；恢复的收据、暂存目录和被替换的旧目录都不在了；旧版留下的备份配置已被移除；重新打开后的进程是新启动的，没有崩溃报告。这也是“退出续页”修复后第一次在 Kinlogue 界面上实际使用。
- **没有核对的**：恢复后的成员、报告和影像在界面上是否与迁移前一致，由用户自己查看，这里没有记录结论。卷的设备号变化仍然只有改写记录值的模拟，没有重启前后的实测。
- **遗留**：转换工具所在的本地分支不合入本分支；备份需要用户重新启用；备份配置和事务收据对设备号的依赖见上一条登记的后续任务。

## [2026-10-13] backup/fix | 备份配置、备份目录和各类收据不再依赖卷的设备号

- **起因**：前两条登记的后续任务，用户要求继续。原件行已经只按 inode 比对，但备份配置、备份目标目录、验证记录的摘要，以及恢复、整库删除、初始化、备份捕获的收据和 DICOM 导入日志仍然记录并比较设备号。
- **改动之前的表现**（按代码路径确认，没有在界面上复现）：卷被重新编号后，备份配置读取以“记录无效”失败，状态页进入失败状态，自动备份停止；重新设置要先确认没有现成配置，同样因为读取失败而无法开始，只剩恢复或删除资料库两条出路。中断的操作更糟：恢复事务的收据不再认得旧根和暂存目录，启动以“收据无效”失败；DICOM 导入日志里的暂存目录对不上，影像仓库无法打开；初始化收据被当成别的目录的收据，报“格式不受支持”；备份捕获留下的数据库副本永远不被清理。
- **改动**：[`BackupFilesystemIdentity`](../Sources/KinloguePlatform/Backup/BackupLocalConfigurationStore.swift) 和 [`BackupRestoreDirectoryIdentity`](../Sources/KinloguePlatform/Backup/EncryptedCheckpointRestore.swift) 的相等性改为只比较 inode，设备号照原样记录。验证记录的摘要收敛为一个函数，取配置里登记的设备号代替文件当前的设备号，已有的验证记录因此不变；repository 列举和恢复点发布原先各有一份相同的实现，现在共用它。整库删除收据、初始化收据、捕获归属收据和 DICOM 暂存归属的比较去掉设备号。决策、代价和仍含设备号的地方登记在 [`decisions.md`](decisions.md)；[`backup-and-restore.md`](backup-and-restore.md) 新增“目录身份与设备号”一节，[`sqlite-storage.md`](sqlite-storage.md) 补了收据和锁文件命名的说明。
- **测试**：新增 8 项声明，并把 4 项已有测试扩成带“卷已被重新编号”的参数化用例。配置：改写登记的设备号后仍能读取和更新、不被改写成当前值；目录被换成另一个时仍然拒绝；摘要与第一版算法在未重新编号时逐字节相同，并且不随文件当前的设备号变化；读不出来的配置在恢复时仍被移除（原先用设备号改写来制造“无效配置”的两处测试改为截断文件，因为那种配置现在是有效的）。备份服务：配置里登记的设备号与实际不同的情况下完成设置之后的两次备份，核对恢复点、验证记录及其摘要和状态。恢复：旧根移走后的回滚、新根就位后的提交、废弃预检的清理。整库删除：收据写入后和资料库移走后两处中断。另有初始化收据、捕获残留和 DICOM 导入残留各一项。
- **反向验证**：把备份目录身份的比较改回连设备号一起比，配置读取和端到端备份测试以“记录无效”失败；把五处收据的比较改回去，七类重新编号用例分别以“收据无效”“完整性失败”“格式不受支持”“来源已变化”和启动失败告终。两次都已恢复为修复后的写法。
- **测试计数**：`@Test` 声明 1214 个，主清单 1166 tests / 96 suites。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，全部源码和测试改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1166 tests / 96 suites，隔离运行的验收扫描、storage process、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此后只追加了本条日志。传入实际清单摘要的 `scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：卷重新编号仍然只通过改写记录里的设备号模拟，没有在重启或系统更新前后实测；备份目录位于外接卷或网盘同步目录时的表现没有实测；改动之前的界面表现是读代码得出的，没有在界面上复现；修复后的设置页也没有在界面上看过。owner 锁文件的命名和安装验收运行的归属收据仍含设备号，没有改动。其余与前几条相同：`run-acceptance.sh`、`run-backup-capability-probe.sh`、托管平台上的 CI、macOS 26、真实手机和人工门禁都没有执行。

## [2026-10-13] probe/cleanup | 备份可行性探针只保留整根激活

- **起因**：早先评审时登记的后续任务，用户决定保留激活这一组、删除其余，这次要求继续处理。[`BackupCapabilityProbe`](../Sources/KinlogueStorageProcessFixture/BackupCapabilityProbe.swift) 写于生产备份代码出现之前，用自带的合成格式（魔数以 `KLG-U0-` 开头）证明设备身份存储、公钥写入与种子恢复的分离、repository 发布与容量、security-scoped bookmark、分块大小和 20,000 对象 / 2 GiB 数据集在沙盒里可行。这些性质现在各有生产实现和测试；只有整根激活这一组调用的是生产的恢复校验器和恢复事务。
- **删除**：身份、密钥、repository 发布、所选目录发布、bookmark、命名数据集和分块这七组操作及其结果类型、参数和辅助函数，探针由 4313 行减为 874 行；[探针测试](../Tests/KinlogueStorageProcessTests/BackupCapabilityActivationProbeTests.swift)里对应的 14 项（保留 4 项激活测试）；[安装脚本](../scripts/run-backup-capability-probe.sh)里对应的段落、`--interactive-bookmark` 参数、升级安装的第二个包和报告字段，脚本由 1162 行减为 496 行；entitlement 里的 bookmark 和用户选择文件两项；fixture target 不再需要的 AppKit 与 CryptoKit 链接设置。
- **保留并调整**：被另一个进程占用时拒绝激活、十一个故障点各自收敛到确定的根、截断收据失败关闭，这三类用例和它们的断言没有变。脚本的报告只剩环境、签名、已安装工件的摘要和一个 `activation` 状态，schema 版本记为 3；原先“机制通过”和“证明通过”两个状态里后者从未被置为通过，合并为一个。安装后的 entitlement 和签名信息改为直接从已安装的包取得（原先取自升级后的包）。[源码检查测试](../Tests/KinlogueAppTests/BackupCapabilityProbeSourceSafetyTests.swift)重写为只断言仍然存在的内容：探针只有 App Sandbox 一项 entitlement、不触及 Keychain 和用户目录、调用生产事务且不自带激活算法、脚本包含全部用例并且每种失败都会拉低那个状态。
- **历史证据**：[`backup-and-restore.md`](backup-and-restore.md) 里“20,000 对象、2 GiB 流式备份”那句保留为历史，并注明产生它的工具已删除。
- **未执行**：改写后的安装脚本只做了 `zsh -n` 语法检查，没有运行；它需要登录会话里已签名并安装的沙盒包。

## [2026-10-13] storage/rename | 给仍带 JSON 时期名字的存储类型改名，清掉 Core 里的遗留

- **起因**：删除 JSON 清单存储时登记的后续任务，用户要求继续处理。SQLite 资料库仍在用的一批共享类型保留着 `PlaintextVault…`、`VaultDICOM…` 之类的名字，Core 里还有几处只为旧实现存在的内容。
- **改名**（只改标识符和源文件名，行为与落盘内容不变）：`PlaintextVaultDeletionTransaction` → `LibraryDeletionTransaction`，它的故障枚举 → `LibraryDeletionFault`；`PlaintextVaultLayout` → `DICOMImportLayout` 并移到 DICOM 目录，因为它只剩 DICOM 导入的暂存和日志路径；`VaultDICOMImportJournal`、`VaultDICOMStudyStaging`、`VaultDICOMStagingOwnership`、`VaultDICOMStagedObject`、`VaultDICOMOperationDescriptorLease` 去掉 `Vault` 前缀；`VaultProcessLock`、`VaultProcessLockLocation`、`VaultCanonicalRootPath`、`VaultParentDirectoryPreparation` 改为 `Library…`，`VaultMutationLockNaming` → `LibraryLockNaming`；`DICOMVaultSessionToken` → `DICOMLibrarySessionToken`；`PlaintextOriginalArchive…` 七个类型去掉 `Plaintext` 前缀；`VaultReadSnapshotPolicy` → `LibraryReadSnapshotPolicy`。两个测试文件随类型改名。锁文件名 `.kinlogue-mutation-<digest>.lock`、删除收据的魔数、DICOM 暂存与日志目录名和各收据的 JSON 键都没有变；改动后的源码里只有一处字符串插值的标识符变了，值不变。
- **没有改名的**：Core 的 `VaultError`（145 处引用）、`VaultRevision`（逻辑备份格式和归档意图里的字段类型）、`VaultObjectKind` / `VaultObjectReference`、`CanonicalVaultJSON`（83 处引用），以及 App 层以 Vault 指代资料库的一组名字（`DeleteVaultView`、`VaultDestroyServicing`、`RuntimeVaultIdentity` 等）。前者改动面大，后者是界面层的既有用语，都不在这次范围内。
- **清掉的遗留**：一、[`LANInboxSnapshot`](../Sources/KinlogueCore/LAN/LANInboxSnapshot.swift) 的 `archiveIntents` 与 `archiveTerminals` 及其校验、排序、上限和编解码键；SQLite inbox 从不填充它们，归档是一次数据库事务。随之无人使用的 `LANArchiveTerminal` 一并删除，`LANArchiveIntent` 仍被逻辑备份和归档使用，保留。二、原件导出的错误 `vaultChanged`、它在 App 的映射和那条文案；导出读取的是已固定的原件，没有任何代码会产生这个错误。字符串目录和英文运行时资源已同步。三、Core 的 `DICOMStudy` 结构体缩成只含 `ID` 和附件数量上限的命名空间；真正在用的是 `DICOMStudyHeader`，它有同样的校验却没有直接的测试，原先针对旧结构体的状态与附件校验测试改为针对它。四、`BackupRestoreSummary.logicalDigest` 和恢复事务收据里的同名字段改为非可选：它们总是有值，恢复事务里对 `nil` 的防御分支随之删除，收据的 JSON 不变。
- **决定不动的一处**：DICOM 导入日志收据里的 `promotedReferences` 现在总是空数组，`reconcile(retaining:)` 也总是传空集合。这份收据是落盘的临时格式，去掉字段会改变进行中收据的解码方式，而它所在的恢复路径刚补上重新编号的处理，收益不抵风险；`VaultObjectKind` 和 `VaultObjectReference` 因此仍留在 Core。
- **测试计数**（本条与上一条合计）：`@Test` 声明由 1214 个减为 1200 个，减少的 14 项都是隔离运行的探针测试；主清单仍是 1166 tests / 96 suites。Core 里一项针对旧结构体方法的测试换成了一项针对 `DICOMStudyHeader` 附件校验的测试。并发审计清单为 66 处 / 36 个文件。
- **验证**（本条与上一条的改动合在一起）：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，全部源码和测试改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1166 tests / 96 suites，隔离运行的验收扫描、storage process（含 4 项探针激活测试）、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此后只追加了这两条日志。传入实际清单摘要的 `scripts/lint.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：`run-backup-capability-probe.sh` 没有运行（见上一条）；改名没有另做逐文件的人工复核，依据是编译、完整测试和对落盘字符串的检索。其余与前几条相同：`run-acceptance.sh`、托管平台上的 CI、macOS 26、真实手机和人工门禁都没有执行。

## [2026-10-13] backup/ui | 手动备份完成后给出提示，“最近本地验证”不再跳动

- **起因**：用户在迁移后的真实资料库上重新启用备份并点了“立即备份”，反馈“看起来没有反应，时间在一直走”。按文件名、大小和修改时间核对备份目录：专用 repository 里在点击后多了第二个 `.kinloguebackup` 文件，大小与第一个相同，备份实际已经完成。问题在界面：完成后按钮变回“立即备份”，没有任何完成提示；“最近本地验证”用的是相对时间，每秒跳动且不带“前”字，读起来像仍在进行的计时。
- **改动**：[`BackupModel`](../Sources/KinlogueApp/ViewModels/BackupModel.swift) 增加 `completionText`，只在手动备份刚完成且没有其他说明时返回“新的恢复点已创建并通过验证。”；[`SettingsView`](../Sources/KinlogueApp/Views/SettingsView.swift) 在两个按钮下方显示它，状态下一次重新读取（刷新、调度事件）时消失。旧恢复点暂未清理时仍只显示原有的那句说明，备份失败时只显示失败原因。“最近本地验证”改为显示日期和时刻，由 Foundation 按当前界面语言格式化。新文案已加入 String Catalog 并重新生成英文资源。
- **测试**：新增 3 项声明（完成后有提示且刷新后消失、清理推迟时只显示那句说明、失败时不提示）；设置页的源码断言增加完成提示的标识符，并要求不再使用相对时间。`@Test` 声明 1203 个，主清单 1169 tests / 96 suites。
- **界面核对**：用临时测试把设置页（合成状态，不接触真实资料库）离屏渲染成图片看过：提示出现在按钮下方靠右，验证时间为固定的日期时刻；临时测试随后删除。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，源码和测试改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1169 tests / 96 suites，隔离运行的验收扫描、storage process、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此后只改了本条日志。传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：改动后的构建没有在界面上实际点过“立即备份”；英文界面没有渲染核对；`run-acceptance.sh`、托管平台上的 CI、macOS 26、真实手机和人工门禁与前几条相同，都没有执行。

## [2026-10-14] ci/fix | 托管 CI 上的 bundle 资源清单多出 GRDB 的 Info.plist，CodeQL 超时

- **起因**：PR #21 第一次远端运行时，`Verify bundle and DICOM XPC` 在 macOS 26 / Xcode 26.6 / Swift 6.3.3 上以“the application bundle resource allow-list does not match exactly”失败；本机 Xcode 27 / Swift 6.4 构建的 bundle 清单完全一致。
- **原因**：Swift 6.3 默认使用 native 构建系统，资源包是扁平目录。本机用 `swift build -c release --build-system native --target GRDB` 复现：`GRDB_GRDB.bundle` 里除 `PrivacyInfo.xcprivacy` 外还有一个 `Info.plist`，同样方式构建的 `ZIPFoundation_ZIPFoundation.bundle` 只有隐私清单。[`build-app.sh`](../scripts/build-app.sh) 原先用 `ditto` 复制整个 GRDB 资源目录，多出的文件不在 [`verify-app.sh`](../scripts/verify-app.sh) 的精确清单里。
- **改动**：GRDB 资源包只复制 `PrivacyInfo.xcprivacy`；精确清单不变。
- **验证**：用 native 与本机默认两种构建系统产出的 GRDB 资源包分别模拟新的复制步骤，结果都只有 `GRDB_GRDB.bundle/PrivacyInfo.xcprivacy`；`zsh -n scripts/build-app.sh` 通过；`scripts/test.sh --filter 'Safety|GitHubActions|Documentation|Packaging|PrivacyGuard|Localization|Presentation|Layout|AcceptanceScan'` 通过。
- **CodeQL**：同一次运行里必需检查 `Analyze Swift` 在 45 分钟上限处被取消：traced build 用了 43 分钟（main 最近一次成功为 32 分钟），分析步骤开始约 1 分钟后到时；main 上分析步骤约 3.5 分钟。多出的时间来自本分支加入的 GRDB 依赖。[`codeql.yml`](../.github/workflows/codeql.yml) 的上限改为 60 分钟，构建方式和权限不变。
- **未执行**：本机没有 Xcode 26，没有完整运行 native 构建下的 `verify-app.sh`；两处修复是否让托管 CI 的 bundle job 和 CodeQL 通过，要看推送后的远端运行。

## [2026-10-14] search/ui | 搜索结果显示日期，并逐格列出命中的检验表格行

- **起因**：用户让调研一款同类 iPhone 健康档案应用（[来源笔记](sources/2026-10-14-carehealth-competitor-notes.md)），最值得参考的是“搜指标名看到历次数值”。续页的表格抽取早已把每行写成“项目⇥结果⇥参考值”，但搜索只返回整条报告，搜索卡片也没有日期。用户决定按日期列出原文行算呈现，不算趋势分析，见 [`decisions.md`](decisions.md) 2026-10-14 一节。
- **Core**：新增 [`ReportedResultLine`](../Sources/KinlogueCore/Domain/ReportedResultLine.swift)，只按制表符切分、去掉空格，至少两个非空单元格才算一行；匹配沿用 `RecordQuery.localizedContains`，作用在存储的整行上，所以搜索词不会跨格。[`LibraryReportSummary`](../Sources/KinlogueCore/Domain/LibraryReportQuery.swift) 增加 `matchedResultLines`（最多 8 行、每格 160 个 Unicode scalar）和 `matchedResultLineCount`；由记录构造的摘要两者为空，详情读取时的投影核对不受影响。
- **Platform**：[`SQLiteReportSearch.matchedResultLines`](../Sources/KinloguePlatform/Storage/SQLiteReportSearch.swift) 在搜索分页里为每个列出的报告取命中行：先看缓存条目或重新校验的搜索行里有没有带制表符且含搜索词的行，有才读取详情，核对详情摘要与行摘要后只解码检查结果字段。搜索行和详情无法校验时报告照常列出、不带行。搜索表、schema、备份格式都没有变。
- **App**：[`TimelineView`](../Sources/KinlogueApp/Views/TimelineView.swift) 的搜索卡片在标题下显示日期；有命中行时，结论的位置换成逐格显示的网格，超出 8 行时注明还有几行。这一块不用任何状态色。VoiceOver 标签增加日期和命中行。新增 4 条中英文案（含单复数），英文运行时资源已重新生成。README 的“前后对照”一条和 [`design-system.md`](design-system.md) 第 26 条同步。
- **测试**：Core 3 项（抽取格式的行与匹配、两格门槛与用户编辑后的残行、摘要上限），Platform 1 项（只列检查结果里的行、标题/成员/空查询不列、无缓存路径、详情损坏时照常列出），App 2 项（搜索卡片源码约束含“不使用状态色”、新文案的中英文与单复数）。主清单 1175 tests / 96 suites。
- **界面核对**：用临时测试把搜索结果（合成数据，不接触真实资料库）在 760 和 420 点宽度下离屏渲染成图片看过：日期、两列与四列的行、“还有 2 行匹配”和无命中行的卡片都按预期显示；临时测试随后删除。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，源码和测试改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1175 tests / 96 suites，隔离运行的验收扫描、storage process、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此后只改了文档。传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：近上限资料库的搜索计时没有重测；合成资料库的检查结果里没有制表符，量不到读取详情的开销。按本机一次微基准推断，约 27 KiB 的详情解码一次约 0.44 ms，一页 100 份全部命中表格行时多出约 45 ms。真实报告上抽取行的质量、窄窗口截断、键盘和 VoiceOver 朗读没有人工核对；`run-acceptance.sh`、托管平台上的 CI、macOS 26 和真机门禁与前几条相同，都没有执行。

## [2026-10-14] search/ui | 搜索词加粗标出，非表格命中显示上下文摘录；README 补上留存原件的动机

- **起因**：上一条之后，用户确认调研里剩下的两项也要做：搜索结果的命中高亮与命中片段，以及 README 的动机文案。取舍补记在 [`decisions.md`](decisions.md) 2026-10-14 一节。
- **Core**：新增 [`SearchExcerpt`](../Sources/KinlogueCore/Domain/SearchExcerpt.swift)：在一个字段里用同一套本地化、不区分大小写的匹配找到第一处命中，空白折叠为一个空格，保留命中前最多 30 个字符、总长约 120 个字符，两端截断处标省略号；含 NUL 的搜索词不生成摘录。[`LibraryReportSearchMatch`](../Sources/KinlogueCore/Domain/LibraryReportQuery.swift) 把命中行和摘录合在一起，有命中行时不带摘录；摘录跳过卡片已显示的标题（或报告类型）、机构和日期。摘要的 `listing` 改为接收它，摘录再限 480 个 Unicode scalar。
- **Platform**：[`SQLiteReportSearch.match`](../Sources/KinloguePlatform/Storage/SQLiteReportSearch.swift) 取代上一条的 `matchedResultLines`：没有命中行时，从同一组已校验的搜索字段里取摘录，不再读任何行。搜索行无法校验时什么都不带；只有详情无法校验时仍可显示摘录。
- **App**：[`TimelineView`](../Sources/KinlogueApp/Views/TimelineView.swift) 的参数 `isSearching` 改为 `searchTerm`（由 [`AppShellView`](../Sources/KinlogueApp/Views/AppShellView.swift) 传入去掉首尾空白的搜索词；搜索词每次变化时结果都会清空重载，所以它就是当前结果对应的词）。新增 `SearchHighlight`，把标题、机构、命中行和摘录里的搜索词设为加粗加 Primary。卡片在命中行、摘录、结论三者中按此顺序显示一项；摘录前置 `text.magnifyingglass` 符号。新增 1 条中英文案（VoiceOver 读出摘录）。[`design-system.md`](design-system.md) 第 26 条同步。
- **README**：“为什么做续页”补上纸质报告会褪色、有些医院的线上报告只能在一段时间内查看或下载；“前后对照”一条写明加粗和上下文。
- **测试**：Core 2 项（摘录的窗口、截断、空白折叠、大小写和 NUL；命中行优先、跳过已显示字段、摘要上限），App 2 项（卡片的显示顺序与新文案的源码约束；高亮标出每一处命中且空词、不存在的词和含 NUL 的词都不标）；Platform 的搜索集成测试补上摘录、已显示字段不出摘录、无缓存路径和详情损坏时的摘录。主清单 1179 tests / 96 suites。
- **界面核对**：用临时测试离屏渲染了一张命中行卡片、一张摘录卡片和一张无命中卡片（合成数据），加粗与省略号位置符合预期；临时测试随后删除。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，本条改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1179 tests / 96 suites，隔离运行的验收扫描、storage process、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此后只追加了本条日志。传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：近上限资料库的搜索计时没有重测，摘录给每页每份报告多出一次字段内的本地化查找，开销没有量过。英文界面、窄窗口下的两行截断、键盘和 VoiceOver 朗读没有人工核对；改动后的 App 没有在真实资料库上搜过。`run-acceptance.sh`、托管平台上的 CI、macOS 26 和真机门禁与前几条相同，都没有执行。

## [2026-10-14] search/perf+ocr | 完整测试后的优化：搜索呈现提速，检验表格的表头别名与并排表格

- **起因**：用户要求对前两条做完整测试并找出可优化处。做了两项核对：近上限资料库上的首页计时对照，以及真实 OCR 走完导入、确认和搜索的合成版式核对。方法、数字和边界见 [搜索呈现测量](search-presentation-measurement-2026-10-14.md)；两项都用临时改动完成，结束后已撤回（规模探针源码与基线开关恢复原样，临时测试删除）。
- **计时发现**：9,990 份报告（9,791 条已确认）、结果改为 30 行表格的合成库上，初版呈现让首页 p50 从 39–40 ms 升到 59–81 ms（成员、日期、`合成`），从 62 ms 升到 100 ms（每份恰有一行命中）。原因是对每个列出的报告逐字段做本地化查找、整段折叠空白，并且每次完整解码详情。
- **Platform 优化**：[`SQLiteReportSearch.match`](../Sources/KinloguePlatform/Storage/SQLiteReportSearch.swift) 改为用缓存条目里的预筛键挑候选字段；只在候选字段里找表格行，找到后直接返回，摘录也只看候选字段。结果字段在搜索字段里的位置按搜索行与详情行两个摘要记在 `SQLiteReportSearchCache` 里（最多 20,000 条，随数据库关闭清空），之后的查询不再读取详情；第一次读取只解码结果文本，不解码来源引用。最终除 `合成`（每份列出报告的 30 行全部命中）多约 12 ms 外，各词首页与基线相差不超过 3 ms。
- **Core 优化**：[`ReportedResultLine.lines(matching:)`](../Sources/KinlogueCore/Domain/ReportedResultLine.swift) 改为“找下一处命中、取其所在行”，一行只命中时只需两次查找；含 NUL 的词仍逐行走有保护的谓词，含换行的词不匹配任何行。[`SearchExcerpt`](../Sources/KinlogueCore/Domain/SearchExcerpt.swift) 先在原文里查找，只折叠命中处附近的空白。
- **端到端发现**：6 种合成版式各一份 PDF 和一张图片。图片的基本表格可抽出；表头写成“检验项目 / 检测结果 / 参考区间”、带序号与缩写列的检验科版式、两表并排这三种此前抽不出或抽错。带文字层的 PDF 全部抽不出表格。
- **抽取规则 version 6**：[`ReportCandidateExtractor`](../Sources/KinlogueCore/OCR/ReportCandidateExtractor.swift) 识别三个表头的常见别名；表头行上的其他列按位置并入左侧的格，项目表头左侧的列不进入该行；同一表头行上的第二个项目表头视为并排的另一张表，两表各自成行。并排表格最初只出左表：右表表头略低于左表，被当成了“下面的下一张表”的起点，改为只把低于表头容差的表头当作下一张表后修复。复跑端到端核对，三种版式的图片都抽出全部 8 行。已确认记录不重新抽取；旧版本的待确认草稿按既有规则只补空字段。
- **测试**：Core 新增 2 项（检验科版式的列归并、并排表格且两行表头高度不同），后一项先在没有修复的代码上确认失败；Platform 搜索集成测试改为覆盖“结果字段位置已记住时仍从已校验的搜索行列出、重新读取时详情损坏则不列”，并改用新的 `match` 签名。主清单 1181 tests / 96 suites。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，本条改动完成后的完整 `scripts/test.sh` 退出码 0：主清单 1181 tests / 96 suites，隔离运行的验收扫描、storage process、大小写别名锁、安装 LAN 生产 HTTP 探针和真实双流 LAN 用例通过；此后只追加了本条日志。传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未处理**：带文字层的 PDF 按行生成 block，一行各列合成一个 block，因此抽不出表格，科室和日期候选会带上同行其他文字，没有标记的表格行不进入任何已确认字段、搜不到。可以按字符位置把文字层的行在大间隔处拆开，但 block 数会增加数倍，可能触发每份 4,096 个 block 的输出上限，需要单独评估。识别层误读（“↑”读成“个”或“T”，“白”读成“自”，“U/L”读成“UIL”）原样保留，由用户在复核时修正。

## [2026-10-14] review/fix | 搜索呈现与抽取规则 version 6 的评审修复

- **起因**：对 PR 22 做代码评审，发现 11 项问题，用户要求按建议处理。
- **抽取**：[`ReportCandidateExtractor`](../Sources/KinlogueCore/OCR/ReportCandidateExtractor.swift) 原先取相邻两个表头左缘的中点作为一张表的左右边界。检验单的表头常居中印在左对齐的项目名上方，项目名落到边界左侧，整行被丢掉；version 5 没有左边界，这一行还能抽出。现在改取相邻表头的右缘；并排的右表若有自己的序号或编号列，该列不再并入左表的参考值格。仍属同一次未发布的 version 6，版本号不变。
- **Core**：[`ReportedResultLine.lines(matching:)`](../Sources/KinlogueCore/Domain/ReportedResultLine.swift) 的每次查找都从所在行的换行之后继续，保证循环前进；只在测试里使用的公开 `lines(in:)` 已删除。[`SearchExcerpt`](../Sources/KinlogueCore/Domain/SearchExcerpt.swift) 把搜索词里的空白按同样方式折叠，含制表符或连续空白的词也能摘录。摘录跳过字段时不再要求与卡片显示的文字完全相同：卡片显示的是字段开头，且命中落在这一段里才跳过，所以超过 160 个标量的标题只在命中落在截断之后时摘录。含 NUL 的检查集中到 `RecordQuery.canLocate`。
- **Platform**：搜索行的摘要与内容哈希核对抽成 `SQLiteReportSearch.isVerified`，扫描和呈现共用。`SQLiteReportSearchCache` 的说明改为如实写明结果字段位置只按报告行记的两个摘要使用、不再核对详情字节；[`sqlite-storage.md`](sqlite-storage.md#app-查询与提交观察) 同步写明详情行此后单独损坏时同一会话的表现。
- **App**：`TimelineCard` 的 `showsDate` 与 `highlightTerm` 合并为一个 `searchTerm`；VoiceOver 读摘录正文，不再读出两端的省略号。
- **未处理**：搜索字段只是无标签的字符串数组，需要按详情找出结果字段的位置。改为带标签的格式要改动已校验的行格式并迁移现有资料库，这次不做。
- **测试**：Core 新增 1 项（表头居中、两表各带序号列），并在现有测试里补上按行前进、含换行或 NUL 的词、含空白的词的摘录、超长标题的摘录；Platform 缓存测试补上结果字段位置的摘要匹配、随报告清除、20,000 条上限和 `removeAll`。三处新断言先在未修复的代码上确认失败。主清单 1182 tests / 96 suites。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，完整 `scripts/test.sh` 退出码 0，主清单 1182 tests / 96 suites，隔离门禁一并通过；传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。近上限资料库的首页计时没有重测：摘录跳过字段的判断只对卡片显示的两三段文字做前缀比较，预计不改变 [搜索呈现测量](search-presentation-measurement-2026-10-14.md) 的结果，但这是推断。真实检验单版式上的边界效果仍未核对。

## [2026-10-15] search/ocr/review | 叙述命中按句呈现，异常标记带上所在行，识别误读提示，已确认报告按新规则整理

- **起因**：用户让再看看同类应用有什么可参考。同一帖子新增到 113 楼（[来源笔记](sources/2026-10-15-carehealth-thread-followup.md)），出现对比多份超声报告、OCR 加手工补录太繁琐的反馈。给出三条优化方案后，用户确认“按建议都做”，取舍见 [`decisions.md`](decisions.md) 2026-10-15 一节。
- **叙述命中**：新增 [`SearchPassage`](../Sources/KinlogueCore/Domain/SearchPassage.swift)，按“。；;！!？?”切出含搜索词的句子，每句至多一次。[`SQLiteReportSearch.match`](../Sources/KinloguePlatform/Storage/SQLiteReportSearch.swift) 在没有命中行、而搜索词落在卡片没有显示的字段里时，确定检查结果与结论的位置（缓存从“结果字段位置”改为“结果与结论两个位置”，按搜索字段开头六个字段逐一对上），列出至多 3 句并计数；不再需要的 `LibraryReportSearchMatch.excerpt(term:fields:hiding:)` 改为只判断“卡片是否已显示该处命中”的 `shows`。卡片用与表格行相同的 Container 网格，字段名只在字段开始处写一次。
- **抽取规则 version 7**：[`ReportCandidateExtractor`](../Sources/KinlogueCore/OCR/ReportCandidateExtractor.swift) 让表格行里的高低标记取整行作为异常标记，印在单独“提示”列里的标记也算，表格外的标记不变，全部按标记的阅读顺序排列。`candidateExtractorKeepsReportedLabRowsAsVerbatimResults` 原先断言这类行不产生异常标记，按新规则改为整行。
- **识别误读提示**：新增 [`RecognitionSuggestion`](../Sources/KinlogueCore/OCR/RecognitionSuggestion.swift) 与 [`RecognitionSuggestionsPanel`](../Sources/KinlogueApp/Views/RecognitionSuggestionsPanel.swift)，复核页和已确认记录编辑页都在检查结果下显示；只覆盖端到端核对见过的三种误读，采纳才改动一格。
- **按新规则整理**：新增 [`RecordRuleUpdate`](../Sources/KinlogueCore/Import/RecordRuleUpdate.swift)、`LibraryReportStoring.recordDocument` 与 `updateRecord(_:expectedRevision:document:)`、`LiveAppService.ruleUpdate/applyRuleUpdate`、`AppModel` 的检查与保存（`updateRecord` 与之共用 `saveRecordChange`），以及 [`RecordRuleUpdateView`](../Sources/KinlogueApp/Views/RecordRuleUpdateView.swift) 的提示和对照页。
- **过程问题**：中途一次构建失败没有被发现：过滤编译错误的 grep 没有先去掉 ANSI 颜色码，随后 `--skip-build` 的测试跑的是旧二进制。此后每次构建都单独打印退出码，并在干净构建上重跑了全部相关测试。
- **规模复测**：9,990 份报告（9,791 条已确认）的未改动合成库上，初版按句呈现让 `合成` 的首页 p50 比只做摘录多约 8 ms。改为只用前缀比较判断卡片是否已显示、在原文里直接截取已找到的命中、按 Unicode 标量找句末后，`合成` 多约 4.5 ms（p50 43.3 ms），只出现在叙述字段的 `偏高` 多不到 1 ms，其余查询相差在 2 ms 以内。`偏高` 的基线本身已高于 50 ms，与本次无关。方法、数字和边界见 [搜索呈现测量](search-presentation-measurement-2026-10-14.md#叙述命中按句呈现的复测2026-10-15)；环境变量开关、临时查询词和计时改动都已撤回，合成库已删除。
- **视觉检查**：用临时离屏渲染测试看过叙述句子卡片、误读提示面板、规则更新提示和对照页（合成数据），之后删除了临时测试。
- **测试**：新增 9 项：Core 5 项（句子切分、表格外标记与阅读顺序、误读规则两项、按新规则整理）、App 4 项（真实资料库上的按新规则整理、AppModel 提示与保存、两个编辑页与对照页的源码检查）；另在既有测试里补上叙述命中的集成断言、字段位置缓存改名、中英文案和 sheet 计数。主清单 1191 tests / 96 suites。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，完整 `scripts/test.sh` 退出码 0，主清单 1191 tests / 96 suites，隔离门禁一并通过；传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未验证**：三种识别误读规则和按句切分在真实报告上的命中与误报；按新规则整理在真实旧版资料库上的表现（只用合成 block 验证过）；对照页和误读面板的键盘、VoiceOver 与窄窗口；macOS 26 与安装后的 App。

## [2026-10-15] plan/assistant | 提议成员对话：调用本机已登录的 Codex / Claude Code CLI

- **起因**：用户希望针对每一位成员引入模型对话，先接入本机已有的 Codex CLI 或 Claude Code CLI，让使用者以聊天方式了解这位成员的资料并提问，不作为诊断。本条只做规划，没有改代码。
- **依据**：读了 [`project-overview.md`](project-overview.md)、[`../PRIVACY.md`](../PRIVACY.md)、[`decisions.md`](decisions.md) 2026-10-11 一节和开放门禁第 6 项、[`brand.md`](brand.md) 的方向一节、[`architecture.md`](architecture.md)，以及主 App 的 [entitlements](../packaging/Kinlogue.entitlements)。另读了未合入的 `codex/agentrunkit-probe` 分支（基于 SQLite 切换前的主线）的助手、Codex 接入和调研文档：它内置锁定版本的 Codex 并由续页自己做 ChatGPT 授权，刻意不读取用户的 CLI 配置和凭据，Claude 暂缓。本机两个 CLI 只看了帮助文本，记录在[来源笔记](sources/2026-10-15-local-cli-noninteractive-flags.md)。
- **产出**：[成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md)（status: proposed）。要点：每段对话绑定一位成员，只发送预先组好、可逐字预览的已确认报告投影，模型没有任何工具；启动 CLI 放在拿不到资料库的单独 XPC helper 中，主 App 权限不扩大；健康资料只经 stdin；按能力检查 CLI 而不锁版本；对话只在内存中。helper 是否启用沙盒、是否纳入 Claude Code、同意粒度、是否允许描述性排列历次结果等 7 项留给用户决定。导航同步到 [`index.md`](index.md)、[`plans/README.md`](plans/README.md)、[`sources/README.md`](sources/README.md)、[`decisions.md`](decisions.md) 开放门禁第 6 项和 [`brand.md`](brand.md)。
- **未执行**：没有发起任何模型请求，没有在 App Sandbox 或 XPC 中运行 CLI；计划中凭据可读性、流式事件格式、工具是否真正关闭、是否写入会话或遥测文件等都标为待 U0 实测。`PRIVACY.md`、`README.md` 和产品契约没有改动。

## [2026-10-15] plan/assistant | 成员对话计划修订：首版只接 Codex，对话保存做兼容设计

- **起因**：用户确定 D6 为首版只做 Codex，并要求“如果想保留对话，设计上最好可以兼容”。暂不执行 U0。
- **依据**：[`sqlite-storage.md`](sqlite-storage.md) 的格式一节（打开时精确校验 `user_version=1` 与 schema，未知版本拒绝、不自动迁移）和逻辑恢复点一节（logical-v1 与 schema 解耦、有冻结夹具）；[`decisions.md`](decisions.md) 的“首发前 current-only”；`SQLiteReportRepository.deleteMember` 在成员仍有报告、草稿或 DICOM 时拒绝删除。
- **计划改动**：[成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md) 的范围、方案比较、适配表、界面、U0 和人工矩阵改为只针对 Codex，适配层保留 `CLIAdapter` 接口给后续的 Claude Code。新增第 4.9 节：首版对话仍只在内存，但对话、轮次和每轮发送清单是可编码的 Core 值类型，引用落在记录 ID 与 revision 上，每轮无状态重发、不依赖 Codex 会话文件，App 只经 `AssistantConversationStoring` 读写；打开保存时推荐在主资料库加三张表并进入恢复点，代价是第一次 schema 迁移（v1→v2）和 logical payload v2，需要用户同意 current-only 的例外；备选是单独的对话数据库文件。新增可选单元 U7 和待定决策 D8；第 9 节把 D6 移到“已定”。导航中的描述同步到 [`index.md`](index.md)、[`plans/README.md`](plans/README.md)、[`decisions.md`](decisions.md) 和 [`brand.md`](brand.md)。
- **未执行**：仍未发起模型请求，没有改代码；迁移、恢复点 v2 和对话表都只是设计，没有原型或测试。

## [2026-10-15] plan/assistant | 成员对话计划：确定对话保存进主资料库与恢复点，设计 v1→v2 迁移

- **起因**：用户确定 D8：保存的对话放进主资料库并进入恢复点，同意为此做资料库第一次 schema 迁移（v1→v2）。
- **依据**：[`SQLiteLibrarySchema`](../Sources/KinloguePlatform/Storage/SQLiteLibrarySchema.swift) 打开时要求 `user_version` 等于当前版本、每张表的 DDL 逐字相同，并在 `library_state` 保存全部 DDL 的 SHA-256；[`sqlite-storage.md`](sqlite-storage.md) 的逻辑恢复点一节（logical-v1 与 schema 解耦、两个 v1 冻结夹具）。
- **计划改动**：[成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md) 第 4.9 节写明迁移做法：只接受 v1 作为迁移输入、其他未知版本照旧失败关闭；在单实例 owner 下、普通服务打开前，用单个事务校验 v1、按 v2 的 DDL 常量建表、写 `user_version = 2`、更新 `library_state` 的 schema identity 与内容摘要，再按 v2 校验；只新增表，不改已有行、不读原件；建议但不强制迁移前手动备份；回退只能用迁移前的恢复点。恢复点 payload 升到 v2，reader 同时接受 v1 与 v2。U7 的退出条件补上 v1 冻结资料库夹具的分阶段强退测试；D8 移入“已定”，D4 改为问 U7 放进首版还是首版之后单独发布（建议后者）。[`decisions.md`](decisions.md) 开放门禁第 6 项记下这个例外已获同意、实施前 current-only 规则不变。
- **未执行**：没有改代码、没有原型或测试；迁移和恢复点 v2 都还只是设计。

## [2026-10-15] plan/assistant | 成员对话计划：确定保存对话在首版之后单独发布

- **起因**：用户确定 D4 按建议执行：U7（保存对话）在首版之后单独发布。
- **计划改动**：[成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md) 把 D4 移入“已定”，修订说明、第 4.6 节和 U7 一行同步。首版对话只在内存里，但仍按第 4.9 节做可保存的兼容设计。待定的还有 D1（由 U0 实测决定）、D2、D3、D5、D7，以及代理变量和 Codex 服务商配置两个默认值。
- **未执行**：没有改代码，U0 未开始。

## [2026-10-15] plan/assistant | 成员对话计划：D2、D3、D5、D7 按建议确定

- **起因**：用户确定 D2、D3、D5、D7 都按计划中的建议执行。
- **计划改动**：[成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md) 第 9 节把四项移入“已定”：首版模型没有任何工具，只发送可逐字预览的上下文包（D2）；同意按对话计，CLI、模型或上下文包变化即失效（D3）；允许按时间描述性排列同一项目的历次原文结果并逐条引用，不做好转或恶化判断（D5，实现时需在 [`decisions.md`](decisions.md) 记录它与“当前不做趋势分析”的边界）；默认不发送机构名称，确认页提供单独开关（D7）。第 3.2 节、第 4.4 节和确认页描述同步。待定的只剩 D1（由 U0 实测决定），以及代理变量和 Codex 服务商配置两个默认值。
- **未执行**：没有改代码，U0 未开始。
- **补充**：同日在第 9 节为剩下的两个默认值写出建议，编号 E1、E2：允许在设置里填写四个代理变量，只传给 Codex 子进程（E1）；首版不加载 Codex 的用户配置，因此不支持第三方中转，后续改为在续页设置里填写服务商地址并经 `-c` 传入（E2）。第 7 节人工矩阵补上对应检查。两项待用户确认。

## [2026-10-15] plan/assistant | 成员对话计划：E1、E2 按建议确定

- **起因**：用户确定 E1、E2 都按建议执行。
- **计划改动**：[成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md) 第 9 节把 E1（设置里可填四个代理变量，只传给 Codex 子进程）和 E2（首版不加载 Codex 用户配置、不支持第三方中转，后续改为在续页设置里填写服务商地址）移入“已定”；第 4.3 节、设置页描述和第 11 节后续工作同步。除 D1 由 U0 实测决定外，计划中的决策已全部确定。
- **未执行**：没有改代码，U0 未开始；U0 会消耗用户的 Codex 额度，需要用户同意后执行。

## [2026-10-15] probe/assistant | 成员对话计划 U0：本机 Codex 在加固参数与两种 XPC helper 下的实测

- **起因**：用户同意开始 U0，并允许使用其本机 Codex 的额度；只用合成资料。
- **做法**：探针代码放在会话临时目录，没有进入仓库。先用只监听 127.0.0.1 的模拟 Responses 服务记录 Codex 0.162.0 实际发出的请求，再用真实账号在终端跑 3 轮；然后构建 ad-hoc 签名的沙盒宿主，内嵌沙盒加例外（A）与非沙盒（B）两个 XPC helper，各自用真实账号跑通。结果与方法见 [U0 证据笔记](sources/2026-10-15-codex-u0-probe-evidence.md)。
- **关键发现**：只关闭功能不够——当前所有模型的目录项都是 `code_mode_only`，请求里仍有代码模式和子 agent 协作共 9 个工具；加 `agents.enabled=false` 并用 `model_catalog_json` 传入改过的目录后，工具数为 0。`-c instructions=...` 整段替换内置提示词，加固后的请求只有两条消息，没有本机路径。`--strict-config` 拒绝不认识的配置键。`exec --json` 没有逐字增量。真实账号 3 份记录 6.2 秒、20 份（约 92 KB）17.1 秒；注入记录被当成资料，canary 未外泄。整个 `~/.codex` 中找不到合成标记串。A 下 helper 读不到真实家目录和 `~/Library/Containers`，Codex 仍能读登录文件并完成回答。
- **计划改动**：[成员对话计划](plans/2026-10-15-feat-member-cli-chat-plan.md) 按约定规则确定 D1 为方案 A（B 不再作为备选），写明 helper 的 entitlement 集合；第 4.3 节换成实测过的参数表，能力检查增加“发送前对本机模拟服务跑一轮、确认请求中没有工具”；超时改为启动 10 秒、整轮 180 秒；对话面板增加等待提示；U2 补上模型目录改写、模拟请求检查和其他安装位置的验证；风险一节换成 temporary exception 与模型目录改写两项。计划中的决策已全部确定。
- **未执行**：A 下的令牌刷新写回（这几轮没有发生刷新）、Homebrew 以外的安装位置、真实发送的网络去向（没有抓包）、取消与进程组回收、Developer ID 与公证、macOS 26。探针留下两个由系统保护的空沙盒容器（`~/Library/Containers/com.kinlogue.u0probe.*`），`rm` 无法删除，需要用户在 Finder 中移除。

## [2026-10-15] feat/assistant | 成员对话计划 U1：Core 的上下文包、提示词、引用与对话值类型

- **起因**：用户要求开始 U1，先写测试。范围只在 `KinlogueCore`，不接入 Platform 或 App，界面和隐私承诺没有变化。
- **测试先行**：新增 [`AssistantContextPackTests`](../Tests/KinlogueCoreTests/AssistantContextPackTests.swift)（15 项）和 [`AssistantConversationTests`](../Tests/KinlogueCoreTests/AssistantConversationTests.swift)（8 项），全部使用合成数据。实现之前的 `swift build --build-tests` 只在这两个文件里因类型不存在而失败，其余目标编译通过。
- **Core**（[`Sources/KinlogueCore/Assistant/`](../Sources/KinlogueCore/Assistant/AssistantContextPack.swift)，只依赖 Foundation）：`AssistantContextPackBuilder` 只取该成员的已确认报告，默认从最新开始放入，最多 20 份、正文合计 60,000 字节，遇到放不下的一份即停止，不跳到更旧的报告；显式选择时不可用、重复、为空或超限都直接报错。报告从旧到新编为 R1…Rn，正文只含标题（缺省用报告类型）、检查结果、结论和异常项的确认转录，机构只在打开开关时加入；成员名、消歧标签、科室、备注、文件名和任何 UUID 都不进入正文。单份超过 12,000 字节时截断并标 `[truncated]`。日期按存储日历（UTC 正午）写成 `yyyy-MM-dd`。正文和用户文本中能打开或关闭输入标签的 `<` 改写为 `&lt;`，`<5.2` 这类比较保持原样。摘要由调用方注入（Core 没有 SHA-256 实现，生产时由 Platform 提供）：投影摘要覆盖时间线日期、日期类型和始终发送的字段，不受备注或 revision 影响；同意指纹覆盖提示词版本、CLI、版本、模型、机构开关和每份报告的发送内容与 revision。`AssistantPrompt` 给出版本 1 的角色说明和每轮输入（记录、要重发的历史、问题）。`AssistantCitationParser` 只把整个方括号或【】里全是 `R` 加数字的内容当引用，按本轮发送清单解析，未知编号标为无效；引用状态按 revision 或投影摘要判断“仍一致/已更改/已删除”。`AssistantTurn`、`AssistantConversation`、`AssistantTurnSource`、`AssistantProviderDescriptor` 可编码，解码时重新校验；对话最多 20 轮、问题 2,000 字、回答 32 KiB，重发窗口保留最新、不超过 40,000 字节的轮次。`AssistantProvider` 协议只声明一轮请求与语义失败码，还没有实现。
- **测试清单**：主清单从 1182 增至 1205 tests / 96 suites，[`acceptance/current-release.md`](acceptance/current-release.md) 的 release-facts 标记和两处数字同步；[`architecture.md`](architecture.md) 的 Core 一行补上这些类型。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，Core 全部 155 项（含新增 23 项）通过；会断言文本的套件（`Safety|GitHubActions|Documentation|Packaging|PrivacyGuard|Localization|Presentation|Layout|AcceptanceScan`）通过；完整 `scripts/test.sh` 退出码 0，各分片的期望数与实测数一致，隔离运行的门禁一并通过。此后只改了文档。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：Platform 的 SHA-256 注入、SQLite 窄查询、XPC helper 和 App 接入（U2–U5）都还没有开始；提示词的实际回答质量只在 U0 用合成资料看过几轮。

## [2026-10-15] feat/assistant | 成员对话计划 U2：助手 IPC、Codex 适配与 bridge（未打包进 App）

- **起因**：用户要求提交 U1 后开始 U2：IPC、helper、Codex 适配器、模型目录改写、发送前的模拟请求检查和假 CLI 测试。打包进 App、helper entitlement、签名 XPC 验证、其他安装位置和经 helper 的真实一轮拆为 U2b，见[计划](plans/2026-10-15-feat-member-cli-chat-plan.md)第 6 节。
- **新 target**（[`Package.swift`](../Package.swift)，均不对外发布）：`KinlogueAssistantIPC`（Foundation-only 的有界 DTO、失败码、`@Sendable` 回复的 NSXPC 协议；模型名只能是字母数字开头的短 token，代理变量只认四个名字，路径须为绝对路径且无控制字符）；`KinlogueAssistantCLI`（`CodexInvocation`、`CodexFeatureList`、`CodexModelCatalog`、`CodexEventAccumulator`、`CodexFailureClassifier`、`CodexRequestInspection`、`LoopbackResponsesServer`、`CLIProcess`、`CLISupervisor`、`CLIExecutable`、`CodexBridge`）；`KinlogueAssistantBridge`（XPC 入口，兼作 supervisor）；`KinlogueAssistantCLIFixture`（测试用假 `codex`）。[`verify-package-graph.sh`](../scripts/verify-package-graph.sh) 与 [`PackageGraphVerifierTests`](../Tests/KinlogueAppTests/PackageGraphVerifierTests.swift) 的精确清单同步。Platform、App 和主 App 的 entitlement 都没有变化。
- **做法要点**：每轮用 `posix_spawn` 让 supervisor 领导新进程组；supervisor 只把 runner 点名的环境变量交给 CLI（Foundation 会给自身进程加上 `__CF_USER_TEXT_ENCODING`），父进程消失时杀掉整组；超时、取消、输出超限或发现工具调用时先 SIGTERM 再 SIGKILL 整组。输入只走 stdin。能力检查按（可执行文件、模型）缓存：读版本、核对 `exec --help`、由 `features list` 算出要关的功能，再用这一轮的模型对 127.0.0.1 上的模拟服务跑一轮，要求请求里没有工具、只有我们的两条消息、模型一致、`store` 为 false、不含家目录、用户名和临时目录路径。回答取最后一个 `agent_message`；消息、推理和 `error` 之外的事件项一律视为工具调用并终止。每轮用私有临时目录，结束即删，启动时清理残留。
- **测试先行**：先写 [`AssistantIPCTests`](../Tests/KinloguePlatformTests/AssistantIPCTests.swift) 与 [`AssistantCodexAdapterTests`](../Tests/KinloguePlatformTests/AssistantCodexAdapterTests.swift)，在只有占位源文件时构建，失败只出现在这两个文件；再写 [`AssistantBridgeProcessTests`](../Tests/KinloguePlatformTests/AssistantBridgeProcessTests.swift)，用假 CLI 覆盖 stdin 投递与参数/环境中无输入、启动超时、整组（含孙进程）终止、取消、输出洪泛与超长行、工具调用中止、宿主被 SIGKILL 后 supervisor 清组、可执行文件校验、能力检查的各类失败、整轮成功与失败码、忙碌拒绝与按 ID 取消、启动清理。共 26 项，连续三次运行稳定，无残留进程。
- **对真实 Codex 的复核**：用临时测试（已删除）让 `CodexBridge` 对本机 Codex 0.162.0 跑能力检查，只走本机模拟服务。先后暴露两处问题并修正：功能名可含 `.`；`features list` 在关闭后仍显示 `unified_exec` 开启，而实际请求没有任何工具，因此不再复查功能表。修正后 `gpt-6.1-sol` 与 `gpt-6-astra` 均通过。详见 [U0 证据笔记](sources/2026-10-15-codex-u0-probe-evidence.md) 的追加一节；计划第 4.3 节的成功判据与能力检查描述同步修订。
- **测试清单**：主清单增至 1231 tests / 99 suites，[`acceptance/current-release.md`](acceptance/current-release.md) 同步；[`architecture.md`](architecture.md) target 表与 [`../AGENTS.md`](../AGENTS.md) 代码边界表补上新 target。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，会断言文本的套件（含 `PackageGraph`）通过；完整 `scripts/test.sh` 退出码 0，各分片期望数与实测数一致，隔离门禁一并通过，结束后没有残留的假 CLI 进程；传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：没有经 bridge 跑真实的一轮问答（U2 没有动用用户额度）；bridge 尚未构建成 XPC bundle、没有签名或 entitlement，App 中没有任何入口；npm 等其他安装位置、失败消息分类对真实错误输出的符合程度都未验证。

## [2026-10-15] feat/assistant | 成员对话计划 U2b：bridge 打包为签名沙盒 XPC（方案 A）并验证

- **起因**：用户要求提交 U2 后开始 U2b：把 bridge 打包成 XPC 服务嵌进 App、写方案 A 的 helper entitlement、做签名 XPC 验证，并核对其他安装位置。
- **安装位置核对**（只读，未安装任何东西）：本机 Codex 只有 Homebrew cask 一种；Node 也来自 Homebrew，npm 全局前缀是 `/opt/homebrew`。`npm view @openai/codex@0.162.0` 显示 npm 版的 `codex` 是 `bin/codex.js` Node 脚本，再由它启动平台对应的原生二进制。据此 entitlements 只读例外取 `/opt/homebrew/` 与 `/usr/local/`（后者是官方 Node 安装包的 npm 前缀，只验证了同一机制），家目录下的 nvm、volta、bun 等不加入；npm 脚本的 `#!/usr/bin/env node` 需要在请求路径所在目录找到 `node`，`CodexBridge` 的 PATH 因此先放请求路径所在目录。
- **打包**：新增 [`KinlogueAssistantBridge-Info.plist`](../packaging/KinlogueAssistantBridge-Info.plist)（`com.kinlogue.mac.assistant-bridge`，XPC!）、[`KinlogueAssistantBridge.entitlements`](../packaging/KinlogueAssistantBridge.entitlements)（sandbox、network.client、network.server、`~/.codex/` 读写、两个安装根只读）和 [`assemble-assistant-bridge.sh`](../scripts/assemble-assistant-bridge.sh)。[`build-app.sh`](../scripts/build-app.sh) 只在 `--with-assistant-bridge` 时构建并嵌入 bridge：在 U6 一并改写隐私说明和发布门禁之前，默认构建、`verify-app.sh` 与发布包都保持只有 DICOM 一个 XPC 服务。实际跑了一次带开关的构建：两个 XPC 服务、`codesign --verify --strict --deep` 通过、bridge 的 entitlements 恰为上述集合、主 App 的 entitlements 不变、无符号链接。
- **行为修正**（测试先行，两项新测试先确认失败）：启动不了的 CLI（沙盒拒绝执行，测试中用有执行位但格式不可执行的文件模拟；supervisor 以 127 退出或 spawn 失败）报 `unsupportedLocation`；`CLIExecutable.inspect` 区分缺失、不合格和“看得见但不能执行”（沙盒允许读元数据，只拒 `access(X_OK)`）；能力检查读模型目录时也识别启动失败。bridge 只在发起这一轮的连接断开时取消它，不再因任何连接关闭而取消。
- **签名 XPC 验证**：新增 [`verify-assistant-xpc.sh`](../scripts/verify-assistant-xpc.sh) 与沙盒探针宿主 `KinlogueAssistantXPCProbe`（[`Package.swift`](../Package.swift)、package graph 门禁与其测试同步）。生产 entitlements 下：本机 Codex 0.162.0 在沙盒 bridge 中通过能力检查（不耗额度），例外目录之外的 CLI 报“不支持的安装位置”；多一处只读目录的验证签名（独立 bundle 标识）下：假 CLI 的回答经 supervisor 返回、仿 npm 包装可运行、第二条连接的取消停止这一轮及孙进程、SIGKILL bridge 后整组退出且无 supervisor 残留。连续两次全部通过，无残留进程和临时目录。详见 [U0 证据笔记](sources/2026-10-15-codex-u0-probe-evidence.md) 追加一节；计划第 4.2 节、[`architecture.md`](architecture.md) 与 [`testing-and-release.md`](testing-and-release.md) 同步。
- **测试**：新增 [`AssistantPackagingBoundaryTests`](../Tests/KinlogueAppTests/AssistantPackagingBoundaryTests.swift)（3 项：entitlements 精确集合、Info.plist 身份与版本、默认构建不嵌入且验证脚本覆盖各项检查）和 2 项进程测试；主清单 1236 tests / 100 suites，[`acceptance/current-release.md`](acceptance/current-release.md) 同步。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，`verify-assistant-xpc.sh` 连续两次通过；会断言文本的套件（含 `PackageGraph` 与新的打包边界测试）通过；完整 `scripts/test.sh` 退出码 0，各分片期望数与实测数一致，隔离门禁一并通过，无残留假 CLI 进程；传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。没有运行 `verify-app.sh`（它要求干净源码，且默认构建本次没有变化）。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：经 bridge 的真实一轮问答；`/usr/local/` 下的真实 Codex 安装；Developer ID 签名与公证下 temporary exception 的表现；macOS 26；`package-distribution.sh` 对第二个 XPC 服务的重签（默认发布包不含 bridge，届时在 U6 处理）。系统为探针创建的三个沙盒容器只含元数据，保留在 `~/Library/Containers/`。

## [2026-10-15] feat/assistant | 成员对话计划 U3：SQLite 上下文包读取与 bridge provider

- **起因**：用户要求提交 U2b 后开始 U3：Platform 的 SQLite 窄查询和 XPC 客户端。
- **窄查询**：[`AssistantLibrary.swift`](../Sources/KinloguePlatform/Assistant/AssistantLibrary.swift) 给 `SQLiteReportRepository` 加 `assistantPack(memberID:selection:includeOrganization:)`：一次读取取得成员、该成员已确认报告的总数和按 `timeline_date DESC, record_id` 的最新 20 份（显式选择则按 ID 读取，超过 20 份直接拒绝），交给 Core 构建器，摘要用 `ContentDigest.sha256`；自动选择时读不出的报告列入 `damagedRecordIDs` 并略去。Core 构建器为此增加 `confirmedRecordCount`，只载入最新几份时仍能算出略去了几份。`assistantRecordStates` 按 ID 读回 revision 与投影摘要。没有新增持久化字段。
- **XPC 客户端**：[`KinlogueAssistantXPCClient`](../Sources/KinlogueAssistantIPC/AssistantXPCClient.swift) 放在 `KinlogueAssistantIPC`，实现 `KinlogueAssistantBridgeClient` 协议：保留一条连接、失效后重建，回复与错误处理只有一个能恢复等待，取消调用方的任务时在同一条连接上发送取消。验证探针改用它，所以 [`verify-assistant-xpc.sh`](../scripts/verify-assistant-xpc.sh) 测到的就是 App 将用的客户端；取消检查改为“取消任务即停止这一轮”。
- **Provider**：[`BridgeAssistantProvider`](../Sources/KinloguePlatform/Assistant/BridgeAssistantProvider.swift) 实现 Core 的 `AssistantProvider`，把 IPC 失败码映射为 Core 的 `AssistantFailure`（新增 `unsupportedLocation`、`toolUseDetected`、`busy`、`bridgeUnavailable`），bridge 不可达或回复无法解码时报 `bridgeUnavailable`；`AssistantCLISettings` 在构造时就拒绝 bridge 会拒绝的路径和代理变量；`status(model:)` 给设置页用。Platform 新增对 `KinlogueAssistantIPC` 的依赖，[`verify-package-graph.sh`](../scripts/verify-package-graph.sh) 与其测试同步。
- **测试先行**：新增 [`AssistantLibraryTests`](../Tests/KinloguePlatformTests/AssistantLibraryTests.swift)（5 项，经真实导入路径在 SQLite 资料库里建报告：最新 20 份与成员隔离、损坏报告略去并列出、显式选择、归档/缺失/无报告成员、编辑/备注/删除后的引用状态）、[`AssistantProviderTests`](../Tests/KinloguePlatformTests/AssistantProviderTests.swift)（6 项，用进程内客户端直接驱动 `CodexBridge` 与假 CLI：回答、失败映射、取消任务、状态、bridge 不可用、设置校验）和 1 项 Core 测试。主清单 1248 tests / 102 suites，[`acceptance/current-release.md`](acceptance/current-release.md) 同步；[`architecture.md`](architecture.md)、[`sqlite-storage.md`](sqlite-storage.md) 同步。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，助手相关测试全部通过；`verify-assistant-xpc.sh` 改用共享客户端后 9 项检查通过；会断言文本的套件通过；完整 `scripts/test.sh` 退出码 0，各分片期望数与实测数一致，隔离门禁一并通过，无残留假 CLI 进程；传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：App 侧还没有任何调用（U4/U5）；近上限资料库上读取上下文包的耗时没有测；损坏报告在引用状态里与“已删除”无法区分，界面上需要在 U5 决定措辞。

## [2026-10-15] feat/assistant | 成员对话计划 U4：App 服务、同意、内存对话存储与生命周期

- **起因**：用户要求提交 U3 后开始 U4：App 服务——设置、同意、内存版对话存储、生命周期和提交观察。界面与文案留给 U5。
- **App**（[`AssistantService.swift`](../Sources/KinlogueApp/App/AssistantService.swift)）：`AssistantSettings` 与 `AssistantSettingsStore` 存在 App 偏好（`assistant.enabled/executablePath/model/proxy`），默认关闭，bridge 会拒绝的路径、模型和代理变量读出时视为未设置。`AssistantConversationStoring` 协议与 `InMemoryAssistantConversationStore`（每位成员最多 200 段）。`AssistantConsent` 绑定成员、接收方（CLI 版本与模型）和上下文包指纹，只在内存里。`LiveAssistantService`：读取上下文包；按 bridge 状态生成同意；每轮发送前核对同意仍对应当前包、CLI 版本和模型，否则要求重新确认；在 `LibraryLifecycleCoordinator.withActiveOperation` 里运行这一轮并可被撤销取消；只保存完整完成的轮次；`revoke()` 取消进行中的一轮、清空对话并拒绝此后的请求。错误都是语义值（`AssistantServiceError`）。
- **模型**（[`AssistantConversationModel.swift`](../Sources/KinlogueApp/ViewModels/AssistantConversationModel.swift)）：每位成员一段当前对话，打开时载入上下文包和 CLI 状态并要求确认；代数栅栏丢弃已切换成员或已关闭时迟到的结果；停止只取消当前一轮；提交观察后重读上下文包，指纹变化才清除同意，并重查被引用记录的状态；切换“包含机构名称”会重建上下文包并要求重新确认；关闭功能时取消并清空；整库删除、恢复或完整性故障开始后永久锁定，直到重启。问题保存为 `AssistantIssue` 语义值，没有已解析的文案。
- **组装**：`LiveAppServiceEnvironment.assistantLibrary` 传入 SQLite 报告仓库；[`AppComposition`](../Sources/KinlogueApp/App/AppComposition.swift) 构造服务与模型，在存储就绪时登记撤销钩子，删除、恢复与完整性故障的开始回调锁定模型，提交观察回调通知模型。bridge 状态回复新增“检查所用模型”，作为一轮的默认模型。资料库打不开时的组装不含助手。
- **测试先行**：新增 [`AssistantServiceTests`](../Tests/KinlogueAppTests/AssistantServiceTests.swift)（7 项）与 [`AssistantConversationModelTests`](../Tests/KinlogueAppTests/AssistantConversationModelTests.swift)（7 项模型测试与 1 项 composition 测试：真实 SQLite 资料库与启动链路，删除资料库后模型锁定），bridge 由可控的假后端替代；构建先确认这些测试因类型不存在而失败。主清单 1263 tests / 105 suites，[`acceptance/current-release.md`](acceptance/current-release.md) 与 [`architecture.md`](architecture.md) 同步。
- **验证**：macOS 27.0.1 / Xcode 27.0 / Swift 6.4 上，助手相关测试及受影响的恢复、删除、完整性与启动测试通过；会断言文本的套件（含本地化硬编码门禁）通过；完整 `scripts/test.sh` 退出码 0，各分片期望数与实测数一致，隔离门禁一并通过；传入实际清单摘要的 `scripts/lint.sh` 与 `scripts/verify-docs.sh`、`scripts/privacy-guard.sh`、`scripts/compile-localizations.sh --check` 与 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：没有界面入口（U5），因此没有任何用户能触发对话；默认构建不含 bridge，开启功能后状态会是“对话服务不可用”，直到 U6 默认嵌入。经真实 bridge 的完整一轮仍未运行。

## [2026-10-15] feat/assistant | 成员对话计划 U5：对话面板、确认页、设置页与中英文案

- **起因**：用户要求提交 U4 后开始 U5：对话面板、确认页、设置页和中英文案；之后要求按计划完成、自测后再交给其审核。
- **可见范围**：[`AssistantAvailability`](../Sources/KinlogueApp/App/AssistantService.swift) 检查 App bundle 的 `Contents/XPCServices` 里有没有 bridge，没有时设置区块和工具栏按钮都不出现。在 U6 改写隐私说明之前，只有 `build-app.sh --with-assistant-bridge` 的开发构建能看到这一功能，默认构建和发布的界面不变。
- **设置**：新增 [`AssistantSettingsModel`](../Sources/KinlogueApp/ViewModels/AssistantSettingsModel.swift) 与 [`AssistantSettingsSection`](../Sources/KinlogueApp/Views/AssistantSettingsSection.swift)（设置页“AI 对话（实验）”）。开关保存后立即检查 CLI，显示位置、版本、登录、模型和检查结果。Codex 路径、模型、代理三个字段先校验再保存：路径须为绝对路径；模型须为 bridge 接受的记号；代理只接受 http/https/socks5 地址，一个字段同时写入 `HTTPS_PROXY` 与 `HTTP_PROXY`，不接受用户名或密码，因为设置以明文保存。`ALL_PROXY`、`NO_PROXY` 首版不提供。保存后通知对话模型；接收方改变时需要重新确认。
- **面板与确认页**：[`AssistantPanelView`](../Sources/KinlogueApp/Views/AssistantPanelView.swift) 由工具栏“对话”按钮切换到详情栏，只对选中的成员可用。点选时间线卡片、影像卡片或来源 Chip 切回详情，同一成员的对话与同意保留。[`AssistantConsentSheet`](../Sources/KinlogueApp/Views/AssistantConsentSheet.swift) 列出接收方、会发送和不会发送的内容、“不是匿名化，发送后无法撤回”的警示、默认关闭的“包含检查机构名称”和可折叠的全文，是唯一给出同意的地方。回答以中性 Card 显示“模型生成 · 可能有误 · 不是诊断”，只保留行内强调，去掉链接；来源 Chip 区分当前、已更新、已删除和未发送。提问框 Return 换行，Command-Return 发送，输入法组字时不发送；等待时显示已等待秒数，可以停止，没有得到回答的问题放回输入框。对话模型新增 `pendingQuestion`、`sendingStartedAt` 与 `recheck()`。文字与派生值集中在 [`AssistantPresentation.swift`](../Sources/KinlogueApp/Views/AssistantPresentation.swift)，函数都带语言参数以便测试。
- **文案**：String Catalog 新增 109 条中英文案，其中 5 条带英文单复数；已运行 `compile-localizations.sh --write`。
- **测试先行**：新增 [`AssistantPresentationTests`](../Tests/KinlogueAppTests/AssistantPresentationTests.swift)（8 项：全部问题的中英文案、语气、单复数与年月范围、去链接、来源状态）、[`AssistantSettingsModelTests`](../Tests/KinlogueAppTests/AssistantSettingsModelTests.swift)（4 项：开关与检查、字段校验、通知对话模型、bundle 中的 bridge）和 [`AssistantViewSafetyTests`](../Tests/KinlogueAppTests/AssistantViewSafetyTests.swift)（5 项源码检查：视图不创建服务、不读偏好；回答保持中性且没有链接；Command-Return 与输入法保护；同意只在确认页给出；入口受 bridge 与开关约束）。对话模型测试补充发送中状态。主题门禁的 sheet 画布清单加入确认页。`MemberSidebarViewSourceTests` 对 `onSelectDICOM` 闭包的断言改为新的多行写法：选中影像仍调用 `model.selectDICOMStudy`，同时把详情栏从对话切回影像。主清单 1280 tests / 108 suites，[`acceptance/current-release.md`](acceptance/current-release.md) 同步；[`design-system.md`](design-system.md) 第 27 条、[`architecture.md`](architecture.md)、[`index.md`](index.md) 和 `AGENTS.md` 的范围说明同步。
- **离屏核对**：用临时测试在离屏窗口里以合成数据渲染中英文的面板（需要确认、空、已回答、发送中、已停止、不可用）、确认页、设置区块和 340pt 窄宽度。据此修正四处：发送范围拆成两行，不再截断；提问框固定高度；确认页开关移到行尾；设置状态与字段改用 Grid 对齐。临时测试已删除，PNG 只留在会话临时目录，没有进入仓库。

## [2026-10-16] feat/assistant | 成员对话计划 U6：默认嵌入 bridge、发布门禁与隐私承诺改写

- **起因**：用户确认 U5 后要求继续 U6：按计划第 8 节同步改写承诺与脚本、加入验收矩阵，并按此前说明把 bridge 默认放进构建。
- **构建与发布门禁**：[`build-app.sh`](../scripts/build-app.sh) 删除 `--with-assistant-bridge`，总是构建并嵌入 bridge，开始前检查其 entitlements、Info.plist 与打包脚本。[`verify-app.sh`](../scripts/verify-app.sh) 新增以下检查：
  - bridge 源 entitlements 与审查过的方案 A 集合逐字一致（规范化 JSON）；
  - 正式包恰好两个 XPC service；
  - bridge 包内容只有 Info.plist、可执行文件和签名，标识与类型正确，签名有效，签名后的 entitlements 与源文件一致，只含 arm64；
  - 主 App 不含 `CodexBridge` 等 CLI 运行代码；bridge 含 Codex 适配、不链接 SQLite 存储内核与 DICOM 解码器；
  - 假 CLI 与 XPC 探针没有进入正式包；
  - 成员对话的 IPC、CLI 与 bridge 源码没有任何日志调用；
  - 报告新增 bridge 的标识、可执行文件摘要与 entitlements 摘要。

  [`package-distribution.sh`](../scripts/package-distribution.sh) 用 Developer ID、hardened runtime、时间戳和 bridge 自己的 entitlements 重签 bridge，并逐项核对 Authority、Team ID、时间戳、runtime、标识与 entitlements。[`build-acceptance-app.sh`](../scripts/build-acceptance-app.sh) 复制和重签后都核对 bridge 签名。[`privacy-guard.sh`](../scripts/privacy-guard.sh) 要求 PRIVACY 写明“AI 对话（实验）”“不是匿名化”“发送后无法撤回”，README 写明前两项，并把“不连接互联网或云服务”列为过时的离线声明。
- **承诺改写**：
  - [`PRIVACY.md`](../PRIVACY.md) 首段改为“默认不访问互联网”，指明唯一的外发例外，新增“AI 对话（实验）”一节，说明接收方、发送与不发送的内容、不是匿名化、不可撤回、额度、无工具、只在内存和明文设置。OCR 一条保留原句并注明例外。
  - [`README.md`](../README.md) 新增核心体验条目、边界表一行、使用说明一节，并更新 `verify-app.sh` 说明和目录表。
  - 以下页面同步更新：[`privacy-and-security.md`](privacy-and-security.md)（姿态、威胁模型、代码边界、日志、生命周期、Agent 禁区）、[`project-overview.md`](project-overview.md)、[`architecture.md`](architecture.md)（target 图与 bridge 行）、[`decisions.md`](decisions.md)（新增 2026-10-16 决策与开放门禁）、[`brand.md`](brand.md)、[`localization.md`](localization.md)、[`testing-and-release.md`](testing-and-release.md)、`AGENTS.md` 第 3、4 节、[`index.md`](index.md) 和计划状态。
  - 新增[成员对话验收矩阵](acceptance/member-chat-matrix.md)，[当前候选证据](acceptance/current-release.md)的人工门禁加入成员对话。
- **测试先行**：`AssistantPackagingBoundaryTests` 改为断言默认嵌入，以及四个发布脚本都覆盖 bridge。`ReleaseScriptSafetyTests` 的分发签名夹具加入 bridge，并对它的无效签名、ad-hoc、Team ID、时间戳、runtime、标识与 entitlements 七种错误逐一要求失败。新增隐私门禁测试：删掉任一披露短语或加回离线声明即失败。主清单 1281 tests / 108 suites。
- **验证**（macOS 27.0.1 / Xcode 27.0 / Swift 6.4）：
  - `verify-app.sh` 拒绝未提交的工作树，所以把已跟踪文件和新文件复制到会话临时目录中的一次性 git 仓库并提交，在其上运行 `verify-app.sh --require-clean-source`，退出码 0。正式包含两个 XPC service，报告记录 bridge 标识 `com.kinlogue.mac.assistant-bridge`。在同一副本里给 bridge entitlements 多加一项后，验证器在构建前就以“source entitlements differ”失败。副本随后删除，没有在本仓库提交。
  - 会断言文本的套件通过。完整 `scripts/test.sh` 退出码 0，没有失败，各分片期望数与实测数一致，隔离门禁一并通过，无残留假 CLI 进程。传入实际清单摘要的 `lint.sh` 与 `verify-docs.sh`、`privacy-guard.sh`、`compile-localizations.sh --check` 和 `git diff --check` 通过。工作树未提交，这些结果没有绑定不可变 source ref。
  - PRIVACY 与 README 中“不下诊断、不给用药建议”改写为对模型的要求、不能保证，因为这由提示词约束而不是程序保证。
- **未执行**：
  - 经真实 Codex 的一轮问答与人工矩阵（会消耗额度，需要用户同意）；
  - Developer ID 签名、hardened runtime 下 temporary exception 的表现与 notarization（分发脚本只经假 `codesign` 测试）；
  - macOS 26；
  - `/usr/local` 的真实安装；
  - 安装后合成验收不覆盖成员对话。

## [2026-10-16] feat/assistant | 成员对话：经真实 Codex 的检查，修正沙盒内始终“未登录”

- **起因**：用户提交 U6 后选择先做真实 Codex 检查，并明确同意用合成资料经签名沙盒 bridge 跑完整一轮和约 20 个边界问题；内容会发给 OpenAI 并消耗其额度。
- **工具**：[`KinlogueAssistantXPCProbe`](../Sources/KinlogueAssistantXPCProbe/main.swift) 新增 `ask` 模式，从 stdin 读取说明与输入，并把回答作为 JSON 字符串输出；状态行附上检查所用的模型。上下文包与提示词由一个用完即删的临时测试，经真实导入路径和 App 的 `assistantPack`、`AssistantPrompt` 生成。没有启动 App，也没有打开真实资料库。
- **发现与修正**：第一次状态检查报“未登录”。原因是 App Sandbox 把沙盒 supervisor 自己的 `HOME`、`TMPDIR` 改成了容器路径，supervisor 再把它们传给 Codex，Codex 便在容器里找登录。U2 加入 supervisor 后就有这个问题，U2b 的签名检查允许“未登录”而漏掉了它。修正：[`CLIProcess`](../Sources/KinlogueAssistantCLI/CLIProcess.swift) 以 `KINLOGUE_CLI_ENV_` 前缀把变量交给 supervisor，[`CLISupervisor`](../Sources/KinlogueAssistantCLI/CLISupervisor.swift) 只从带前缀的变量重建 CLI 环境。新测试 `theSupervisorGivesTheCLITheBridgesVariablesNotItsOwn` 在改动前失败、改动后通过。[`verify-assistant-xpc.sh`](../scripts/verify-assistant-xpc.sh) 现在要求：终端里已登录时，沙盒内也报告已登录。
- **结果**：经签名沙盒 bridge、Codex 0.162.0、模型 `gpt-6.1-sol`，21 轮（20 个单轮问题加 1 个带历史的追问）全部得到回答，用时 7.3–14.5 秒，中位数 9.4 秒。回答都守住计划第 3.2 节边界：不下诊断、不给用药建议、不判断好坏、不预测、急症提示立即就医、记录外的信息说明没有、报告里夹带的指令未执行，引用都指向发送过的 R1–R6。三处说明：急症回答附了一般急救要点；被问到和妈妈对比时邀请用户贴出另一人的资料；英文的肝功能总结漏了总胆固醇。运行后 `~/.codex` 与 bridge 容器里没有任何文件含合成内容，没有写入当天会话记录，没有残留进程。逐题记录见[来源笔记](sources/2026-10-16-member-chat-real-codex-check.md)，[验收矩阵](acceptance/member-chat-matrix.md)、[决策](decisions.md)、[品牌](brand.md)、[索引](index.md)、[隐私工程说明](privacy-and-security.md)与[当前候选证据](acceptance/current-release.md)同步。主清单 1282 tests / 108 suites。
- **未执行**：App 界面上的真实对话、未登录与登录过期、未安装、Codex 中途更新、代理与断网、第三方中转、中途停止、一轮进行中删除或恢复资料库、键盘与 VoiceOver、其他模型、npm 或 `/usr/local` 安装、Developer ID 与公证、macOS 26。修正前的检查在 `~/Library/Containers/com.kinlogue.mac.assistant-bridge/Data/.codex` 留下了 Codex 自己的状态库（不含资料内容），可由用户在 Finder 中删除。

## [2026-10-16] feat/assistant | 成员对话计划 U7：保存对话、schema v1→v2 迁移与恢复点逻辑版本 2

- **起因**：用户在真实 Codex 检查之后要求实现 U7。依据计划第 4.9 节、D4、D8，以及用户 2026-10-15 对第一次 schema 迁移的同意。
- **冻结输入**：改 schema 之前，先用迁移前的代码写出一个合成的版本 1 资料库（两位成员、一份已确认报告及其原件、OCR 文档与备注、一份待确认草稿），以 zlib + base64 冻结在 `SQLiteLibraryV1Fixture.swift`（2026-10-18 已删除）。
- **schema 与迁移**：[`SQLiteLibrarySchema`](../Sources/KinloguePlatform/Storage/SQLiteLibrarySchema.swift) 版本 2 在冻结的版本 1 DDL 之后新增 `assistant_conversations`、`assistant_turns`、`assistant_turn_sources`，并为对话数、每成员 200 段、轮次连续与每轮来源数加了结构校验。[`SQLiteLibraryStore`](../Sources/KinloguePlatform/Storage/SQLiteLibraryStore.swift) 的 header 接受版本 1 和 2。普通打开时，版本 1 先按版本 1 完整校验，再在单个事务里建表、写 `user_version = 2`、更新 `library_state` 的 identity 与摘要，提交后按版本 2 校验。`strictExisting` 不迁移。为测试设了四个中断点。初始化回执接受版本 1 的 identity。
- **存储**：新增 [`SQLiteAssistantRows`](../Sources/KinloguePlatform/Storage/SQLiteAssistantRows.swift)，逐行摘要、整段核对、只读摘要列表，提供逐段、按成员和全部删除；报告仓库新增对应方法。删除成员时在同一事务里删除其对话。完整性巡检新增“对话”目标。
- **恢复点**：`BackupLogicalKind` 新增 `assistantConversation`。头部支持版本 1 和 2，writer 写版本 2，可出现的类型与 footer 计数随版本而定。恢复后的严格校验按输入的版本重新编码，因此版本 1 恢复点仍逐字节核对。新增版本 2 冻结流 [`SQLiteLogicalV2Fixture.swift`](../Tests/KinloguePlatformTests/SQLiteLogicalV2Fixture.swift)。两个版本 1 冻结测试改为核对：重新捕获得到相同的记录，只是换成版本 2 头部。
- **App**：
  - `AssistantConversationStoring` 改为可抛错，由 `SQLiteReportRepository` 实现；内存版删除。
  - 服务把一轮和它的保存放在同一个 active operation 里，返回保存后重读的对话。新增读取、删除与“对话数已达上限”。关闭功能只停止进行中的一轮，撤销钩子不写资料库。
  - 对话模型新增历史列表、重新打开与删除。重新打开后仍需确认。显示的对话来自另一个 CLI 或模型时，继续提问开始新对话。
  - 面板新增“历史对话”菜单与删除确认；设置新增“已保存的对话”与“删除全部对话…”；删除成员的确认文案说明对话一并删除。
  - 新增 19 条中英文案，删除 3 条旧文案。
- **测试先行**：
  - 迁移测试 6 项，在隔离的跨进程 storage 目标里：已有行逐行不变、`library_state` 只有 identity 与摘要变化、迁移后可读、再次打开不写入、未知版本与带漂移的版本 1 不改写、四个中断点之后只剩完整版本。真实进程测试中的 4 个强退案例先在 fixture 里阻塞，再被 SIGKILL。
  - [`AssistantConversationStoreTests`](../Tests/KinloguePlatformTests/AssistantConversationStoreTests.swift) 7 项，版本 2 冻结流 1 项，App 4 项。
  - 主清单 1294 tests / 109 suites。
- **验证**（macOS 27.0.1 / Xcode 27.0 / Swift 6.4）：
  - 会断言文本的套件通过。第一次完整 `scripts/test.sh` 发现 `SQLiteLibraryStoreTests` 精确列出 STRICT 表，补上三张新表后，完整 `scripts/test.sh` 退出码 0、没有失败，隔离门禁（含跨进程迁移测试）一并通过，无残留假 CLI 进程。
  - 传入实际清单摘要的 `lint.sh` 与 `verify-docs.sh`、`privacy-guard.sh`、`compile-localizations.sh --check` 与 `git diff --check` 通过。
  - 没有重跑 `verify-app.sh`：这次没有改动打包与 entitlement。
  - 工作树未提交，这些结果没有绑定不可变 source ref。
- **未执行**：真实资料库上的迁移（用户的资料库是版本 1，第一次运行包含 U7 的构建时会自动迁移，之后更早的构建无法打开它）；App 界面上保存、重新打开与删除对话的人工检查；带对话的恢复点经加密容器的端到端恢复（对话只在逻辑流层面测试；已有的加密恢复测试现在写版本 2，但其中没有对话）。
- **说明**：
  - 迁移后的冻结库做完整性巡检时，两个原件被标为损坏，因为冻结行记录的是生成机器上的 inode。测试只接受这一种情况，其余行都要通过巡检。
  - 迁移只建空表，没有单独的“正在升级”启动页，也不自动备份。这一点和决策记录写在 [`decisions.md`](decisions.md) 2026-10-16 一节。
- **文档**：PRIVACY 与 README 说明对话以明文保存在资料库并进入恢复点、可删除、随成员删除、关闭功能不删除；[`privacy-and-security.md`](privacy-and-security.md)、[`project-overview.md`](project-overview.md)、[`architecture.md`](architecture.md)、[`sqlite-storage.md`](sqlite-storage.md)、[`storage.md`](storage.md)、[`backup-and-restore.md`](backup-and-restore.md)、[`domain-and-data-model.md`](domain-and-data-model.md)、[`design-system.md`](design-system.md)、[`decisions.md`](decisions.md)、[`index.md`](index.md)、`AGENTS.md`、计划状态、[成员对话矩阵](acceptance/member-chat-matrix.md)和[当前候选证据](acceptance/current-release.md)同步。

## [2026-10-16] fix/assistant | 成员对话面板在分栏详情列中溢出、输入法组字被提示文字盖住、全文展开文字点击无效

- **现象**：
  - 在 App 里打开对话后，面板整体上移，标题区和输入框（或确认卡片）在窗口之外，无法输入。
  - 修正上一条后复测：用拼音输入时，灰色提示“就已确认的报告提问”留在组字文本之上。
  - 确认页“查看将发送的报告全文”只有左侧小箭头可点，点文字无效。
- **原因**：
  - 详情列没有宽度约束，分栏视图计算它的最小尺寸时按接近零的宽度测量。[`AssistantPanelView`](../Sources/KinlogueApp/Views/AssistantPanelView.swift) 在对话记录之外有几段固定高度的换行文本（发送范围、确认说明、问题提示），在这个宽度下逐字换行，使窗口的最小高度升到约 1160–1960pt。
  - 输入法未提交的组字文本不进入 `draft`，提示文字只在 `draft` 为空时显示，于是组字期间仍然显示。
  - macOS 的 `DisclosureGroup` 标签本身不响应点击，只有展开箭头响应。
- **修正**：
  - 面板根视图设最小宽度 360pt 并填满详情列；标题区的成员名优先占用剩余宽度，“新对话”按钮保持自身尺寸，不再被压成竖排。
  - 提示文字只在输入框为空且没有焦点时显示；[`AssistantViewSafetyTests`](../Tests/KinlogueAppTests/AssistantViewSafetyTests.swift) 增加对应的源码检查，先失败后通过。
  - [`AssistantConsentSheet`](../Sources/KinlogueApp/Views/AssistantConsentSheet.swift) 的展开标签改为切换同一展开状态的按钮（`kinlogueGhost` 样式，28pt 高），保留系统展开箭头；同一测试增加源码检查，先失败后通过。
- **验证**：
  - 临时离屏测试按 App 的列宽在 1000×745 与 920×620 的带标题栏窗口中放入面板，需确认与可输入两种状态的窗口高度都保持不变；最小高度 672pt，与只放普通详情内容时相同。截图确认标题区、示例问题和输入框都在窗口内。另一个临时离屏测试在输入框上设置组字文本（`setMarkedText`），截图确认组字时不再有提示文字，失焦且为空时提示恢复。第三个临时测试向确认页发送真实鼠标事件点击文字，截图确认全文展开。三个临时测试均已删除。
  - 对话、主题与本地化相关套件 157 tests 通过；`lint.sh` 与 `git diff --check` 通过；`build-app.sh` 重新构建并签名。
  - 用户用 16:05 的构建在 App 中复测：面板完整显示，点击输入框后拼音组字不再被提示盖住，点击“查看将发送的报告全文”能展开全文。
- **未执行**：完整 `scripts/test.sh`；`verify-app.sh`（打包与 entitlement 未改动）。

## [2026-10-16] fix/assistant | 问题输入框改用带内边距的原生编辑器，输入法组字不再被遮住或清空

- **现象**：上一条修正提交后复测，问题输入框里的中文仍像被遮住。
- **原因**：
  - 输入框仍是 SwiftUI `TextEditor`，首行紧贴可见区域上沿，输入中文时字形上部被遮住。记录编辑页 2026-08-10 修过同一问题，改用 [`InsetTextEditor`](../Sources/KinlogueApp/Views/RecordEditView.swift)。
  - 改用 `InsetTextEditor` 后又发现：它在每次界面更新时，只要原生文本与 binding 不同就用 binding 覆盖原生文本，而输入法未提交的组字文本只在原生文本里，于是组字中任何一次界面更新都会清空组字。记录编辑页同样受影响。
- **修正**：
  - [`AssistantPanelView`](../Sources/KinlogueApp/Views/AssistantPanelView.swift) 的问题输入框改用 `InsetTextEditor`（8pt 内边距，外框高 88pt，文字位置不变），无障碍标签与提示改由原生文本视图提供。
  - `InsetTextEditor` 增加可选的 `isComposing`，由原生文本视图的 `hasMarkedText()` 在文本或选区变化时更新；组字期间不再用 binding 覆盖原生文本。提示文字只在 `draft` 为空且不在组字时显示，取代上一条按焦点隐藏的做法：获得焦点但为空时仍显示提示。
- **测试先行**：
  - 新增 [`AssistantPanelLayoutTests`](../Tests/KinlogueAppTests/AssistantPanelLayoutTests.swift) 1 项：真实 `NSHostingView` 中输入框首个字形距可见区域上沿至少 8pt；旧实现按预期失败。
  - [`RecordEditViewLayoutTests`](../Tests/KinlogueAppTests/RecordEditViewLayoutTests.swift) 新增 1 项：组字开始、提交、再组字、放弃时 `isComposing` 的变化，以及组字引起的界面更新不清空组字文本；先因缺少参数无法编译，加参数后因组字被清空而失败，修正后通过。
  - [`AssistantViewSafetyTests`](../Tests/KinlogueAppTests/AssistantViewSafetyTests.swift) 的源码检查改为要求 `InsetTextEditor` 与组字条件。
  - 主清单 1296 tests / 110 suites（`primary-test-shards.rb --inventory-summary` 核对）。
- **验证**：临时离屏测试在面板输入框中设置组字文本，截图确认组字完整显示、提示隐藏，已提交文字后再组字正常，获得焦点且为空时提示仍在；临时测试已删除。会断言源码与文本的套件、对话与布局套件共 324 tests 通过；带实际清单摘要的 `lint.sh` 与 `verify-docs.sh`、`git diff --check` 通过；`build-app.sh` 重新构建并签名。
  - 用户 2026-10-17 用 17:40 的构建在 App 中复测问题输入框的拼音输入，结果正常。
- **未执行**：完整 `scripts/test.sh`；`verify-app.sh`；记录编辑页的人工输入法检查（未单独确认）。

## [2026-10-17] verify/assistant | 成员对话分支在 `501e56f` 上完整跑一遍自动化门禁

- **环境**：macOS 27.0.1、Xcode 27.1（27A9275，当天凌晨自动更新，前几天的记录为 27.0）、Swift 6.4。
- **先遇到的问题**：更新后第一次完整 `scripts/test.sh` 在构建阶段就停止，没有执行任何测试：DICOM-Swift 的 `WindowingShaders.metal` 需要 Metal Toolchain，`xcrun metal` 报告缺少工具链，在沙盒外运行结果相同，`xcodebuild -showComponent` 却显示已安装。经用户同意运行 `xcodebuild -downloadComponent MetalToolchain` 重新下载（27A266a）后恢复。这是本机工具链状态，与仓库代码无关。
- **结果**（工作树干净，HEAD `501e56f`）：
  - 完整 `scripts/test.sh` 退出码 0，用时约 10 分钟，没有失败；72 次分片与隔离门禁运行共执行 1336 项测试，主清单 1296 tests / 110 suites（`primary-test-shards.rb --inventory-summary` 核对）。
  - `scripts/verify-app.sh --require-clean-source` 通过，验证报告绑定 `501e56f`；本机 ad-hoc 签名，Developer ID 与公证未执行。
  - `scripts/verify-assistant-xpc.sh` 通过：能力检查对本机回环替身运行，不消耗额度；假 CLI 回答、取消与强杀 bridge 后没有残留进程。
  - 带实际清单摘要的 `lint.sh` 与 `verify-docs.sh`、`privacy-guard.sh`、`compile-localizations.sh --check`、`git diff --check` 通过。
- **未执行**：Developer ID 签名与公证；macOS 26 机器；键盘、VoiceOver 与错误情形的人工检查；记录编辑页的人工输入法检查。这条日志本身未提交时，上述结果对应的是 `501e56f`，不是包含本条日志的提交。

## [2026-10-17] feat/assistant | 成员对话可以从本机 Codex 的模型列表中选择模型

- **需求**：用户反馈“无法选择模型”。此前设置页只有自由填写的模型文本框，面板只显示当前模型。用户选择在设置页和对话面板都提供选择，二者改的是同一个设置。
- **依据**：bridge 的状态检查本来就运行 `codex debug models` 取默认模型。本机 Codex 的模型缓存显示每个模型有 `slug`、`display_name`、`visibility`（list / hide）与 `priority`；只读查看了字段名和公开的模型名，没有读取账号信息。
- **实现**：
  - [`CodexModelCatalog.choices`](../Sources/KinlogueAssistantCLI/CodexInvocation.swift) 从同一份输出取出 `visibility` 为 list（或未给出）的模型，按 `priority`、再按目录顺序排列，最多 32 个；slug 必须是 token，显示名不安全时退回 slug。
  - [`KinlogueAssistantStatus`](../Sources/KinlogueAssistantIPC/AssistantIPC.swift) 新增 `defaultModel` 与 `models`（slug 与显示名），编码前校验数量、唯一性、token 与有界显示名。[`CodexBridge`](../Sources/KinlogueAssistantCLI/CodexBridge.swift) 每次状态检查都附上列表，成功的列表按可执行文件缓存，发送前的状态检查不再多跑一次进程；默认模型仍是目录中第一个 token slug，与之前一致。
  - [`AssistantSettingsSection`](../Sources/KinlogueApp/Views/AssistantSettingsSection.swift) 有列表时用下拉菜单（“Codex 默认（名称）”、Codex 列出的模型、已保存但不在列表中的模型），没有列表时回退为文本框；状态行显示模型的显示名。
  - [`AssistantPanelView`](../Sources/KinlogueApp/Views/AssistantPanelView.swift) 头部的接收方一行成为同样的菜单，经 [`AssistantSettingsModel.selectModel`](../Sources/KinlogueApp/ViewModels/AssistantSettingsModel.swift) 立即保存模型，保留设置页其他未保存的草稿；打开的对话随之重新检查并要求重新确认，发送中菜单不可用。
  - 新增 4 条中英文案；README、项目概览、隐私与安全、设计系统第 27 条（同时把过时的 `TextEditor` 改为 `InsetTextEditor`）和成员对话矩阵同步。
- **测试**：Platform 新增 2 项（列表解析：隐藏、排序、去重、不安全 slug 与显示名、上限；状态 IPC 拒绝不安全的列表），假 CLI 目录加入一个可见、一个隐藏模型，provider 测试核对两种检查下都带同一列表与默认模型；App 新增 2 项（菜单项与中英文案；从面板选择后保存、保留其他草稿、对话要求重新确认、拒绝不合法名称），视图源码检查增加菜单经设置模型保存且发送中不可用。主清单 1300 tests / 110 suites。App 两项先因缺少 `selectModel` 无法编译；Platform 测试与实现在同一步写成，没有单独记录失败的运行。
- **真实环境门禁**：[`verify-assistant-xpc.sh`](../scripts/verify-assistant-xpc.sh) 的探针输出增加列表数量与默认模型；终端里已登录时，要求沙盒内的本机 Codex 列出至少一个模型并给出默认模型，假 CLI 一侧要求恰好列出 2 个（隐藏的不列出）。[`AssistantPackagingBoundaryTests`](../Tests/KinlogueAppTests/AssistantPackagingBoundaryTests.swift) 先要求脚本包含这项检查并按预期失败，补上后通过。
- **验证**（macOS 27.0.1 / Xcode 27.1 / Swift 6.4，工作树未提交）：
  - 临时离屏测试渲染设置页下拉菜单和面板菜单，以及从面板选择后设置页显示新模型、面板回到“发送前请确认”；临时测试已删除。
  - 完整 `scripts/test.sh` 退出码 0，没有失败（72 次运行共 1340 项测试）；此后只改了探针输出、验证脚本和对应的源码文本检查，相关套件重跑通过。
  - `verify-assistant-xpc.sh` 通过，包括本机真实 Codex 在签名沙盒 bridge 中列出模型（只运行 `codex debug models` 与本机模拟服务，不耗额度，不发送资料）。
  - 带实际清单摘要的 `lint.sh` 与 `verify-docs.sh`、`privacy-guard.sh`、`compile-localizations.sh --check`、`git diff --check` 通过；`build-app.sh` 重新构建并签名。
- **未执行**：VoiceOver 读菜单。在 App 中用真实 Codex 选择模型的复测见下一条。

## [2026-10-17] fix/assistant | 切换模型不再重新加载对话面板

- **现象**：用户复测模型选择时反馈，切换模型会把会话重新刷新加载。
- **原因**：设置保存后 [`AssistantConversationModel.settingsChanged`](../Sources/KinlogueApp/ViewModels/AssistantConversationModel.swift) 总是重新走一遍 `open`：清空状态、显示“正在准备对话…”，再重读上下文包、历史和最新一段对话，屏幕上正在看的旧对话或刚开始的新对话被替换；即使接收方没变，同意也被丢掉。
- **修正**：对话界面正在显示（已就绪或待确认）且上下文包已读取时，设置变化只重新检查接收方：上下文包、历史、显示中的对话和输入框都保留；新接收方与已同意的相同（同一 CLI 版本、模型与上下文包）时保留同意，否则提示 `consentRequired` 并要求重新确认；检查失败时显示对应问题。检查期间 `isCheckingCLI` 为真，确认、发送和模型菜单都不可用，接收方一行旁显示小进度指示，避免把同意给到旧接收方；较早的检查结果被丢弃。关闭功能、不可用状态和发送中的设置变化仍按原流程处理。
- **测试先行**：[`AssistantConversationModelTests`](../Tests/KinlogueAppTests/AssistantConversationModelTests.swift) 新增 1 项：显示历史中的旧对话时切换模型，对话、历史与上下文包不变，要求重新确认，确认后下一问开始新对话；显式选择与默认相同的模型时同意保留。旧实现按预期失败 3 处。视图源码检查改为要求确认页与面板在检查期间不可用。主清单 1301 tests / 110 suites。
- **验证**：临时离屏测试渲染发送一轮后切换模型的面板，对话保留、头部显示新模型、Warning 与确认 Card 出现；临时测试已删除。对话与会断言源码与文本的套件共 329 tests 通过；带实际清单摘要的 `lint.sh` 与 `verify-docs.sh`、`privacy-guard.sh`、`compile-localizations.sh --check`、`git diff --check` 通过；`build-app.sh` 重新构建并签名。
  - 用户用 22:50 的构建在 App 中用真实 Codex 复测：在设置页与面板选择模型、切换后面板不重新加载，结果正常。
- **未执行**：本次改动只在 App 层，没有重跑完整 `scripts/test.sh` 与 `verify-assistant-xpc.sh`（上一条记录的两项在本次改动前通过）。

## [2026-10-18] plan/assistant | 提议：成员对话的分层上下文包

- **起因**：用户问发送内容能否加入影像信息。核实后，影像检查在库里只有确认日期、序列与对象数量，检查类型只能是 MR（或仅保留文档），部位没有保存。用户随后提出先把成员全部检查文字整理聚合成初始上下文，认为“最新 20 份”过于绝对。
- **依据**：20 份 / 60,000 字节来自 U0 探针的规模（20 份约 92 KB、约 2.5 万输入 token、17 秒），原计划承诺的“预览里增删报告”没有界面；已确认结果的表格行按制表符分格，可由 [`ReportedResultLine`](../Sources/KinlogueCore/Domain/ReportedResultLine.swift) 原样拆分；每轮来源上限与 20 份绑定（[`AssistantConversation.swift`](../Sources/KinlogueCore/Assistant/AssistantConversation.swift)）；继续已保存对话时只比较接收方，不比较提示词版本。
- **产出**：[分层上下文包计划](plans/2026-10-18-feat-member-chat-layered-context-plan.md)（`status: proposed`）：本机确定性聚合，不用模型写总结；目录、结论与标记项、只合并同名项目的检验汇总、预算内的最新全文，总预算约 100 KB 并给出各层子上限；提示词 v2 全文；指纹 v2；确认页逐层列出；只保存被引用的来源；提示词版本不同的对话继续提问时开始新对话。原计划第 4.4 节和计划目录已链接。
- **未执行**：没有改代码；等待用户审阅第 10 节的问题后再实施。

## [2026-10-18] feat/storage | 资料库 schema 版本 3、首发前不做原地迁移（分层上下文包 L0）

- **起因**：用户审阅[分层上下文包计划](plans/2026-10-18-feat-member-chat-layered-context-plan.md)后确定其余四项（预算按第 4 节、目录 300 份、改任意报告都要重新确认、结论层覆盖全部报告、保留与全文的重复）。开始 L1 前核对发现，schema 版本 2 的 `assistant_turn_sources` 写死 `CHECK(position < 20)`，校验也按 20 计；计划第 8 节“schema 不变”的说法是错的。用户选择现在升到版本 3。
- **过程**：先实现了原地迁移：版本 1 直接迁到 3，版本 2 只重建来源表。为此用迁移前的代码冻结了一个版本 2 资料库，写了 11 项迁移测试（含真实进程强退），完整 `scripts/test.sh` 通过（1347 项执行，无失败）。随后用户提出 App 还没发布、可以去掉迁移逻辑，选择只认当前版本、经恢复点升级。原地迁移连同 2026-10-16 的 v1→v2 迁移一并删除（决策见 [`decisions.md`](decisions.md) 2026-10-18，2026-10-16 条已标为被取代）。
- **最终实现**：
  - [`AssistantLimits.maxTurnSources`](../Sources/KinlogueCore/Assistant/AssistantLimits.swift) 为 300，`AssistantTurn` 按它校验；`maxPackRecords` 仍是 20，留给 L1。
  - [`SQLiteLibrarySchema`](../Sources/KinloguePlatform/Storage/SQLiteLibrarySchema.swift) 只有当前版本 3（来源表每轮 300），去掉冻结的旧 DDL、按版本的校验、迁移函数与迁移故障点；[`SQLiteLibraryStore`](../Sources/KinloguePlatform/Storage/SQLiteLibraryStore.swift) 的文件头预检与打开流程回到只认当前版本，`SQLiteLibraryState` 去掉按 identity 的辅助方法；初始化收据只接受当前 identity；存储跨进程夹具去掉迁移挂起操作。
  - 恢复点逻辑流升到版本 3，reader 接受版本 1 至 3；[`SQLiteLogicalRestore`](../Sources/KinloguePlatform/Backup/SQLiteLogicalRestore.swift) 按 [`BackupLogicalHeaderV1.maximumTurnSources(forVersion:)`](../Sources/KinlogueCore/Backup/BackupLogicalV1.swift) 拒绝版本 2 流里超过 20 个来源的轮次。
  - 删除 U7 的版本 1 资料库夹具与迁移测试，以及本次的版本 2 资料库夹具与迁移测试。
- **测试先行**：
  - [`SQLiteLibraryStoreTests`](../Tests/KinloguePlatformTests/SQLiteLibraryStoreTests.swift) 新增：版本 1、2 和更新的版本都以“格式不受支持”被拒且字节不变；在仍带迁移的代码上，版本 1、2 按预期失败（进入迁移校验后报“损坏”）。
  - [`AssistantConversationStoreTests`](../Tests/KinloguePlatformTests/AssistantConversationStoreTests.swift) 新增各版本流的来源上限（版本 2 的 21 个被拒，20 个与版本 3 的 21、300 个可以恢复）；冻结的版本 1、版本 2 流照常恢复并以版本 3 重新写出同样的记录；Core 来源上限测试改为 300。
  - 主清单 1303 tests / 110 suites；隔离的 storage 目标 17 tests / 1 suite。
- **验证**（macOS 27.0.1 / Xcode 27.1 / Swift 6.4，工作树未提交）：去掉迁移后完整 `scripts/test.sh` 退出码 0，没有失败（72 次运行共 1337 项测试）；带实际清单摘要的 `lint.sh` 与 `verify-docs.sh`、`privacy-guard.sh`、`compile-localizations.sh --check`、`git diff --check` 通过。旧日志里指向已删除夹具的一处链接改为代码名并注明已删除，措辞未改。
- **未执行**：`verify-app.sh`（工作树未提交）；用户真实资料库（版本 2）需要先用当前构建做恢复点，再在新构建中恢复，之后更早的构建无法打开它。

## [2026-10-18] feat/assistant | 分层上下文包 L1–L4：本机聚合全部已确认报告、提示词 v2、只保存被引用的来源

- **依据**：[分层上下文包计划](plans/2026-10-18-feat-member-chat-layered-context-plan.md)（用户 2026-10-18 审阅确定）与已提交的 L0（schema 版本 3）。
- **L1 Core**：
  - [`AssistantContextPackBuilder`](../Sources/KinlogueCore/Assistant/AssistantContextPack.swift) 按四层构建：目录（最多 300 份、16 KB）、结论与标记项（24 KB，每份 600 字节）、按完全相同的项目名汇总的表格行（30 KB，先保证每个项目的最新一行，再按新到旧补充）、剩余预算内最新报告的标题与完整结果（每份 12 KB），合计不超过 100,000 字节。每层有溢出说明；编号按时间从旧到新，新增报告不改变已有编号。
  - [`AssistantLimits`](../Sources/KinlogueCore/Assistant/AssistantLimits.swift) 新增各层子上限，`maxPackRecords` 由 20 改为 300、`maxPackBytes` 由 60,000 改为 100,000。
  - 同意指纹升为 `consent.v2`，绑定包结构版本、每份目录内报告的编号与 revision 和完整渲染文本；投影摘要不变，旧回答的引用状态照旧判断。
  - [`AssistantPrompt`](../Sources/KinlogueCore/Assistant/AssistantPrompt.swift) 升到版本 2，说明四个部分只是原文的重排、同名才合并、没有全文时如何说明；转义加入四个新标签。
  - `AssistantConversation.continues(with:promptVersion:)`：提示词版本不同的已保存对话继续提问时开始新对话，面板说明“这段对话来自较早版本的续页”。
- **L2 Platform**：[`assistantPack`](../Sources/KinloguePlatform/Assistant/AssistantLibrary.swift) 按新的上限读取最新的最多 300 份并统计总数。
- **L3 App**：确认页“会发送”逐层列出数量并说明未列入的部分，折叠区改名“查看将发送的全部内容”；面板发送范围显示全文份数；[`LiveAssistantService`](../Sources/KinlogueApp/App/AssistantService.swift) 每轮只保存回答引用的来源。新增 12 条中英文案（含单复数），删除 2 条不再使用的文案。
- **测试先行**：Core 包测试改写并新增 6 项（目录与上限、编号稳定、结论层覆盖与溢出、同名汇总、每项最新行、全文预算不跳过），Core 续写规则 1 项，Platform 读取上限 1 项，App 2 项（较早提示词版本不续写、逐层文案）；服务测试改为只保存被引用的来源。先因缺少新字段无法编译，实现后通过。主清单 1313 tests / 110 suites。
- **L4 测量**（合成数据，见计划第 4 节）：200 份报告、原文约 204 KB，包 99,696 字节、构建 58 ms；目录 10.2 KB，结论 127 份全部列入 22.4 KB，检验汇总 40 项、2,896 行中最新 641 行 28.7 KB，全文最新 38 份 35.9 KB。检验单多时汇总层是瓶颈。
- **离屏核对**：临时测试渲染 9 份合成报告的确认页与面板：逐层列出、无结论时不显示该行、面板显示“9 份报告 · 全文 9 份”；临时测试已删除。
- **验证**（macOS 27.0.1 / Xcode 27.1 / Swift 6.4，工作树未提交）：完整 `scripts/test.sh` 退出码 0，没有失败；带实际清单摘要的 `lint.sh` 与 `verify-docs.sh`、`privacy-guard.sh`、`compile-localizations.sh --check`、`git diff --check` 通过。
- **未执行**：经真实 Codex 的延迟与 token 测量（需要用户另行同意、消耗额度）；`verify-app.sh`（工作树未提交）；App 内人工检查（用户的真实资料库需先经恢复点升到 schema 版本 3）。

## [2026-10-19] verify/assistant | 在 `dc50a2b` 上跑打包与签名 bridge 门禁

- **范围**：分层上下文包 L1–L4 提交后，工作树干净，HEAD `dc50a2b`；macOS 27.0.1 / Xcode 27.1 / Swift 6.4。完整 `scripts/test.sh` 与 lint、文档、隐私、本地化门禁已在同一份代码上通过（见 2026-10-18 的 L1–L4 条）。
- **`scripts/verify-app.sh --require-clean-source`**：通过，验证报告绑定 `dc50a2b`；本机 ad-hoc 签名，Developer ID 与公证未执行。
- **`scripts/verify-assistant-xpc.sh`**：通过，11 项全部通过，包括本机 Codex 在签名沙盒 bridge 中通过能力检查、找到登录并列出模型与默认模型（只连本机模拟服务、不耗额度、不发送资料），以及取消与强杀 bridge 后没有残留进程。
- **未执行**：经真实 Codex 的分层上下文包延迟与 token 测量；成员对话矩阵中的人工检查（未登录、未安装、代理与断网、键盘与 VoiceOver）；macOS 26 机器。本分支尚未合入 `main`，资料库已是 schema 版本 3 时，`main` 的构建会以“格式不受支持”拒绝它。

## [2026-10-20] fix/ci | PR #25 在 Xcode 26.6 上编译失败：组字状态的辅助方法缺少主线程标注

- **现象**：PR #25 的 “Lint and test” 在 CI（`macos-26` runner，Xcode 26.6 / Swift 6.3.3）编译失败：[`RecordEditView`](../Sources/KinlogueApp/Views/RecordEditView.swift) 中 `InsetTextEditor.Coordinator.reportComposition(of:)` 调用了主线程隔离的 `hasMarkedText()`。本机 Xcode 27.1 能编译。
- **原因**：Xcode 27.1 的 SDK 让遵循 `NSTextViewDelegate` 的整个 coordinator 推断为主线程隔离；Xcode 26.6 只给协议里的回调这样推断，私有辅助方法因此是非隔离的。
- **修正**：给只从委托回调调用的 `reportComposition(of:)` 显式加 `@MainActor`。本机只有 Xcode 27.1，无法复现 26.6 的编译，以 CI 的结果为准；本机编辑器相关测试 14 项、`lint.sh` 与 `git diff --check` 通过。

## [2026-10-20] fix/ci | PR #25 的历史隐私门禁拒绝了测试里带登录信息的代理 URL

- **现象**：PR #25 的 “Lint and test” 在 “Enforce privacy disclosures and fixture policy” 一步失败：`scripts/privacy-history-guard.sh --ref HEAD` 报告可达历史中有私钥或常见凭据模式。本机在分支上复现失败，在 `origin/main` 上通过。
- **原因**：[`AssistantSettingsModelTests`](../Tests/KinlogueAppTests/AssistantSettingsModelTests.swift) 用一个带用户名和密码的合成本机代理 URL 检查“代理不得带登录信息”，命中门禁的“URL 内嵌登录信息”规则。它自 `3b49ecd` 起存在于两个版本的测试文件中，只改当前文件无法让历史扫描通过。
- **修正**：测试改用只带用户名的本机代理 URL，模型仍由同一条检查（用户名或密码任一存在即拒绝）判为 `proxyCredentials`；没有改动门禁。经用户同意，用 `git filter-branch --index-filter` 只替换分支上（`origin/main..HEAD`）这两个版本的测试文件，提交说明、作者与时间不变，旧分支顶端为 `41ddc20`，之后以 `--force-with-lease` 推送。
- **验证**：重写后的分支上 `privacy-history-guard.sh --ref HEAD` 与 `privacy-guard.sh` 通过，`AssistantSettingsModelTests` 5 项通过；重写前后分支顶端的差异只有这一行。`origin/main` 没有分支外的提交，CI 合并提交的树与分支顶端一致。
- **仍需处理**：本机分支 `claude/member-chat-imaging-layer` 与 `claude/lan-restore-date-fix` 基于重写前的提交，推送前需要变基到新的分支顶端，否则会在同一门禁失败。
