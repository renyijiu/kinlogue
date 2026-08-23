# 局域网上传与待确认队列

## 能力边界

局域网上传是由 Mac 用户主动开启的临时、配对、当前会话限定的文件投递入口。它用于把手机上的图片或 PDF 转移到 Kinlogue；它不是远程病历浏览器、报告编辑器或后台同步服务。

当前产品模型没有“上传分组”：

- 手机只维护一个可反复追加的文件选择列表，不选择家庭成员、报告日期或页序；
- 每个文件独立保留上传状态，失败或重试不阻塞其他文件；
- Mac 按完整原件内容合并重复上传，展示一个无分组的待确认队列；
- 用户在 Mac 单选或多选原件，设置报告页序、家庭成员和报告日期，再组成一份 .needsReview 报告；
- 只有成功归档的所选项会从队列移除；未选项和失败项继续保留。

监听只绑定用户选择的合格本机地址，不绑定通配地址。传输使用普通 HTTP，不提供 TLS；只能在可信任的私人 Wi-Fi 或有线局域网中开启。手机只看到当前会话的文件和进度，不能浏览 Mac 上的成员、历史报告、OCR、时间线或原件。

## 从选择到人工确认

~~~mermaid
flowchart TD
  Start["Mac 用户明确开始接收"] --> Pair["手机打开地址并输入一次性验证码"]
  Pair --> Pick["选择或继续追加图片/PDF"]
  Pick --> LocalDedup{"手机有界逐块比较确认相同?"}
  LocalDedup -->|"是"| Ignore["只保留一个本地选择项"]
  LocalDedup -->|"否或无法确认"| Upload["逐文件上传"]
  Upload --> Canonical{"Mac SHA-256 + 长度已存在?"}
  Canonical -->|"是"| Merge["合并到已有待确认项"]
  Canonical -->|"否"| Queue["新增待确认项"]
  Merge --> Select
  Queue --> Select["Mac 单选或多选"]
  Select --> Order["确认报告页序、成员和日期"]
  Order --> ReportDedup{"完整报告原件集合已存在?"}
  ReportDedup -->|"是"| Existing["复用并导航到已有报告"]
  ReportDedup -->|"否"| Draft["创建一份 .needsReview 报告"]
  Existing --> Drain["移除本次所选队列项"]
  Draft --> Drain
  Drain --> Confirm["人工确认后才进入时间线/搜索/比较"]
~~~

手机文件展示名先经过 LANInboxDisplayMetadataSanitizer。控制字符、路径分隔符、双向控制字符和过长 UTF-8 内容会被替换或截断；展示名永远不参与对象路径构造，也不作为 Mac 权威去重条件。

## 手机选择列表与本地去重

手机页面没有拖动排序、分组完成或报告归属操作。用户可以多次打开文件选择器继续追加文件，也可以取消尚未保存的项目。

浏览器只在文件名、大小、最后修改时间和媒体类型都相同时，把项目列为本地比较候选；随后按 1 MiB 块逐字节比较。比较受以下总预算限制：

| 项目 | 上限 |
| --- | ---: |
| 当前会话文件项 | 1,000 |
| 单个新选择的比较候选 | 4 |
| 一次选择操作累计读取 | 64 MiB（比较两侧合计） |
| 一次选择操作累计时间 | 1 秒（单调时钟） |
| 并行上传 | 2 |

只有逐字节确认相同的文件才在手机侧忽略。浏览器不支持读取、读取失败、候选过多、超时或超过字节预算时，都会回退到正常上传，由 Mac 做权威去重；不能因为元数据相似而丢弃文件。长比较会主动让出浏览器事件循环，用户删除项目会取消对应比较。

## 文件级 HTTP 协议

当前文件协议使用固定资源：

- POST /api/pair：消费一次性验证码并建立当前浏览器会话；
- GET /api/session：使用 capability cookie 恢复当前会话文件列表；
- POST /api/files/reserve：登记一个独立文件的展示 metadata；
- PUT /api/files/<remoteFileID>：流式上传该文件；
- GET /api/files/<remoteFileID>：读取当前会话可见状态；
- POST /api/files/<remoteFileID>/cancel：显式取消尚未保存的文件。

不存在创建、完成、排序或撤回报告分组的 HTTP 接口。LANHTTPHandler 在解码 body、查找远端文件 ID 或打开写入 sink 前，先完成 authority、origin、framing、session、CSRF 和速率 admission。上传 body 使用有界 streaming backpressure，不整体缓存在内存。

同一传输身份的 publish、内容合并和终态重放对手机返回同形的通用成功结果；内部 item/blob ID、digest、duplicate destination 和 Vault 失败原因不会越过 HTTP 边界。

## 会话与认证

LANReceiver、LANSession 和 LANHTTPHandler 共同维护一次内存会话：

1. 每次开始接收都会生成新的 session ID、runtime generation、短验证码、capability cookie 和 CSRF token；旧会话立即失效。
2. 验证码有效期为 10 分钟，首次成功后被消费。
3. cookie 是 host-only、session-only、HttpOnly；mutation 还需要当前 CSRF proof。
4. cookie-only restore 只允许恢复和查询当前会话，不授权 mutation。
5. 认证成功本身不刷新 idle；只有 receiver 接受的活动才刷新 15 分钟 idle。
6. stop、替换会话、超时或安全敏感 lifecycle event 会清空全部凭据和计数器。

配对失败、非 body 操作、轮询和上传分别受 peer/global 速率或并发限制；失败只返回固定粗粒度类别，不返回文件内容、路径、凭据或底层错误。

## Mac 权威内容合并与状态

完整上传先校验声明长度并计算 SHA-256。PlaintextLANInboxStore 使用 SHA-256 + byteCount 作为原件内容身份：

- 身份不存在时发布一个稳定 sequence 的 LANInboxItem；
- 身份已存在时只写传输 receipt，复用已有 item/blob，不新增队列行；
- 相同文件名或大小但字节不同会形成不同 item；
- 连接中断只清理 partial 并允许重试，不冻结为成功；
- 用户明确取消、删除或归档会记录终态，防止已被 admission 的晚到 body 重新生成队列项。

一个待确认项独立经历：

~~~mermaid
stateDiagram-v2
  [*] --> stored
  stored --> preprocessing
  preprocessing --> reviewable
  preprocessing --> unsupported
  preprocessing --> failed
  failed --> preprocessing: 单项重试
  unsupported --> preprocessing: 单项重试
  reviewable --> archived: 所选报告归档成功
  stored --> deleted: 明确删除
  reviewable --> deleted: 明确删除
~~~

只有 reviewable 项可进入报告选择。unsupported、失败或完整性异常项不会阻塞其他项，也不会被伪装成可归档；用户可以单独重试或删除。

## Mac 选择、排序与报告去重

待确认队列按首次发布 sequence 稳定显示，不把上传会话或选择时间包装成分组。Mac 用户可以：

- 单选一个原件组成单页/单源报告；
- 多选最多 20 个原件，并只针对本次归档调整报告页序；
- 选择一个未归档家庭成员和一个报告日期；
- 点击页序中的文件名可在右侧切换该原件的完整预览；预览图和“查看原图”均只面向可复核的图片/PDF 原件。每次加载冻结 item revision 并推进 preview generation，只有仍是最新选择且 revision 未变的结果可以发布；关闭、切换、刷新发现 revision 改变或整库 lifecycle 都会清空旧 payload；
- 独立“查看原图”窗口首次按窗口适配显示完整图片或 PDF 页，用户再通过放大/缩小控件查看细节；动态缩放上限至少允许达到当前有界解码图像或 PDF 页的实际尺寸；
- 页序内联预览只保留当前选中原件的一份已验证 payload；从内联预览打开独立窗口时复用该 payload，不再次读取同一份最大 100 MiB 原件；
- 单项重试或显式删除。

删除确认在弹窗操作进入异步存储链路前冻结当次 `(item ID, expected revision)` 集合；弹窗关闭只结束确认展示，不能让异步 action 改为读取刷新后的 revision。存储层按冻结 revision 原子验证，发生并发变化时保留队列项并要求刷新后重试。

Mac 接收期间仍每秒检查一次 receiver liveness，但不再每秒解析 inbox manifest 和枚举完整物理目录。`LANInboxChangeMonitor` 只观察 inbox/blobs/partials/derived 目录事件与当前 partial 文件增长，并推进不含路径或内容的进程内 generation；generation 变化只是一条 dirty hint，真正刷新仍调用 `snapshotAndStorageSummary()`，重新取得共享 mutation lease 并执行权威 manifest、root binding、引用和物理 accounting 校验。连续 partial 写入最多在下一次一秒心跳合并为一次 UI 刷新；外部实例的 manifest 原子替换和对象发布同样会触发下一次刷新。receiver 停止时无论 generation 是否变化都执行最终刷新，整库删除则先停止观察器和轮询，再依赖既有 lifecycle generation fence 拒绝迟到结果。

页序、成员和日期在归档 intent 中冻结。改变页序只重组已缓存的逐原件 OCR/provenance，不重新识别原件。

App 会先把 DatePicker 的本地日历选择规范化为既有的 UTC 正午日期语义；Platform 在创建 durable intent 前再把 `Date` 投影到 `millisecondsSince1970` 编解码的稳定值。这样 intent 写盘后重读仍可做严格相等校验，不会因为亚毫秒浮点差异把有效选择误报为 `staleRevision`。已经失去 transport receipt、但 item/blob/derived artifact 仍完整且处于 reviewable 的恢复队列，继续允许归档；receipt 不是创建报告的前置条件。

报告级精确去重继续使用版本化 ReportFingerprint：它是 source digest 和长度组成的 multiset，保留 multiplicity，但不使用文件名、页序、成员、日期或 OCR 文本。完整原件集合相同时复用已有 .needsReview draft 或已确认记录，忽略本次新选的成员、日期和名称，不创建重复报告；部分重合或近似内容不会跳过。

LANReportArchiveCoordinator 与 PlaintextVault.commitStagedReportSelection 保证：

1. 重新验证所选 item revision、内容身份和可读对象；
2. 以 Mac 选择顺序建立新的 ReportSource/Attachment；
3. 原子发布一份 .needsReview draft，或返回当前 Vault 中的 exact duplicate；
4. 只有 Vault 结果已提交或已验证存在后，才记录 inbox 归档终态并移除所选 item；
5. 任一步失败时保留原队列项，允许用户重试；
6. 未完成的归档 intent 会在下次启动恢复；已完成归档遗留的 staging 文件也会按持久化终态继续清理，不用异步 fire-and-forget 任务承担可靠性；只有清理成功的 terminal 才被 acknowledgement，失败 terminal 留到下次启动，成功 terminal 不长期累积。

## 存储和资源边界

LAN inbox 位于 [storage.md](storage.md) 描述的 lan-inbox/ 明文子树。原件 blob、上传 partial、逐原件 derived OCR 和 inbox.json 不会在手机上传阶段直接进入时间线。

主要安全上限包括：

| 范围 | 上限 |
| --- | ---: |
| 持久化待确认 item | 5,000 |
| 每个会话传输 receipt | 1,000 |
| 一次组成报告的原件 | 20 |
| active uploads | 2 |
| 每个 upload pending memory | 4 MiB |
| 全局 upload pending memory | 16 MiB |
| 文件展示名 | 1,024 UTF-8 bytes |

这些是 admission/decoder 安全上限，不是固定总存储配额。真实磁盘写入或同步失败时，当前文件不会发布为待确认项，partial 会在安全边界内清理，并保留重试路径。

备份只保存 durable reachable graph：reviewable item 引用的 derived artifact 会连同摘要、长度和真实字节进入加密恢复点，上传或预处理中的 partial 不会进入。若 checkpoint 冻结时 item 已是 durable `.preprocessing`，恢复 staging 的只读 strict validator 允许其不存在 transient partial；整库恢复事务先完成重启收敛，随后普通 inbox startup 会把该项转为可重试 `.failed(.storageFailure)` 并移除 attempt 引用。派生文件缺失或摘要不符会在恢复确认前失败关闭，不能只凭 manifest 路径通过。

## 生命周期

用户手动停止、锁屏/屏保、系统睡眠、用户 session resign、network path change、关闭最后一个主窗口、退出 App 或 idle timeout 都会停止接收，撤销旧地址和 proof，并取消仍在进行的上传。已经完整发布到 Mac 待确认队列的 item 保留。

普通焦点丢失、临时 sheet、系统唤醒或重新打开 App 不会自动创建或恢复接收会话。应用重启后必须由用户明确重新开始，手机旧 cookie/CSRF 不能恢复新会话。

整库删除开始时，`LANInboxModel` 会先不可逆锁定本进程的 Vault lifecycle、推进 generation、停止轮询/预处理和窗口通知，并立即清空队列、选择、预览、接收凭据与错误状态。之后所有已经 admission 的初始化、刷新、地址解析、接收启停、归档、预处理、重试、删除和预览异步结果都必须同时匹配旧操作冻结的 generation 且 lifecycle 未锁定才可发布；迟到回调不能重新填充已删除资料、重启 receiver、刷新新界面或触发 catalog 回调。当前进程只有重启后才能重新打开普通 Vault 访问。

对应 App model 回归使用可控 gate 覆盖地址解析迟到、receiver start 迟到、archive terminal 迟到和多项删除中途进入整库 lifecycle：迟到 start 会补做底层 stop，archive 不触发 catalog callback，多删除只允许已经进入的单项结束且不再启动下一项。

手机页面为每次浏览器端连接状态维护独立 generation。清除连接和验证码成功配对都会推进 generation，取消旧轮询/恢复请求，并重置文件列表、上传队列、mutation epoch 与取消 tombstone；因此配对前已经发出的 cookie restore 即使迟到，也不能覆盖新 CSRF token、文件行或连接状态。仍在排队、文件逐块比较或 reserve `await` 中的旧 picker 工作同样失效；这些旧任务返回或失败时不能向重新配对后的文件列表、待上传队列或状态提示写入，也不能刷新新界面或重置新会话的轮询 timer。新会话可以重新启动轮询，而不会继承旧选择的异步尾部。对应可执行 Node `vm` 回归见 [`LANPhoneAssetSafetyTests.swift`](../Tests/KinloguePlatformTests/LANPhoneAssetSafetyTests.swift)。

同一连接还维护只在内存中的 mutation epoch。每次选择、reserve、开始/推进/结束上传、重试、取消或移除改变本地文件状态时都会推进 epoch；`GET /api/session` 轮询在发出前同时冻结 generation 与 epoch，任一值在等待期间变化就丢弃整份旧 snapshot。远端状态合并只接受不低于当前 `attemptRevision` 的 revision，并且不能把本地 saved/cancelled 终态或正在取消的状态改回活动态。取消成功的 `remoteFileID` 会进入当前连接的 tombstone set，后续 snapshot 不能把该行重新加入；只有明确清除连接或成功配对进入新的 generation 时才释放 tombstone。Node `vm` 回归会真实挂起 `/api/session`，在返回前分别执行重试、取消、上传完成或成功配对，再释放旧 snapshot，证明列表不回退、不复活且新连接 proof 不被旧恢复覆盖。

## 排查顺序

1. 确认 Mac 和手机在可信任的同一 LAN，且不是 guest/client-isolated network。
2. 确认 macOS firewall 允许 Kinlogue 入站连接，并使用 UI 当前显示的地址。
3. 确认验证码未过期、会话未停止，且手机没有缓存旧凭据。
4. 查看手机单个文件是 reserved、receiving、interrupted 还是 saved；中断项可独立重试。
5. 在 Mac 查看对应待确认项是否仍在本机处理、可归档、unsupported 或失败。
6. 报告归档失败时保留选择和队列项；不要根据手机通用结果猜测 Vault 状态。

当前自动化与真实设备门禁见 [acceptance/lan-upload-matrix.md](acceptance/lan-upload-matrix.md) 和 [acceptance/lan-upload-feasibility.md](acceptance/lan-upload-feasibility.md)。
