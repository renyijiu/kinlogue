# Kinlogue 局域网上传验收矩阵

本矩阵只使用生成的图片、PDF 和文字，不使用真实病历。网络地址、验证码、文件名和上传内容不进入版本库或验收报告。自动化通过不能代替未执行的真实设备与系统版本验证。

## 最近完整 LAN 候选证据

- 版本：`0.5.0`（build `5`）
- LAN 产品协议：无分组文件队列
- 签名：ad-hoc，本机测试安装；未执行 Developer ID 签名或 notarization
- 安装验收身份：使用与正式包内容一致的 executable；仅随机隔离的测试身份额外具有 `network.client`，用于在同一进程内回连其 loopback listener。正式包仍只有 `network.server`。
- 当前 Mac：macOS `26.6`，Xcode `26.6`（build `17F113`）
- 正式包哈希：每次 ad-hoc 签名构建后以未纳入版本库的 `dist/verification-report.json` 为权威来源；验收与最终安装必须使用同一次报告中的哈希，不能沿用历史构建值。
- 本矩阵绑定干净源码 revision `10d58e6ee4949c85e297e4cc8b5757eeecd481ea`；正式 App content-manifest SHA-256 为 `4745f6955d048f39b70e92fff8dd60f5f64263f4e089a2c4a8423f02b5c04c28`，正式 executable SHA-256 为 `c5c685976b15c9dbd4061df629071e3acf06660b2d3371100efa9baa705909ea`。总状态见 [当前候选证据](current-release.md)。
- 隔离验收身份因额外 `network.client` entitlement 重新 ad-hoc 签名，其 probe executable SHA-256 为 `39b02a9ae8d1d3971a744ade84eba2fa2c979fec546bac3a6c84e7329126a026`；该值不能替代正式包 executable 哈希。

## 自动与本机验收

| 环境 | 场景 | 状态 | 证据/说明 |
| --- | --- | --- | --- |
| 当前 Mac | 单元、存储、协议、并发、去重、OCR、导出与 UI 模型完整测试 | 通过 | 当前测试清单与自动化总状态由 [当前候选证据](current-release.md) 唯一维护。LAN lifecycle 的地址解析、receiver start、archive callback 和 multi-delete 交错已有定向回归；受限运行中的 socket bind 与 deadline 进程组探测失败来自外层沙箱，不计为产品失败 |
| 当前 Mac | 源码隐私扫描与 clean-source 构建前置条件 | 通过 | `scripts/privacy-guard.sh` 与 `scripts/verify-app.sh --require-clean-source` |
| 当前 Mac | 正式 bundle、入站 entitlement、用途说明、资源与签名 | 通过 | 2026-08-19 从干净 revision `10d58e6` 运行完整 `scripts/verify-app.sh --require-clean-source`；release build、App/XPC bundle、ad-hoc 签名、entitlement allow-list、资源、依赖锁和生产身份检查均通过 |
| 当前 Mac | 隔离身份安装、真实 receiver、重启、强制退出恢复与清理 | 通过 | 2026-08-19 运行 `scripts/run-acceptance.sh`：4 个合成成员、96 条记录/附件；生产 executable probe、流式/中断上传、去重、进程重启、强制终止恢复、canary 扫描和清理均通过，扫描命中为 0；随机安装 App 已按 identity 清理 |
| 当前 Mac | 正式 App 安装与 Launch Services 启动 | 通过 | 已先正常退出旧进程并保留可恢复的时间戳 App 备份；正式 `com.kinlogue.mac` 安装副本与报告绑定 bundle 逐字节一致，strict deep codesign 与 App/Helper executable 哈希复核通过，并由 Launch Services 成功启动；没有移动或重建 Vault |

## 正式发布门禁

| Mac / 客户端 | 必测场景 | 状态 |
| --- | --- | --- |
| macOS 14 + 指定版本 iOS Safari | 地址/二维码、配对、重复追加、多文件独立状态、本地重复选择、重试、Mac 队列合并/多选归档、停止与锁屏生命周期 | 未验证；正式发布前需要真实设备 |
| macOS 14 + 指定版本 Android Chrome | 同上 | 未验证；正式发布前需要真实设备 |
| macOS 15 + 指定版本 iOS Safari | 同上 | 未验证；正式发布前需要真实设备 |
| macOS 15 + 指定版本 Android Chrome | 同上 | 未验证；正式发布前需要真实设备 |

正式设备行还必须记录执行日期、操作者、准确的系统/浏览器版本、网络与防火墙/客户端隔离条件、候选 executable 哈希、结果与失败分类。任何未执行行保持“未验证”，不根据当前 Mac 或自动化结果推断。
