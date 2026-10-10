# Go 手机上传

Go 预览按 Swift 基线实现“从手机接收”：Mac 用户在侧栏“手机上传”中选择本机网络接口、确认当前是可信任的私人局域网后明确开始接收；手机浏览器扫描二维码或输入地址，再输入一次性验证码配对，之后可以逐个上传图片或 PDF。手机只投递文件，成员、报告日期、原件顺序及最终确认都由 Mac 决定。协议、手机页面和行为对照见 Swift [LAN 专题](lan-upload.md)。

2026-10-10 起，预览包 [Entitlements.plist](../packaging/go-preview/Entitlements.plist) 精确为 App Sandbox、用户选择文件读写和 `com.apple.security.network.server`，原生监听不再被固定门禁阻断。**真实 iOS/Android 手机和真实网络切换尚未验收**，验收清单见文末；在完成前不要把预览版作为真实资料的唯一保存位置。

## 开始、地址与配对

- 只列出已启用、非回环、有连续非零 netmask 的本机 IPv4 / 全局 IPv6 地址；不监听通配地址，也不支持 IPv6 link-local。监听使用 `IP_BOUND_IF` / `IPV6_BOUND_IF` 绑定所选接口，端口由系统分配。
- 必须勾选“可信任的私人网络”确认才可开始；每次开始后确认会清除。传输是普通 HTTP，不提供 TLS。
- 开始后显示 `http://<地址>:<端口>/`、只包含该地址的二维码（不含验证码）、“复制地址”（只复制地址）和 6 位验证码。二维码由仓库内 [`internal/qr`](../internal/qr/qr.go) 生成（byte 模式、纠错级别 M），不依赖额外模块。
- 验证码约 10 分钟内有效，首次成功配对后即失效。能力 cookie、CSRF 和上传状态只在内存保存；停止后失效，不写入备份。

## 会话期限与停止

与 Swift 一致，已配对会话在 **连续 15 分钟没有被接受的活动** 后结束；配对、文件预约、取消、上传中持续收到的数据和上传保存都算活动，单纯轮询会话状态不算。没有从创建起计算的总时限，因此持续上传的大批文件不需要中途重新配对。

以下事件会立即撤销会话、使地址和凭据失效，并取消正在进行的上传；已经完整保存的文件保留：

- 点击“停止接收”、关闭窗口或退出应用；
- 系统睡眠、屏幕睡眠、用户会话切出（与 Swift 相同，使用公开的 `NSWorkspace` 通知，见 [lan_lifecycle_darwin.go](../internal/macos/lan_lifecycle_darwin.go)）；
- 所选接口、地址或前缀变化，或 SystemConfiguration 报告网络路径变化（[lan_network_darwin.go](../internal/macos/lan_network_darwin.go)）；
- 15 分钟无活动，或未配对的验证码过期。

普通应用失焦不会停止接收；唤醒、重开窗口或重启不会自动恢复会话。和 Swift 一样，公开通知不能覆盖所有“亮屏锁定”的路径：锁屏本身不保证停止接收，离开前应点击“停止接收”。若系统通知观察器无法安装，开始按钮保持禁用并显示原因，已保存队列仍可整理。

## 接收与传输边界

[传输模块](../internal/lan/receiver.go) 沿用 Swift 手机页面的 HTML/CSS 和协议（`/api/pair`、`/api/session`、`/api/files/reserve`、`PUT`/`GET /api/files/<id>`、`/cancel`），Go 客户端补充中断重试及迟到请求事件防护。

- socket 被接受后先校验对端属于所选接口前缀，再交给 HTTP；原始请求头校验拒绝重复长度及混合传输 framing，再检查固定 authority、Origin、会话、CSRF、速率和有界 JSON。
- 请求头须在 15 秒内到达，普通请求 30 秒；上传正文 30 秒内没有新数据即中断，单个文件最多传输 15 分钟（与 Swift 的 header/progress/upload 期限一致）。中断项可以在手机上单独重试。
- 每会话最多 1000 个文件、两条并行上传；单文件上限 100 MiB。输入流在元数据锁外写入私有暂存文件，只有完整长度与摘要校验通过后才发布。
- 手机仅收到本会话进度与通用保存结果，不得到成员、报告、OCR、摘要或 Mac 内部 ID。

撤销先同步取消当前或启动中的会话，并用撤销代数使事件前已排队的启动请求失效，再异步关闭连接、等待处理器与暂存清理。测试见 [receiver_test.go](../internal/lan/receiver_test.go) 与 [lan_test.go](../internal/app/lan_test.go)。

## 持久队列与归档

[Store inbox](../internal/library/inbox.go) 最多保存 5000 项，以 SHA-256 和长度合并完全相同原件；文件名仅为有界展示元数据。每项有独立识别状态及 revision。识别失败保留原件，可以逐项重试；可以删除单项，或多选后一次删除所选项（删除确认冻结所选 ID 与 revision）。重启不自动接收或重新识别。停止、退出及整库恢复共用 [Service 接收生命周期](../internal/app/lan.go)，等待已进入的处理完成后才关闭资料库。

Mac 最多选择 20 项可整理原件，调整顺序、填写成员及日期后归档。归档冻结 ID/revision，在一个 SQLite 事务中创建待确认报告并消费所选队列项；失败保留队列。完全相同的原件组合仅复用已有待确认或已确认的完整报告，不改写其人工字段或确认状态；部分重合仍可组成新报告。删除或归档前已开始的另一条相同内容上传不能在完成后复活旧队列项。

[Mac 面板](../internal/desktop/lan.go) 与 Swift 一样分三栏：中栏“待确认队列”逐项显示状态、大小、接收时间及预览/重试/删除，选中原件后底部展开归档表单，选择归档成员（不预选）和报告日期；右栏“作为 1 份报告”调整页序并完整预览所选原件；“从手机接收”打开独立的接收弹窗。后台刷新保留编辑表单，不静默更新已选择项的 revision。归档时识别结果中带已知标签或标题的内容会作为建议填入新报告仍为空的医院、科室、报告类型和检查结论，归档时给出的标题保留。归档成功后停留在队列并显示结果：新报告出现在侧栏“待确认”，只有明确确认才进入正常搜索；命中已有报告时可点“查看已有资料”打开它（已确认报告进入原成员时间线）。预览按原件和页码读取，手机看不到预览。

## 资料格式与备份

手机队列自 schema v4 起存在；当前 schema 为 v5（为报告追加人工填写字段，见 [Go 预览](go-native-preview.md)），已知 v1–v4 在事务内升级，旧程序拒绝新格式。快照自 v2 起包含队列原件及有效 OCR，当前写出 v3，旧快照 v1 仍可恢复为空队列。处理中项恢复为可重试失败；未完成暂存、凭据及接收会话不进入快照。恢复摘要分别展示报告原件数和手机待整理项数。进程强杀、旧备份、旧 journal、队列往返及晚到上传回归见 [inbox_test.go](../internal/library/inbox_test.go)、[inbox_legacy_test.go](../internal/library/inbox_legacy_test.go)。详细恢复边界见 [Go 备份专题](go-backup-and-restore.md)。

## 与 Swift 的已知差异

- 日期由 mygo 自绘的日历选择器选择，或明确设为“日期未知”，以 `YYYY-MM-DD` 保存；不是 Swift 的系统日期选择器。
- 原件预览只在面板内分页显示，没有 Swift 的独立“查看原图”缩放窗口。
- 队列不显示实际占用字节数。
- 平台适配仍引用 `macos.LANInterface`，未做 Windows/Linux 移植。

## 验收状态

自动化只使用合成内容：HTTP 使用内存请求和 `net.Pipe`，测试不会打开真实网卡监听。

```sh
go test ./internal/lan ./internal/qr ./internal/library ./internal/app ./internal/desktop ./internal/macos ./cmd/kinlogue
go test -race ./internal/lan ./internal/library ./internal/app ./internal/desktop ./internal/macos
go vet ./...
```

手机页面事件顺序回归由 [client_test.go](../internal/lan/client_test.go) 调用 Node.js 执行实际客户端的离线 DOM/XHR 仿真；未装 Node.js 时该专项明确跳过。二维码编码另以独立解码器（zbar、OpenCV）核对过版本 1–10 与全部 8 种掩码，属于开发核对，不进入 CI。

**仍待真机验收**（签名沙盒包、当前 Mac、真实 iPhone 与 Android 浏览器）：

1. 首次开始时 macOS 防火墙提示与允许后的连接；扫描二维码打开页面、配对、上传 PDF 与图片并在 Mac 归档确认。
2. 手动停止后旧页面失效、需重新配对；15 分钟无活动后停止，持续上传时不中断。
3. 上传中切换应用继续；上传中停止或断网时半文件不入库、已保存项保留；慢速上传和中断重试。
4. 系统睡眠、屏幕睡眠、切换用户与 Wi-Fi 切换时会话停止，且不会自动恢复。
5. 访客隔离网络下无法连接时的提示；VoiceOver 读出二维码与验证码标签。

5000 项队列持续轮询性能、限流/peer 表完整边界、原生观察器安装/通知/移除竞态的行为测试仍需补充。[公开 API 与工具链依据](sources/go-lan-public-api-2026-10-09.md)与[锁屏 API 核对及历史取舍](sources/go-lan-lock-api-2026-10-09.md)保留调研记录。
