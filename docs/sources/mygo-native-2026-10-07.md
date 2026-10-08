---
title: mygo 原生界面与 Go 本机存储来源
author: egoist / purego contributors / modernc.org
captured: 2026-10-07
kind: pattern-reference
---

# mygo 原生界面与 Go 本机存储来源

本笔记记录本次 Go 重写使用的一手来源及版本定位。项目实现和执行结果由 [Go 预览专题](../go-native-preview.md)维护，不把上游自述或路线图当作 Kinlogue 的验收结果。

## 来源

| 来源 | 版本或定位 | 核实内容 |
| --- | --- | --- |
| [egoist/mygo README](https://github.com/egoist/mygo/tree/v0.2.15) | `v0.2.15`，commit `da84fc54dfc532704f60d5a066c0d1025d4dd282` | 同时提供系统 WebView 和 Go native UI；后者由 mygo 在 GPU 上绘制，支持 Go 控件和系统窗口/对话框等 API。不是 AppKit 控件的逐项绑定。 |
| [mygo native UI roadmap #105](https://github.com/egoist/mygo/issues/105) | 2026-10-06 创建，基于 `da84fc54dfc5` 评估；2026-10-07 读取 | 上游列出文本/集合无障碍、locale 控件、原生视图嵌入和 PDF 等专用预览的改进方向；路线图不承诺 SwiftUI/WinUI 功能对等。 |
| [ebitengine/purego](https://github.com/ebitengine/purego/tree/v0.11.1) | `v0.11.1` | Go 调用系统动态库与 Objective-C 的桥接能力；本项目只调用公开 macOS API。 |
| [modernc.org/sqlite](https://pkg.go.dev/modernc.org/sqlite@v1.60.1) | `v1.60.1` | 不依赖 cgo 的 SQLite 驱动；本项目固定模块和传递依赖，用真实数据库测试确认门、重启和文件约束。 |

调研曾查看 mygo 后续主干 commit `869768d02d9154d5b2f9f3a6ebb39767f8f96983`；本阶段实现锁定的仍是 `v0.2.15`。主干新增能力和性能修订不能写成当前依赖已具备的行为。

## 本项目采用的部分

- 采用 mygo 的 Go native UI 路径，不使用 HTML、JavaScript 或 WebView 来绘制当前业务界面。
- 采用 purego 调用 Apple 本机文档和识别框架，保持生产 `CGO_ENABLED=0`；这不使 Apple API 成为跨平台能力。
- 采用 SQLite 保存新资料格式，原件作为不可变文件保存；应用层自己维护确认门、成员隔离和生命周期。

## 未采用或仍待验证

未启用 mygo 自动更新、网络服务、WebView 业务界面或上游开发 inspector。没有把上游“支持 screen reader”概括为 Kinlogue 已通过 VoiceOver，也没有把上游跨平台构建能力扩展成 Apple OCR 已支持其他系统。中文输入、辅助技术、长时间运行、实际内存和不同 macOS 版本仍需应用层验收。
