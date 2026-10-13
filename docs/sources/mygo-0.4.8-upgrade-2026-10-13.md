# mygo v0.4.8 升级来源追加

采集日期：2026-10-13。本文记录本次锁定的外部版本及源码对照，不改写 [v0.3.7 来源追加](mygo-0.3.7-upgrade-2026-10-10.md) 和更早的输入/日历补丁记录。项目当前采用和验证状态见 [Go 预览专题](../go-native-preview.md)。

## 锁定来源

- 官方发布：[v0.4.8](https://github.com/egoist/mygo/releases/tag/v0.4.8)，UTC 2026-10-12 21:54:51 发布（新加坡时间 2026-10-13）。采集时 GitHub latest API 与 tag 一致。
- commit：`c0e1068027faf8b14777c9cb925c937ef34ac2bb`。
- 原始模块摘要：`h1:NpzFFiv8L4uXhkriknAehoucN//gtCtnGgr/DzQxZIw=`。
- 原始 go.mod 摘要：`h1:+B7ZTBwVfa/nL/6+o6Vm8xBFYwJoFCg4VJbY9k6T0E8=`。
- 许可为 MIT，保留在 [`third_party/mygo/LICENSE`](../../third_party/mygo/LICENSE)。以上摘要标识上游模块，不标识打过补丁的本地目录。

## 上游变化及本项目取舍

[v0.4.0 发布说明](https://github.com/egoist/mygo/releases/tag/v0.4.0) 明确改变 `AlertDialog` 的 Escape 返回值为 `AlertDismissed`，并调整 CLI 分发文件名。Kinlogue 使用自己的 `Modal` 流程和签名包脚本，不使用 `AlertDialog` 或 CLI 分发命名。现有取消、未保存导航和备份恢复回归仍需要通过，不能仅据 API 编译成功判断兼容。

v0.4.8 新增 `ui/editor` 编辑器/差异查看器和共享 rope 文本实现；Kinlogue 没有接入新编辑器、音频或嵌入网页功能。运行时源码子集保留根 Go 文件、`internal/`、`transfer/`、`audio/`、`ui/`、模块文件和许可；不加入 CLI、示例、网站、插件或 JavaScript 包。`audio/` 是新版运行时依赖所需的上游包，不代表应用新增音频能力。

原版 v0.3.7 与 v0.4.8 的 `ui/date.go`、`ui/datetime_test.go` 逐字节一致，因此两文件日历补丁可以原样应用；为满足现有格式门禁，另对上游 `internal/gpu/metal/metal.go` 的四个字段执行纯空白对齐；除此之外其余保留文件与 v0.4.8 逐字节相同。范围见 [`SOURCE.md`](../../third_party/mygo/SOURCE.md)。应用继续采用上一轮接受的上游组字语义，不移植 v0.2.15 输入补丁；旧版真实输入法验收不能继承。

根模块要求 `v0.4.8` 并保留唯一相对路径 `replace`；Go 1.27.2 与其他直接依赖不变。上游模块新增的音频解码依赖保持其原始锁定版本，应用并未导入这些可选解码器。

## 打包边界与验证入口

[`build-go-preview.sh`](../../scripts/build-go-preview.sh) 和 [`verify-go-preview.sh`](../../scripts/verify-go-preview.sh) 要求新包链接 v0.4.8；`--previous` 仅额外接受已知 v0.2.15/v0.3.7，以保留此前构建的旧包。旧包保留不等于资料库降级，未知版本不被放行。

[`upgrade_test.go`](../../packaging/go-preview/upgrade_test.go) 覆盖两种旧版本的上游/本地替换形态及旧二进制逐字节保留；新增负例证明 v0.3.7 不能作为当前包通过校验。该负例在更新校验器之前失败，更新后通过。

完整命令、实际结果及未执行门禁记录在 [Go 预览验证表](../go-native-preview.md#本轮验证状态) 和 [日志](../log.md)，不把本文的来源说明当作真实输入法或发布验收证据。
