# DICOM-Swift 1.3.3 release 边界探针（2026-08-07）

本页记录 Kinlogue DICOM MRI Viewer 计划 U1 的公开依赖可行性证据。它只使用无身份的最小 SwiftPM consumer，不读取私有 MRI 样本，也不代表 Kinlogue 当前已经集成 DICOM。

## 探针输入

- 上游依赖：[DICOM-Swift 1.3.3](https://github.com/ThalesMMS/DICOM-Swift/releases/tag/1.3.3)。
- SwiftPM 请求：`exact: "1.3.3"`，consumer 只依赖 `DicomCore` product，并只调用 `DCMDecoder(contentsOf:)`。
- tag object：`022fb4feacc1a9553f46b7c45e1993f744284c43`。
- 实际解析源码 revision：`9ae0851e134af274651b646519b8a7aaeee05f05`。
- 传递依赖：ZIPFoundation `0.9.20` / `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`；swift-argument-parser `1.8.2` / `6a52f3251125d74daf04fcbd5e6f08a75d074382`。
- 证据环境：macOS 26.6 arm64、Apple Swift 6.3.3；该环境只证明本次 release 产物，不替代 macOS 14/15 兼容性矩阵。

## 可复核结果

最小 consumer 的 `swift build -c release` 成功，并生成 arm64 Mach-O executable。对最终 executable 运行 `otool -L`，可见 `Network.framework` 与 `CFNetwork.framework`。运行 `nm -nm`，最终可执行文件仍包含以下实现或类型元数据：

- `DicomStorageSCPServer.start` 与 `NWListener` imports；
- `DicomDIMSEMessageReader` 与 `DicomDIMSEAssociationPool`；
- `URLSessionDicomWebHTTPTransport`；
- `DicomWebServer`。

因此，哪怕 consumer 没有调用网络 API，DICOM-Swift 1.3.3 的同一 `DicomCore` target 仍会把 SCP、DIMSE 和 DICOMweb 实现带入最终 release executable。这直接触发 Viewer 计划 R22/KTD2 的“production executable 不得包含这些实现”停止条件。

## 当前结论与边界

- 未向 `Package.swift`、生产 target、adapter、测试或 App bundle 写入 DICOM-Swift；没有留下半接入代码。
- 在明确选择“隔离 helper / 最小审计 package”或修改 executable 边界之前，不继续 catalog v3 与 Viewer 实现。
- 本次证据证明的是链接产物边界失败；没有继续运行 socket、parser mutation 或日志 canary，因为这些较晚门禁无法推翻已经触发的停止条件。

## 后续决策记录

同日用户选择继续直接引用官方 exact 1.3.3，但只把 `DicomCore` 链接进单独签名、无网络 entitlement、无 Vault-root 权限的 XPC Helper；主 App 只保留有界 IPC client。该决策不改变上述探针事实，实施与新门禁以 [`../plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md`](../plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md) 的 KTD1–KTD2 为准。
