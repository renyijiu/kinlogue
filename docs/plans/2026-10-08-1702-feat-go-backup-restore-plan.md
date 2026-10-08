---
title: Go Manual Encrypted Backup and Restore
type: feat
status: active
date: 2026-10-08
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Go Manual Encrypted Backup and Restore

## Goal Capsule

- **Objective:** 用户能保存完整 Go 资料库的加密副本，并在资料库损坏或更换 Mac 后恢复记录及原件。
- **Means:** 有界逻辑快照、age 认证加密和先验证后替换的本地恢复事务，见 KTD1–KTD5。
- **Authority:** 用户已同意完成稳定性验收并继续备份恢复；`AGENTS.md`、当前代码和可复现证据优先。本计划的 `status` 仅满足仓库计划分类门禁，不记录执行进度。
- **Execution profile:** 先有行为测试；跨进程文件替换必须有真实 SQLite、原件和 SIGKILL 重启证据；独立 Go worktree 完成实现、审查和文档。
- **Stop conditions:** 不确定目录所有权、旧库或恢复事务身份冲突时保留全部内容并拒绝激活；不得以初始化空库掩盖失败。
- **Delivery:** 不新增项目；不提交、push 或创建 PR。仅用合成内容验收。

## Product Contract

### Requirements

- R1. 先补真实中文输入、删除及保存面板失败/取消验收；自动化与 VoiceOver、系统矩阵等人工未验收项分别记录。
- R2. 手动备份包含全部成员、报告状态、人工修正、初始 OCR、有序原件、创建时间和语言设置；不包含已删除资料、孤儿、锁、临时文件或工作队列。
- R3. 每份备份生成独立恢复码，显示对应备份标识，用户保存并重新输入后才能选择目标；丢码无法恢复。App 不持久化恢复码，不自动复制或上传。
- R4. 成功只表示所选本地备份完整写入、重新解密验证并原子发布。取消、写入/验证失败不得破坏已有目标或冒充成功。
- R5. 恢复先在私有新目录完整验证；错误码、损坏、截断、未来格式、超限和取消不得修改当前资料。只能对验证后的摘要确认整库替换，不合并或自动确认 OCR。
- R6. 确认替换后停止接收新任务，取消并等待正在运行的任务、关闭数据库、持久化替换；完成或此后失败都只允许退出重启。中途断电/终止必须在启动打开资料库前收敛。
- R7. 内容损坏或不支持版本的资料库仍有恢复入口；不安全路径、另一实例占用或身份不明的恢复事务继续拒绝操作。旧库作为本机明文副本保留，不递归删除未知内容。
- R8. 备份/恢复入口沿用未保存编辑和输入法保护；错误/状态及无障碍标签中英齐全；恢复码不进入持久状态、日志、AX 密码值或下次会话的撤销记录。

### Key Decisions and Scope

- **手动整库备份优先。** (session-settled: user-approved — chosen over LAN, DICOM and model integration in this iteration.) 自动备份、网盘协议、长期注册密钥、保留清理、增量备份、记录合并和 Swift 格式兼容均不做。
- 活动资料库继续是沙盒内明文；加密只适用于外部备份。认证加密不提供发送者签名或防回滚承诺。不保证 Go 内存或系统剪贴板安全擦除。
- 重建使用已有领域校验，不导入任意 SQLite 文件或执行归档内 SQL。

### Acceptance Examples

- AE1 (R2–R4). 含两成员、排序后的多原件确认报告、失败草稿和人工备注的合成库备份后恢复，全部字段及原件字节相同，未确认内容仍不参与搜索。
- AE2 (R4–R5). 使用其他备份的码、修改/截断尾部或加入额外条目，恢复失败；原库仍能搜索并编辑，已存在备份目标不变。
- AE3 (R6–R7). 在每个持久化阶段强制终止；已有库时连续两次重启只有完整旧库或完整新库，旧库保留，不能形成空库或混合库。原本无库且未提交时，恢复协调保持无库并进入恢复入口，不能用自动建空库掩盖中断。
- AE4 (R7–R8). 当前 DB 损坏时只显示恢复/退出；有效备份仍能准备并在确认后恢复，锁定实例和 symlink 不能绕过。
- AE5 (R3, R8). 取消码输入、重新打开、Undo 不能找回上一会话的码；未保存编辑阻止直接进入备份，保存后备份包含这次修改。

## Planning Contract

### Current Evidence

`internal/library/store.go` 持有单连接 SQLite 和库内 `.owner.lock`，`Open` 会进行恢复/初始化，不能当不可信归档验证器。`internal/app/service.go` 的普通 command 登记退出，Close 等待全部命令；在 command 内调用 Close 会自锁。`internal/macos/export_darwin.go` 已有授权、协调、无目录枚举发布和原子替换，但校验限于单报告 ZIP。mygo 的输入框 setText 保留 Undo，因此恢复码字段需要每次会话使用新身份。

### Key Technical Decisions

- **KTD1 (R2, R5): 流式逻辑归档。** 在 Store 互斥和 App 修改队列内输出一个版本化 TAR：首项为有限的库头/成员/语言，随后按报告写有限 JSON 和该报告的有序原件。条目路径只由固定名及验证过的 ID 生成，拒绝链接、扩展头、重复、未知项和尾随数据。每份来源保留原始长度和 SHA-256；仅完整图验证成功后输出可供恢复的摘要。重建到自建 schema 的新 Store，原件逐个流式校验写入；处理中状态规范为 failed/interrupted。不得在打开 Rows 时通过同一单连接查询详情。
- **KTD2 (R3–R5): 采用固定 age v1.3.2。** 使用上游推荐的 HybridIdentity，单备份随机身份；关闭加密流并验证完整解密至真正 EOF，不能把 TAR EOF 当认证完成。备份发布前解密重读与原始明文摘要比较；还须验证内容归档。无自创密码协议、无密码派生分支。依赖和新增许可证固定归档。
- **KTD3 (R4–R5): 复用文件发布机制。** 在现有 macOS 模块提取最小内部发布函数，外部原件 ZIP 的限制和验证保持不变；新增备份 writer/readback verifier 和流式 selected-file reader，继续协调、安全 scope、regular/no-follow、目标身份和提交后的取消语义。不增加 entitlement。
- **KTD4 (R6–R7): 稳定父目录 lease 与恢复 journal。** 在启动 reconciliation 和 Store.Open 前持有资料根父目录的私有进程锁，正常/降级运行全程持有。旧根内 owner lock 继续检查，阻止老版本实例占用；新目录必须独占创建、固定相对名、同卷，journal 保存目录 inode/device 身份，原子写并 fsync。不得从文件名或缺失推断所有权。此次把 Go 库标记提升为 v3，已知 v2 只事务更新版本（v1 先完成既有结构迁移），模型不变；所有候选库均为 v3，因此不认识父锁/journal 的旧 v2 程序会拒绝打开，不能在恢复未完成时写入候选库。每次 rename 仍验证身份并使用目标不存在语义，防止旧版在缺根间隙创建的另一库被覆盖；冲突时保留所有根并拒绝启动。
- **KTD5 (R6, R8): 准备与激活分离。** 生命周期 owner 持有 stage token，Prepare 可取消并返回计数，Cancel 只清理身份匹配的自建 stage。Activate 是一次性、位于普通 command 外的操作，先 Seal/Close App（含 read/preview），再替换根。该边界后无 Cancel 或回到旧屏幕，直到重启。降级入口无需 Store，使用系统语言，不调用普通成员/列表服务。

### Format Limits

单原件沿用 100 MiB、每报告 20 原件。备份总明文/密文各有独立有界读取预算（初始 64 GiB 明文、65 GiB 密文），成员/报告各至多 100,000，原件至多 1,000,000；超限报错，不静默截断。库头至多 32 MiB、单报告 JSON 至多 64 MiB（20 个来源各允许 2 MiB OCR），每个文本仍使用现有领域限制。实现应选择能够完整表达当前合法模型的最小格式，所有长度/计数在分配和写入前检查。备份文件扩展名 `.kinloguegobackup` 区分 Swift。

### Restore Commit and Recovery

| durable journal | 启动行为（先持有父锁，后打开普通 Store） |
| --- | --- |
| 无 | 正常打开；不扫描或清理无主兄弟目录 |
| prepared，旧根仍在 | 保留旧根；仅处理 identity 匹配的 stage |
| retirement/install intent，旧根可能已移动，新根可能已安装，未 commit | 按 journal 身份将候选移回 owned slot，旧根回到 Library；原本无库时恢复无库状态 |
| committed，但 journal 尚未退役 | 验证新库及原件，成功则退役 journal；失败恢复已知旧根并报告恢复失败 |
| 身份不明、receipt 损坏、预期旧根丢失 | 保留全部内容并阻止正常使用，绝不自动创建空库 |

只有新根安装、完整验证及目录同步后记录 commit。必须在普通业务开放前成功退役 journal，避免后来将已修改的新库回滚。旧根放在明确归属的 retained slot，界面说明仍是本机明文副本且本轮不会自动清理；未知旧根只做有界 rename，不遍历/递归删除。阶段 callback 仅内部测试使用，生产无环境注入入口。

### API and Ownership

| owner | 最小职责 |
| --- | --- |
| library | `WriteSnapshot(ctx, writer)`；`RestoreSnapshot(ctx, reader)` 仅空新库；严格图验证和摘要；store 锁保护一致性 |
| backup | age 生成/解析码、Encrypt/Decrypt/Verify，无 UI/文件路径/业务 DB；固定有界协议 |
| library runtime | 父 lease、stage token、journal、激活及启动 reconciliation；不持有 UI 或原生 OCR |
| app | 普通备份使用 command；Prepare 的取消登记；独立 Activate 先 Close 再调用 runtime；降级协调也不创建假 Store |
| macos | selected file 的流式输入和已验证的原子输出；不解析领域 records |
| desktop | 一个备份/恢复面板，恢复码会话隔离、摘要确认、dirty guard、退出重启和中英文；不创建任意根目录 |

## Implementation Units

### U1. Native reliability evidence

**Goal/Requirements:** R1；真实窗口补输入、删除、覆盖/取消，记录未验收项。
**Files:** Go 主题、日志；仅当可复现缺陷需要修正时改对应 UI/原生函数和针对性测试。
**Verification:** 合成草稿删除后队列消失且输入源文件字节不变；IME 候选取消/提交/Undo；不得将 AX 读取冒充 VoiceOver。

### U2. Snapshot and encryption

**Goal/Requirements:** R2–R5；完整可验证备份格式。
**Dependencies:** 无。
**Files:** 新 `internal/library/snapshot*.go`、`internal/backup/*.go`；必要最小 Store validator 调整；`go.mod`/`go.sum`、许可证打包门禁。
**Approach:** KTD1–KTD2，先真实 Store 混合图往返测试及坏尾部/成员关系/重复 ID/超限/取消测试，再实现。
**Verification:** 所有字段和 bytes 保留；备份时并发修改不能拼接不同状态；错误 key、截断、额外 ciphertext/明文、未来版本不能通过；空库可往返，未确认记录不进搜索。

### U3. Root ownership and recovery transaction

**Goal/Requirements:** R5–R7；可重启收敛的整库激活。
**Dependencies:** U2 的验证契约。
**Files:** 新 `internal/library/runtime*.go` 与 process fixture 测试；`store.go`、`migration_test.go` 的 v3 标记升级；`cmd/kinlogue/main.go` 最后集成。
**Approach:** KTD4–KTD5 和恢复表；目录身份与 lease 是必需边界，不加入通用迁移框架。
**Verification:** 每个 durable write/rename/sync gap 的真实 SIGKILL 后两次启动；旧库存在/不存在/损坏、旧 root lock 占用、symlink/slot 替换、坏 receipt、commit 后新库损坏均有明确结果。冻结 v2 reader 证明候选在 journal 未退役前也无法由旧版打开；v2→v3 中断不能改变任何领域数据。

### U4. Native IO and app lifecycle

**Goal/Requirements:** R4–R7；实际选择文件、完整写入、串行快照及任务排空。
**Dependencies:** U2–U3。
**Files:** `internal/macos/export_darwin.go`、新 backup IO 文件及非 Darwin stub；`internal/app/backup*.go`、必要 `service.go` 变更和跨层测试。
**Approach:** KTD3–KTD5，保持既有 ZIP 测试；对激活使用独立 owner，不在普通 command 内 Close。
**Verification:** 原子新建/覆盖及失败旧目标保留；完整 readback；blocked native preview/import 与激活交错无死锁，新 read/write 拒绝；准备取消仍能使用旧库。

### U5. Native backup and recovery UI

**Goal/Requirements:** R3、R5–R8；正常/损坏库都能完成入口。
**Dependencies:** U2–U4。
**Files:** `internal/desktop/backup*.go`、既有 view/desktop/strings/tests、`cmd/kinlogue/main.go`。
**Approach:** 复用 job generation 和 leave guard；生成视图与重新输入分步；每次 code editor 用新 identity，Password 隐去 AX/copy；显式复制按钮说明剪贴板边界。
**Verification:** 错误 reentry 拒绝创建；cancel/reopen/Undo 没有上次码；旧准备结果不能激活/清理新 stage；降级启动不读普通 Store；activation 开始后退出等待，失败仍 restart-only。

### U6. Evidence and docs

**Goal/Requirements:** R1–R8 的可复核交付。
**Dependencies:** U1–U5。
**Files:** `docs/go-native-preview.md`、新增 Go 备份专题/来源、README、PRIVACY、privacy-and-security、index、log、plans/sources 目录；`.gitignore`、当前树/历史隐私扫描和对应脚本测试纳入 `.kinloguegobackup` 及完整 age Hybrid 私钥（扫描不输出命中内容）。
**Verification:** 真实签名应用合成 backup→restore；独立代码审查及相关复测；文档只写已验证事实。原工作区不改动，产物和恢复码不进 Git。

## Verification Contract

- `CGO_ENABLED=0 go test ./...`、`go vet ./...`、格式检查；核心 `go test -race ./internal/library ./internal/backup ./internal/app ./internal/desktop`。
- library 的真实文件/SQLite 往返和生产恢复方法 SIGKILL，app 的非 interruptible preview 等待，macOS 发布故障与密文完整性测试。
- `scripts/build-go-preview.sh`、`scripts/verify-go-preview.sh`、`scripts/privacy-guard.sh`、`scripts/verify-docs.sh`；新增 age/transitive 许可证固定收录。
- 实际签名窗口验证与自动化分别记录。其他 macOS、真实 File Provider、VoiceOver、人工 OCR 和托管 CI 未运行时必须明确标记。

## Definition of Done

- 手动备份和正常/降级恢复均接入真实 Backend，AE1–AE5 有针对性证据。
- 输入归档验证、完整密文认证、原目标保留、任务排空及跨进程恢复没有被简化掉。
- 文件/密钥/路径不进入 Git 或内容日志；无自动备份/网络/迁移旧 Swift 资料等范围扩张。
- 文档、许可证、索引、日志及真实通过/未验收边界同步；代码审查发现的实质问题已处理。

## Appendix

- 本仓库事实：[`../go-native-preview.md`](../go-native-preview.md)、[`../../internal/library/store.go`](../../internal/library/store.go)、[`../../internal/app/service.go`](../../internal/app/service.go)、[`../../internal/macos/export_darwin.go`](../../internal/macos/export_darwin.go)。
- 外部依据：[age v1.3.2 release](https://github.com/FiloSottile/age/releases/tag/v1.3.2)、[锁定 API](https://github.com/FiloSottile/age/blob/v1.3.2/age.go)、[HybridIdentity](https://github.com/FiloSottile/age/blob/v1.3.2/pq.go)、[格式规范](https://c2sp.org/age@v1.1.0)、[认证边界](https://words.filippo.io/age-authentication/)。外部实现不能替代本应用的恢复验证。
