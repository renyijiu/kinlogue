# DICOM MRI Viewer 调研来源（2026-08-06）

本页记录 DICOM MRI 本机查看计划使用的外部来源和可复核观察。它是来源层笔记，不代表 Kinlogue 当前已经具备这些能力；目标行为见 [`../plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md`](../plans/2026-08-06-001-feat-dicom-mri-viewer-plan.md)。

## 输入来源

- [OpenDicomViewer 论文](https://link.springer.com/article/10.1007/s10278-026-02085-w) 与 [参考实现](https://github.com/Christian-Stroetmann/OpenDicomViewer)：用于理解 SwiftUI DICOM Viewer 的功能拆分和开源先例，不作为整体集成依赖。
- [DICOMHERO Swift 示例](https://dicomhero.com/sample-swift-ios-app/)：用于比较成熟商业 SDK 的本地解码/查看接入方式，保留为未来兼容性回退选项。
- [DICOM-Swift](https://github.com/ThalesMMS/DICOM-Swift)、[1.3.3 release](https://github.com/ThalesMMS/DICOM-Swift/releases/tag/1.3.3) 与 [1.3.3 Package.swift](https://github.com/ThalesMMS/DICOM-Swift/blob/1.3.3/Package.swift)：首版选择的 Swift 解码基础及其依赖、资源和平台声明。
- [DICOM PS3.3 2026c Image Plane Module](https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.7.6.2.html)：Image Orientation/Position (Patient) 和病人坐标系定义。
- [DICOM PS3.5 2026c Transfer Syntax Specifications](https://dicom.nema.org/medical/dicom/current/output/chtml/part05/chapter_A.html)：传输语法编码规范。

## 本次采用的来源事实

- DICOM-Swift 1.3.3 的低层逐文件 decoder 能作为本机解码边界；Study/Series 扫描、排序、资源限制、错误映射和缓存仍由 Kinlogue 自己负责。
- 包含路径日志或全系列无界任务/缓存的高层 loader 不适合 Kinlogue 的隐私和内存边界，计划不使用这些入口。
- DICOM-Swift 的 package 资源和传递依赖必须进入 SwiftPM lock、App bundle、许可清单和发布验证，不能只让开发构建通过。
- Image Orientation (Patient) 给出行/列方向余弦，Image Position (Patient) 给出首个 voxel 的病人坐标；二维切片栈应优先按由两者计算的空间投影排序，而不是依赖文件名。
- DICOM 标准和 decoder 支持范围都大于首版产品范围。计划仅允许经典单帧 MR Image Storage 的 Explicit VR Little Endian 图像，其他图像格式明确失败；有效非图像对象只惰性保留。

## 私有样本边界

用户提供的 MRI 目录仅用于本机、仓库外的技术可行性和最终人工兼容检查。其真实路径、文件名、UID、标签、像素、截图、精确清单和派生验收数据不保存到本页、Git、测试 fixture、日志、构建产物或验收报告。

## 未由来源证明的事项

- 可成功初始化或解码像素不等于窗宽窗位、符号位、重采样或空间顺序显示正确；这些必须由合成 fixture 的精确期望值证明。
- 当前私有样本通过不等于支持通用 DICOM、压缩传输语法、多帧 MR、PACS 或诊断用途。
- 第三方依赖存在相关类型不等于 production executable 的路径可达；反过来，未调用也不自动证明没有日志或网络表面。计划要求单独的 source、linkage、entitlement 和运行时 canary 门禁。
