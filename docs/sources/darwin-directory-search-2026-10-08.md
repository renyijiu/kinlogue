---
title: Darwin 目录搜索 descriptor 的公开定义
author: Apple
source_url: https://raw.githubusercontent.com/apple-oss-distributions/xnu/xnu-10002.1.13/bsd/sys/fcntl.h
captured: 2026-10-08
kind: external-spec
---

## 来源摘要

Apple 公开的 [XNU `xnu-10002.1.13` 头文件](https://raw.githubusercontent.com/apple-oss-distributions/xnu/xnu-10002.1.13/bsd/sys/fcntl.h)在 `__DARWIN_C_LEVEL >= 200809L` 区域定义 `O_EXEC = 0x40000000`，并定义 `O_SEARCH = O_EXEC | O_DIRECTORY`，用途是以搜索权限打开目录。当前开发机 SDK 的公开 `sys/fcntl.h` 中也存在相同定义。

这是公开头文件中的标志，不是私有 macOS API。头文件定义本身不证明具体 App Sandbox 授权、文件系统持久性或所有系统版本的行为。

## 本项目采用的部分

[`openExportDirectory`](../../internal/macos/export_darwin.go)用此标志固定目标父目录，并保留 close-on-exec、禁止跟随链接和后续身份校验。锁定的 Go `syscall` / `x/sys` 未暴露该常量，因此局部写出公开数值并说明来源。目的只是不额外请求枚举父目录的权限，不扩大应用 entitlement。

采用决策来自真实签名沙盒包中导出失败的复现；禁止目录读取的[平台回归](../../internal/macos/export_darwin_test.go)在旧实现失败、修正后通过。最终包经保存面板新建 ZIP 的执行结果和准确范围见 [Go 预览专题](../go-native-preview.md)及[实现日志](../log.md)，不将项目结果混同为 Apple 的承诺。

## 未采用或仍待验证的部分

不使用私有宏，不请求整个目标目录授权，也不把 `O_SEARCH` 当作跨平台文件能力。实际覆盖、File Provider、其他 macOS/Intel 及断电场景仍须各自验证；本次结果不提供这些保证。
