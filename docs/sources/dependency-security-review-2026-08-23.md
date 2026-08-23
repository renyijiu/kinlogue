---
title: Public dependency and GitHub security review
author: Kinlogue maintainers
source_url: https://github.com/advisories?query=type%3Areviewed+ecosystem%3Aswift
captured: 2026-08-23
kind: external-spec
---

## 来源摘要

- GitHub Advisory Database 的 SwiftNIO 公告 `GHSA-r3rc-9hpw-54v9`、`GHSA-rj37-6j9x-74q6` 与 `GHSA-cq87-8r7h-962v` 均把 `2.100.0` 列为修复版本；本仓库锁定 `2.101.3`。
- ZIPFoundation `0.9.18` release notes 记录 symlink containment 与 path escape 修复；本仓库锁定 `0.9.20`。
- GitHub 官方 Dependabot ecosystem 表列出 Swift v5/v6 的 `package-ecosystem: swift`；CodeQL compiled-language 文档说明 Swift 分析需要 macOS runner。
- CodeQL Action `v4.36.0` 的 annotated tag peel 到 commit `7211b7c8077ea37d8641b6271f6a365a22a5fbfa`，仓库 workflow 固定该完整 SHA。

复核入口：

- <https://github.com/advisories/GHSA-r3rc-9hpw-54v9>
- <https://github.com/advisories/GHSA-rj37-6j9x-74q6>
- <https://github.com/advisories/GHSA-cq87-8r7h-962v>
- <https://github.com/weichsel/ZIPFoundation/releases/tag/0.9.18>
- <https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories>
- <https://docs.github.com/en/code-security/reference/code-scanning/codeql/build-options-for-compiled-languages>
- <https://github.com/github/codeql-action/releases/tag/v4.36.0>

## 本项目采用的部分

- `Package.swift` 使用 exact version，`Package.resolved` 固定对应 commit；release 构建只允许 resolved versions。
- Dependabot 同时覆盖 SwiftPM git dependency 与 GitHub Actions；CodeQL 以最小权限在固定 macOS runner 手工构建 Swift。
- 依赖更新仍需通过 Kinlogue 自己的 untrusted-input、XPC、资源、隐私和 bundle 门禁，不能仅凭上游 release note 自动合并。

## 未采用或仍待验证的部分

- 旧私有仓库在本次检查时没有启用 Dependabot alerts 或 code scanning，因此不能把旧仓库 API 的 403 解释为“零漏洞”。新公开仓库创建后仍需启用并观察真实远端运行。
- 公共查询未发现 DICOM-Swift 1.3.3 的 GitHub reviewed advisory，但这不是独立安全审计、模糊测试覆盖或安全保证。Kinlogue 继续把解码放在受限 XPC 中。
- Kinlogue 的 checkpoint 格式、密钥分层和恢复事务没有独立密码学/安全审计；当前结论只来自源码、测试和公开原语文档。
