---
title: GitHub 项目 README 信息结构参考
author: GitHub、LocalSend contributors、CotEditor contributors、Immich contributors、Ente contributors
source_url: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes
captured: 2026-08-05
kind: pattern-reference
---

## 来源摘要

本笔记记录本次 README 重写所参考的公开信息结构，不把外部项目的能力或措辞当作 Kinlogue 的产品事实。

- [GitHub Docs：About the repository README file](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)：README 应优先说明项目做什么、为什么有用、如何开始和到哪里获取更多信息；较长内容应下沉到专项文档。
- [LocalSend](https://github.com/localsend/localsend)：首屏给出品牌、单句定位和导航，随后按功能、使用方式、构建与排障组织信息，并明确局域网边界。
- [CotEditor](https://github.com/coteditor/CotEditor)：用简洁的 macOS 产品定位开场，紧邻系统要求、设计原则、源码构建和许可证。
- [Immich](https://github.com/immich-app/immich)：把重要状态/风险提示和核心链接放在功能细节之前。
- [Ente](https://github.com/ente-io/ente)：以产品为何存在和隐私承诺建立叙事，再链接到更具体的产品、安全与贡献文档。

## 本项目采用的部分

- 首屏使用图标、品牌名、中英文标语和一句话定位，让读者先理解“是什么”和“为什么”。
- 在功能列表之前展示当前测试候选状态，避免把本机验收写成公开发布。
- 将核心体验、隐私/医疗边界、版本姿态和本机构建分开，让用户承诺与开发者入口都能快速定位。
- 保留 README 中必要的手机投递说明，把完整协议、存储、排障和验收细节链接到项目 Wiki。
- 不复制外部项目文案；所有 Kinlogue 能力和限制仍以本仓库代码、测试、隐私说明与验收矩阵为依据。

## 未采用或仍待验证的部分

- 当前没有 Git 跟踪的产品界面截图，因此没有借用其他项目常见的截图画廊结构；应用图标仅用于品牌识别。
- 当前没有公开下载页、已 notarize 安装包或稳定 release，因此不添加下载按钮、商店链接或“production ready”徽章。
- 当前没有独立贡献指南、支持社区或项目官网，因此不伪造对应入口。
