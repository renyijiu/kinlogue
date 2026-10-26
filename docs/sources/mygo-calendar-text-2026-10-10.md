# mygo 本地日历文案补丁来源追加

采集日期：2026-10-10。本文追加记录依赖来源，不改写 [mygo 本地输入补丁来源追加](mygo-local-patch-2026-10-07.md)；锁定的上游版本、commit、摘要和许可与该笔记相同。项目采用情况由 [Go 预览专题](../go-native-preview.md)维护。

## 仓库内可复核事实

上游 v0.2.15 的 [`ui/date.go`](https://github.com/renyijiu/kinlogue/blob/bdb25e1ebf650be880621aea1c100b57d87afce9/third_party/mygo/ui/date.go)把日历的月份标题、星期表头、读屏用的日期名称和上/下个月按钮名称写死为英文；[上游路线图](https://github.com/egoist/mygo/issues/105)仍把控件本地化列为完善方向。Kinlogue 的界面语言为简体中文时，日期选择器因此显示英文月份和星期。

本地补丁新增 `CalendarText` 与 `SetCalendarText`，由应用提供这些文案；未调用时保持上游英文文案。精确修改范围以 [`SOURCE.md`](../../third_party/mygo/SOURCE.md)为准，回归见 [`ui/datetime_test.go`](https://github.com/renyijiu/kinlogue/blob/bdb25e1ebf650be880621aea1c100b57d87afce9/third_party/mygo/ui/datetime_test.go)。Kinlogue 侧的文案在 [`internal/desktop/strings.go`](../../internal/desktop/strings.go)，由界面每帧按当前语言设置。

这是本地修改，不是上游发布内容。日期输入框内的 `2006-01-02` 数字格式和从周一开始的星期顺序没有改动；读屏对中文日期名称的朗读没有人工验收。

2026-10-26 导航追加：上述历史源码链接固定到最后保留补丁的提交；当前已由官方本地化替代，见 [v0.6.4 升级来源](mygo-0.6.4-upgrade-2026-10-26.md)。
