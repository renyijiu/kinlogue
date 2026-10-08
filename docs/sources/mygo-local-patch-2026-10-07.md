# mygo 本地输入补丁来源追加

采集日期：2026-10-07。本文追加记录依赖来源，不改写 [首阶段来源笔记](mygo-native-2026-10-07.md)，也不充当 Kinlogue 功能或系统输入法验收结论。项目采用情况由 [Go 预览专题](../go-native-preview.md)维护。

## 锁定的上游

- 仓库与版本：[egoist/mygo v0.2.15](https://github.com/egoist/mygo/tree/v0.2.15)。
- 对应 commit：`da84fc54dfc532704f60d5a066c0d1025d4dd282`。
- 原始模块摘要：`h1:I+JbmjJnAXD1XbPRM0qhEHKuVMgdKvV1yNlprPldVXk=`。
- 原始 go.mod 摘要：`h1:1sRzZ6jEhKE7iuEQXjyoXDgxyxQ1uTgMHDcDKZvoDIU=`。
- 许可为 MIT，原文保留在 [`third_party/mygo/LICENSE`](../../third_party/mygo/LICENSE)。

以上摘要标识下载的上游模块，**不能用来证明修改后的本地目录与原版一致**。

## 仓库内可复核事实

根 [`go.mod`](../../go.mod)仍要求 `github.com/egoist/mygo v0.2.15`，通过一个 `replace` 指向 `third_party/mygo`。目录保存运行时/UI 所需根 Go 文件、`internal/`、`ui/`、平台实现、嵌入资源和测试，不复制上游 CLI、网站、示例或 JavaScript 包。

本地补丁针对已定位的预编辑取消丢失选区文字、提交/撤销边界和跨输入状态处理。精确修改范围以随源码维护的 [`SOURCE.md`](../../third_party/mygo/SOURCE.md)为准；补丁代码不是上游发布内容，文档不能将本地修正归于原版 v0.2.15。

输入回归在 [`ui/editor_regression_test.go`](../../third_party/mygo/ui/editor_regression_test.go)使用合成文字及事件；根模块测试不会进入嵌套模块，必须从 `third_party/mygo` 单独运行 UI 测试、race 和 vet。[独立 Go workflow](../../.github/workflows/go-ci.yml)显式包含嵌套 UI 测试和 vet；真实输入法、焦点切换与 VoiceOver 仍需平台人工验收。

更新上游版本时，应按 `SOURCE.md` 比对本地修改、重跑嵌套和应用测试，并重新核对生产包构建信息与许可证；不得只删除 `replace` 就假定相同行为已由上游提供。
