# mygo v0.6.4 升级来源追加

采集日期：2026-10-26。本文记录官方版本和适配依据；当前应用状态见 [Go 预览专题](../go-native-preview.md)。此前 [v0.4.8 来源](mygo-0.4.8-upgrade-2026-10-13.md)保留为历史。

## 锁定来源

- 官方发布：[v0.6.4](https://github.com/egoist/mygo/releases/tag/v0.6.4)，UTC 2026-10-25 07:38:35 发布；采集时 GitHub latest API 和发布页一致。
- commit：`6255ea40139d06e0762a7c4a32626148ba410478`。
- 模块摘要：`h1:VzCqZKgvXcym5cSYKoC6IkTgcVeGZquPiui/a3oE36o=`。
- go.mod 摘要：`h1:dVav53PwF2xEotjf4oA5lTY2Jp2exgzyjLhbSXhbMwE=`。
- [官方 go.mod](https://github.com/egoist/mygo/blob/v0.6.4/go.mod)要求 Go 1.27.3；应用、构建校验和 Go CI 一起锁定该工具链。purego、SQLite、age、hpke 与 x/sys 的直接或既有锁定版本保留。mygo 新引入 x/net v0.59.0 和 x/text v0.43.0；前者的 go.mod 要求 x/crypto v0.57.0，最小版本选择据此推进该间接依赖。备份协议和 age 版本未变。

以上摘要由 `go mod download -json` 返回，并写入根模块 go.sum。当前使用未修改的官方模块，无本地 replacement。MIT 许可和补丁历史入口保留在 [third_party/mygo](../../third_party/mygo/SOURCE.md)，不再包含源码副本或嵌套模块；构建产物携带实际链接模块的许可。

## 需要适配的上游变化

[v0.5.0 发布说明](https://github.com/egoist/mygo/releases/tag/v0.5.0)列出两项相关变化：

- 输入值在控件构造返回前更新；是否可编辑取决于用户操作时展示的上一帧，而不是消费输入时刚设置的 Disabled/ReadOnly。Kinlogue 保留帧末处理保存/关闭意图及组字保护，通过现有输入、撤销、导航、确认和异步保存回归核对。
- `App.Locale` 改为应用支持语言中的实际显示语言。自管文案的应用须声明 `App.SetLanguages`。官方控件已有中文资源和日历日期格式，不必继续携带本地 CalendarText 补丁。

具体实现依据：[locale.go](https://github.com/egoist/mygo/blob/v0.6.4/locale.go)、[ui/date.go](https://github.com/egoist/mygo/blob/v0.6.4/ui/date.go)、[中文资源](https://github.com/egoist/mygo/tree/v0.6.4/locales/zh-Hans)、[语言文档](https://github.com/egoist/mygo/blob/v0.6.4/docs/i18n.md)。应用声明 en/zh-Hans，导入中文控件资源，并在读取或成功保存资料库语言设置后同步 App.SetLocale。“跟随系统”传空字符串清除覆盖；上游在 macOS 使用全局语言偏好解析系统语言，避免先前应用语言覆盖冒充系统选择。

日期栏使用用户区域格式，星期起始日也由区域决定。日期仍作为 `YYYY-MM-DD` 保存；新显示不触发资料迁移。旧输入补丁仍不恢复；未启用上游新增的终端、模型、音频、Secrets、更新器或网页能力。

## 构建与验证边界

当前构建拒绝所有 module replacement，当前包要求 mygo v0.6.4 / Go 1.27.3。`--previous` 额外接受已知 mygo v0.2.15、v0.3.7、v0.4.8 和 Go 1.27.1/1.27.2，仅用于保留旧包；旧本地替换必须仍是对应 mygo 的 `./third_party/mygo`，不能被当前 v0.6.4 使用。

[`upgrade_test.go`](../../packaging/go-preview/upgrade_test.go)覆盖旧包两种依赖形态、原二进制保留、官方许可证，以及当前包拒绝旧版本/本地替换/缺少备份加密依赖。官方依赖负例先在旧校验器上出现预期失败，再修改校验器使其通过。[日历回归](../../internal/desktop/fields_test.go)覆盖英文、中文选日、跟随系统，以及语言切换不改存储日期。

实际命令与结果见 [验证表](../go-native-preview.md#本轮验证状态)和 [日志](../log.md)。合成截图、自动事件与构建成功不能替代真实输入法、VoiceOver、实际手机或分发验收。

上游 [TestDiffFrameAllocs](https://github.com/egoist/mygo/blob/v0.6.4/ui/bench_test.go)测量 steady/warm 帧的分配次数，上限为 2。当前 Mac 非 race 为 2/2；完整 race 为 3/4，导致该额外验证失败，但未报告数据竞争。未调整官方测试。该测试在 short 模式跳过，另外两个随机布局/绘制测试缩减种子数；因此 short race 与完整 race 的结果分开记录。
