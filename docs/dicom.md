# DICOM 导入与 Viewer

本页是当前 DICOM 产品定位、导入、索引、XPC 解码、Viewer 生命周期和支持边界的单一专题页。存储页只拥有 Vault 通用原子性和 DICOM 图闭合约束，架构页只拥有跨 target 隔离，设计系统只拥有视觉与交互规则。

## 产品定位

DICOM 是 Kinlogue 核心健康记录流程的受限辅助能力：让用户保存检查原件，并在复诊前查看受支持的二维灰度 MR Series。它不是诊断工具、通用影像工作站、PACS 客户端或产品主线转向。

App 不解释像素、不生成测量或医学结论。DICOM 自由文本和像素不进入报告 OCR、搜索或比较；时间线只显示用户确认的成员、检查日期和检查级摘要。

## 用户流程

1. 用户从独立入口选择一个文件夹；报告/OCR 文件入口不接受 DICOM。
2. App 以不含文件名、路径或 UID 的聚合状态扫描和复制源文件，源目录不被修改。
3. 一个检查必须完整通过 allowlist、资源、分组、索引和图闭合校验，才原子发布为 `needsReview`。
4. 用户明确选择活跃家庭成员和检查日期后，检查进入成员时间线和独立影像库。
5. 已确认且受支持的 Series 可在独立 macOS 窗口查看；删除只影响 App 管理的副本。

## 导入与持久化

`DICOMFolderScanner` 使用 descriptor-relative、`O_NOFOLLOW` 的有界遍历，把候选复制到同卷 opaque staging。扫描、索引和发布共用 Vault mutation lease；ownership receipt 在第一份 staged bytes 前持久化。对象与 index 先发布，`library.json` 最后原子替换。

取消必须等待真实事务终态。manifest commit 之前可以返回取消；之后只有在 catalog 中证明相同 study ID、fingerprint、index 和附件图已提交时才返回成功。无法证明提交时，cleanup 或 commit 错误保持失败，不能把可能已提交的检查误报为取消。

每次 reopen 都实读并验证 index 版本、study ID、Series/instance 顺序、attachment 集合、fingerprint 和 UID digest 冲突。缺失、digest/length 不符、图不闭合或未知版本都 fail closed，不暴露部分检查。更完整的布局和恢复规则见 [`storage.md`](storage.md)。

## XPC 解码边界

主 App、Core 和 Platform 不链接 `DicomCore`。主进程先有界校验 Part 10 envelope，只向独立签名的 sandbox XPC Helper 传只读 descriptor 和小型请求。Helper 没有网络、用户文件或 Vault-root entitlement；它复制到私有临时文件后解码，只返回有界的单帧 raw sample 与几何 DTO。

同步解析受硬 watchdog 约束。crash、hang、连接中断和无效/超大 reply 都映射为固定失败；生产路径没有 in-process decoder fallback。构建和签名证据见 [XPC 构建记录](sources/2026-08-07-dicom-xpc-xcode-build-evidence.md)。

## Slice service 与 Viewer 生命周期

`DICOMSliceService` 只能从 Vault 验证过的 opaque session descriptor 按需读取一个 instance。进程级内存预算、canonical LRU 和串行 foreground scheduler 限制同时存活的 raw/canonical/render bytes；像素不写入 Vault、日志、持久预览或截图。

Viewer 的 metadata、decode 和 canvas publish 都带 generation/session/render identity。Series 或切片切换先清旧像素；迟到结果不能重绘。删除 study、外部 refresh 移除或 whole-Vault lifecycle 时，App 先清空并关闭相关 Viewer，再发布新 snapshot。内存压力清理全局 cache，窗口关闭清理对应 session。

## 当前支持范围

当前受支持的可查看对象是 classic single-frame、Explicit VR Little Endian、灰度 MR，包含仓库矩阵明确覆盖的 stored sample、rescale、MONOCHROME1/2、窗宽窗位和 geometry/Instance Number/content fallback 排序。

以下能力不支持：

- 压缩 transfer syntax、enhanced/multiframe 或彩色影像；
- 诊断解释、测量、MPR/MIP、三维重建或动态影像时间轴；
- PACS、DICOMweb、远程查询或发送；
- 持久缩略图、截图、Viewer 自动导出或 OCR；
- 未列入 [DICOM 验收矩阵](acceptance/dicom-mri-viewer-matrix.md) 的兼容性声明。

允许的惰性 SR/encapsulated document 只保留原件，不解析自由文本、不 OCR、不进入搜索。原始 UID 只在导入期间短暂参与分组/冲突检查，持久层只保存 vault-local digest。

## 当前版本边界

当前实现只接受 ordering policy v2，并在 reopen 时验证已持久化顺序和 Series geometry/layout；policy v1 或其他版本均失败关闭，不会被静默重排或改写。Vault 同样只接受 catalog v3。除恢复先前由用户明确发起、且已写入有效 durable deletion receipt 的整库删除外，未知版本、未知非空目录和损坏图继续非破坏性失败关闭；旧开发资料需要由用户在仓库外自行导出或重置，App 不提供自动迁移。

这一 current-only 方针已按 [决策登记](decisions.md) 落地；历史 predecessor/rollback 契约只保留在 `docs/plans/`、`docs/sources/` 和追加式日志中，不定义当前能力。

## 证据

- 当前候选总表：[`acceptance/current-release.md`](acceptance/current-release.md)
- DICOM 支持与安装矩阵：[`acceptance/dicom-mri-viewer-matrix.md`](acceptance/dicom-mri-viewer-matrix.md)
- 文件夹导入契约：[`sources/2026-08-07-dicom-folder-import-contract.md`](sources/2026-08-07-dicom-folder-import-contract.md)
- Slice service 契约：[`sources/2026-08-07-dicom-slice-service-contract.md`](sources/2026-08-07-dicom-slice-service-contract.md)
- App flow 与 Viewer：[`sources/2026-08-07-dicom-app-flow-contract.md`](sources/2026-08-07-dicom-app-flow-contract.md)、[`sources/2026-08-07-dicom-viewer-ui-contract.md`](sources/2026-08-07-dicom-viewer-ui-contract.md)
