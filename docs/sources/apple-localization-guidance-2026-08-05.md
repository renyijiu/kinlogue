---
title: Apple app and Swift package localization guidance
author: Apple
source_url: https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog
captured: 2026-08-05
kind: external-spec
---

## 来源摘要

本笔记记录本次 macOS 双语改造采用的 Apple 官方资料入口：

- [Localizing and varying text with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)：以 String Catalog 管理可翻译字符串、插值和复数变化。
- [Preparing your app's text for translation](https://developer.apple.com/documentation/xcode/preparing-your-apps-text-for-translation)：区分用户可见文本与不应翻译的数据，并为翻译保留上下文。
- [Preparing your interface for localization](https://developer.apple.com/documentation/xcode/preparing-your-interface-for-localization)：使用不同语言和本地化测试配置检查布局与遗漏文案。
- [Localizing package resources](https://developer.apple.com/documentation/xcode/localizing-package-resources)：Swift package 声明默认语言，并从 package resource bundle 读取本地化资源。
- [Bundling resources with a Swift package](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package)：通过 target resources 和 `Bundle.module` 访问 SwiftPM 资源。
- [`LocalizedStringResource` initializer](https://developer.apple.com/documentation/foundation/localizedstringresource/init(_:defaultvalue:table:locale:bundle:comment:)-1apqa)：使用类型化插值、locale 和 bundle 构造本地化资源。

## 本项目采用的部分

- 以简体中文作为 source/development localization，以英文作为当前唯一附加翻译。
- 用户可见静态文案、动态插值、错误和无障碍标签进入 `Localizable.xcstrings`；复数由 catalog variation 表达。
- `Info.plist` 的应用名和局域网用途说明使用各语言的 `InfoPlist.strings`。
- 运行时优先遵循 main app bundle 的 preferred localization；SwiftPM/test 环境回退到 `Bundle.module`。
- 翻译目录由脚本编译并在 release bundle 中做精确 allow-list 验证。

## 未采用或仍待验证的部分

- 当前没有第三种语言、右到左语言或应用内语言选择器。
- 本次未把 LAN 手机浏览器页面纳入 macOS App 的语言协商；该页面仍是当前会话内的独立中文资源。
- 真实 macOS 14/15 上的英文布局、键盘和 VoiceOver 人工检查仍需执行。
