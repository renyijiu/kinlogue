# Go 手机上传

Go 预览已加入手机上传协议、持久队列、Mac 整理界面和备份兼容。入口为侧栏“手机上传”。当前预览仍在 UI 与原生 socket 入口禁用新接收，等待单独授权入站权限和真实网络验收；仍可整理已有队列。用户已选择优先跨平台：普通后台切换可继续，离开前手动停止，会话设固定期限，不保证锁屏自动停止。协议设计在门禁将来满足后仍要求选择具体私人网络接口、确认普通 HTTP 明文边界并明确开始。手机只投递文件，成员、报告日期、原件顺序及最终确认由 Mac 决定。Swift 对照契约见 [LAN 专题](lan-upload.md)。

**当前授权边界：本轮没有增加沙盒入站网络权限，也没有启动真实局域网监听。** 默认 [Entitlements.plist](../packaging/go-preview/Entitlements.plist) 仍只含沙盒及用户选择文件读写权限。因此这不是已完成真实手机验收的可发布替换版；签名应用入站权限及真实私人网络验收需单独授权。

## 接收与取消

[传输模块](../internal/lan/receiver.go) 沿用 Swift 手机页面的 HTML/CSS 和协议，Go 客户端补充中断重试及迟到请求事件防护，提供配对、会话恢复、文件预约、流式上传、查询、取消和退出。验证码有效十分钟且只用一次；会话从创建起最多十五分钟，手机活动不能续期，这一总时限不充当锁屏检测。能力 cookie、CSRF 和上传状态只在内存保存；停止后失效，不写入备份。每会话最多 1000 个文件、两条在途上传；单个文件沿用 100 MiB 上限。手机仅收到本会话进度与通用保存结果，不得到成员、报告、OCR、摘要或 Mac 内部 ID。

HTTP 前先限制真实 socket 的地址族和所选接口前缀；原始请求头校验拒绝重复长度及混合传输 framing，再检查固定 authority、Origin、会话、CSRF、速率和有界 JSON。输入流在元数据锁外写入私有暂存文件，只有完整长度与摘要校验后才能发布。受支持的生命周期回调先同步撤销当前或启动中的会话，并用撤销代数使事件前已排队的启动请求失效，异步关闭连接，再等待处理器与暂存清理；已经持久保存的项保留。测试见 [receiver_test.go](../internal/lan/receiver_test.go)。可选 `mediaType` 接受手机页面实际发送的 `null`，其余必填字段仍严格拒绝空值。

[原生接口适配](../internal/macos/lan.go) 排除通配、回环、混合地址族及不支持的接口，使用公开 socket 选项绑定具体接口。[网络通知](../internal/macos/lan_network_darwin.go) 监听 SystemConfiguration 的接口、全局及服务变化，同一地址快照下的路径事件也撤销会话；安装失败拒绝开启，另有定时复核及提交前检查。

[生命周期适配](../internal/macos/lan_lifecycle_darwin.go) 的系统睡眠、屏幕睡眠和用户会话离开通知仅作可选的提前撤销增强，不作为跨平台安全保证。普通应用失焦不停止；唤醒、重开窗口或重启不自动开启。**锁屏不等于停止接收，离开前应点击“停止接收”。** 十五分钟期限从会话创建起计算且不能由手机续期，它限制会话寿命，不检测锁屏；定时器和完整清理受系统调度、存储及原生 OCR 退出影响，不承诺硬实时截止。

本机离线实测分两轮：睡眠样本收到 willSleep/didWake；独立 Control–Command–Q 且用户确认屏幕常亮的样本没有收到已订阅通知。测试没有网络或上传，不能作为上传停止延迟证据。后续用户明确选择跨平台优先，停止锁屏专属方案探索，不引入 Keychain、Endpoint Security 或未文档化信号。[API 与取舍记录](sources/go-lan-lock-api-2026-10-09.md)保留历史依据。

## 平台边界与后续启用

- 平台无关的契约：显式开始/手动停止、十五分钟不可续期会话、凭据撤销、旧排队启动失效、不自动重开、完整原件原子发布、半文件清理和已保存项保留。实现主要在 `internal/lan`、`internal/app` 和 `internal/library`，现有合成数据完整性回归继续保留。
- 平台适配：接口绑定、网络变化、可选系统通知、原生窗口及 OCR。当前 `LANConfig`/桌面接口仍引用 `macos.LANInterface`，UI 就绪状态仍与观察器安装结果耦合；本轮仅整理边界，未宣称已经完成跨平台抽象或 Windows/Linux 移植。
- 当前 [LANReceptionReadiness](../internal/macos/lan.go) 仍固定拒绝，[ListenLAN](../internal/macos/lan_listener_darwin.go) 在任何 socket 前阻断，UI 开始按钮保持禁用。历史内部错误名 `ErrLANLockUnavailable` 暂保留，不代表产品仍要求补齐锁屏检测。
- 后续需另行授权真实私人网络测试及 macOS 入站 entitlement；再单独修改就绪门禁，将可选系统观察器与接收资格解耦，保留接口/来源/配对等网络校验。不能仅改权限或设置环境变量开启。
- 启用前执行签名沙盒包与真实 iOS/Android 验收：手动停止、持续活动下总期限、后台继续、半文件取消、已保存数据保留、旧凭据失效、显式重新配对、网络变化和恢复/退出。真实锁屏自动停止不再是验收承诺。

## 持久队列与归档

[Store inbox](../internal/library/inbox.go) 最多保存 5000 项，以 SHA-256 和长度合并完全相同原件；文件名仅为有界展示元数据。每项有独立识别状态及 revision。识别失败保留原件，可以逐项重试或明确删除；重启不自动接收或重新识别。停止、退出及整库恢复共用 [Service 接收生命周期](../internal/app/lan.go)，等待已进入的处理完成后才关闭资料库。

Mac 最多选择 20 项可整理原件，调整顺序、填写成员及日期后归档。归档冻结 ID/revision，在一个 SQLite 事务中创建待确认报告并消费所选队列项；失败保留队列。完全相同的原件组合仅复用已有待确认或已确认的完整报告，不改写其人工字段或确认状态；部分重合仍可组成新报告。损坏的已有报告原件不能导致新收到的完整副本丢失。删除或归档前已开始的另一条相同内容上传不能在完成后复活旧队列项；删除后明确开始的新上传仍可保存。

[Mac 面板](../internal/desktop/lan.go) 的后台刷新保留编辑表单，不静默更新已选择项的 revision。新归档进入现有报告复核流程，只有明确确认才进入正常搜索；命中已确认报告时打开其原成员时间线，不重复要求确认。删除有独立确认；预览按原件和页码读取，手机看不到预览。

## 资料格式与备份

当前 schema 为 v4，已知 v1/v2/v3 在事务内升级；旧程序拒绝新格式。快照 v2 包含队列原件及有效 OCR，旧快照 v1 仍可恢复为空队列。处理中项恢复为可重试失败；未完成暂存、凭据及接收会话不进入快照。恢复摘要分别展示报告原件数和手机待整理项数，总字节数包含两者。

已有 v3 未退休恢复 journal 仍按原快照格式验证摘要，再执行升级，不能以新格式重算旧摘要。进程强杀、旧备份、旧 journal、队列往返及晚到上传回归见 [inbox_test.go](../internal/library/inbox_test.go)、[inbox_legacy_test.go](../internal/library/inbox_legacy_test.go)。详细恢复边界见 [Go 备份专题](go-backup-and-restore.md)。

## 验收入口与未完成项

手机页面事件顺序回归由 [client_test.go](../internal/lan/client_test.go) 调用 Node.js 执行实际客户端的离线 DOM/XHR 仿真；Node.js 仅为测试工具，未装时此专项测试明确跳过，不进入应用包。

自动化只使用合成内容，HTTP 使用内存请求和 `net.Pipe`，不打开真实网卡监听：

```sh
go test ./internal/lan ./internal/library ./internal/app ./internal/desktop ./internal/macos ./cmd/kinlogue
go test -race ./internal/lan ./internal/library ./internal/app ./internal/desktop ./internal/macos
go vet ./...
```

[应用集成测试](../internal/app/lan_test.go) 覆盖配对上传至 SQLite、OCR、停止取消及恢复激活；[界面测试](../internal/desktop/lan_test.go) 覆盖未保存编辑、冻结选择、失败保留、显式网络确认和中英最小窗口。设置 `KINLOGUE_LAN_UI_EVIDENCE` 为测试输出目录可保存纯合成的布局图；此变量仅由测试读取，不是生产运行时入口。布局图不是实际签名窗口或 VoiceOver 验收。

独立审查确认的六项行为/文档问题均已修复并定向回归；接收与 Store 之间的取消另用受阻快照写入验证。5000 项上限下的持续轮询延迟、配对/鉴权/轮询限流阈值与 peer 表清理的完整边界测试、原生生命周期观察器安装/通知合并/移除竞态的行为测试仍需补充。

真实 iOS/Android 浏览器、签名沙盒入站授权、实际网络切换、手动停止/总期限下的真实上传、慢速手机上传及 VoiceOver 尚未验收；系统通知仅完成上述离线样本观察。本轮不提交、不推送、不发布，不读取真实医疗资料。[公开 API 与工具链依据](sources/go-lan-public-api-2026-10-09.md)记录其来源。
