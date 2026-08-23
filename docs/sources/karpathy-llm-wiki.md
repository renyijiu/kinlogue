---
title: LLM Wiki
author: Andrej Karpathy
source_url: https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f
captured: 2026-08-04
kind: pattern-reference
---

# LLM Wiki：项目采用说明

## 来源摘要

该来源提出一种由 LLM 持续维护的本地 Markdown 知识库：原始资料保持不可变，LLM 把资料编译为互相链接的 Wiki 页面，再由一个 schema 文件约束目录结构、写入规则、查询和维护流程。它特别强调两个可导航的基础文件：面向内容的 `index.md` 和按时间追加的 `log.md`；知识库还应定期检查过时主张、矛盾、孤儿页面和缺失链接。

来源中的实现细节是抽象模式，不等同于 Kinlogue 的技术要求。完整原文见上面的公开 URL。

## 本项目采用的部分

- `AGENTS.md` 作为 Agent schema，先读索引和专题页，再回到代码/测试核实行为。
- `docs/index.md` 作为内容导向的项目入口，集中维护页面、状态和证据链接。
- `docs/log.md` 作为追加式时间线，记录文档 ingest、重大变化和未完成的验收门禁。
- `docs/sources/` 作为外部资料层；专题页只引用来源，不把来源摘要冒充运行时事实。
- 通过专题页之间的 Markdown 链接累积上下文，查询时先索引、再深入相关页面、最后核对代码。
- 把文档 lint 当作知识库健康检查：断链、孤儿页、矛盾状态和过时命令都属于可修复的文档缺陷。

## 本项目没有直接采用的部分

- 当前仓库没有引入向量数据库、MCP 知识服务或额外检索基础设施；中等规模下优先使用 Markdown 索引、`rg` 和 Git 历史。
- `Sources/` 与 `Tests/` 不是由 LLM 任意改写的 raw vault，而是受软件工程约束的可执行事实来源；Agent 只能按代码任务授权修改它们。
- Wiki 页面不能覆盖隐私说明、测试结果或产品决策的事实优先级；如果总结与实现冲突，必须回到代码/测试修正总结。
