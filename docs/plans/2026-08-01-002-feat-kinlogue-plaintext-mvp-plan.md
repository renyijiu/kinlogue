---
title: Kinlogue macOS Plaintext MVP - Plan
type: feat
date: 2026-08-01
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
status: active
supersedes: 2026-08-01-001-feat-kinlogue-macos-vault-plan.md
---

# Kinlogue macOS Plaintext MVP - Plan

## 目标

交付一个不依赖 Apple 开发者账号、Data Protection Keychain 或应用层加密即可在本机安装验证的原生 macOS MVP：一位用户在一台 Mac 上为多位家人管理报告，通过本机 OCR 和人工确认建立时间线，并快速并排查看历史结论与原件。

## 当前决策

- 报告原件、成员资料、OCR 结果和搜索字段保存在 App Sandbox 内的本机明文资料库。
- 不使用 Keychain，不提供应用层加密；首次启动必须在打开资料库前展示这一事实。
- SHA-256 只用于发现意外损坏，不宣称认证、防篡改、防回滚或保密。
- 清单是唯一提交点：对象先以不可变文件持久化，清单再原子发布；重启只能看到完整旧代或完整新代。
- 保留同进程与跨进程写入协调、路径和符号链接防护、私有目录权限及 App Sandbox。
- 当前版本不提供内置备份、恢复、云同步或旧加密库迁移。
- 发现旧版 `vault.marker` 或未知非空布局时停止，不覆盖、不删除现场。
- 删除只移除 App 管理的当前明文资料库，不承诺清除源文件、Time Machine、APFS 快照或外部副本。

## 实现路径

1. **明文资料库** — 使用版本化 `library.json`、规范化 catalog、对象长度和 SHA-256 摘要；实现初始化、读取、提交、孤儿清理、损坏检测与安全删除。
2. **App 接线** — 默认环境改用 `PlaintextVault` 与本机导入草稿；移除 Keychain、加密 envelope、备份和恢复服务。
3. **兼容边界** — 识别旧加密资料库并锁定 UI；不提供自动迁移或破坏性入口。
4. **用户说明** — 首启阻断式披露，统一 README、隐私说明、加载和删除文案。
5. **本机交付** — ad-hoc 签名 `.app`，精确 Sandbox entitlement；验证 executable 不直接链接 Security.framework，生产源码不包含旧加密运行时。
6. **自动验收** — 仅用合成数据验证 4 位成员、96 条记录和 96 份原件的写入、正常重启、强制终止后重启、检索、资料库外泄漏扫描和清理。
7. **人工尾项** — 真实私有样本 OCR 与键盘/VoiceOver 抽检由用户在仓库外执行，自动报告保持 `pendingManual`。

## 验收标准

- 无 Keychain 或开发者账号时可以初始化、关闭、重新打开、读取和删除本机资料库。
- 原件字节在资料库中可直接读取；UI 和文档明确告知当前没有应用层加密。
- 对象缺失、长度变化、SHA-256 不符、截断或格式错误的清单均报告损坏，不返回部分结果。
- 并发提交最多一个从指定 generation 成功；中断后不会出现混合代数据。
- 旧加密资料库和未知目录不会被初始化或删除逻辑覆盖。
- 正式 App 构建、全量单元/集成测试、隔离安装重启验收及资料库外 canary 扫描全部通过。
- 最终交付包含 `dist/Kinlogue.app`、`dist/verification-report.json` 与 `dist/acceptance-report.json`；未执行的真实样本和辅助功能检查明确标记。

## 后续安全升级边界

后续可在独立版本中增加应用层加密、Keychain 密钥管理和云同步。升级必须提供显式、可恢复、可验证的明文到加密迁移流程，并在完整迁移与重启验证前保留原资料，不得把当前 SHA-256 完整性检查描述为安全认证。
