# Go LAN 公开 API 与工具链来源（2026-10-09）

本记录对应 Go 手机上传实现，不代表真实网络或签名应用验收。

- [Go release history](https://go.dev/doc/devel/release)：Go 1.27.2 于 2026-10-08 发布，包含 net/http、net/textproto 等安全修复。新增 HTTP 服务的构建及 CI 固定此补丁；旧 1.27.1 包仅可经过 previous 验证后保留。
- [Go 下载清单](https://go.dev/dl/?mode=json)：本机临时工具链使用官方 darwin-arm64 archive；SHA-256 为 `76812b213b1b2302c978d28fa52fa92d541704b9e7d9d5db8002c50e4018c4c5`。未替换系统 Go 安装。
- [net/http](https://pkg.go.dev/net/http)：Shutdown 等待活动请求而非强制取消；实现另外撤销会话、取消上下文、关闭连接并等待自己的处理器屏障。
- [Apple IP_BOUND_IF](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/in.h)：具体接口 socket 绑定，不能以通配监听回退。
- [SCDynamicStore 通知键](https://developer.apple.com/documentation/systemconfiguration/scdynamicstoresetnotificationkeys(_:_:_:))、[dispatch queue](https://developer.apple.com/documentation/systemconfiguration/scdynamicstoresetdispatchqueue(_:_:))：支持网络状态通知；通知本身不替代连接及提交前接口复核。
- [NSWorkspace 系统睡眠](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification)、[用户会话离开](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification)：后者描述用户会话切换，不能泛化为所有锁屏场景。实现不采用私有的锁屏或屏保通知名。
- [入站服务 entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server)：沙盒入站服务需要单独能力。本轮保留原权限，真实接收未开启。

项目事实入口：[Go 手机上传](../go-lan-upload.md)。
