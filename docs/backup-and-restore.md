# 加密目录备份与恢复

续页可以把完整资料库写成自包含的 `.kinloguebackup` 加密恢复点。用户选择一个父目录，App 在其中创建固定的 `.kinlogue-backup-v1` 专用子目录；父目录可以是普通本地目录、外置盘、已挂载 NAS，或阿里云盘、百度网盘等桌面客户端管理的同步目录。

这不是网盘 API 集成。续页没有互联网客户端、网盘账号或远端状态接口，只能证明所选目录中的本地恢复点已经完成写入、重新打开、认证和完整读取。界面始终把“本地恢复点已验证”和“网盘同步状态未知”分开；普通本地目录若与 Mac 一起丢失，不能提供异机防丢失能力。

## 用户流程

### 首次设置

1. 在“设置 → 数据备份”选择父目录；系统目录选择面板授予持久的 security-scoped bookmark。
2. 续页创建专用 repository，生成一个 256-bit 随机恢复码，并要求完整回输和确认已经独立保存。
3. 自动备份默认关闭。设置完成后可以手动“立即备份”，或再开启自动备份。

专用 repository 的名称以 `.` 开头，Finder 默认不会在父目录列表中显示它。设置页提供“在访达中显示”，直接打开实际保存 `.kinloguebackup` 文件的 repository；手动备份运行期间显示明确的创建中状态，完成后才刷新“最近本地验证”。

恢复码及其恢复私钥不会写入 Keychain、UserDefaults、配置文件或 repository。本机只保存不能解密恢复点的加密公钥和设备签名身份；遗失恢复码时续页无法找回或解密既有恢复点。

如果首次设置已经持久化本机备份身份、但在 repository 发布完成前中断，设置页会在重启后显示“未完成”状态。用户可以输入自己独立保存的原恢复码继续同一 enrollment；这条路径复用原有恢复根、设备签名身份和 writer epoch，不生成新的恢复码或 signer。也可以通过二次确认显式放弃本机 pending identity 后重新配置；放弃失败会保持 pending 状态并显示错误，不会静默清除。恢复码输入只保留在当前恢复操作的内存状态中，成功、失败、取消或放弃后立即清空。

### 手动与自动备份

- 手动备份每次都会创建新的恢复点。
- 设置页加载和普通状态刷新只读取 app-private 配置、scheduler metadata 与目的地授权状态，不冻结或逐对象枚举活动资料库。当前状态页不显示需要全库扫描才能得到的空间估算；实际手动/自动备份仍在操作开始时生成并验证权威 source plan，容量门禁也继续使用该计划。
- 关闭自动备份只更新 app-private scheduler 配置，不准备 source plan，也不冻结或逐对象枚举活动资料库；重新启用时仍先生成权威 source plan，再开始观察 revision 和安排任务。
- 自动备份只在 App 运行时工作；durable Vault/LAN inbox revision 变化后等待 5 分钟静默期，两个已验证恢复点之间至少间隔 24 小时，并在启动、激活或唤醒时补偿到期任务。
- 自动备份若在目录授权预检或恢复点创建期间明确遇到 repository offline，会把失败和到期时间持久化，并最多按 1 分钟、5 分钟、15 分钟安排三次有界退避；当前 App 运行期间由内存 timer 到期触发，不依赖新的唤醒或资料变化。退出只取消内存 timer，不清除 durable due，重启后继续原等待；目的地恢复且到期后自动重试，成功会清除失败和 attempt。若成功解析目的地时当前 revision pair 已由原恢复点覆盖，scheduler 只清除这组可恢复失败与重试 metadata，不创建新恢复点，也不推进“最近本地验证”；actionable failure 继续保留。超过上限后停止自动安排并保留可见失败。bookmark 需要重选、身份冲突/历史分叉、认证、容量、资源上限、publication indeterminate 和验证失败不会进入这条重试。
- 同一进程中的手动、自动、保留清理、恢复和整库删除经过同一个串行 operation fence。跨进程 writer 还必须取得 app-private 备份身份目录本身的 owner-only、no-follow publication lease；该目录 inode 与当前 configuration root、repository、backup set、authorization 和 writer epoch 绑定，不依赖同步 repository 中可被替换的命名 lock 文件。权威扫描、sequence 分配、排他发布、正式文件完整回读和 durable witness 写入在同一 lease 内完成，并保持 `repository → app-private configuration` 锁顺序。sequence 同时取当前可见最大值、当前 writer 的 durable witness 高水位和 authorization floor 的保守后继，因此最新叶暂时消失后重启也不会复用已见序号。
- 默认保留 5 份，允许 2–30。手动和自动恢复点使用同一个池。
- 只有新的恢复点在正式文件上完整回读验证并写入 durable witness 后，旧恢复点才进入清理候选；还要连续观察至少 24 小时。损坏、未知、分叉、身份不匹配或缺少 witness 时不会删除任何恢复点。
- 一次保留清理在固定 publication lease 内只做一次权威全目录扫描并形成删除批次；扫描前后固定 repository 目录 generation。批次中的每个目标仍在 `beforeDelete` 窗口后按固定叶名重开，逐项复核 regular/single-link 文件身份、认证 checkpoint 内容和 repository identity digest，并精确重验计划保留的全部叶；目录发生未由本批删除产生的增删/替换，或任一保留叶缺失/换 inode，都会在 unlink 前保守推迟。配置 revision、writer identity、保留策略或 witness 在删除前改变也会推迟，成功删除后才推进本批 generation 与下一项，因此成本仍是一次 O(repository) 权威扫描加每个删除叶/有限保留集合的精确验证，而不是为 28 个删除目标重复 28 次全目录读取。
- 删除失败不会推翻新的成功备份，只会显示清理延后。保留数量是本地目录的最终目标，不是网盘远端保留数量承诺。

### 恢复

恢复入口在正常设置页，以及资料库缺失、损坏或版本不支持的降级启动界面中都可用：

1. 用户选择已下载到本机的 `.kinloguebackup`，输入恢复码。
2. 续页在 App 私有、同卷 staging 中解密，并以真实 Vault 和 durable LAN inbox validator 做非修复式完整验证。
3. 界面只显示成员、记录、待确认项目数量和解密后大小，不显示健康内容。
4. 用户再次确认后，恢复会替换而不是合并当前资料库；durable receipt 保护 whole-root 切换、回滚和下次启动收敛。
5. 成功后必须退出并重新打开 App。本机备份配置会移除，外部恢复点保持不变，也不会被自动采用为新的备份目标。

确认替换后，`LibraryLifecycleCoordinator` 会取消并等待已经进入的普通报告导入、重试和重新 OCR，以及 LAN、DICOM 与原件导出操作；这些任务到达终态后才允许 whole-root 切换。并发选择恢复点使用 operation generation 隔离，较旧的迟到 preparation 只能清理自己的 staging，不能覆盖或取消较新的已验证恢复点。

验证失败、错误恢复码、空间不足、截断/篡改、未知格式或对象图不完整都不会替换当前资料库。确认前的失败仍可取消并重新选择；确认后的 activation 失败已经进入 destructive convergence，界面只允许退出并重新打开 App，不再声称当前资料库没有变化。解密 staging 的 receipt 在首个明文字节前持久化；启动时先清理或收敛遗留恢复事务，再开放普通存储服务。

## 格式与安全边界

- 一个恢复点覆盖 exact `VaultRevision` 与 exact durable LAN inbox revision，以及两者的完整 committed reachable graph；不包含 LAN partial、进程内任务、未提交 staging 或 App 偏好。
- 每次使用新的 DEK；CryptoKit HPKE `Curve25519/SHA-256/ChaChaPoly` 封装 DEK，payload 使用 AES-256-GCM、最多 256 KiB 的认证 frame。manifest 加密，footer 由 recovery-root 授权的设备 Ed25519 身份签名。
- repository 只接受固定 opaque 叶名、regular file、单硬链接和有界大小；读取、发布与删除均基于 no-follow descriptor 和 identity 复核。正式叶排他发布，不覆盖同名文件。
- publication mutex 是 app-private configuration root 的固定目录 inode；同步 repository 中遗留或外部创建的 `.kinlogue-publication.lock` 只作为兼容保留项忽略，不能参与互斥或替换真实 lease。保留清理与发布采用相同 lease 和 `repository → app-private configuration` 锁顺序，避免 scan/delete 与 publish 交错。
- 备份配置的发布 fence 绑定稳定 writer identity（enrollment/writer epoch、backup set、device authorization 与 repository/config identity），而不是易变的配置 revision。自动开关、保留数量、scheduler、bookmark refresh 和已有 witness 可以在写入期间合法变化；最终 witness 会在配置的跨进程锁内追加到最新、仍属于同一 writer 的记录。若 reset/re-enrollment 已改变稳定身份，发布前失败关闭；若正式文件发布后已无法确认同一 writer，则报告 publication indeterminate 且不删除所有权无法证明的 final。
- 当前活动 Vault 仍是 App Sandbox 内的明文资料库。备份加密不会把活动 Vault、Time Machine 或 APFS 快照变成加密内容。
- 同一 macOS 登录会话中的恶意软件或管理员不在保护范围。若本机设备签名私钥被复制，攻击者可以伪造该 backup set 下的新恢复点；包含该事件只能停止旧 writer 并创建全新的 backup set。恢复码遗失或泄漏同样没有服务端补救路径。
- fresh Mac 仅凭恢复码和当前可见文件可以验证、解密和恢复，但无法证明同步目录没有隐藏更新或回滚到更旧的可见历史；发生序列分叉时续页暂停写入和清理，不静默选择赢家。

## 当前验证边界

Core/Platform/App 自动化覆盖 canonical 格式、pending enrollment 重启恢复与显式放弃、错误恢复码、篡改/截断、资源上限、目录替换、稳定 writer 配置变化、真实双进程线性 publication、保留策略、私有 staging、whole-root 回滚、设置模型和降级恢复。LAN 图证据通过真实 store upload 与 `LANDerivedArtifactSink` 同时形成 reviewable derived artifact 和 durable `.preprocessing`：权威 source plan/container 包含前者的真实字节、排除 transient partial；生产 `BackupRestoreVerifier`/transaction 恢复后 strict validator 接受完整图，派生叶被逐字节篡改时拒绝，正常启动又把没有 partial 的 preprocessing 收敛为可重试 `.failed(.storageFailure)`，不会伪装成 reviewable。跨进程恢复探针不再维护第二套 activation 状态机：seed 只生成合成 checkpoint，execute 与 relaunch reconcile 直接调用生产 `BackupRestoreVerifier` 和 `BackupRestoreTransaction`。当前 Mac 的真实子进程矩阵会在 existing root 的 intent、writer reset、old-root move、new-root activation、validation、commit 六个 durable phase，以及 absent root 适用的五个 phase 触发 `SIGKILL`；新进程必须收敛到精确旧根、空根或新根，并由真实 Vault 与 durable LAN inbox strict validator 证明 receipt、staging 与 rollback 已清理。隔离的 ad-hoc probe 还完成了 20,000 对象、2 GiB 合成数据的流式备份和完整读取。

activation 的安装探针按生产事务契约逐 phase 固定终态，不再把任意旧根或新根都视为成功：existing root 在 intent、writer reset、old-root move 后必须恢复精确旧根，后续三 phase 必须保留新根；absent root 在 intent、writer reset 后必须保持无根，后续三 phase 必须保留新根，且每项都要求 transaction/preflight receipt、staging 与 rollback 全部不存在。另一个 production integration case 在 preparation 已通过后定长破坏 staging 中的 committed Vault object；`BackupRestoreTransaction.activate` 的 activation 后 strict validation 必须返回 `graphInvalid`，并立即恢复逐文件相同的旧根或原本的无根状态，同时清空上述事务工件。

当前 Mac 已人工完成真实 Powerbox 目录设置和多次“立即备份”，并在 Finder 中核对专用 repository 内存在多个完整 `.kinloguebackup` 文件；该证据只覆盖本机已安装开发候选，不代替正式分发门禁。尚未执行的人工/分发门禁包括：手动恢复、真实阿里云盘/百度网盘客户端传播、外置盘/NAS、macOS 14/15 独立机器、Developer ID/notarization，以及键盘/VoiceOver 恢复流程。准确状态见 [`acceptance/current-release.md`](acceptance/current-release.md)。
