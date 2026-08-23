# DICOM App flow contract — 2026-08-07

## 范围

本笔记记录 DICOM MRI Viewer 计划 U5 在当前源码中的 App 用户流程接入。它只使用运行时生成、无 Patient Name/ID/Birth Date 等身份 tag 的 DICOM fixture；没有读取用户私有 MRI，也没有把真实文件名、路径、UID 或内容写入仓库或测试输出。

U5 不实现切片 Viewer。它把已经存在的 U1–U4 隔离解码、catalog v3、目录导入和按需切片基础接到以下用户动作：

- 从独立入口选择一个 DICOM 文件夹；
- 查看不含内容的对象数量进度，取消未完成导入；
- 对完整 `.needsReview` study 明确选择活跃家庭成员和检查日期；
- 在独立医学影像库中按成员查看已确认检查，重新打开确认信息或删除检查；
- exact re-import 复用已有 review/library destination，不重复发布检查。

## 代码边界

- `DICOMImportModel` 用 operation generation 丢弃关闭界面后晚到的成功/失败结果；取消只调用一次 Platform workflow cleanup。
- `LiveAppService` 的 import、最终 catalog 读取、review index 读取、确认和删除都在共享 `LibraryLifecycleCoordinator.withActiveOperation` 内完成；library revoke 后这些入口统一返回 `revoked`，没有 App 侧绕过路径。
- `saveDICOMStudy` 复用普通 catalog generation/commit 冲突处理；相同 member/date 的重复确认不创建新 generation。
- `AppSnapshot` 只携带 `DICOMStudySummary`；报告 timeline、OCR、search、comparison 和 `OriginalDocumentPayload` 查询仍只读取报告模型。
- UI 只展示 study 状态、用户选择的成员/日期，以及 viewable/inert/Series/ignored/duplicate 聚合计数。文件名、路径、原始 UID、自由文本和像素不会进入该层。
- DICOM 与报告导入保持不同 file picker、review 和 navigation domain；成员删除在仍有 DICOM study 引用时 fail closed。

## 可复核测试

- `DICOMImportModelTests`：成功、exact re-import、取消、picker 取消与晚到结果 fence。
- `DICOMStudyReviewModelTests` / `DICOMLibraryModelTests`：明确确认、删除、成员选择、library 投影和稳定排序。
- `DICOMAppModelTests` / `DICOMViewSafetyTests` / `MemberSidebarViewSourceTests`：报告域隔离、独立入口/导航、presentation lifecycle 和无 identifier UI 文案。
- `LiveDICOMAppServiceIntegrationTests`：生成式目录经真实 `DICOMImportWorkflow → PlaintextVault → LiveAppService` 完成 import、review、confirm、exact re-import、成员依赖、study/member 删除；并验证重复确认不增加 generation、revoke 后四类 DICOM App 操作全部 fail closed。

当前源码的 U5 定向回归通过 22 tests / 7 suites；更广 DICOM/App/本地化/package 回归通过 188 tests / 21 suites。`scripts/lint.sh`、`scripts/privacy-guard.sh`、localization check、package graph 和 `git diff --check` 通过；`scripts/test.sh --quiet` 通过 690 tests / 68 suites与独立 real-socket/RSS gate，6 项 Vision 仍是既有 outer-sandbox known issues。这项证据不替代正式 bundle、安装后 DICOM UI、slice Viewer、真实 MRI、macOS 14/15 或人工键盘/VoiceOver 验收。
