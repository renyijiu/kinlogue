# 隐私与安全工程说明

这是一份面向维护者和 Agent 的工程说明；用户可见承诺以 [`../PRIVACY.md`](../PRIVACY.md) 和 [`../README.md`](../README.md) 为准。本文不把存在的防护夸大成未实现的安全能力。

## 当前安全姿态

| 面 | 当前实现 | 不应声称 |
| --- | --- | --- |
| 本地存储 | App Sandbox 内明文文件；Vault/inbox 有 generation、digest、路径和权限检查 | 应用层加密、保密存储、抗恶意回滚 |
| 备份 | 用户选择目录中的自包含 checkpoint 使用 HPKE + AES-GCM 认证加密、设备签名和完整正式文件回读 | 活动 Vault 已加密、网盘已经上传、远端保留 N 份、全局最新性 |
| 密钥 | 不使用 Keychain；恢复 seed/私钥不持久化，本机只保存不能解密 checkpoint 的设备签名 seed 与恢复根公钥 | 服务端找回恢复码、设备身份能解密、同登录会话恶意软件防护 |
| 完整性 | SHA-256 检测意外截断、缺失和错误引用，并参与本机精确去重；catalog/object metadata 交叉校验 | 密码学认证、签名、防篡改或攻击者重写防护 |
| 网络 | 用户主动开启的临时 LAN listener；普通 HTTP；pairing + cookie + CSRF + session generation | TLS、公共网络安全、远程访问或云同步 |
| OCR | macOS Vision/PDFKit 本机处理 | 云端 OCR、医学诊断或治疗建议 |
| 供应链 | SwiftPM exact versions + resolved commit；SwiftNIO/ZIPFoundation 锁定版本高于本次复核的公开修复线；GitHub Actions 固定完整 SHA | 未启用远端扫描时的“零漏洞”、DICOM 解码器或备份密码学已独立审计 |
| 原始文件导出 | 用户明确选择目标后生成一个未加密 ZIP；只含已确认原始附件，发布后由用户保管 | 加密容器、备份/恢复格式、导出副本仍受 App 删除控制 |
| 发布 | ad-hoc signed arm64 candidate；可作为带明确警告的 GitHub Pre-release 供知情测试者手动下载 | Developer ID、notarization、Apple 恶意软件检查或正式公共发布准备完成 |

能访问当前 macOS 用户资料的其他用户/软件，以及 Time Machine、APFS snapshot 和外部副本，都在当前明文 MVP 的保护承诺之外。

## 简化威胁模型

### 保护对象

报告原件、成员资料、OCR blocks、人工修正、搜索字段、source references、LAN inbox blobs/derived data、catalog 关系和可推断的存在性信息。

### 当前纳入的风险

- 损坏、截断、重复或格式异常的导入；
- 路径穿越、符号链接替换、非 regular file、恶意文件名和不受控临时 partial；
- 并发/跨进程提交和重启中断导致的混合 generation；
- LAN 未配对访问、旧 cookie/CSRF、过度 poll、过量并发或 body memory pressure；
- 真实病历进入 Git、日志、测试、App bundle、临时目录或验收报告；
- 误把 OCR/规则候选当成确认后的医学事实。
- 通过导出名称泄漏内部 UUID/digest/path、路径穿越或名称碰撞，以及失败/取消后留下看似成功的 `.zip`。
- 同步目录中的 symlink/hardlink/FIFO/父目录替换、恶意超限容器、截断/重排/替换、并发恢复点分叉，以及失败恢复留下私有明文 staging。

### 明确不承诺的风险

- 同一登录会话中的恶意软件、管理员/root、已解锁屏幕的系统截图、实时内存取证；
- 其他系统服务对明文 Application Support、备份或快照的读取；
- 普通 HTTP 在不可信 LAN 上被窃听或篡改；
- ad-hoc 候选包的开发者身份、Apple 恶意软件检查或公共分发信任链；下载者需要自行核对 SHA-256，并在理解风险后手工覆盖 Gatekeeper。

## 代码中的保护边界

- `PlaintextVault`：对象 immutable、`library.json` 单一提交点、generation/Catalog validation、SHA-256、orphan cleanup、原子 replace。
- `AtomicFileStore`、`VaultRootBinding`、`VaultProcessLock`：`O_NOFOLLOW`、descriptor identity、父/root inode 检查、共享 root mutation coordination。
- `PlaintextVaultInitializationTransaction` / `PlaintextVaultDeletionTransaction`：初始化和删除 receipt、quarantine、同步和崩溃恢复。
- `ImportedFileValidator`、`PDFTextExtractor`、`VisionTextRecognizer`：输入类型、页/像素/输出预算、单页处理和取消检查。
- `LANSession`：一次性 pairing、session generation、idle timeout、constant-time comparison、peer/global rate limits。
- `LANHTTPHandler`：authority/origin/framing、header/body deadlines、认证先于 body/remote ID、粗粒度 phone error mapping。
- `LANInboxPartialContext` / `PlaintextLANInboxStore`：partial descriptor、inode identity、blob/derived 原子发布、manifest 后提交和失败清理。
- `LANSessionLifecycleMonitor` / `LibraryLifecycleCoordinator`：停止事件撤销 credential、关闭连接和删除前关闭接收入口。
- `OriginalArchivePlan` / `PlaintextOriginalArchiveExporter`：只选择已确认原始附件；输出名称经过 Unicode、保留名、路径分隔符、长度和碰撞处理，不包含内部 ID。导出固定 Vault revision，逐项通过 no-follow descriptor 流式复核长度/digest，写入同卷私有非 `.zip` 暂存，全量验证后才原子发布；取消和提交前失败不会留下成功外观的 partial。`LibraryLifecycleCoordinator` 让整库删除先取消并等待已进入的导出，提交阶段不可取消。
- `BackupKeyHierarchy` / `BackupLocalConfigurationStore`：CryptoKit 域分离派生恢复签名与 HPKE 根；恢复 seed 不持久化。app-private 0700/0600 canonical 配置绑定 bookmark、repository identity、public roots、device authorization、scheduler 和 full-reader witness，missing/corrupt/mismatch 均失败关闭。
- `EncryptedBackupContainerWriter` / `BackupContainerReader` / `BackupTrustVerifier`：manifest 加密、256 KiB 有界 frame、fresh DEK/nonce domain、HPKE envelope、AES-GCM 与 signed footer；public-only 验证不接触恢复 seed，seed-only reader 先验证签名与 ciphertext commitment，再解密和解释 entry。
- `PlaintextLibraryBackupSource` / `EncryptedCheckpointWriter` / `BackupRepository`：在同一 Vault-wide lease 冻结 exact Vault + inbox pair，逐 entry 通过短 lease和 no-follow descriptor 流读；repository 只处理固定 opaque direct-child regular leaves，排他发布、同 inode private full-reader 后才签发 durable witness。unknown/corrupt/fork 状态阻止 writer 或 retention。
- `BackupRestoreVerifier` / `BackupRestoreTransaction`：首个 staging 明文字节前先持久化 preflight receipt；只在 app-private 同卷 staging 解密并 strict reopen，确认后以 root-bound typed receipt 执行 replace/rollback，启动时先收敛遗留事务。本机配置删除位于 destructive fence 内，外部 checkpoint 不受影响。
- `DICOMPart10Envelope` / `KinlogueDICOMIPC`：主进程只做有界 Part 10 envelope 与 typed DTO 校验；跨进程只传一个只读 descriptor 和受大小限制的 `Data`，不传 URL、路径或 Vault authority。
- `DICOMFolderScanner` / `VaultDICOMStudyStaging` / `VaultDICOMImportJournal`：security-scoped source 只通过 no-follow descriptor traversal 读取；staging 使用同卷、opaque UUID、私有权限和只读文件。receipt 在首个 staged byte 前持久化并绑定目录 identity；重启清理先咨询当前 catalog reachability，拒绝 symlink/replacement，失败时保留 opaque receipt 重试。
- `KinlogueDICOMDecoderHelper.xpc`：exact DICOM-Swift 1.3.3 只链接进独立 App Sandbox Helper。Helper entitlement 只有 App Sandbox，无 network client/server、inherit、用户文件或 Vault-root 权限；输入先复制到 opaque 私有临时文件，固定错误映射后清理，解析由硬 watchdog 有界终止。VOI LUT Function 只按单 tag 惰性读取，非 `LINEAR` 函数拒绝，不通过 `getAllTags()` 展开无关自由文本。主 App 没有 `DicomCore` 或 DICOM 网络实现，也没有解码失败时的进程内 fallback；真实进程门禁用合成自由文本/URL canary 验证 unified log 不泄漏且 Helper 运行时无 network socket。
- `DICOMSliceService`：只接受 `PlaintextVault` 产生的 opaque revision/instance descriptor；managed object 在 decode 前后复核 digest、identity 和长度，raw frame 仍只经 XPC adapter。cache key 不含路径、UID 或 W/L history，错误只暴露固定 Kinlogue case。canonical/current-render 像素只在有界内存中存在；RAII lease 保证 service 释放不遗留预算，switch/close/lifecycle failure 只清对应 session token，pressure 才全局清 cache 并使旧 image handle 失效。这不承诺安全擦除调用方主动复制的 bytes、原始明文附件或系统备份。
- `DICOMImportModel` / `DICOMStudyReviewModel` / `DICOMLibraryModel` / `DICOMStudyViewerModel`：用户界面只显示检查状态、用户确认的成员/日期、modality、尺寸、切片/Series 与 inert-object 聚合状态，不展示或记录文件名、路径、原始 UID 或 DICOM 自由文本。确认后的检查只把日期、成员和对象数量等检查级摘要投影到成员时间线；DICOM 原件、自由文本和像素仍不进入报告 OCR、搜索或比较。Viewer canvas 为当前帧保留一份有界的拥有式内存快照，不写预览/截图；App registry 在单 study 删除、外部删除刷新或 whole-Vault revoke 时先让所有目标窗口同步清空像素/失效请求，再等待 slice service close 并关闭窗口。普通关闭、Series 切换或 memory pressure 同样会使对应旧结果/handle 失效。

这些保护主要解决“意外损坏、错误状态、资源滥用和错误路径写入”；它们不把明文文件变成加密文件。

依赖安全结论是点时证据，不是长期保证。当前版本、公开公告、GitHub 扫描能力和未完成的独立审计见 [依赖安全来源笔记](sources/dependency-security-review-2026-08-23.md)；任何自动更新都必须重新经过本仓库的 XPC、资源、隐私和 untrusted-input 门禁。

## 日志和诊断规则

- 普通 App error 只使用稳定 failure/event code、opaque ID、大小和状态，不输出原文、文件名、URL、完整路径、peer、cookie、CSRF、远端文件 ID 或底层错误文本。
- HTTP log 只允许 route/reason/status class 等 allowlist 字段；`LANHTTPLogEvent` 不携带 target、header、peer、credential、filename、digest 或 underlying error。
- 测试和脚本可以输出合成数据数量、长度和 SHA-256；不能输出合成内容所在的用户路径或复制真实资料。
- 验收报告只记录 gate、版本、哈希、状态和不含内容的摘要；DICOM 安装门禁只增加合成对象计数、毫秒、RSS、descriptor 和字节数，不记录 tag、UID、文件名、路径或像素。完整地址、验证码、文件名和正文不落盘。

## 数据生命周期

- Mac 选择的源文件不会被修改或删除；App 会复制到自己的 Vault。
- U3 DICOM Platform import 只从 Vault-owned staged bytes 派生持久事实；成功/取消后回收 staging，进程崩溃时由下一次受协调的 reopen/import 回收。原始 DICOM bytes 会作为明文 immutable attachment 保留，但不会进入 OCR、搜索或自动导出，也不会生成持久预览。
- U4 on-demand slice service 不生成持久 thumbnail、preview、截图或像素日志。Vault destroy 在等待 active descriptor read 前撤销 slice lifecycle generation，晚到 transform 不能重新发布旧像素；删除仍是 ordinary unlink，不描述为 secure erasure。
- U5 App 确认只保存用户选择的家庭成员与日期；它不把 DICOM 内容转录成报告字段。删除检查会移除其 catalog/index 引用和不再共享的 App-owned 原件，最初选择的文件夹不受影响。
- U6 Viewer 只在当前 presentation 内保存 Series/切片、W/L、pan/zoom 与一个可失效 image handle；没有持久 thumbnail、截图、导出、剪贴板或拖放入口。像素本身可能烧录身份信息，因此仍按敏感明文处理；删除检查或整库前会先清空所有相关窗口的拥有式快照，再等待底层 session 关闭。
- 手机完整上传的唯一原件保留在 Mac 待确认队列，直到用户明确删除或把所选项成功归档；不会自动过期。手机只可在当前会话中取消尚未保存的文件，不能删除 Mac 已发布的待确认项。
- 提交后 Vault 原件由 record/draft/source ownership 持有；删除 inbox 副本不会删除已经归档的原件。
- Vault destroy 只删除 App 管理的当前目录，并对目标 inode/path 做绑定检查；它不承诺清除外部副本。
- 已发布的导出 ZIP 位于用户选择的位置，已经离开 Vault 生命周期；Vault destroy 不删除、跟踪或安全擦除它。用户界面必须在导出前说明这是未加密副本且不能恢复资料库。
- 已发布的 `.kinloguebackup` 同样位于外部 repository；Vault destroy 或 restore 不删除它。retention 只处理当前 backup set 中经过认证、完整验证并满足 24 小时连续观察的恢复点，且不承诺第三方客户端远端已经上传或删除。
- 删除失败或发生部分删除时，receipt/quarantine 让后续运行只继续处理已验证的同一目标，不能借路径替换删除另一个 Vault。

## Agent 和测试禁区

- 真实病历只能在仓库外做私密人工验收，且不得复制、截图、日志化或放入测试结果。
- DICOM 自动化只能在运行时生成不含 Patient Name/ID/Birth Date 等身份 tag 的 synthetic fixture；仓库和 bundle 门禁拒绝 checked-in `.dcm`、`.dicom`、`.nii` 和 `.nii.gz` fixture。当前 Mac 的 U7 安装验收只使用该生成器；此外，一份经用户明确授权、始终位于仓库外的私有 MRI 样本已完成隔离完整导入并通过，未保留样本、路径、身份 tag、UID、像素或截图。这个结果只覆盖当前 Mac 上的一份样本，更广的厂商、检查类型与独立系统矩阵仍未执行。
- `scripts/privacy-guard.sh` 默认拒绝仓库内 PDF、JPEG、PNG、HEIC 和 TIFF 等受支持报告原件扩展，只精确放行已审查的 AppIcon 文件路径；新增品牌图片也必须逐路径评审，不能通过目录级通配放行。该扩展名门禁不声称能语义识别任意 PHI；已知敏感值仍通过 `KINLOGUE_FORBIDDEN_VALUES` 扫描，代码、文档和其他扩展中的身份信息继续受仓库禁区约束。
- `scripts/privacy-history-guard.sh` 通过 Git object database 扫描准备公开的 reachable refs，覆盖曾提交后删除的医疗/报告类附件、备份或签名容器、`.env`/私钥路径、完整格式的恢复码、常见凭据模式、精确私密资料库存证据和调用方提供的 forbidden values；`.env.example` 是唯一环境文件名例外。门禁只报告规则类别，不回显命中路径或内容；它不能替代公开托管平台上的 PR、Issue、Actions log、release asset 和 fork 审计。
- 不要使用真实文件名来验证去重、展示名、OCR 或 LAN；使用生成 fixture 和 run-scoped canary。
- 不要因为调试方便打开内容日志、保存 cookie/验证码、把 App Sandbox 路径写进报告或把整页 PDF 输出到终端。
- 不要在未确认可信网络前启动 LAN listener；不要把 `network.server` entitlement、可行性 marker 或 test-only client entitlement 扩大到不该有的 bundle。
- 修改 `README.md`、`PRIVACY.md`、`packaging/Info.plist`、entitlements、验证脚本或网络行为时，必须一起检查本页和对应验收文档。

## 未来安全升级边界

当前只有外部备份容器使用应用层认证加密；活动 Vault 仍为明文，也仍不使用 Keychain。内置云同步、活动 Vault 加密和多设备合并仍属于后续独立决策。任何升级必须同时提供迁移格式、密钥生命周期、失败恢复、重启校验、旧数据保留/删除策略和新的 threat model；不得把备份容器的加密能力扩大描述为整个产品已经加密。
