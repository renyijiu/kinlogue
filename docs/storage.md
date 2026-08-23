# 存储格式与持久化不变量

## 资料库根目录

生产运行时由 `AppRuntimeIdentity` 固定到：

```text
~/Library/Application Support/Kinlogue/Vault/
```

验收运行使用带随机 run ID 的隔离目录：

```text
~/Library/Application Support/Kinlogue/Acceptance/<runID>/SourceVault/
```

路径由系统 Application Support、签名 bundle identity 和验收配置推导；生产 App 不接受环境变量或任意用户路径作为 Vault 根目录。

## PlaintextVault 布局

```text
Vault/
├── library.json
├── dicom-import-journals/  # transient durable opaque ownership receipts
├── dicom-import-staging/   # transient same-volume opaque read-only copies
└── objects/
    ├── catalog/
    ├── record/      # report metadata objects and DICOM study indexes
    ├── attachment/
    ├── ocr/
    ├── thumbnail/
    └── descriptor/
```

`library.json` 是唯一的 logical commit point。对象名由服务端生成的 UUID 和固定 kind/extension 组成：OCR 使用 `.json`，其他对象使用 `.data`。展示名、URL、用户输入或手机文件名不能进入对象路径。

当前 catalog v3 把成员、报告记录、附件、草稿和 DICOM study header 编码在 manifest 内；原件 attachment、OCR document 和每个 study 的 `.record` index 通过对象 reference 可达。DICOM 原件仍是普通不可变 `.attachment`；catalog 的 study header 是 attachment/index reachability 和删除的权威根。未被当前 catalog 引用的对象可以在加载时作为 orphan 清理候选，但清理失败不能阻止读取已验证的当前 generation。

## Manifest 与 generation

明文 Vault manifest 包含：

| 字段 | 作用 |
| --- | --- |
| `magic` | 当前明文格式标识 `KLGPLAINTEXT1`。 |
| `formatVersion` | 明文 manifest 格式版本，目前为 `1`。 |
| `commitID` | 本次 manifest 提交的 UUID。 |
| `catalogSHA256` | canonical catalog JSON 的 32-byte SHA-256，用于发现损坏。 |
| `catalog` | `VaultCatalog`（当前 domain catalog format v3）。 |
| `objects` | 每个可达对象的 kind/ID、字节数和 SHA-256。 |

每次 mutation 必须：

1. 读取并完整验证当前 manifest、catalog、引用和对象 metadata；
2. 检查 `expectedGeneration == current.generation`，新 catalog generation 恰好加一；
3. 先把新的 immutable objects 写入并同步；
4. 最后原子替换 `library.json`；
5. 尝试清理不再可达的对象，但不让可选清理破坏已提交的 generation。

因此中断恢复时，公开的状态只能是完整旧代或完整新代，不允许“旧 catalog + 新对象”或“新 catalog + 缺对象”的混合可读状态。并发提交最多一个从同一 generation 成功，其他提交得到 mutation conflict。所有持久化 generation 推进都经过 `VaultGeneration.successor`；到达 `UInt64.max` 时以 invalid generation 失败关闭，不允许整数回绕成旧代。

DICOM study 提交和每次 reopen 还会从磁盘实读其 index，校验 index 版本、study ID、retained/viewable 闭合、Series/instance 顺序、attachment 集合、重算 fingerprint 和 vault-wide UID digest 冲突。index 缺失、大小/哈希不符或图不闭合都 fail closed，不暴露部分 study。

`HealthRecord.revision` 在 catalog v3 中是可选字段：缺失解码为 `0`，值仍为 `0` 时重新编码继续省略 key。这样只读重开不会改变缺少该字段的既有 v3 canonical catalog bytes，manifest 中已经保存的 catalog digest 仍可复核；第一次成功编辑才写入非零 revision。

普通 catalog mutation 必须完整保留当前 DICOM study 集合。移除 study 的 `VaultCommitRequest` 必须显式声明全部目标 ID，且 proposed catalog 不能继续包含这些 ID；实际移除集合与授权集合不完全一致时，`PlaintextVault` 在写对象或 manifest 前以 invalid catalog 拒绝提交。报告 draft、确认/丢弃和 LAN 归档重建 catalog 时也必须透传 study，并把其 attachments 计入保留集合。

ordering policy v2 还会在 reopen 以线性投影遍历验证已持久化的 geometry order 与 Series orientation/layout，而不是按当前算法重新排序；其他 policy version 均失败关闭。查看一个 slice 时，`PlaintextVault` 用当前 vault revision token 重新验证全部 DICOM index，并只在该次 resolve 内复用 requested study 已验证的 index，精确核对 opaque study/Series/instance/attachment、digest、length 与 image attributes，再从 managed object path 打开 regular-file descriptor。descriptor 在 XPC decode 前后都流式复核 digest、inode 和长度；短 lease 返回 owned raw frame 后即释放 catalog coordination。

切片像素不写入 Vault。生产 `DICOMSliceService` 实例共享进程级 384 MiB 预算、32 slices/192 MiB canonical LRU 和最多一个 active foreground + 一个 active prefetch scheduler；newest pending foreground 在旧 active 真正结束前不能开始。checked admission 覆盖 object、主进程 XPC reply 与 decoded frame 两份 raw bytes、canonical、render/upload 以及缺失 W/L 时的 percentile sort scratch。active reservation 以 RAII lease 原子转移为 cache/current-render 计费；service 释放也会回收 retained render，超过 cache byte cap 的 canonical 会在 active lease 转移前清零。canonical 与 current render 都使用引用型单一 storage，session switch/close/lifecycle failure 只清对应 token，memory pressure 才全局清 cache。Vault destroy 在等待 active descriptor lease 前推进 lifecycle generation，transform 完成后的最终 publish 必须再次匹配该 generation，否则清除对应 cache/render 并返回 stale session。

DICOM import 在第一份 staged bytes 出现前先原子写入 opaque ownership receipt，再创建并绑定 operation staging directory 的 device/inode。扫描、index 和 publication 共用同一个进程内/跨进程 mutation lease；完整、排序后的 attachment/index promotion 集合在首个 managed-object write 前一次性持久化，对象和 index 再先于 manifest 发布。取消会等待这一事务进入真实终态：manifest commit 前取消后做 abort/reconciliation；已跨过 manifest commit 且 catalog 可证明同一 study ID、fingerprint、index object 与 attachment graph 时返回成功提交的 study，即使本次 cleanup 仍需由 durable receipt 重试。无法证明精确提交时，abort/reconciliation 错误会显式失败而不是被取消状态掩盖。成功、取消和可恢复失败都会按当前 catalog 的可达引用做 reconciliation。重启或下一次导入同样先读取有效 manifest，再保留已被 catalog 采用的对象并仅回收不可达的 journal-owned 对象；若 ownership cleanup 仍需重试，新导入会 fail closed，不继续累积 receipt。staging 回收只通过 descriptor-relative no-follow 操作处理匹配身份的 UUID 文件；遇到 symlink、未知 entry 或目录替换时拒绝 unlink 并保留 receipt 重试。

本页只拥有 DICOM 的 Vault 图、提交和恢复不变量；导入流程、XPC、slice service、Viewer 与支持边界见 [`dicom.md`](dicom.md)。

## 读取、损坏与兼容边界

`PlaintextVault.inspect()` 可能返回：

- `absent`：根目录不存在或为空；
- `operationInProgress`：根级协调正在进行；
- `legacyEncrypted`：发现旧版 `vault.marker`，当前代码不覆盖、不迁移、不删除；
- `damaged`：manifest、catalog、对象存在性/长度/digest 或路径不一致；
- `unsupportedVersion`：格式版本不支持；
- `ready(revision)`：全部必需验证通过。

App 启动使用 `loadValidatedCatalog()` 在一次解析中同时完成 `inspect()` 等价的全对象校验并取得 catalog；只有 `absent` 才初始化空 Vault。自动恢复直接从这份已验证 catalog 选择可恢复草稿，恢复完成后再读取一次最新 catalog 交给 UI，避免把验证结果丢弃后重复扫描相同对象，同时仍保证恢复前完整性门禁和恢复后的新鲜快照。

未知非空目录、部分初始化收据、符号链接替换、缺失对象、长度变化、digest 不匹配和 malformed manifest 都必须 fail closed，不能返回部分 catalog。

需要同时消费 catalog 与一个或多个对象的读取链路使用 `VaultStore.readSnapshot`。`PlaintextVault` 在一次 root-scoped mutation lease 中只解析一次 manifest，先让调用方同步选择当前 catalog 中的对象 reference，再按同一代 metadata 读取并校验对象；单次最多选择 32 个对象、累计保留最多 128 MiB。返回快照前 lease 已释放，因此后续 OCR、DICOM index 投影或 UI 解码不会长期阻塞提交。导入草稿/去重、报告原件、多来源重新识别和 DICOM study index 都使用这条一致性读取路径；其中待确认页通过 `ImportDraftStore.loadReviewSnapshot` 同时取得 draft、OCR、成员和首个原件，不再跨两次 generation 拼接页面内容。接口没有逐次 `loadCatalog + readObject` 的兼容回退实现。

## 文件系统安全与删除

- Vault root、对象目录和 transaction receipt 需要当前用户拥有；管理目录使用私有权限（通常 `0700`），receipt 使用 `0600`。
- 文件打开和目录访问使用 `O_NOFOLLOW`/descriptor identity 检查，避免把路径替换成符号链接后写入错误位置。
- `VaultProcessLock` 与 `VaultMutationCoordinator` 同时覆盖进程内和跨进程竞争。
- 删除先写一个绑定 canonical root path、device/inode 的 receipt，再把当前目录移入确定的 quarantine。清理会先打开并绑定该 quarantine descriptor，只通过 `openat` / `fstatat` / `unlinkat` 和 no-follow 规则递归处理原目录内容；即使可见 quarantine 名称随后被替换，也不会递归进入替换目录，最终名称与已绑定 identity 不一致时保留 receipt 并失败关闭。
- 每次 Vault 访问都会在版本探测前恢复这笔已授权删除；因此有效 durable deletion receipt 可以删除随后被识别为旧版本或损坏的原目录。没有该 receipt 时，旧版本、未知布局和损坏内容仍保持不变并失败关闭。
- 删除不会承诺抹除 Finder 原始文件、Time Machine、APFS snapshot、系统备份或其他副本；它只管理 App 自己的当前资料库。

## 存储资源上限

这些是安全/解码上限，不是对用户磁盘总量的承诺：

| 对象 | 上限 |
| --- | ---: |
| manifest | 64 MiB |
| Vault 对象总数 | 20,000 |
| attachment | 100 MiB |
| thumbnail | 32 MiB |
| catalog / record / OCR | 16 MiB |
| descriptor | 128 KiB |

DICOM 在上表的通用 Vault 上限之外还叠加以下 catalog/index 门禁：

| DICOM 图 | 上限 |
| --- | ---: |
| 单 study retained objects | 2,000 |
| catalog studies | 256 |
| catalog 唯一 retained DICOM objects | 10,000 |
| catalog 累计 Series | 4,096 |
| 单 study index (`.record`) | 16 MiB |

单次 DICOM 文件夹 intake 另外固定为 traversal depth 16、10,000 entries、2,000 DICOM objects、2 GiB unique source bytes、100 MiB/object、两名 worker 的预算上限和八个 import-owned source/staging descriptors 的预算上限。scanner 使用 iterative component-identity worklist，从持有的 root 逐段 `openat`/`O_NOFOLLOW` 重开深层目录并立即关闭上一段；两名 worker 共用一个已验证的 staging operation descriptor。exact digest/length duplicate 在每个两项 batch 后立即按 descriptor/identity 删除，因此 object/byte 上限只计算唯一原件。设本次唯一原件总量为 `S`、检查时已经进入同卷 staging 的字节为 `A`：容量门禁要求当前额外可用空间至少为 `2S - A + 256 MiB`。因此第一份复制前是 `2S + headroom`，全部 staged 后的最终 publication 是 `S + headroom`，不会把已占用的 staging 字节重复计入“仍需可用空间”。这是保守的峰值安全预算，不是总资料库 quota；算术溢出或容量查询失败都失败关闭。

这些上限在构造/解码、commit 前和持有最终 catalog lock 的实际对象验证中重新检查。超限 proposal 在写新对象或 manifest 前被拒绝。

LAN inbox 另外有待确认 item、传输 receipt、并发和内存上限，见 [`lan-upload.md`](lan-upload.md)。产品决策明确不设置固定 storage-byte quota；真实文件系统写入失败时当前文件不会发布为可处理 item，并提供清理/重试路径。

## LAN inbox 独立子树

LAN inbox 不会在手机上传时直接创建报告 draft，而是在同一个 Vault root 下用独立 manifest 保存无分组待确认队列：

```text
Vault/
└── lan-inbox/
    ├── inbox.json
    ├── blobs/       # 已接收的不可变原件 blob
    ├── partials/    # 上传中的 descriptor-bound partial
    └── derived/     # 每个 canonical item 的本机预处理结果
```

`lan-inbox/inbox.json` 是 inbox 的唯一 logical commit point；blob/derived 先发布，manifest 后原子替换。完整上传按 SHA-256 + byte count 合并为 canonical item，相同内容不会增加 blob 或队列行。partial 由一次上传 attempt 拥有，连接中断、session stop、revision 变化或失败后不能发布为 item。

inbox manifest 同样校验 generation、vault ID、item/receipt/terminal 引用、对象路径、字节数和 digest，并通过 `VaultRootBinding` 绑定当前 Vault 的 root/parent identity。用户删除或报告归档会先写同一 generation 的 content terminal，防止已经 admission 的晚到 body 重新生成 item；物理 blob/derived 只在最后一个逻辑引用消失后清理。

报告归档先通过 `VaultReportSelectionStaging` 暂存已验证原件，再由 `PlaintextVault.commitStagedReportSelection` 原子发布一份 `.needsReview` draft 或确认 exact duplicate。只有 Vault 结果持久化后，inbox 才移除本次所选 item并记录 durable terminal；terminal 只在对应 staging 清理成功后按 intent/receipt identity 精确 acknowledgement。清理失败会保留 terminal 供下次启动继续恢复，成功路径不会让 lifetime terminal 无界累积。

## 已确认原始文件导出

`PlaintextVault.prepareOriginalArchiveExport` 在受协调读取中返回 catalog revision、导出清单和附件 metadata。清单只包含 `.confirmed` 报告的每一条 source row 与 `.confirmed` DICOM study 的 catalog-authoritative `attachmentIDs`；同一附件被两条报告 source row 引用时仍按两行输出。总 entry 数固定上限为 30,000，超过已完成 writer characterization 的边界会在读取原件前失败关闭。草稿、待确认 DICOM、OCR document、DICOM index、catalog、LAN inbox 和孤儿对象都不可达。

每个 ZIP entry 开始前，Vault 短暂重新取得 mutation lease，要求 exact `VaultRevision` 和 attachment metadata 未变，并通过 `O_NOFOLLOW` 打开后复制一个固定身份的只读 descriptor。lease 在单项字节流开始后释放，避免长时间阻塞普通 catalog/LAN 操作；任何并发 mutation 会让后续项或发布前最终 revision 复核失败，整个未发布暂存被清理。因此成功 ZIP 对应一个闭合 revision，而失败不会返回混合代际的归档。

`PlaintextOriginalArchiveExporter` 使用 ZIPFoundation `0.9.20` 的 stored entry 和 64 KiB provider 逐块 `pread`，同步校验长度与 SHA-256。work archive 位于目标同卷的私有 item-replacement directory，名称不带 `.zip`；新目标由该 API 生成的零字节 placeholder 会在写入前移除。写入后同步文件、重新打开并逐 entry 解压复核路径/数量/长度/digest，再做最终 revision 校验。只有这些步骤全部成功才原子 move/replace 用户目标：普通文件 authority 路径绑定目标和 work 父目录 descriptor 并以 `renameat` 发布，目录替换时按已捕获 inode 清除 placeholder/work；`NSSavePanel` security scope 路径使用 `NSFileCoordinator` 提供的协调 URL 与 Foundation replace/move，不额外要求未获授权的父目录访问。提交阶段不再接受取消；发布后还会尽力同步父目录，但 `NSSavePanel` 只授予目标文件而未授予父目录时的 `EACCES` / `EPERM`，以及文件系统明确不支持目录同步的错误，不会把已完整校验和原子发布的 ZIP 误报为失败；真正的目录 I/O 错误仍报告“发布状态不确定”。目标在 Vault 内、非 `.zip`、symlink 或非 regular replacement 均被拒绝。

输出目录和文件名只由用户可见成员名、确认日期、稳定序号、清洗后的报告显示名和类型扩展构成；DICOM 使用通用 `.dcm` 名称。内部 UUID、attachment/study ID、digest、原始路径和 DICOM UID 不进入 ZIP。该 ZIP 不含恢复 manifest，不能作为 Vault backup。

## 版本、备份与未来路线

- 当前 App 只接受并写入 catalog v3；DICOM index 只接受 ordering policy v2。除恢复先前由用户明确发起、且已写入有效 durable deletion receipt 的整库删除外，catalog v1/v2 和其他 policy version 都不迁移、不覆盖、不删除，检查与加载均失败关闭，并保持原有目录和字节不变。
- 空目录仍可初始化为当前格式；未知非空目录、损坏 manifest/catalog、对象图不闭合或不支持版本都不能被当成新资料库覆盖。需要继续使用旧开发资料时，应先由对应旧代码在仓库外导出，或由用户手工重置开发 Vault；当前 App 不提供自动迁移。
- 旧加密 Vault 通过 `vault.marker` 识别后停止；没有隐式转换。
- 当前版本提供用户选择目录的加密 `.kinloguebackup` checkpoint 与整库替换恢复，但不提供云同步、网盘 API、iCloud 或 CloudKit。checkpoint 覆盖 exact Vault + durable LAN inbox committed graph；显式原始文件 ZIP 仍只是不可恢复 catalog 的明文交接副本。
- backup 本机配置与恢复事务 receipt 位于 Vault 外的可信 Application Support sibling，避免 whole-root 替换复制旧设备身份或移动自己的恢复记录。恢复 staging/rollback 只存在于同一 app-private parent，不写入用户选择的同步目录。
- checkpoint 使用独立密码学认证；活动 Vault 的 SHA-256 语义和明文姿态没有改变。未来若加入活动 Vault 加密或云同步，仍必须提供显式迁移、密钥生命周期和失败恢复协议，不能把当前 SHA-256 重新命名成认证。

完整格式、自动化、保留和恢复顺序见 [`backup-and-restore.md`](backup-and-restore.md)。
