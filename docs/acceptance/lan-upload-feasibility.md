# 局域网上传 U1 可行性记录

> **Archive / superseded:** 本页记录生产 LAN receiver 落地前的 U1 可行性实验。当前 entitlement、会话行为和发布状态以 [局域网上传矩阵](lan-upload-matrix.md) 与 [当前候选证据](current-release.md) 为准。

该实验专用 host、entitlement 与构建开关已在生产 LAN 路径稳定后删除；下文中的名称和命令仅用于解释 2026-08-02 的历史证据，不能在当前 checkout 中执行。

本记录只使用合成字节，不包含姓名、病历或其他健康资料。U1 的目标是证明公开 macOS API、精确接口绑定和临时会话生命周期满足上线前硬门槛；它不代表生产包已经开启局域网接收。

## 构建边界

- 在 2026-08-02 的 U1 feasibility build 中，生产 `Kinlogue.app` 当时仅具有 App Sandbox 与用户选择文件读写 entitlement，不具有 `com.apple.security.network.server`。
- 当时只有以 `scripts/build-acceptance-app.sh --lan-feasibility` 构建的隔离验收身份使用 `packaging/KinlogueLANFeasibility.entitlements`。
- 当时的隔离身份将主可执行文件替换为独立的 `KinlogueLANFeasibilityHost`；生产可执行文件不包含可行性标记、启动参数或 listener composition。
- SwiftNIO 固定为官方 `2.101.3`（revision `0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b`），不允许范围依赖。
- 监听器只能绑定用户从合格接口中确认的精确 IPv4 地址；不绑定 `0.0.0.0`，也不按来源子网拒绝已路由连接。

## 当前机器记录（2026-08-02）

| 字段 | 结果 |
| --- | --- |
| OS / 架构 | macOS 26.6 / arm64 |
| Xcode | 26.6 |
| Swift | 6.3.3 |
| 隔离 App bundle hash | `8f4bbfe7ddf51be822756ae1e6b9eb9a07e15b655aabb85553250d4a31ea890f`（按 bundle 内文件 SHA-256 清单再做 SHA-256） |
| 隔离可执行文件 SHA-256 | `a092986d0406dc19b2e44c9315b9c3dac229164ae744467a25ad4820fe3660da` |
| 合成内容 | 固定非医疗 UTF-8 字节；不记录内容，只记录长度和 SHA-256 |
| 自动化单元测试 | 当前 Xcode 下 transport、并发 start/stop、活跃 child 关闭、生命周期、公开通知映射与隔离身份测试通过 |
| 构建与签名 | 已构建 ad-hoc 签名隔离身份；marker、purpose string 与精确 entitlement allow-list 一致 |
| 安装包局域网接收 | 已从用户 Applications 目录启动隔离身份；精确地址接收 28 字节固定 fixture 后，主窗口关闭、凭据失效和 listener/已接受连接关闭均在 1 ms 测量精度内完成；无参数重启以退出码 64 拒绝且未恢复监听 |

## 必须补齐的安装验收矩阵

每个事件记录：UTC 时间、OS/硬件、Xcode/Swift、已签名 App SHA-256、选中的接口名和地址（报告中遮盖最后一段）、事件、事件前后监听 socket 是否可连接、关闭耗时、旧凭据是否失效、唤醒或重启后是否保持未接收状态。不得记录上传文件名、正文、token 或完整 IP。

当时的隔离 host 只在签名 bundle 同时具有 acceptance marker、LAN feasibility marker、精确 purpose string，并收到 `--lan-feasibility-host`、`--bind-host=<已选择地址>` 与 allow-list 场景时启动。`last-primary-window-close` 在收到 28 字节固定合成 fixture 后关闭主窗口；`await-public-lifecycle` 在收到 fixture 后保持运行，供人工触发公开 workspace/application 生命周期事件。标准输出先产生不含 IP 的 `ready` JSON，停止后产生含事件名、接收摘要、关闭毫秒数与凭据状态的 `stopped` JSON；只有关闭小于 1 秒、fixture 精确匹配且凭据失效才返回成功。安装驱动必须保持客户端 socket 打开，另行验证它在 1 秒内收到 EOF/reset；JSON 和提交记录都不得保存完整地址。

| 环境/事件 | 当前结果 |
| --- | --- |
| macOS 14 独立机器 | 未执行：正式发布兼容性门禁，不阻塞当前 Mac 上继续开发 |
| macOS 15 独立机器 | 未执行：正式发布兼容性门禁，不阻塞当前 Mac 上继续开发 |
| 当前 Mac：锁屏、屏保、睡眠、快速用户切换、网络路径变化 | 待人工触发；不得由自动化脚本扰动当前会话 |
| 当前 Mac：最后一个主窗口关闭、重新打开 | 通过：安装后 `ready`/`stopped` JSON 均为成功，事件为 `lastPrimaryWindowClosed`，App 内关闭延迟 0 ms；外部保持连接收到 EOF 为 0 ms；旧凭据无效；无参数重新启动拒绝且未监听 |
| 当前 Mac：焦点丢失、临时 sheet 打开/关闭 | 公开通知映射/主窗口对象过滤单元测试通过；待安装运行回执 |
| 当前 Mac：退出、唤醒、重新启动 App | 部分通过：无参数重新启动保持未接收；真实退出和唤醒事件仍待人工矩阵 |

任何应停止事件发生后，监听器或已接受连接在 1 秒后仍可到达，或旧会话凭据仍有效，都必须停止后续局域网上传实现；不得用扩大 entitlement、通配绑定或跳过事件来绕过。
