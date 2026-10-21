# 隐私与安全工程说明

这是一份面向维护者和 Agent 的工程说明；用户可见承诺以 [`../PRIVACY.md`](../PRIVACY.md) 和 [`../README.md`](../README.md) 为准。本文不把存在的防护夸大成未实现的安全能力。

## 当前安全姿态

| 面 | 当前实现 | 不应声称 |
| --- | --- | --- |
| 本地存储 | App Sandbox 内的明文数据库和原件文件；有 revision、行摘要、路径和权限检查 | 应用层加密、保密存储、抗恶意回滚 |
| 备份 | 用户选择的文件夹或文件中的明文 ZIP：索引 + logical-v1 数据流 + 全部原件；发布前完整读回校验；保留只删本机写入且未被改动的文件 | 备份已加密、防篡改、网盘已经上传、远端保留 N 份 |
| 密钥 | 不使用 Keychain，也不生成或保存任何密钥；早期加密备份留在本机的设备密钥与公钥在启动时移除 | 任何形式的加密或认证 |
| 完整性 | SHA-256 检测意外截断、缺失和错误引用，并参与本机精确去重；数据库行摘要与原件元数据交叉校验 | 密码学认证、签名、防篡改或攻击者重写防护 |
| 网络 | 用户主动开启的临时 LAN listener；只绑定所选本机地址并在 HTTP 前限制为其已验证 IPv4/IPv6 前缀；普通 HTTP；pairing + cookie + CSRF + session generation | TLS、公共网络安全、跨前缀远程访问或云同步 |
| OCR | macOS Vision/PDFKit 本机处理 | 云端 OCR、医学诊断或治疗建议 |
| 成员对话（实验） | 默认关闭；用户开启并按对话确认后，单独签名的沙盒 XPC bridge 启动用户本机已登录的 Codex，只经 stdin 传入一位成员的已确认报告投影。主 App 不出站；bridge 读不到资料库，只有 `network.client`、本机回环 listener、`~/.codex/` 读写和两个安装根只读例外。每个 CLI 与模型先对本机模拟服务做一次请求检查，请求里出现工具、额外消息或本机路径即拒绝；bridge 不写日志 | 匿名化、发送可撤回、服务方不保留或不用于训练、回答正确、由程序保证非诊断、temporary exception 在 Developer ID / notarization 下的表现已验证 |
| 供应链 | SwiftPM exact versions + resolved commit；SwiftNIO/ZIPFoundation 锁定版本高于本次复核的公开修复线；GitHub Actions 固定完整 SHA | 未启用远端扫描时的“零漏洞”、DICOM 解码器或 ZIP 解析已独立审计 |
| 发布 | ad-hoc signed arm64 candidate；可作为带明确警告的 GitHub Pre-release 供知情测试者手动下载 | Developer ID、notarization、Apple 恶意软件检查或正式公共发布准备完成 |

能访问当前 macOS 用户资料的其他用户/软件，以及 Time Machine、APFS snapshot 和外部副本，都在当前明文 MVP 的保护承诺之外。

## 简化威胁模型

### 保护对象

报告原件、成员资料、OCR blocks、人工修正、搜索字段、source references、LAN inbox 的原件与预处理结果、记录之间的引用关系和可推断的存在性信息；成员对话开启后，还包括发送给 Codex 的上下文包，以及保存在资料库里的问题与回答。

### 当前纳入的风险

- 损坏、截断、重复或格式异常的导入；
- 路径穿越、符号链接替换、非 regular file、恶意文件名和不受控临时 partial；
- 并发/跨进程提交和重启中断导致的混合 generation；
- LAN 未配对访问、旧 cookie/CSRF、过度 poll、过量并发或 body memory pressure；
- 真实病历进入 Git、日志、测试、App bundle、临时目录或验收报告；
- 误把 OCR/规则候选当成确认后的医学事实。
- 通过备份内原件路径泄漏内部 UUID/digest/path、路径穿越或名称碰撞，以及失败/取消后留下看似成功的 `.zip`。
- 恢复时把 ZIP 当作不可信输入：路径穿越的条目名、重名条目、索引与内容不符、声明大小与实际膨胀不符、超量条目、源文件在读取中被替换，以及失败恢复留下私有 staging。
- 保留清理误删用户自己的文件：只删除账本中记录、名字/inode/大小/修改时间都未变的本机写入文件。
- 成员对话把未确认内容、其他成员的资料、姓名、备注、文件名或本机 ID 带出；同意过期后仍发送；报告文字里夹带的指令让模型调用工具或越过回答边界；Codex 加载用户的 hooks、MCP、插件或项目说明；健康资料进入命令行参数、环境变量、日志或 Codex 会话历史；子进程在取消、bridge 崩溃或资料库删除后继续运行。

### 明确不承诺的风险

- 同一登录会话中的恶意软件、管理员/root、已解锁屏幕的系统截图、实时内存取证；
- 其他系统服务对明文 Application Support、备份或快照的读取；任何拿到备份压缩包的人（包括网盘服务商）读取或改写其中内容；
- 普通 HTTP 在不可信 LAN 上被窃听或篡改；
- ad-hoc 候选包的开发者身份、Apple 恶意软件检查或公共分发信任链；下载者需要自行核对 SHA-256，并在理解风险后手工覆盖 Gatekeeper。
- 成员对话发送后的一切：服务方的保留、训练与访问控制，用户 Codex 账号或 `~/.codex` 凭据被盗，用户本机 Codex 程序本身的可信度，以及模型回答的正确性。续页只能限制发送什么、在用户确认后才发送，不能撤回已发送的内容。

## 代码中的保护边界

- `SQLiteLibraryStore` / `SQLiteLibraryOwner`：资料库的唯一实现。资料库打开期间持有单实例 owner 锁，校验可信根与文件身份；STRICT 表的每行带内容摘要并在读取时校验；原件经 `staged → live → deleting` 发布和回收，reader pin 防止提前删除。搜索用的解码缓存只在进程内，关闭数据库时清空。
- `AtomicFileStore`、`LibraryProcessLock`、`LibraryCanonicalRootPath`：`O_NOFOLLOW`、descriptor identity、父/root inode 检查；owner 锁文件按资料库解析后的身份命名，路径被替换时拒绝使用。
- `SQLiteLibraryInitialization` / `LibraryDeletionTransaction`：初始化和删除 receipt、quarantine、同步和崩溃恢复。
- `ImportedFileValidator`、`PDFTextExtractor`、`VisionTextRecognizer`：输入类型、页/像素/输出预算、单页处理和取消检查。
- `LANNetworkInterfaceResolver` / `LANServerTransport`：从连续且非零的 netmask 固化所选接口前缀；未知、不可解析、IPv4-mapped IPv6、跨地址族或越界 socket 对端在安装 HTTP pipeline 前失败关闭。IPv6 global unicast 可用但只接收同前缀对端；当前拒绝需要 zone identifier 的 IPv6 link-local。
- `LANSession`：一次性 pairing、session generation、idle timeout、constant-time comparison、peer/global rate limits。
- `LANHTTPHandler`：authority/origin/framing、header/body deadlines、认证先于 body/remote ID、粗粒度 phone error mapping。
- `SQLiteLANInboxStore` / `LANUploadSink`：接收字节之前登记上传的归属和实际 inode；完成后在同一 inode 上校验长度与摘要，一个事务发布原件、队列项和回执；取消和恢复只清理归属可以证明的文件。
- `LANSessionLifecycleMonitor` / `LibraryLifecycleCoordinator`：停止事件撤销 credential、关闭连接和删除前关闭接收入口。
- `BackupArchivePlan` / `BackupArchiveIndex`：给每个原件分配经过 Unicode、保留名、路径分隔符、长度和碰撞处理的路径，原件路径不含内部 ID；索引只接受 `files/` 下的相对路径，拒绝 `..`、绝对路径、反斜杠、控制字符、重名和超量。
- `SQLiteLogicalBackupSource` / `BackupArchiveWriter`：在一次 admission 内固定 revision、pin 住可达原件并取得数据库的内部副本，之后在副本上逐项严格验证并流式输出逻辑记录；原件在写入时才通过 no-follow descriptor 打开并复核长度/digest/身份。工作文件写在同卷私有非 `.zip` 暂存，全量读回校验后才发布：文件夹内 `RENAME_EXCL`，保存面板目标原子替换；取消和提交前失败不会留下成功外观的 partial。`LibraryLifecycleCoordinator` 让整库删除、恢复和完整性停机先取消并等待已进入的备份或导出，提交阶段不可取消。
- `BackupSettingsStore` / `BackupFolderAuthority` / `BackupFolderRetention`：app-private 0700/0600 记录 bookmark、目录 inode、调度状态与账本，不记录备份内容；每次使用重新解析 bookmark 并核对 inode；保留只删除账本中身份完全一致的文件，其余只从账本移除。
- `BackupArchiveReader`：no-follow 打开所选文件；只读取索引点名的条目，按名字精确查找，不用条目名在磁盘建文件；逐条目限长、核对 CRC-32 与 SHA-256，读完复核源文件身份。
- `BackupRestoreVerifier` / `BackupRestoreTransaction`：首个 staging 字节前先持久化 preflight receipt；只在 app-private 同卷 staging 重建并 strict reopen，确认后以 root-bound typed receipt 执行 replace/rollback，启动时先收敛遗留事务。切换中关闭自动备份；外部备份文件不受影响。
- `DICOMPart10Envelope` / `KinlogueDICOMIPC`：主进程只做有界 Part 10 envelope 与 typed DTO 校验；跨进程只传一个只读 descriptor 和受大小限制的 `Data`，不传 URL、路径或 Vault authority。
- `DICOMFolderScanner` / `DICOMStudyStaging` / `DICOMImportJournal`：security-scoped source 只通过 no-follow descriptor traversal 读取；staging 使用同卷、opaque UUID、私有权限和只读文件。receipt 在首个 staged byte 前持久化并绑定目录 identity；重启清理按资料库登记的归属判断，拒绝 symlink/replacement，失败时保留 opaque receipt 重试。
- `KinlogueDICOMDecoderHelper.xpc`：exact DICOM-Swift 1.5.0 只链接进独立 App Sandbox Helper。Helper entitlement 只有 App Sandbox，无 network client/server、inherit、用户文件或 Vault-root 权限；创建私有临时文件后、写入前立即 unlink，通过仍打开的 descriptor 保存有界独立副本，并以 `/dev/fd` 交给 decoder。最后一个 descriptor 关闭或进程退出后由内核回收，crash/watchdog 不依赖 defer 删除具名原件；解析由硬 watchdog 有界终止。VOI LUT Function 只按单 tag 惰性读取，非 `LINEAR` 函数拒绝，不通过 `getAllTags()` 展开无关自由文本。主 App 没有 `DicomCore` 或 DICOM 网络实现，也没有解码失败时的进程内 fallback；真实进程门禁用合成自由文本/URL canary 验证 unified log 不泄漏且 Helper 运行时无 network socket。
- `DICOMSliceService`：只接受资料库产生的 opaque 会话令牌和 instance descriptor；原件在 decode 前后复核 digest、identity 和长度，raw frame 仍只经 XPC adapter。cache key 不含路径、UID 或 W/L history，错误只暴露固定 Kinlogue case。canonical/current-render 像素只在有界内存中存在；RAII lease 保证 service 释放不遗留预算，switch/close/lifecycle failure 只清对应 session token，pressure 才全局清 cache 并使旧 image handle 失效。这不承诺安全擦除调用方主动复制的 bytes、原始明文附件或系统备份。
- `DICOMImportModel` / `DICOMStudyReviewModel` / `DICOMLibraryModel` / `DICOMStudyViewerModel`：用户界面只显示检查状态、用户确认的成员/日期、modality、尺寸、切片/Series 与 inert-object 聚合状态，不展示或记录文件名、路径、原始 UID 或 DICOM 自由文本。确认后的检查只把日期、成员和对象数量等检查级摘要投影到成员时间线；DICOM 原件、自由文本和像素仍不进入报告 OCR、搜索或比较。Viewer canvas 为当前帧保留一份有界的拥有式内存快照，不写预览/截图；App registry 在单 study 删除、外部删除刷新或 whole-Vault revoke 时先让所有目标窗口同步清空像素/失效请求，再等待 slice service close 并关闭窗口。普通关闭、Series 切换或 memory pressure 同样会使对应旧结果/handle 失效。

- `AssistantContextPackBuilder` / `SQLiteReportRepository.assistantPack`：只取一位成员的已确认报告，在本机分层整理：最多 300 份的目录、结论与标记项、按完全相同的项目名汇总的表格行，以及剩余预算内最新报告的全文，合计不超过 100,000 字节，各层有子上限，每份全文不超过 12,000 字节并标注截断（见[分层上下文包计划](plans/2026-10-18-feat-member-chat-layered-context-plan.md)）；不含姓名、备注、文件名、原件或记录 ID，机构名称默认不放入；报告文字中能闭合输入标签的 `<` 会被转义。
- `SQLiteAssistantRows`：对话、轮次与发送清单逐行带字段分隔摘要，读取时整段核对；完整性巡检把对话作为独立目标。
- `LiveAssistantService` / `AssistantConversationModel`：同意绑定上下文包指纹、CLI 版本、模型和提示词版本，只在内存里，重新打开已保存的对话后第一次发送仍要确认；每轮发送前重查 CLI 状态并核对指纹；每轮在 `LibraryLifecycleCoordinator.withActiveOperation` 内运行，整库删除或恢复会先撤销服务、取消进行中的一轮并清空对话。
- `KinlogueAssistantBridge.xpc` / `CodexBridge` / `CLISupervisor`：bridge 以固定参数启动 Codex（`exec --json --ephemeral --ignore-user-config --ignore-rules --strict-config --sandbox read-only`，关闭会话历史、分析、遥测、网页搜索和子代理（agents），未列入白名单的功能逐个禁用，并改写模型目录去掉工具字段）；输入只走 stdin；环境变量只有 `HOME`（真实家目录）、`USER`、`LOGNAME`、`PATH`、`LANG`、`LC_ALL`、每轮私有的 `TMPDIR` 和用户设置的代理变量，每轮的工作目录与临时目录用后删除。App Sandbox 会把沙盒 supervisor 自己的 `HOME` 与 `TMPDIR` 改成容器路径，因此这些变量以 `KINLOGUE_CLI_ENV_` 前缀交给 supervisor，由它重建 CLI 的环境。能力检查对本机回环模拟服务发一次请求，确认工具数为零、只有两条消息、模型一致、`store` 为 false 且不含本机路径，结果按可执行文件和模型缓存。供用户选择的模型列表取自同一个 `codex debug models` 输出中可见（`visibility` 为 list）的模型，只传 slug 与显示名，二者都按有界文本校验，按可执行文件缓存。子进程在独立进程组中运行，首字节 10 秒、整轮 180 秒超时，输出上限 2 MiB；`--supervise` 进程在 bridge 退出时结束整组。IPC 只传有界文本 DTO，不传文件句柄、记录 ID 或成员名。

这些保护主要解决“意外损坏、错误状态、资源滥用和错误路径写入”；它们不把明文文件变成加密文件。

依赖安全结论是点时证据，不是长期保证。当前版本、公开公告、GitHub 扫描能力和未完成的独立审计见 [依赖安全来源笔记](sources/dependency-security-review-2026-08-23.md)；任何自动更新都必须重新经过本仓库的 XPC、资源、隐私和 untrusted-input 门禁。

## 日志和诊断规则

- 普通 App error 只使用稳定 failure/event code、opaque ID、大小和状态，不输出原文、文件名、URL、完整路径、peer、cookie、CSRF、远端文件 ID 或底层错误文本。
- HTTP log 只允许 route/reason/status class 等 allowlist 字段；`LANHTTPLogEvent` 不携带 target、header、peer、credential、filename、digest 或 underlying error。
- 测试和脚本可以输出合成数据数量、长度和 SHA-256；不能输出合成内容所在的用户路径或复制真实资料。
- 成员对话的 IPC、Codex 适配与 bridge 源码不含任何日志调用，`verify-app.sh` 以源码扫描阻止新增；失败只以固定失败码跨进程返回，Codex 的原始输出不越过 bridge。
- 验收报告只记录 gate、版本、哈希、状态和不含内容的摘要；DICOM 安装门禁只增加合成对象计数、毫秒、RSS、descriptor 和字节数，不记录 tag、UID、文件名、路径或像素。完整地址、验证码、文件名和正文不落盘。

## 数据生命周期

- Mac 选择的源文件不会被修改或删除；App 会复制到自己的 Vault。
- U3 DICOM Platform import 只从 Vault-owned staged bytes 派生持久事实；成功/取消后回收 staging，进程崩溃时由下一次受协调的 reopen/import 回收。原始 DICOM bytes 会作为明文 immutable attachment 保留，但不会进入 OCR、搜索或自动导出，也不会生成持久预览。
- U4 on-demand slice service 不生成持久 thumbnail、preview、截图或像素日志。Vault destroy 在等待 active descriptor read 前撤销 slice lifecycle generation，晚到 transform 不能重新发布旧像素；删除仍是 ordinary unlink，不描述为 secure erasure。
- U5 App 确认只保存用户选择的家庭成员与日期；它不把 DICOM 内容转录成报告字段。删除检查会移除其数据库行和不再共享的 App-owned 原件，最初选择的文件夹不受影响。
- U6 Viewer 只在当前 presentation 内保存 Series/切片、W/L、pan/zoom 与一个可失效 image handle；没有持久 thumbnail、截图、导出、剪贴板或拖放入口。像素本身可能烧录身份信息，因此仍按敏感明文处理；删除检查或整库前会先清空所有相关窗口的拥有式快照，再等待底层 session 关闭。
- 手机完整上传的唯一原件保留在 Mac 待确认队列，直到用户明确删除或把所选项成功归档；不会自动过期。手机只可在当前会话中取消尚未保存的文件，不能删除 Mac 已发布的待确认项。
- 提交后 Vault 原件由 record/draft/source ownership 持有；删除 inbox 副本不会删除已经归档的原件。
- Vault destroy 只删除 App 管理的当前目录，并对目标 inode/path 做绑定检查；它不承诺清除外部副本。
- 已发布的备份 ZIP 位于用户选择的位置，已经离开 Vault 生命周期；Vault destroy 或 restore 不删除、跟踪或安全擦除它，只移除本机的备份设置与账本。用户界面在设置页和导出前说明这是未加密的完整副本。
- 保留清理只针对本机账本记录的、仍未被改动的文件，且不承诺第三方客户端远端已经上传或删除；早期版本写入的 `.kinloguebackup` 和隐藏 `.kinlogue-backup-v1` 目录不被改动。
- 删除失败或发生部分删除时，receipt/quarantine 让后续运行只继续处理已验证的同一目标，不能借路径替换删除另一个 Vault。
- 成员对话保存在资料库的三张 STRICT 表里（schema 版本 3），与报告一样是明文，也进入不加密的备份 ZIP（`data/library.klog`）。删除一段对话、删除成员（同一事务）、整库删除与恢复都在既有生命周期内完成；一轮与它的保存是同一个 active operation，整库删除或恢复会先取消它。关闭功能只停止进行中的一轮，不删除已保存的对话。已经发送给服务方的内容不受续页的任何删除影响。

## Agent 和测试禁区

- 真实病历只能在仓库外做私密人工验收，且不得复制、截图、日志化或放入测试结果。
- DICOM 自动化只能在运行时生成不含 Patient Name/ID/Birth Date 等身份 tag 的 synthetic fixture；仓库和 bundle 门禁拒绝 checked-in `.dcm`、`.dicom`、`.nii` 和 `.nii.gz` fixture。当前 Mac 的 U7 安装验收只使用该生成器；此外，一份经用户明确授权、始终位于仓库外的私有 MRI 样本已完成隔离完整导入并通过，未保留样本、路径、身份 tag、UID、像素或截图。这个结果只覆盖当前 Mac 上的一份样本，更广的厂商、检查类型与独立系统矩阵仍未执行。
- `scripts/privacy-guard.sh` 默认拒绝仓库内 PDF、JPEG、PNG、HEIC 和 TIFF 等受支持报告原件扩展，只精确放行已审查的 AppIcon 文件路径与摘要锁定的合成产品预览；新增图片也必须逐路径评审，不能通过目录级通配放行。该扩展名门禁不声称能语义识别任意 PHI；已知敏感值仍通过 `KINLOGUE_FORBIDDEN_VALUES` 扫描，代码、文档和其他扩展中的身份信息继续受仓库禁区约束。
- `scripts/privacy-guard.sh` 与 `scripts/privacy-history-guard.sh` 还拒绝当前树和历史中的备份包（`kinlogue-backup.json`、`续页备份*.zip`、`Kinlogue Backup*.zip`、`.kinloguebackup`），`.gitignore` 也忽略这些名字。
- `scripts/privacy-history-guard.sh` 通过 Git object database 扫描准备公开的 reachable refs，覆盖曾提交后删除的医疗/报告类附件、备份或签名容器、`.env`/私钥路径、完整格式的恢复码、常见凭据模式、精确私密资料库存证据和调用方提供的 forbidden values；`.env.example` 是唯一环境文件名例外。门禁只报告规则类别，不回显命中路径或内容；它不能替代公开托管平台上的 PR、Issue、Actions log、release asset 和 fork 审计。
- 不要使用真实文件名来验证去重、展示名、OCR 或 LAN；使用生成 fixture 和 run-scoped canary。
- 不要因为调试方便打开内容日志、保存 cookie/验证码、把 App Sandbox 路径写进报告或把整页 PDF 输出到终端。
- 自动化只能用假 CLI 和合成资料驱动成员对话；`verify-assistant-xpc.sh` 对真实 Codex 只做不耗额度的本机能力检查。经真实 Codex 的一轮会消耗用户额度并把内容发给服务方，只能在用户明确同意后用合成资料进行，不得发送真实病历。
- 不要在未确认可信网络前启动 LAN listener；不要把 `network.server` entitlement、可行性 marker 或 test-only client entitlement 扩大到不该有的 bundle。
- 修改 `README.md`、`PRIVACY.md`、`packaging/Info.plist`、entitlements、验证脚本或网络行为时，必须一起检查本页和对应验收文档。

README 的合成产品预览 `docs/assets/kinlogue-overview-2026-10.jpg` 也经过逐文件审查；当前树门禁与历史门禁均按精确路径和固定 SHA-256 放行。历史中曾替换成未批准内容，即使后来恢复原图，历史门禁仍拒绝。

当前预览图使用带日期的文件名，是因为它在“同一路径可登记多条摘要”的规则合入之前更新，当时历史门禁对每个路径只认一个摘要。旧路径 `docs/assets/kinlogue-overview.jpg` 只为历史中的原图保留登记，当前树门禁不再接受该路径上的任何文件。今后更新预览图不需要再换文件名：替换文件后更新 `privacy-guard.sh` 中的预览图摘要，并在摘要清单里为同一路径追加一行。预览图必须只含合成数据；当前这张由测试进程用假数据服务渲染真实的 App 界面生成，没有启动 App，也没有截取屏幕。

历史门禁的已审查摘要登记在 [`scripts/privacy-history-media-digests.txt`](../scripts/privacy-history-media-digests.txt)，每行是一组“摘要 + 精确路径”。已替换的应用图标仍留在可达历史中，所以同一路径可以登记多条摘要，每个历史版本都必须命中其中一条；完全重复的行、未列入门禁路径清单的路径，以及缺少任何一条摘要的路径都会让门禁失败。更换图标时只追加新行、保留旧行；图标母版和生成方式见 [`brand.md`](brand.md)。当前树门禁仍只按精确路径放行 AppIcon 位图，不校验其摘要。

## 未来安全升级边界

资料库与备份都不使用应用层加密，也不使用 Keychain。早先的备份认证加密已于 2026-10-19 按用户决定移除（见 [`decisions.md`](decisions.md)）；备份索引保留 `encryption` 字段，将来可以在整个 ZIP 外加一层而不改内部结构。内置云同步、资料库或备份加密和多设备合并仍属于后续独立决策。任何升级必须同时提供迁移格式、密钥生命周期、失败恢复、重启校验、旧数据保留/删除策略和新的 threat model。
