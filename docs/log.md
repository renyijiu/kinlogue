# Project Knowledge Log

本文件是项目知识库的追加式日志。每个条目记录一次可复核的 ingest、query、lint 或重大文档维护；不要改写历史条目来伪造当前状态。最新状态以专题页和代码/测试为准。

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
