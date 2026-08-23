---
title: GitHub Actions 与 macOS CI/CD 来源笔记（2026-08-05）
author: GitHub、Apple 与开源 macOS 项目维护者
source_url: https://docs.github.com/en/actions/reference/security/secure-use
captured: 2026-08-05
kind: pattern-reference
---

## 来源范围

本页只保存本次 CI/CD 设计使用的公开来源定位和必要摘要，不是 Kinlogue 当前发布状态的证据。项目结论以 [`../testing-and-release.md`](../testing-and-release.md)、代码、脚本和验收矩阵为准。

### GitHub 官方资料

- [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)：完整 commit SHA 是把第三方 Action 固定到不可变版本的方式；workflow 应使用最小 token 权限。
- [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)：标准 `macos-15` runner 是 arm64；固定 OS label 可避免 `macos-latest` 迁移带来的环境漂移。
- [actions/runner-images](https://github.com/actions/runner-images)：2026-08 的公告显示 macOS 14 image 已进入弃用窗口，并计划在 2026-11-02 后不再受支持；这也是 CI 选择 `macos-15`、继续把 macOS 14 留在独立兼容性矩阵的原因之一。
- [Using artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)：公开仓库在当前计划可用；GitHub Free/Pro/Team 的私有仓库不可用，私有仓库需 Enterprise Cloud。因此 Kinlogue 以 repository variable 显式启用，不把它变成未知计划下的硬失败。
- [actions/attest](https://github.com/actions/attest)：对最终可分发二进制生成 provenance；当前 workflow 固定到已核对的完整 SHA。

### Apple 官方资料

- [Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)：Mac App Store 外分发应使用 Developer ID，随后提交 Apple notarization；自定义流程可用 `notarytool` 和 `stapler`。
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)：分发签名需要 Developer ID、hardened runtime、secure timestamp，且不能携带 `get-task-allow=true`。
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)：自定义流程使用 `ditto -c -k --keepParent` 生成提交 ZIP；公证后应把 ticket staple 到 App，再创建最终分发 ZIP。
- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)：外部构建系统可以手工签名；签名时不应使用 `codesign --deep`，验证时仍可用 `--deep --strict`。

## 同类公开仓库观察

- [CotEditor test workflow](https://github.com/coteditor/CotEditor/blob/main/.github/workflows/test.yml)：PR/push 同时运行 package tests、App tests 和 release build smoke test，并显式记录工具链环境。
- [IINA CI workflow](https://github.com/iina/iina/blob/develop/.github/workflows/ci.yml)：在固定 macOS/Xcode 环境构建并保存 App artifact。
- [Stats build/linter workflows](https://github.com/exelban/stats/tree/master/.github/workflows)：将 build 和 SwiftLint 分开，并为同一 ref 启用 concurrency cancellation。
- [Rectangle build workflow](https://github.com/rxhanson/Rectangle/blob/main/.github/workflows/build.yml)：PR/push 使用 ad-hoc identity 做可构建 artifact，不把它冒充 Developer ID 发布包。
- [CodeEdit pre-release workflow](https://github.com/CodeEditApp/CodeEdit/blob/main/.github/workflows/CI-pre-release.yml)：pre-release 在 lint/test 之后部署，并限制仓库 owner。

## 本项目采用的部分

- 固定 macOS runner、记录工具链、同一 ref 取消旧 CI；
- PR/main 上执行 lint、测试和 release bundle smoke/verification；
- release 与 CI 分离，tag 与 `Info.plist` 版本互相校验；
- 当前 tag workflow 不使用 Apple secrets，最终 ad-hoc ZIP 做签名完整性、精确 entitlement、解包后 bundle hash 和可选 provenance 复验；
- GitHub Release 明确标记为非 draft 的 Pre-release 和 `ad-hoc candidate`，其可见性仍受仓库访问控制；人工兼容性和真实设备矩阵仍是正式发布门禁；
- Developer ID、临时 keychain、公证、staple 与 Gatekeeper 验证保留在未来凭据升级脚本中，不冒充当前自动化能力。

### 2026-08-05 ad-hoc 候选发布修订

项目当前没有 Apple Developer ID，因此 tag workflow 改为发布非 draft 的 arm64 ad-hoc GitHub Pre-release，而不是等待 Apple Secrets 或生成不可见的 draft。当前仓库是 private，该 Pre-release 仅供具备仓库读取权限的用户下载；如需向没有仓库权限的公众分发，必须先公开仓库或把候选包放到独立的公开下载位置。Developer ID/notarization 脚本保留为未来升级路径。候选包必须在标题、安装说明和 metadata 中声明未公证状态，并让下载者校验 SHA-256 后按 Apple 官方“隐私与安全性 → 仍要打开”流程手工确认；不建议关闭 Gatekeeper 或递归移除 quarantine。

本修订参考 [Apple：安全地打开 Mac 上的 App](https://support.apple.com/102445)。Apple 明确指出，未签名或未公证软件可能带来恶意软件和隐私风险，因此“用户可以覆盖提示”不能写成“与正式签名等价”。

### 2026-08-06 runner 工具链修订

- [actions/runner-images](https://github.com/actions/runner-images) 当前可用镜像表列出标准 arm64 `macos-26` label，并说明每个 macOS 版本只支持一个 Xcode 主版本。
- GitHub Actions run `31076517030` 在 `macos-15` / Xcode 16.4 上出现 SwiftUI 私有 `KeyViewProxy` 数量差异，且全量 Swift Testing 在 90 分钟后被取消；同一分支在当前证据机 Xcode 26.6、相同并行度下 648 项测试约 51 秒完成。
- 因此 CI 和候选发布 workflow 改为固定 `macos-26`，让自动化使用项目当前验证过的完整 Xcode 主版本；macOS 14/15 仍保留为独立兼容性门禁，不能由新 runner 结果替代。

## 未采用或仍待验证的部分

- 未引入依赖 Homebrew/第三方 SwiftLint Action 的 lint 路线；当前 gate 使用 Xcode 自带编译器 warnings-as-errors、源码卫生和现有 package graph verifier。
- 未把 `macos-26` CI 结果写成 macOS 14/15 独立机器兼容性证据。
- artifact attestation 的实际可用性取决于仓库 visibility/plan；默认关闭，开启后才可记录为执行证据。
- Developer ID、notarization 和 GitHub draft Release 尚未在本次本机修改中执行；需要 Environment secrets、Apple 服务和 GitHub tag 后单独验收。
