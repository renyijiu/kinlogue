# 原始来源层

`docs/sources/` 保存项目 Wiki 使用过的外部来源、产品约束或历史材料的来源笔记。它对应 LLM Wiki 的 raw sources 层：来源内容一旦录入，默认追加保存，不在这里被 Agent 改写成项目结论。

## 保存规则

- 每个来源笔记必须包含标题、作者/组织、来源 URL 或仓库路径、获取日期、用途和简短的“本项目采用了什么”说明。
- 来源笔记只记录必要的摘要和定位信息，不复制受版权保护的长文，不保存 token、私有 URL、真实病历或完整会话转储。
- 外部来源发生修订时新增一份带日期的来源笔记，并在 Wiki 专题页记录当前采用哪一版；不要覆盖旧笔记。
- 代码、测试和当前验收报告不需要复制到这里；它们已经是仓库内的原始事实，专题页直接链接即可。
- 任何来源如果不能被公开复核，必须在笔记中标注“私有/未公开”，不能把它写成无条件的公共事实。

## 推荐格式

```markdown
---
title: ...
author: ...
source_url: ...
captured: YYYY-MM-DD
kind: pattern-reference | product-decision | external-spec
---

## 来源摘要

## 本项目采用的部分

## 未采用或仍待验证的部分
```

## 来源目录

### 知识库、发布与产品文档

- [`karpathy-llm-wiki.md`](karpathy-llm-wiki.md)：知识库组织方式。
- [`github-actions-macos-ci-cd-2026-08-05.md`](github-actions-macos-ci-cd-2026-08-05.md)：macOS CI/CD 与 Apple 分发边界。
- [`dependency-security-review-2026-08-23.md`](dependency-security-review-2026-08-23.md)：SwiftPM 已知公告、CodeQL/Dependabot 能力与独立审计缺口的点时复核。
- [`apple-localization-guidance-2026-08-05.md`](apple-localization-guidance-2026-08-05.md)：Apple 本地化资料。
- [`swift-macos-engineering-guidance-2026-08-19.md`](swift-macos-engineering-guidance-2026-08-19.md)：Swift API、并发、SwiftUI 状态、性能与 App Sandbox 官方实践复核。
- [`2026-08-05-github-readme-patterns.md`](2026-08-05-github-readme-patterns.md)：README 信息结构调研。

### DICOM 调研与阶段契约

- [`2026-08-06-dicom-mri-viewer-research.md`](2026-08-06-dicom-mri-viewer-research.md)：Viewer 方案、标准和私有样本边界。
- [`2026-08-07-dicom-swift-1.3.3-release-boundary.md`](2026-08-07-dicom-swift-1.3.3-release-boundary.md)：第三方包的 release consumer 边界。
- [`2026-08-07-dicom-xpc-xcode-build-evidence.md`](2026-08-07-dicom-xpc-xcode-build-evidence.md)：XPC target、资源、签名和生成式 round-trip。
- [`2026-08-07-dicom-folder-import-contract.md`](2026-08-07-dicom-folder-import-contract.md)：有界目录导入、staging、journal 和原子发布。
- [`2026-08-07-dicom-catalog-v3-contract.md`](2026-08-07-dicom-catalog-v3-contract.md)：catalog v3 隐私最小化图与迁移契约。
- [`2026-08-07-dicom-policy-v2-rollback-contract.md`](2026-08-07-dicom-policy-v2-rollback-contract.md)：开发期 policy-v2 predecessor/rollback 证据。
- [`2026-08-07-dicom-slice-service-contract.md`](2026-08-07-dicom-slice-service-contract.md)：按需解码、内存预算和 lifecycle fence。
- [`2026-08-07-dicom-app-flow-contract.md`](2026-08-07-dicom-app-flow-contract.md)：文件夹导入、确认、影像库和报告域隔离。
- [`2026-08-07-dicom-viewer-ui-contract.md`](2026-08-07-dicom-viewer-ui-contract.md)：Viewer model、canvas、交互和无障碍。
- [`2026-08-09-dicom-canvas-lifetime-correction.md`](2026-08-09-dicom-canvas-lifetime-correction.md)：像素快照生命周期修正。
- [`2026-08-09-dicom-viewer-window-presentation.md`](2026-08-09-dicom-viewer-window-presentation.md)：独立窗口呈现和撤销边界。
