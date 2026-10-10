# Go 接收锁屏 API 核对（2026-10-09）

> 以下早期“必须解决锁屏才能启用”的结论已被文末产品取舍替代；保留研究历史，不代表当前要求。

本记录只使用 Apple 官方公开文档；未执行锁屏、未开启监听，也未申请新权限。

| 来源 | 文档明确的范围 |
| --- | --- |
| [NSWorkspace.sessionDidResignActiveNotification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification) | 用户会话切出前发出；没有声称覆盖全部亮屏锁定。 |
| [NSWorkspace.screensDidSleepNotification](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification) | 屏幕进入睡眠时发出；屏幕睡眠不能等同亮屏锁定。 |
| [NSApplication.didResignActiveNotification](https://developer.apple.com/documentation/appkit/nsapplication/didresignactivenotification) | 应用把活动状态交给另一个应用后发出；没有声称它是全路径锁屏通知或锁屏前同步屏障。 |
| [ES_EVENT_TYPE_NOTIFY_LW_SESSION_LOCK](https://developer.apple.com/documentation/endpointsecurity/es_event_type_notify_lw_session_lock) | Endpoint Security 的公开事件符号；本页没有提供对上传提交的原子撤销保证。 |
| [es_new_client](https://developer.apple.com/documentation/endpointsecurity/es_new_client(_:_:)) | 创建客户端要求 `com.apple.developer.endpoint-security.client`，并要求用户通过 TCC 授予完整磁盘访问。 |

判断：以上 AppKit 文档不足以证明当前预览的全部亮屏锁定撤销约束。没有据此断言所有 macOS 公共 API 都无法实现。Endpoint Security 只是需要另行评估的路线，尚未验证事件延迟、丢失、会话关联、重启和提交屏障；不建议为了手机上传直接扩大至完整磁盘访问。未采用私有通知名、私有会话字典键或新增权限。

当前措施：真实接收明确禁用，原生 `ListenLAN` 在接口枚举及 socket 创建前返回固定不可用代码，界面也不启用开始按钮。保留已有队列的查看、识别和归档。安全禁用消除了当前版本开启未受保护会话的路径，不能把它登记为锁屏接收机制已实现或真实手机验收已通过。重启、增加 entitlement 或设置环境变量都不会解除此门禁；需要后续代码变更及受支持机制的证据。实现见 [Go 手机上传](../go-lan-upload.md)。

## 后续要求调整：后台继续，允许有限停止延迟

用户已明确普通后台切换不能停止上传，锁屏可以短暂延迟，但必须最终停止且不损坏数据。此处不再要求零字节或瞬时截止；剩余问题是能否识别全部锁屏，而不是追求系统通知与磁盘提交的零延迟原子性。

补查 [CGSessionCopyCurrentDictionary](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary()) 和 [Window Server Session Properties](https://developer.apple.com/documentation/coregraphics/window-server-session-properties)：官方列出的标准字段是用户、控制台、是否位于控制台及登录完成状态，没有锁屏状态保证。未把未文档化的字典键或分布式通知名引入实现。Swift 对照适配器把屏幕睡眠映射为 screenLocked，但这不能补足亮屏锁定的公开保证；本轮不修改 Swift。

可执行部分：收到受支持的睡眠/屏幕睡眠/会话切出事件时，同步取消当前及启动中的接收上下文，异步关闭连接并清理；普通失焦和唤醒不撤销/重启。增加从会话创建起 15 分钟不可续期的总上限，以防手机流量无限维持接收。这是独立的会话总时限，不是锁屏检测，不承诺锁屏后在某个秒数内发现。Go 定时器和操作系统调度也不是硬实时；完整清理等待已进入的存储/原生 OCR 工作退出，不声称磁盘故障下能在固定秒数完成。

在没有可靠低权限锁屏信号的证据前，生产接收门禁保持关闭。无需扩权的务实替代是用户明确选择限时投递批次，或离开时手动停止/使用系统睡眠；这些都改变“所有亮屏锁定自动停止”的要求，尚未得到选择，不能据此解除门禁。Endpoint Security 仍是需另行评估权限和实现的路线，暂不申请完整磁盘访问或真实网络验收。

## 当前延迟结论与验证口径

| 阶段 | 可承诺的范围 |
| --- | --- |
| 普通应用后台/失焦 | 不作为撤销触发源。 |
| 系统睡眠、屏幕睡眠、用户会话离开 | 使用 NSWorkspace 的 willSleepNotification、screensDidSleepNotification、sessionDidResignActiveNotification；回调内同步撤销，返回前当前/启动中上下文已取消，事件前排队请求失效。 |
| 亮屏锁定 → 通知到达 | 上述信号无所有锁定路径的覆盖依据，最大延迟未知，不能给出 N 秒保证。 |
| 取消 → 完整清理 | 连接/暂存异步清理，已进入存储或原生 OCR 需等待退出，无固定时间上界。 |
| 合成回归 | 暂存中断、自主移除及 drain 分别使用 1 秒失败阈值并通过；这只是当前 Mac 测试期限，不是生产时延 SLA。 |
| 真实锁屏实测 | 尚未执行；无网络探针只编译和 self-test，没有安装观察器。 |

因此，即使用户允许短暂延迟，仍缺少低权限、受支持且覆盖全部亮屏锁定的可靠信号。当前不能满足该完整要求，保持生产接收禁用；未将会话总时限替代锁屏检测。

## 最终实测与跨平台取舍（后续用户决定）

独立 Terminal 离线探针在睡眠样本收到 willSleep/didWake；用户随后单独执行 Control–Command–Q 并确认屏幕常亮，该样本没有收到所订阅的系统通知。后者监督器共 111 次心跳，最大相邻间隔约 1.02 秒，主动停止后有完整退出记录。前者不能代替锁屏证据；两轮均未联网或测上传停止延迟，原始临时记录已清理。

用户最终选择“先保持现状，尽量不要依赖平台，后面考虑多平台”：当前 Go 契约接受后台继续、离开前手动停止及创建起十五分钟固定总期限，不再保证可靠锁屏自动停止。停止专属信号探索，不引入 Keychain、Endpoint Security 或未文档化接口；公开睡眠/会话通知仅为可选增强，不是安全保证。以前“锁屏保证必须补齐”的产品门槛由此替代，不改写实测缺少信号的技术事实。

本轮仅更新边界、文案和记录，没有开启接收或增加权限。历史就绪门禁和内部错误名仍保留，后续网络授权、平台适配解耦及真实手机验收详见 [Go 手机上传](../go-lan-upload.md#平台边界与后续启用)。
