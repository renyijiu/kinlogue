# 验收记录目录

本目录区分当前候选证据与历史阶段证据。`passed` 只适用于对应行、revision 和工件；没有执行的人工或设备门禁保持 `notExecuted` 或 `pendingManual`。

## Current

- [`current-release.md`](current-release.md)：当前版本、测试清单、候选身份和整体发布状态的唯一权威账本。
- [`lan-upload-matrix.md`](lan-upload-matrix.md)：当前 LAN 自动化、候选证据和真实设备待办矩阵。
- [`dicom-mri-viewer-matrix.md`](dicom-mri-viewer-matrix.md)：当前 DICOM 支持范围、生成式/私有样本证据和设备待办矩阵。

## Archive

- [`lan-upload-feasibility.md`](lan-upload-feasibility.md)：生产 LAN 实现之前的 U1 listener 可行性记录；不得描述当前 entitlement 或当前产品能力。

保留的归档页用于解释仍有价值的历史验证来源；当前状态页不得把归档结论当成当前候选证据。已删除实现的操作手册不继续保留，决策沿革仍可从 `docs/plans/`、`docs/sources/` 和追加式日志查阅。
