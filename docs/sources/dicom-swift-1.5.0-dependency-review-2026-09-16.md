---
title: DICOM-Swift 1.5.0 依赖与许可证来源核对
author: ThalesMMS / Raster-Lab
source_url: https://github.com/ThalesMMS/DICOM-Swift/tree/8f3605a33ed070160b4e023eacd87f32eae8e913
captured: 2026-09-16
kind: external-spec
---

## 固定来源

| 包 | 版本 / revision | 许可证依据 |
| --- | --- | --- |
| DICOM-Swift | 1.5.0 / `8f3605a33ed070160b4e023eacd87f32eae8e913` | [LICENSE](https://github.com/ThalesMMS/DICOM-Swift/blob/8f3605a33ed070160b4e023eacd87f32eae8e913/LICENSE)，Apache-2.0 |
| J2KSwift | 11.0.2 / `b1949084eeedaafb40bff8f1745bbab19e4bc36d` | [LICENSE](https://github.com/Raster-Lab/J2KSwift/blob/b1949084eeedaafb40bff8f1745bbab19e4bc36d/LICENSE)，MIT |
| JLSwift | 0.9.0 / `53d902fec538e5c12f4ed9864c026be5da66b5dd` | 标签没有许可证；下述后续许可提交的生产源码树完全相同 |
| JXLSwift | 1.4.0 / `760697a54dd253da8e8466c3fd09ecf2c2d89aec` | [LICENSE](https://github.com/Raster-Lab/JXLSwift/blob/760697a54dd253da8e8466c3fd09ecf2c2d89aec/LICENSE)，MIT |
| CompressionFamily | 1.0.1 / `36ef2c94e28a3b74ba395ce6397ba2ae7b041c5e` | [LICENSE](https://github.com/Raster-Lab/CompressionFamily/blob/36ef2c94e28a3b74ba395ce6397ba2ae7b041c5e/LICENSE) 与 NOTICE，Apache-2.0 |

JLSwift 上游许可提交 [`7020e28d`](https://github.com/Raster-Lab/JLSwift/commit/7020e28dcd4fac24cb31a13e6d2a00aa38ac6e73) 新增 Apache-2.0 LICENSE、NOTICE 并明确 README 的授权范围。该提交与 0.9.0 的 `Sources` Git tree 都是 `375e173ad6247e732c4fa1ffde599bf8a1330426`；因此本轮使用相同生产源码对应的显式许可依据，不把 GitHub 当前 license 标签冒充旧版本证据。上游 CharLS 测试夹具另有 BSD-3-Clause 授权；这些夹具未进入 Kinlogue 构建或包。

J2KSwift/JXLSwift LICENSE SHA-256 均为 `5a4885c460e4b7638ce71ecd97d2d98a399c68b8a3b4e190a5b24371d2253277`。CompressionFamily LICENSE 与 JLSwift 上述许可提交的 LICENSE SHA-256 均为 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`。署名与适用完整许可证归入 [`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md)。

## Manifest 事实

固定版本 DICOM-Swift 要求 Swift tools 6.2、macOS 26；`DicomCore` 在 macOS 依赖 ZIPFoundation、J2KCore、J2KCodec、JPEGLS 和 JXLSwift。J2KCodec 进一步依赖 J2KMetal、J2KCodecNEON 与 CompressionFamily；J2KMetal 复制上游预编译的 `default.metallib`。JLSwift/JXLSwift 的 ArgumentParser 是各自 CLI 使用，不代表 Kinlogue 启用了这些 CLI。

J2KSwift 的 JPIP、CLI、测试 App 与 daemon 是另外的 products/targets，不在所选 DicomCore 依赖闭包中。DICOM-Swift 自身仍包含网络相关 API，因此最终安全证据必须来自主进程链接检查、Helper 无网络 entitlement 与真实运行时 socket 检查，不能由“未导入网络产品”推定无网络能力。

## 本项目采用与未采用

使用锁定版本更新底层依赖和构建资源；保持现有 classic single-frame、Explicit VR Little Endian、灰度 MR 范围，不启用压缩、多帧、JPIP/PACS、远程服务或 daemon。项目结论、实测成本与验证记录见 [`dicom.md`](../dicom.md) 和 [`log.md`](../log.md)，本来源笔记不把上游功能或测试结果计为 Kinlogue 已验证能力。
