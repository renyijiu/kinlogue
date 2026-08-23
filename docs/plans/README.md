---
status: navigation
---

# 实施计划目录

计划文件保留需求、权衡和实施历史，不直接证明当前代码能力。当前事实以专题页、代码、测试和 [当前候选证据](../acceptance/current-release.md) 为准。

## 已实施的决策记录

- [`2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md`](2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md)：用户选择目录的客户端加密、版本化备份与整库恢复。Core/Platform/App、自动化、保留和 UI 已实现；真实网盘客户端、Developer ID、macOS 14/15 与完整人工恢复仍在验收账本标为未执行。
- [`2026-08-01-002-feat-kinlogue-plaintext-mvp-plan.md`](2026-08-01-002-feat-kinlogue-plaintext-mvp-plan.md)：明文、本机优先 MVP。
- [`2026-08-02-001-feat-lan-upload-inbox-plan.md`](2026-08-02-001-feat-lan-upload-inbox-plan.md)：临时 LAN 接收与单一待确认队列。
- [`2026-08-06-001-feat-dicom-mri-viewer-plan.md`](2026-08-06-001-feat-dicom-mri-viewer-plan.md)：受限 DICOM 导入与二维 Viewer。
- [`2026-08-10-001-feat-export-all-original-files-plan.md`](2026-08-10-001-feat-export-all-original-files-plan.md)：导出全部已确认原始文件。

## Superseded

- [`2026-08-01-001-feat-kinlogue-macos-vault-plan.md`](2026-08-01-001-feat-kinlogue-macos-vault-plan.md)：早期加密 Vault/Keychain/备份方向，已被明文 MVP 取代，只用于解释决策来源。

新增计划时应在 frontmatter 明确状态，并把当前实现结论编译到相应专题页，而不是继续扩张顶层索引。
