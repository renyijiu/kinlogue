# Kinlogue ad-hoc 候选包安装说明

这是供具备仓库读取权限的自愿测试者手动下载的 **arm64 候选包**，不是经过 Apple Developer ID 签名和 notarization 的正式发布版本。当前仓库是 private，没有仓库权限的公众用户无法访问 GitHub Release；若未来需要公开下载，必须先公开仓库或使用独立的公开下载位置。候选包只适用于 Apple Silicon Mac，最低系统版本为 macOS 14。

## 下载前请确认

- 只从 Kinlogue 官方 GitHub Release 页面下载 `Kinlogue-<version>-arm64-adhoc.zip`。
- 同时下载对应的 `.sha256` 文件，并在终端进入下载目录后运行 `shasum -a 256 -c Kinlogue-<version>-arm64-adhoc.zip.sha256`；只有显示 `OK` 才继续。
- ad-hoc 签名只能证明 ZIP 解包后的代码结构在打包后没有意外变化，不能证明开发者身份，也不代表 Apple 已检查恶意软件。

## 安装与首次打开

1. 解压 ZIP，将 `Kinlogue.app` 拖入当前用户的“应用程序”文件夹。
2. 正常打开一次；macOS 会因为应用没有 Developer ID 和 notarization 而阻止或警告。
3. 只有在你确认下载来源和 SHA-256 后，打开“系统设置 → 隐私与安全性”，在安全提示旁选择“仍要打开”，并再次确认。
4. 后续通常可以像其他应用一样打开。

不要运行要求关闭 Gatekeeper 的命令，也不要对下载目录递归移除 quarantine 属性。Apple 明确提醒，绕过安全检查会增加恶意软件风险；如果你不信任来源，请不要安装。

## 当前候选边界

- 只有该下载所附 `release-metadata.json` 将 `compatibility.workflowReleaseGates` 记录为 `passed` 时，才能确认该次构建完成仓库 lint、隐私门禁、自动测试、正式 bundle 验证、ad-hoc 签名复验和 ZIP 解包复验。验收矩阵的[自动与本机验收](acceptance/lan-upload-matrix.md#自动与本机验收)记录的是既有本机候选证据，不能据此推断当前下载已经执行相同行。
- Developer ID、Apple notarization、macOS 14/15 独立机器、真实手机矩阵、真实样本 OCR 和可访问性人工门禁对本次 GitHub 候选仍是 `notExecuted`，整体状态保持 `pendingManual`；若后续门禁明确失败，应记录为 `blocked`，不能写成 `passed`。逐项范围见验收矩阵的[正式发布门禁](acceptance/lan-upload-matrix.md#正式发布门禁)。
- Kinlogue 的资料库仍是 App Sandbox 内的明文资料库；完整隐私边界见 [`PRIVACY.md`](../PRIVACY.md)。

Apple 的官方说明：[安全地打开 Mac 上的 App](https://support.apple.com/102445)。
