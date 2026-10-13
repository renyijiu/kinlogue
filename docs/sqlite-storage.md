# SQLite 存储内核（开发中）

本分支按 [重构计划](plans/2026-10-10-2322-refactor-sqlite-architecture-plan.md) 把资料库改为 SQLite 数据库加原件目录，这是仓库里唯一的存储实现：[`KinlogueApp`](../Sources/KinlogueApp/App/KinlogueApp.swift) 只通过 `LibraryLaunchCoordinator.makeDefault()` 和 [启动页](../Sources/KinlogueApp/Views/SQLiteAppLaunchView.swift) 取得资料库。本页描述内核、报告/OCR、LAN、规范化 DICOM、逻辑备份/恢复与原件导出的数据库链路。界面入口、App 的生产组装、安装验收的各阶段、测试和跨进程 fixture 都运行在这个资料库上；早先的 JSON 清单实现已于 2026-10-13 删除。迁移后的安装验收只在进程内测试中跑过，`run-acceptance.sh` 还没有在安装后的 App 上重跑；macOS 26 和人工门禁未执行，见 [当前验收账本](acceptance/current-release.md)。

## 连接与单实例

[SQLiteLibraryStore](../Sources/KinloguePlatform/Storage/SQLiteLibraryStore.swift) 使用 GRDB 7.11.1 的单个 `DatabaseQueue`，锁文件位于资料库外、采用复用的 canonical/case-alias 路径规则。`flock(LOCK_EX | LOCK_NB)` 在打开数据库前拒绝第二 owner；数据库关闭用于整库替换时继续持锁，完整关闭或进程退出才释放。锁只用 `flock`：它属于打开的文件描述，不会像进程级的 `fcntl` 锁那样因为同一进程关闭了该文件的另一个 descriptor 而被解除。锁路径被换成符号链接或非普通文件时拒绝使用。

配置为 DELETE journal、EXTRA 同步、fullfsync、外键检查、关闭 trusted schema、defensive 和禁用扩展加载。小型 [C shim](../Sources/KinlogueSQLiteConfiguration/KinlogueSQLiteConfiguration.c) 只适配 Swift 不能安全直接调用的 `sqlite3_db_config` 可变参数；不重新实现 SQLite 绑定。支持扩展的 engine 要求配置成功且回读关闭；编译为 `OMIT_LOAD_EXTENSION` 的 engine 显式验证该选项。来源、许可、privacy bundle 和 engine 点时证据见 [依赖核查](sources/2026-10-11-grdb-engine-review.md)。

### 阻塞调用所在的线程

内核是同步的：一次调用要等 admission 锁、等 SQLite、等文件 I/O。Swift 并发线程池每核只有一个线程，几个这样的等待就能把它占满，届时全进程的异步任务一起停顿；长时间持有 admission 的操作（例如备份捕获）会把这种情况变成现实。因此存储层的每个异步入口（仓库、查询、LAN、DICOM、备份和导出中所有标注 `@concurrent` 的函数）先经 [LibraryStorageExecutor](../Sources/KinloguePlatform/Storage/LibraryStorageExecutor.swift) 把任务移到一组允许阻塞的专用线程；本身会等存储的 actor（`SQLiteReportRepository`、`LANUploadSink`、`DICOMSliceService`、`DICOMSliceCache`）各用一条自己的串行队列；备份、恢复激活、启动时的恢复收敛和原件导出在任务根部切换。内核的同步 API 没有改成异步，直接调用它的代码仍会阻塞调用线程，目前这样做的只有测试和进程 fixture。

[回归](../Tests/KinloguePlatformTests/LibraryStorageExecutorTests.swift) 在 admission 被持有期间启动数倍于线程池宽度的读取，要求线程池上的其他任务照常运行；用调试构建里的观察点确认仓库调用、巡检以及 LAN 上传的完成和取消都不在线程池线程上取 admission；另有一项源码检查要求每个 `@concurrent` 入口都经过该执行器。观察点依据 libdispatch 给线程池线程的队列标签判断，测试先用一个普通任务确认这个判断有效。

## 格式与完整性

[DDL](../Sources/KinloguePlatform/Storage/SQLiteLibrarySchema.swift) 目前包括 18 个 STRICT 表：`library_state`、`members`、`originals`、`ocr_documents`、`reports`、`report_details`、`report_search`、`import_drafts`、`report_sources`、`inbox_items`、`inbox_content_terminals`、`inbox_transport_receipts`、`inbox_uploads`、`inbox_archive_receipts`、`dicom_studies`、`dicom_objects`、`dicom_series`、`dicom_instances`。UUID 使用 16 bytes，摘要 32 bytes，引用、顺序与领域边界由 FK、UNIQUE、CHECK 和后续语义 codec 共同约束。OCR 文档已由报告仓库存入独立表，DICOM 层级保留关系表；LAN 与 DICOM 业务 codec 已接通并由 App 使用。报告日期使用 REAL 保存领域 Date 的持久化精度，避免整数秒截断。

打开已有文件前只读核对 SQLite header、`application_id=0x4B4C4753`、`user_version=1` 和 DELETE 格式；未知库不自动迁移、改写或删除。打开后验证精确 schema、`quick_check`、外键和 `library_state` 的内容摘要。首次创建使用绑定 root inode/schema 的 [初始化 receipt](../Sources/KinloguePlatform/Storage/SQLiteLibraryInitialization.swift)，只恢复本次创建拥有的目录和库；未知文件保持原样。

目前已经实现 `library_state`、`originals` 及报告域（成员、报告/详情/搜索投影、草稿、来源、OCR）的版本化、字段类型/长度分隔语义摘要。报告/草稿绑定来源数量与摘要、文档摘要；详情读取复核热投影、完整搜索字段和来源关系。LAN 行、上传归属与归档回执已有字段分隔语义摘要；DICOM codec 校验层级行、计数、集合摘要、图闭合与几何顺序；不能把 SQLite `quick_check` 当成语义验证的替代。SHA-256 只发现意外损坏，不提供认证、防篡改或防回滚。

## 原件事务与恢复

[SQLiteOriginalLifecycle](../Sources/KinloguePlatform/Storage/SQLiteOriginalLifecycle.swift) 先登记 staged ownership，再通过 no-follow descriptor 写入、hash 和同步；排他 rename 后同一数据库事务发布 live 状态和领域引用。报告/草稿删除在移除最后一条领域引用的同一事务中登记 deleting；已有 pin 可继续消费，新的 pin 被拒绝，最后一个 pin/活动操作退出或重启恢复后才回收已验证 inode 的文件。显式 `deleteOriginal` 仍拒绝被 pin 的原件。重启只处理 staged/deleting，不哈希全部 live 原件；无法证明所有权的文件保留并报告，不按文件名猜测删除。

原件复制和发布校验按 original ID 登记活动操作，释放 admission 后执行长字节 I/O；返回或提交前重新核对根、行摘要、operation/lifecycle、路径身份和取消。活动操作期间，其他记录的数据库读写可以继续，同一原件的竞争修改和资料库关闭/替换返回 `originalBusy`；恢复跳过活动 ID，所有退出路径在关闭 descriptor 后释放登记。

本机导入的字节已在内存中，[报告仓库](../Sources/KinloguePlatform/Storage/SQLiteReportRepository.swift)直接把它们写入 staged 原件并在写入时计算摘要，不再先落一份临时文件；从 descriptor 复制的入口目前只有测试和进程 fixture 使用。两条入口共用登记、同步、回读校验和提交前复核。

stage、报告/LAN 发布与 DICOM 发布共用原件 stat snapshot：既有完整哈希返回 device/inode/长度/纳秒 mtime/ctime，rename 前核对完整 token，rename 后只允许该操作改变 ctime，最终提交前再次核对命名文件。pin 消费前后比较同一 token，能拒绝过程中改写后又恢复原字节的情况；没有增加完整哈希次数。

运行期失败或完成清理按确切 operation ID 选择非 live 原件；DICOM 收尾不扫描其他报告的 staged→publish 间隙。活动、被 pin、被引用或未知 inode 保留并返回未回收 ID，调用方不能把未回收当成功。仅启动恢复使用全库扫描。

pin 固定 descriptor 和文件身份，不在快照捕获时读取全部原件。实际 `withVerifiedDescriptor` 消费前后执行内容与身份验证；pin 释放前阻止物理回收和 owner 关闭。数据库/目录/owner inode 在访问边界复核，根被替换后旧句柄失败关闭。每次成功打开数据库生成新的运行 epoch，跨长 I/O 的目标读取与分页游标绑定该 epoch；即使同一个库、同一提交重新打开，旧请求也被拒绝。

## 启动与空闲完整性巡检

[LibraryLaunchCoordinator](../Sources/KinlogueApp/App/LibraryLaunchCoordinator.swift) 持有一次启动的资料库，它的构造不访问资料库；用户接受明文说明后，才准备可信父目录、取得单实例 owner，依次收敛恢复事务、capture/preflight 和严格删除 receipt，再打开数据库。报告、LAN、DICOM、备份/恢复、导出和删除共用该 owner 与 lifecycle。第二实例被拒后可重试；早先的 JSON 资料库目录、未知 schema 或坏数据库保持原样，仅提供持有同一 owner 的备份恢复入口。未知恢复 receipt 不能授权恢复或删除。界面入口只走这条链路；取不到可信运行时身份时同样得到一个 `LibraryLaunchCoordinator`，它报告资料库不可用而不解析其他位置。资料库打开后，composition 内各服务的启动次序（恢复收敛、存储就绪、后台处理、备份调度）由 [AppStartupCoordinator](../Sources/KinlogueApp/App/AppStartupCoordinator.swift) 负责；两者原先是同一个类型靠标志区分，现已分开。

[完整性巡检](../Sources/KinloguePlatform/Storage/SQLiteLibraryIntegrityScrubber.swift) 在 Ready 后由 [AppIntegrityCoordinator](../Sources/KinlogueApp/App/AppIntegrityCoordinator.swift) 等待空闲两秒再启动。它使用可取消的结构检查、每批 16 个主键、既有严格实体 codec 与单原件流式校验；不创建全库逻辑 spool。前台任务会取消并等待巡检真正结束，并发等待者等待同一任务。完成后的普通读取不重复触发巡检；提交使行覆盖失效，激活和唤醒要求重新确认覆盖。设置页展示未检查、等待、进度、不完整及完成时间/损坏数量；发生 revision 变化只算未完成，不把旧版本检查冒充当前完整性。

巡检在一次打开期间保留[进度记录](../Sources/KinloguePlatform/Storage/SQLiteIntegrityProgress.swift)，关闭或替换数据库时清空。行检查仍绑定一个 revision：被前台任务打断后，只要资料库状态和 SQLite `data_version`（其他连接提交即变化）都未变，就从断点继续，结构检查也不重做；同一 revision 已完成时不再重读行，只重新核对每个原件的文件身份。提交之后行检查从头开始。原件是不可变文件，字节校验通过后按行内容哈希加文件的设备、inode、长度、修改时间和状态变更时间记账，之后只有这些信息变化的文件才重读，每次校验只读一遍。身份信息不变而字节损坏的情况，要到下次读取该原件或重新打开资料库后才发现；这不影响[读原件时的校验](#原件事务与恢复)，读取仍然每次校验。[回归](../Tests/KinlogueAppTests/SQLiteIntegrityAppTests.swift)覆盖断点续跑、提交后行重查而字节不重读、文件改写后被发现，以及其他连接提交后行重查。提交后行检查在大库上的耗时未测量。

[隔离状态](../Sources/KinloguePlatform/Storage/SQLiteIntegrityQuarantine.swift) 仅属于当前 open epoch，在 admission 下记录坏项及其报告、草稿、inbox 或 DICOM 依赖。已发现损坏的目标拒绝读取、编辑、确认和删除，保留字节；无关良好项仍可用。原件预览、ZIP、加密备份和严格校验发现的身份、长度或摘要失败均进入该边界；外层 writer 回传摘要失败，不额外哈希原件。取消和消费者解码错误不作为原件损坏。数据库结构或 owner 身份失败则要求重启。巡检、详情读取和提交观察中的基础设施错误共用 composition 的停机入口：先拒绝新任务，再由独立持有的任务并行排空 UI 和 lifecycle，关闭 LAN receiver，最后进入 restartRequired，避免故障读取或观察任务等待自身结束。已完成的巡检状态也会失效；普通刷新取消不作为基础设施故障。

巡检隔离已打开的报告或草稿后，刷新会关闭该项详情、原件、编辑和比较；草稿复核实例同步关闭并释放原件。迟到错误受请求身份和选中 ID 约束，不关闭后来打开的页面；无关良好项仍可读取。真实 SQLite/LAN/Viewer 回归见 [SQLiteIntegrityAppTests](../Tests/KinlogueAppTests/SQLiteIntegrityAppTests.swift)。

[安装验收](../Sources/KinlogueApp/App/SyntheticAcceptanceRunner.swift) 的 seed、restart、强制终止、LAN、DICOM 和 cleanup 阶段都通过 `LibraryLaunchCoordinator` 打开这个资料库，只允许受验收身份和 inode receipt 约束的合成根，真实 production 身份拒绝这些 phase。seed 用数据服务建成员，每份报告经暂存原件、写入识别文档和确认草稿三步入库；校验按成员、机构和日期做一次定向检索，再逐条读回 96 份报告及其原件字节，并核对搜索、分成员时间线和比较。记录、来源和原件的 ID 由资料库在暂存时分配，报告靠原件摘要对应。每个阶段打开资料库后都要求尚未读取任何原件字节，结束时关闭数据库并释放 owner；强制终止阶段例外，它让进程带着 owner 和打开的数据库等待被杀。原先单独的 candidate 探针已并入这些阶段并删除。[进程内测试](../Tests/KinlogueAppTests/SyntheticAcceptanceRunnerTests.swift) 依次跑完除 DICOM 外的全部阶段；DICOM 阶段需要安装包里的解码 Helper，只能由 `run-acceptance.sh` 执行，迁移后尚未执行。这些结果不代表近上限、安装 App、OS 冷缓存或所有崩溃恢复路径达标。LAN 初始化现已改用首批 100 项查询；独立规模探针的数据库打开至首批摘要不读取原件，安装 App Ready 仍须单独验收。

## 报告、OCR 与窄查询

[SQLiteReportRepository](../Sources/KinloguePlatform/Storage/SQLiteReportRepository.swift) 实现 `ImportDraftStore` 和成员/记录的窄操作；`confirm`、`discard` 完成提交后只返回结果，不返回资料库的整份内容。

[领域 codec](../Sources/KinloguePlatform/Storage/SQLiteReportRows.swift) 将 `ImportDraftDocument`（包括候选、nullable extraction version 和用户 `reviewState`）与草稿 revision 在同一事务保存，复核不生成 OCR 文件。报告文档限 16 MiB；同表为 LAN source 文档保留独立 kind 和 32 MiB 限额。确认将草稿关系转为报告关系；陈旧 attempt/revision、坏来源或错误归属使事务整体回滚。

[实体预算](../Sources/KinlogueCore/Storage/LibraryStorageLimits.swift) 规定单个成员、完整草稿及同一 owner 的来源集合最多 16 MiB canonical JSON。先累计实际 JSON 转义后的 UTF-8 内容长度，再以完整编码大小作最终判断，不截断持久化内容。草稿来源预留由编码器计算的最大合法状态 header，保证后续识别、成员选择和 revision 增长仍可保存。

成员及来源读取先检查 SQL 字节长度和数量，再逐行验证；长度使用 BLOB 字节口径，包含 NUL。搜索和严格备份逐项处理成员。完整成员辅助读取仍受 128 MiB 单次预算约束，不限制资料库成员总字节数；App header、成员选择和复核只读有独立摘要的 160-scalar 成员投影，编辑按 ID 读取完整成员。真实测试覆盖 135 MiB 成员库的按 ID 读取、搜索和逻辑备份，以及精确 16 MiB 成员的恢复闭环。

新草稿的 ID 由 [LibraryOrderedIDGenerator](../Sources/KinloguePlatform/Storage/LibraryOrderedID.swift) 分配：前 48 位是创建时刻的毫秒数，其后 12 位在同一毫秒内递增，其余随机（UUID 第 7 版的布局）。草稿没有单独的排序列，待确认列表、导入状态和启动时的自动恢复都按 `draft_id` 翻页，所以存下来的 ID 字节顺序就是导入的先后；系统时钟在运行期间回拨也不打乱顺序，跨启动则跟随时钟。本机导入和 LAN 归档创建的草稿都用它。这个 ID 因此带有创建时间；它留在资料库和加密恢复点里，不进入导出的 ZIP，也不发送给手机页面。此前用随机 ID 创建的草稿保持原来的相对位置，不会被重排。

报告 staging 或发布失败时，即使尚未返回 original ID，也按本次 operation 精确回收。丢失响应先核对 live 原件、草稿和完整来源身份；草稿已进入 processing 等后续合法状态仍返回已创建。草稿缺失或来源已更换不误报成功，未知 inode 保留并报错。

[查询契约](../Sources/KinlogueCore/Domain/LibraryReportQuery.swift) 每页最多 100 个摘要，每页都携带同次读取的 `LibraryRevision`，游标另绑定 query/member。摘要 title/reportType/organization/conclusion 分别最多 160/128/128/512 个 Unicode scalar；完整转录保留在详情和独立搜索表。普通列表不读取详情、OCR 或完整搜索文本；搜索复用 `RecordQuery` 的 Foundation 本地化子串规则，保持字段边界、中文短词、成员名及 confirmed-only 语义，不包含用户 notes 或原始 OCR。搜索扫描可取消，不中断随后无关查询。

普通分页显式返回读取时发现的 `damagedIDs`，良好项仍可用；冷详情、OCR 和原件在消费时验证，不把尚未读取视作已经完整校验。严格备份需逐项调用验证 codec，不能使用会隔离坏项的分页结果。详情/比较按 ID 有界读取；去重候选需验证来源字节、OCR 和目标 revision，损坏候选不吞掉新导入的良好副本。

仓库只串行化 stage 导入；其余无共享可变状态的入口使用 `nonisolated @concurrent`，同步文件 I/O 不占该 actor 的整条队列。领域提交仍由数据库 admission 串行执行。

## App 查询与提交观察

[Core 目的型契约](../Sources/KinlogueCore/Domain/LibraryApplicationQueries.swift) 与 [SQLite 实现](../Sources/KinloguePlatform/Storage/SQLiteApplicationQueries.swift) 分离 header、混合时间线、按状态草稿、单项复核和最多两条比较记录。AppSnapshot 不保留整份报告/草稿；混合时间线按日期、领域种类和 UUID 排序，游标推进包含损坏项，报告与 study 即使 UUID 相同也不冲突。每页最多 100 项，完整成员、详情与原件按 ID 读取。

[提交流](../Sources/KinloguePlatform/Storage/SQLiteCommitNotifications.swift) 在持久提交且释放 admission 后发布只含 revision 的最新提示，不携带记录内容或 affected IDs。部分上传、回滚与无变化操作不发业务提示；丢失响应但已提交仍发提示。App 的 [观察 owner](../Sources/KinlogueApp/App/AppLibraryObservationCoordinator.swift) 先订阅再读 header，合并通知并重新读取有界当前页面和已打开的目标，激活/唤醒/流重建也按持久 revision 收敛。

header、列表、搜索、成员编辑、复核、详情、原件和比较都有请求身份及库 epoch 围栏；切换筛选立即清空列表和旧游标，分页失败保留已加载项。刷新不清空列表：已显示的行留在屏幕上，模型按原来已加载的行数重新读取后一次替换，草稿各状态同样在新的一页到达后才替换，四个状态并行读取。提交通知、切回应用和唤醒带来的刷新如果读到的 revision 与已显示的相同，只重新核对已打开的记录和草稿，不重载列表；模型自己发起的修改返回的 header 若已由通知应用过，也按同样方式跳过。显式刷新总是重载，因为草稿的重试资格可以在没有提交的情况下变化。“载入更多”遇到陈旧游标时按“已显示行数加一页”的深度重读一次；提交持续到来时退回只读第一页。整库替换同步撤销查询身份后取消并等待全部已进入读取。物理数据库失败使用固定语义错误 `databaseUnavailable`；即使 header 表仍可读也不能回到 Ready。普通行/OCR 损坏则隔离目标。SQL Viewer 的失效只依赖目标 study revision 和库 epoch，无关报告提交不关闭窗口。composition 的普通读写已纳入同一 lifecycle：拒绝新任务后取消并等待已进入操作，已提交命令仍能返回成功结果及必要的有界 header；随后才关闭数据库并保留替换 owner。

[搜索](../Sources/KinloguePlatform/Storage/SQLiteReportSearch.swift) 的每次查询先按存储顺序读出范围内报告的 ID、成员、日期和搜索摘要，在内存里排成时间线次序，再顺序扫描全部搜索行。每一行的字节都重新计算两个摘要并与报告行和搜索行自身的摘要比较，所以无论是否命中，损坏的行都会被报告；每批最多 512 行 / 2 MiB、最多八个同步工作 lane，大于批预算的合法单实体独立处理，取消会等待所有 lane 排空。结果始终是完整的有序命中，首页不提前结束扫描。

是否命中只由各字段上的 Foundation 谓词决定。[预筛键](../Sources/KinloguePlatform/Storage/SQLiteReportSearchKey.swift) 只用来跳过不可能命中的字段：每个标量做兼容分解，再逐标量映射为大写后小写直到稳定，最后只保留字母和数字，字段之间用 UTF-8 中不会出现的字节分隔。Foundation 在任何 locale 下能找到的词，其键一定是该字段键的字节子串；反过来不成立，所以键命中后仍要用 Foundation 确认。不含字母或数字的词没有键，不做预筛。这一保证由 [测试](../Tests/KinloguePlatformTests/SQLiteReportSearchKeyTests.swift) 对照运行系统上的真实 Foundation 检查：穷举每个标量的大小写与规范等价变体，再加多文字、多 locale 的语料和生成文本。设计依据见 [API 来源](sources/2026-10-11-apple-search-semantics.md) 和 [实现核对](sources/2026-10-12-corefoundation-find-implementation.md)。

解码后的字段和预筛键按行缓存在打开的数据库对象上，预算 64 MiB，关闭或替换数据库时清空。缓存不被单独信任：只有本次查询读到的字节算出的摘要与条目的摘要相同，才使用该条目；它省掉的是相同已校验字节的解码和键推导，不是校验。超出预算的行每次重新解码。连接页缓存设为 32 MiB，使近上限资料库的报告表和搜索表在两次搜索之间留在连接内。

搜索词以 NUL 结尾时，带 locale 的 Foundation 搜索会越过文本末尾读取，报告不存在的匹配，对部分文本会直接终止进程。[Core 谓词](../Sources/KinlogueCore/Domain/RecordQuery.swift) 在这种情况下给被搜索文本补一个非 NUL 单元。DICOM study 的 `uid_domain` 同样在 SQL 返回前按固定 domain 字节长度检查，超限时返回占位和损坏标记，列表保留坏项 ID 和健康项，详情、逻辑备份与导出共用该投影；不先将超长字段复制进 Swift 再拒绝。冷热查询使用直接列 `octet_length` 和惰性 CASE，在 SQL 返回前执行字节预算，来源见 [字节边界](sources/2026-10-11-sqlite-column-bounds.md)。近上限资料库上的搜索计时见 [2026-10-12 复测](storage-search-measurement-2026-10-12.md)；此前未通过的基线保留在 [首批实测](storage-refactor-measurement-2026-10-11.md#sqlite-按需查询)。

[文本边界](../Sources/KinloguePlatform/Storage/SQLiteRows.swift) 以 UTF-8 字节绑定 TEXT，并在 GRDB cursor 生命周期内读取完整字节，避免锁定版本默认 C 字符串读写截断 NUL。非法 UTF-8 由行 codec 拒绝；保留合法 NUL、组合 Unicode、空字符串与 NULL 的区别，不修改行摘要或逻辑备份格式。成员、报告热摘要、来源、原件 metadata、导出和逻辑恢复共用该边界。[来源核对](sources/2026-10-11-grdb-text-fidelity.md) 记录具体依赖行为。

## LAN 事务与上传归属

[SQLiteLANInboxStore](../Sources/KinloguePlatform/LAN/SQLiteLANInboxStore.swift) 由 Receiver 经窄协议 `LANUploadStoring` 使用，Mac 队列、预处理及归档直接持有这个类型，共用一个 SQLite owner 和 admission policy。各接收 scope 独立撤销；创建/撤销 scope 与最终提交共用 admission，并在调用方执行器外等待。停止 Receiver 排空自己的 sink，保留 Mac 队列和数据库 owner。

[上传生命周期](../Sources/KinloguePlatform/Storage/SQLiteLANUpload.swift) 在接收字节前登记 `inbox_uploads` 的 operation、scope、transport、attempt 和实际 inode；未知内容不伪造摘要。完成后在 admission 外验证长度/摘要，同 inode rename，事务同时发布原件、队列和回执。响应丢失先核对 durable receipt；取消和恢复只清理归属可证明的文件。实际 descriptor 关闭后才释放活动登记；partial 记账不推进业务 revision。LAN revision 为 SQL generation + 1，初始化不人为制造提交。

LAN source OCR（上限 32 MiB）与 reviewable 状态在同一事务保存，不生成 derived 文件；组合前按现有 128 MiB 读取预算累计所选文档，归档后的报告文档仍限 16 MiB。上传本身不新增 100 MiB 总量限制，后续识别保留原有门槛。缺失或异常硬链接原件进入 integrityFailed，不自动恢复成良好项；owner/root/数据库身份错误保持全局失败。

[归档](../Sources/KinloguePlatform/LAN/SQLiteLANArchive.swift) 在一个事务中转移原件引用、写入草稿/OCR、移除 inbox 并登记相关 session/content 终态，不复制原件。源件及重复目的的字节先验证，再以 epoch 和目标 revision 复核；失败保留良好 inbox 来源。最近 5,000 个完成命令保存完整 command/intent/outcome，重试只返回已提交结果；这些历史回执不拥有原件，也不能授权删除新项。严格备份须逐项验证 [LAN codec](../Sources/KinloguePlatform/Storage/SQLiteLANRows.swift)。屏幕使用独立的 `LANInboxQueueScreen`，按 sequence/UUID 每页读取最多 100 项及其原件/OCR metadata，不读 OCR payload 或全量历史回执。游标绑定库、open epoch、提交和查询用途；坏行仍推进游标，已隔离项另返 ID。全队列数量和内容字节来自有界 metadata 聚合，不表示全库内容已校验，界面也不将其描述成 SQLite 文件的物理占用。严格 `loadSnapshot` 与旧全量容错诊断投影保留各自语义，不伪造截断快照。活动 partial 的物理身份检查在 admission 外完成，返回前再次核对 root/epoch；单个未知或替换 inode 只标记对应上传，保留文件和其他良好项。

App 队列初始化和删除改走不返回全量快照的 `prepare` / `removeItem`，预览和归档只严格查询明确选择的 ID。选择可跨页保留，刷新分批核对每批最多 32 项；多选删除不新增 32 项上限，归档仍遵守原有来源上限。`AppProcessingCoordinator` 独立遍历有界工作页，只在完整扫描后清理尝试记录，未展示的项也能处理，失败仍须显式重试。处理游标允许自身提交推进，继续绑定库和 open epoch。

## 规范化 DICOM 与按序列读取

[SQLiteDICOMRepository](../Sources/KinloguePlatform/Storage/SQLiteDICOMRepository.swift) 复用原有 scanner/indexer 和 decoder，通过窄导入协议提交 study、object、series、instance 行，不保存 index 文件或整份 study BLOB。[Core header](../Sources/KinlogueCore/Domain/DICOMStudyHeader.swift) 不依赖 index 文件的身份。

DICOM 导入先登记活动 operation，覆盖扫描、索引和原件间隙；恢复跳过该操作，未退出时拒绝关闭/替换。[原件接管](../Sources/KinloguePlatform/Storage/SQLiteDICOMOriginals.swift) 先登记 scanner inode 的 staged ownership，再精确 rename 并同步两侧目录；scanner journal 只清理自己的暂存路径。原件完整校验在 admission 外完成，最终以身份、大小和时间戳复核后，一个事务发布全部 live 原件、完整影像图和一次业务 revision。取消等待真实终态；响应丢失按 operation、study 与严格图校验确认结果。异常或替换 inode 保留并报告。

[严格 codec](../Sources/KinloguePlatform/Storage/SQLiteDICOMRows.swift) 保留每 study 16 MiB 等价逻辑编码预算、现有数量和像素限制、UID digest 域/版本、canonical fingerprint、连续 ordinal 及 ordering policy v2；显式调用几何顺序验证。确认前严格验证目标 study。普通 listing 最多读取 256 个 header 并返回坏项 ID；详情只取目标 header/series，打开序列只取该序列的实例和原件 metadata。严格备份须用 strictStudy，并另行完整验证原件字节。

[SQLite slice source](../Sources/KinloguePlatform/DICOM/SQLiteDICOMSliceSource.swift) 的 token 绑定 library/open epoch、study content revision 和目标 series semantic hash。无关成员/报告修改保留会话，目标变更在 decode、缓存命中和最终发布时拒绝。pin 固定原件跨越 decoder await，复制出的 descriptor 立即由 FileHandle 拥有，任何验证失败都会关闭；不持有 NSLock 跨 await。原件/影像行损坏是局部失败，owner/root/数据库错误保留全局分类，App 按需服务已区分此类错误：目标损坏保留其他数据，全局错误锁定界面并排空 Viewer。

220 份合成原件的真实 SQL 导入测试保持最多 3 次 managed full reads、2 次写入及既有 worker/FD/磁盘预算。Viewer 的未缓存解码则是 4 次 pin hash 加 decoder 读取；这与导入计数不同，尚未测量首切片、连续浏览延迟或实际 Viewer FD 峰值，不据此声称 Viewer 性能已达标。

## 逻辑恢复点与原件导出

[logical-v1](../Sources/KinlogueCore/Backup/BackupLogicalV1.swift) 用固定领域顺序、有界长度记录、版本头、计数和 SHA-256 footer 表达完整 committed 图，包括 OCR 复核、LAN 终态/历史归档回执及规范化 DICOM。它不包含 SQLite schema 或数据库文件。两个独立冻结夹具验证当前 reader 能恢复既有 wire bytes；未知版本和早先的文件树格式恢复点在替换前明确拒绝，保留输入和当前资料库。

[捕获](../Sources/KinloguePlatform/Backup/SQLiteLogicalBackupSource.swift) 在同一 admission 内完成 SQL 数量/长度预检、revision、可达原件 metadata pin 和应用自有数据库的内部副本；随后释放 admission，在固定副本上逐项严格验证和输出逻辑记录。源库继续 DELETE/EXTRA 配置；[临时副本](../Sources/KinloguePlatform/Backup/SQLiteLogicalCaptureDatabase.swift) 仅用于一致性读取，拥有私有目录、原子持久化的 inode receipt 和受限缓存。启动在单实例 owner 下、打开数据库前回收可证明归属的副本，未知或被替换对象保留。内部复制按数据库已分配页增长，包含空闲页；超过 5 秒捕获预算会失败，不能由本机近上限一次通过推断所有理论大文档组合均可在 5 秒内捕获。

逻辑 spool 创建后立即解除文件名，每段最多 1 GiB，以 offset/count 流式读取；原件 pin 保存 metadata，读取时才打开 descriptor。原件流保留完整 hash 和前后 inode/长度/mtime/ctime 检查。合法后续编辑或删除不会改变已捕获版本；释放快照后批量归还 pin。资源预检覆盖内部数据库副本、逻辑 spool 和 256 MiB 余量，恢复还根据认证后的实际逻辑记录与关系数量估计当前 schema 的插入空间。

[恢复](../Sources/KinloguePlatform/Backup/SQLiteLogicalRestore.swift) 只将有界逻辑值写入本应用创建的新数据库，不打开恢复点携带的外来数据库。准备和 activation 后均验证完整领域图、原件字节及 logical digest；strictExisting 不初始化、不修复。共享 [owner](../Sources/KinloguePlatform/Storage/SQLiteLibraryOwner.swift) 一次只允许一条连接，lifecycle 排空后关闭数据库但保留整库替换所有权。启动先收敛 root transaction，再处理 capture/preflight，最后打开普通服务。

[SQL 读取取消](../Sources/KinloguePlatform/Storage/SQLiteReadProgress.swift) 在同一串行连接作用域安装 progress handler，保留原始取消/超时语义并在退出时卸载，不影响下一条查询。[原件 ZIP source](../Sources/KinloguePlatform/Export/SQLiteOriginalArchiveSource.swift) 只查询来源 metadata，复用已有流式 writer、hash、回读与排他发布，不加载 OCR 或全部报告详情。

## 当前测试与下一步

[内核测试](../Tests/KinloguePlatformTests/SQLiteLibraryStoreTests.swift) 覆盖配置回读、schema/外键、事务回滚、未知格式、摘要损坏、初始化恢复、staged/live/deleting 与 pin。[真实进程测试](../Tests/KinlogueStorageProcessTests/SQLiteProcessCoordinationTests.swift) 使用生产内核，在第二 owner、SIGKILL 和重开边界验收。

stage/publish 的长字节 I/O 已移出 admission，参数化测试覆盖无关写入继续、同原件竞争、取消清理和重入时 root/row/path 身份变化；这些内核故意阻塞的测试 worker 使用独立 OS Thread，避免占满 Swift cooperative executor；生产入口的做法见[阻塞调用所在的线程](#阻塞调用所在的线程)。[报告集成测试](../Tests/KinloguePlatformTests/LibraryQueryIntegrationTests.swift) 覆盖复核/确认/编辑、完整字段搜索、有界摘要、损坏隔离、取消、epoch、共享原件与带 pin 删除。[LAN 数据库测试](../Tests/KinloguePlatformTests/SQLiteLANInboxTests.swift) 与真实 Receiver、App service、socket 回压和子进程强退测试已覆盖上传/OCR/归档、scope 时序及恢复。[DICOM 数据库测试](../Tests/KinloguePlatformTests/SQLiteDICOMTests.swift) 覆盖真实导入、去重、损坏隔离、Viewer、取消和资源边界，另有 5 个真实强退交接窗口。U3 仍须在 macOS 26 上取证。[逻辑备份测试](../Tests/KinloguePlatformTests/SQLiteLogicalBackupTests.swift)、[捕获测试](../Tests/KinloguePlatformTests/SQLiteLogicalCaptureTests.swift) 和 [恢复进程测试](../Tests/KinlogueStorageProcessTests/SQLiteLogicalRestoreProcessTests.swift) 已验证冻结格式、真实加密发布、恢复后编辑、取消/空间边界及 19 个 root/capture 故障场景；相关 App service 使用实际共享 owner 链路。App 按需查询和数据库提交观察已通过真实 SQL service 注入测试；界面直接使用 SQLite 实现。搜索在 macOS 27 的近上限探针上低于门槛，见 [搜索复测](storage-search-measurement-2026-10-12.md)；LAN 的 Platform 首批 100 项近上限 p95 为 7.648 ms，真实 service/model 分页回归通过，安装 App 计时仍待验证。近上限、约 9.76 GiB 原件及 20,001 个原件的完整发布/严格恢复已通过独立探针，存储打开至首批摘要与短操作数值门槛通过，口径见 [规模闭环](storage-refactor-measurement-2026-10-11.md#sqlite-完整规模闭环)；App/系统门禁仍待验证；启动、恢复/删除、任务排空和巡检已接通并通过真实链路定向回归。界面入口已切换，安装验收的各阶段也已改在这个资料库上运行，但 `run-acceptance.sh`、macOS 26、安装后的 App 与人工门禁尚未执行。开发 schema 尚可调整，不提供旧 JSON 资料库或旧实验数据库的自动迁移。
