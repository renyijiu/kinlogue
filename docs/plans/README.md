---
status: navigation
---

# 实施计划目录

计划文件保留需求、权衡和实施历史，不直接证明当前代码能力。当前事实以专题页、代码、测试和 [当前候选证据](../acceptance/current-release.md) 为准。

## 提议中的计划

- [`2026-10-15-feat-member-cli-chat-plan.md`](2026-10-15-feat-member-cli-chat-plan.md)：针对单个成员、调用使用者本机已登录的 Codex CLI 的只读对话（Claude Code 留待后续），首版不保存对话但按可保存设计。决策已确定，U0–U7 已实现为默认关闭的“AI 对话（实验）”，对话保存在资料库并进入恢复点；人工矩阵见[成员对话验收矩阵](../acceptance/member-chat-matrix.md)。与未合入的 `codex/agentrunkit-probe` 分支的关系见计划第 2 节。


## 实施中的计划

- [`2026-10-18-feat-member-chat-layered-context-plan.md`](2026-10-18-feat-member-chat-layered-context-plan.md)：成员对话的上下文包改为本机确定性的分层聚合（全部已确认报告的目录、结论与标记项、按项目名汇总的检验行，加预算内的最新全文），总预算约 100 KB；只保存被引用的来源。修订成员对话计划第 4.4 节；用户 2026-10-18 审阅确定，L0–L3 已实施，App 内人工检查待执行。
- [`2026-10-10-2322-refactor-sqlite-architecture-plan.md`](2026-10-10-2322-refactor-sqlite-architecture-plan.md)：先修备份/去重与任务所有权，再完成 SQLite 查询、逻辑备份和一次生产切换。进度和证据见[日志](../log.md)，计划本身不回填执行结果。

## 已实施的决策记录

- [`2026-10-19-1715-feat-plain-zip-backup-export-plan.md`](2026-10-19-1715-feat-plain-zip-backup-export-plan.md)：把加密备份与原件导出合并为一种明文 ZIP 备份包（索引文件 + logical-v1 数据 + 按成员排列的原件）；文件夹备份、导出、只删本机写入文件的保留和从 ZIP 恢复已在本分支实施，安装后、网盘客户端与规模门禁未执行。
- [`2026-08-01-002-feat-kinlogue-plaintext-mvp-plan.md`](2026-08-01-002-feat-kinlogue-plaintext-mvp-plan.md)：明文、本机优先 MVP。
- [`2026-08-02-001-feat-lan-upload-inbox-plan.md`](2026-08-02-001-feat-lan-upload-inbox-plan.md)：临时 LAN 接收与单一待确认队列。
- [`2026-08-06-001-feat-dicom-mri-viewer-plan.md`](2026-08-06-001-feat-dicom-mri-viewer-plan.md)：受限 DICOM 导入与二维 Viewer。

## Superseded

- [`2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md`](2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md)：用户所选目录的客户端加密恢复点、恢复码与设备身份；代码已删除，由明文 ZIP 备份计划取代，只用于解释早期设计与威胁模型。
- [`2026-08-10-001-feat-export-all-original-files-plan.md`](2026-08-10-001-feat-export-all-original-files-plan.md)：只含已确认原件、不可恢复的导出；已并入明文 ZIP 备份，“导出备份到…”写出可恢复的完整备份。
- [`2026-08-01-001-feat-kinlogue-macos-vault-plan.md`](2026-08-01-001-feat-kinlogue-macos-vault-plan.md)：早期加密 Vault/Keychain/备份方向，已被明文 MVP 取代，只用于解释决策来源。

新增计划时应在 frontmatter 明确状态，并把当前实现结论编译到相应专题页，而不是继续扩张顶层索引。
