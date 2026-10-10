# mygo v0.3.7 升级来源追加

采集日期：2026-10-10。本文追加记录依赖来源，不改写 [首阶段来源笔记](mygo-native-2026-10-07.md)、[本地输入补丁来源追加](mygo-local-patch-2026-10-07.md)或[日历文案补丁来源追加](mygo-calendar-text-2026-10-10.md)；那三篇描述的是 v0.2.15 时期的点时状态。项目采用情况由 [Go 预览专题](../go-native-preview.md)维护。

## 锁定的上游

- 仓库与版本：[egoist/mygo v0.3.7](https://github.com/egoist/mygo/tree/v0.3.7)，发布于 2026-10-09。
- 对应 commit：`d7f292d6d972eb0718d4012d23527df009e6b349`。
- 原始模块摘要：`h1:hT6jjSBRqtvl3b0zReFGdGjGaNfz1IqvhnrK+Vrje94=`。
- 原始 go.mod 摘要：`h1:1sRzZ6jEhKE7iuEQXjyoXDgxyxQ1uTgMHDcDKZvoDIU=`，与 v0.2.15 相同，依赖没有变化。
- 许可仍为 MIT，原文保留在 [`third_party/mygo/LICENSE`](../../third_party/mygo/LICENSE)。

以上摘要标识下载的上游模块，**不能用来证明修改后的本地目录与原版一致**。

## 上游在 v0.2.15 之后的相关变化

v0.2.15 到 v0.3.7 之间有 11 个发布、65 个提交。与 Kinlogue 直接相关的是：

- v0.3.0 把控件构造函数的返回值由 `*ui.Element` 改为带代际检查的 `ui.Element` 值，键改由 `Context.Key` 指定，并随版本提供 `mygo migrate-ui` 源码迁移和 `mygo vet` 检查；见上游 [`docs/ui/migration.md`](https://github.com/egoist/mygo/blob/v0.3.7/docs/ui/migration.md)。
- v0.2.17 起文本输入改为每个控件一个原生输入客户端，组字与提交属于同一个撤销事务。
- v0.3.7 改变了“无固定高度的列中增长子元素”的高度规则。
- 日历文案仍只有英文；上游路线图仍把控件本地化列为完善方向。

## 仓库内可复核事实

[`third_party/mygo/`](../../third_party/mygo/) 保存 v0.3.7 的根 Go 文件、`internal/`、`transfer/`、`ui/`、`go.mod`、`go.sum` 和许可；除 [`SOURCE.md`](../../third_party/mygo/SOURCE.md)列出的两个日历文件外与上游逐字节相同。根 [`go.mod`](../../go.mod)要求 `github.com/egoist/mygo v0.3.7` 并保留唯一的 `replace`。

原输入补丁没有移植。2026-10-10 用同一组只依赖公开测试接口的用例对照了三个版本的排队输入路径：原版 v0.2.15 有三项失败，带补丁的 v0.2.15 全部通过，原版 v0.3.7 仍有三项失败（在选区上组字会立即替换选中文字、取消后不恢复且丢失重做历史、先结束标记再提交不是一步撤销）。另用上游内部测试的方式直接驱动 v0.3.7 的原生输入客户端，即 macOS 实际使用的路径：提交为一步撤销；在选区上组字同样立即替换选中文字，取消后不恢复，但一步撤销可以取回。这两组对照都在仓库外的临时副本上进行，没有进入仓库的测试。

结论是：原补丁中“提交为一步撤销”和“字段之间重置输入上下文”在 v0.3.7 的原生路径上已有对应实现；“取消组字不改动原文”是上游有意不同的设计，Kinlogue 升级后采用上游语义。无窗口事件测试不能代替真实输入法验收，v0.2.15 时期的真实拼音验收结果不适用于本版本。
