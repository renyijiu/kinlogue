---
title: Swift 与 macOS App 工程实践复核
author: Swift.org / Apple
source_url: https://www.swift.org/documentation/api-design-guidelines/
captured: 2026-08-19
kind: pattern-reference
---

## 来源摘要

本次全仓审计复核了以下官方资料：

- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)：以调用点清晰度、角色命名和最小必要 API 为中心设计接口。
- [Swift Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/) 与 [Structured Concurrency proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md)：让异步任务具有明确生命周期，并用 actor/`Sendable` 表达隔离边界。
- [Managing model data in your app](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)：保持单一事实来源，让界面从可观察语义状态派生显示。
- [Improving your app's performance](https://developer.apple.com/documentation/Xcode/improving-your-app-s-performance) 与 [Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes)：先定位真实重复工作，再缩减不必要的 I/O 和计算。
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) 与 [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)：保持最小 entitlement，并通过用户选择与系统授权边界访问文件。

## 本项目采用的部分

- package 只声明当前消费者需要的 App product；Core、Platform 和辅助 executable 作为内部 target 保持清晰依赖方向。
- 长生命周期 ViewModel 保存语义错误状态与类型化字段标识，显示时再按当前语言解析。
- Vault 启动复用已经完成全对象验证的 catalog，不再丢弃结果后重复解析；PDF OCR 在一次 extraction 中复用不可变语言尝试顺序。
- 删除已完成使命且与当前生产路径重复的可行性 host、entitlement 和第二套同构 CI，同时保留历史证据。

## 未采用或仍待验证的部分

- 没有仅为追随新 API 而整体迁移 Observation；当前 `ObservableObject` 边界已有测试且没有证明它是性能瓶颈。
- 没有并行化 DICOM decode 或移除 ZIP 双重校验；现有顺序和复核属于资源预算、崩溃隔离与原子发布保证。
- PDF viewer 的全页 metadata 预取和 review snapshot 合并仍可在后续以独立测量与回归推进。
