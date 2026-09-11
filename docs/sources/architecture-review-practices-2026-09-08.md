---
title: Swift 并发、流式 I/O 与嵌套签名实践复核
author: Swift project / Apple / ZIPFoundation / DICOM Standards Committee
captured: 2026-09-08
kind: pattern-reference
---

本笔记记录本次架构审查查阅的一手资料及采用范围。它不是第三方安全认证，也不把其他项目的规模、框架选择或最新版本直接当作 Kinlogue 的需求。

| 来源 | 可复核的原始结论 | 本项目采用的部分 |
| --- | --- | --- |
| Swift project：[SE-0306 Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md#actor-reentrancy) | actor 的隔离防止同时访问，但 `await` 期间其他操作仍可改变状态 | 审查 admission 计数、generation、恢复准备与 UI 发布；跨暂停点继续核验同一操作的身份 |
| Swift project：[SE-0304 Structured concurrency](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) | 取消是协作式的；非结构化任务需要明确管理生命周期 | 撤销展示结果与停止实际解密工作分别验证；取消后等待旧任务完成清理 |
| Apple：[SwiftNIO README](https://github.com/apple/swift-nio#conceptual-overview) | 阻塞一个 channel handler 会阻塞共享 event loop 上的其他连接 | 保留当前有界上传、背压和独立文件 I/O 处理；不将同步文件工作搬回 event loop |
| ZIPFoundation：[Closure based Reading and Writing](https://github.com/weichsel/ZIPFoundation#closure-based-reading-and-writing) | provider/consumer 以可控大小的块读写；支持进度和取消 | 保留现有流式 ZIP 导出；多原件 OCR 同样按原件控制同时存活的输入，不提高快照内存上限 |
| Apple：[Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues) | 分发可执行代码需要有效签名、secure timestamp 和 hardened runtime | 对内嵌 Helper 与主 App 分别签名和核验；静态回归不能替代真实 Developer ID/notarization |
| DICOM Standards Committee：[PS3.5 2024e 第 8 章](https://dicom.nema.org/medical/dicom/2024e/output/chtml/part05/chapter_8.html) | Pixel Data Value Field 使用偶数字节长度，必要的 padding 不属于像素样本 | 对受支持的 8-bit 奇数像素对象分别验证编码长度和返回样本长度 |

实现版本仍以 [`Package.swift`](../../Package.swift) 与锁文件为准。本次没有因为外部文档使用 `main` 链接就更新依赖，也没有引入新的状态管理框架、网络服务或持久化后端。具体项目结论由 [架构审查](../architecture-review-2026-09-08.md) 和各专题页维护。
