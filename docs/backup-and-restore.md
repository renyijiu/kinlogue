# 备份、导出与恢复

续页把完整资料库写成一个 **不加密** 的 ZIP 备份包。同一种文件同时用于三件事：解压后按家庭成员和日期查看、打印原件；放在用户选择的文件夹里按份数轮换；以及在本机或另一台 Mac 上整库恢复。设计取舍见 [明文 ZIP 备份与导出计划](plans/2026-10-19-1715-feat-plain-zip-backup-export-plan.md) 和 [`decisions.md`](decisions.md) 2026-10-19 一节；它取代了早先的加密恢复点和“只含已确认原件”的导出。

这不是网盘 API 集成。续页没有互联网客户端、网盘账号或远端状态接口，只能证明所选文件夹中的本地文件已经完整写入并读回校验；文件夹若与 Mac 一起丢失，备份也随之丢失。

## 备份包格式 v1

```text
续页备份 2026-10-19 153012.zip
├── kinlogue-backup.json        # 索引（第一个条目，deflate）
├── 说明.txt                     # 给人看的说明，按写出时的界面语言；恢复时忽略
├── data/library.klog           # logical-v1 数据流（deflate）
└── files/                      # 每个原件恰好一份（stored）
    ├── <成员>/<日期> - Report 0001 - Source 0001 - <来源名>.<扩展名>
    ├── <成员>/<日期> - DICOM 0001/0001.dcm
    ├── _待确认/Draft 0001 - Source 0001 - <来源名>.<扩展名>
    ├── _待确认/DICOM 0001/0001.dcm
    ├── _手机待整理/0001 - <显示名>.<扩展名>
    └── _其他/0001.<扩展名>
```

- **索引** [`BackupArchiveIndex`](../Sources/KinlogueCore/Backup/BackupArchiveIndex.swift)：`format`、`formatVersion`、`minimumReaderVersion`、`encryption: "none"`、`backupID`、整秒的 `createdAt`、写出它的版本、资料库的 `libraryID / generation / commitID`、各类计数、数据流的路径/长度/SHA-256，以及每个原件的 id、路径、长度、SHA-256 和内容类型。UUID 为小写，摘要为小写十六进制，JSON 按键排序并缩进。新版本写出的未知字段被忽略；`minimumReaderVersion` 高于当前 reader 或 `encryption` 不是 `none` 时以“格式不受支持”拒绝。
- **数据流** 沿用 [logical-v1](sqlite-storage.md#逻辑数据流与备份)：成员、报告与 OCR 复核、草稿、LAN 队列与回执、规范化 DICOM 图；不含 SQLite 文件。冻结夹具继续验证当前 reader 能读既有 wire bytes。
- **路径规划** [`BackupArchivePlan`](../Sources/KinlogueCore/Backup/BackupArchivePlan.swift) 从同一次捕获的数据流读出成员、报告来源、草稿、DICOM 与 LAN 记录，给每个原件分配唯一路径：已确认报告和已确认影像按成员（含已归档成员）与日期排列，沿用早先导出的命名；未确认报告、草稿和待确认影像放进 `_待确认`，手机上传放进 `_手机待整理`，任何没有被这些记录命名的原件放进 `_其他`，不会被漏掉。同一原件被多处引用时只写一次，放在规划顺序中第一次出现的位置。名称经过 Unicode 规范化、控制字符与 `<>:"/\|?*` 替换、Windows 保留名加前缀，单段不超过 120 字节、整条不超过 512 字节，在大小写不敏感的文件系统上也不重名；内部 UUID 不进入 `files/` 下的路径。`_` 开头的文件夹名按写出时的界面语言本地化，恢复不依赖它们。
- **上限**：原件不超过 25,000 个，索引不超过 16 MiB，数据流与原件合计不超过 4 TiB；超过 4 GiB 或 65,535 个条目时使用 ZIP64（锁定的 ZIPFoundation `0.9.20` 包含该实现，大包未实测）。

## 写入

[`BackupArchiveWriter`](../Sources/KinloguePlatform/Backup/BackupArchiveWriter.swift) 每次写一份：

1. 用 [`SQLiteLogicalBackupSource`](../Sources/KinloguePlatform/Backup/SQLiteLogicalBackupSource.swift) 在一次 admission 内固定 revision、pin 住全部可达原件并生成数据流；之后的合法编辑或删除不改变这份备份。
2. 规划路径、计算数据流摘要并生成索引。
3. 在目标所在卷的私有 item-replacement 目录中写工作文件（不带 `.zip`）：先索引和说明，再数据流，最后逐个原件；原件逐块读取并核对长度、SHA-256 和文件身份，摘要不符时原件被标为损坏、备份失败。
4. 容量预检要求原件与数据流总量、每条目 1 KiB 开销和 256 MiB 余量。
5. 同步后重新打开，按顺序逐项解出并核对路径、长度、CRC-32 和 SHA-256，再核对 pin 与 spool 仍未变化。之后进入不可取消的提交。
6. 发布：
   - **备份文件夹**：用 `renameatx_np(RENAME_EXCL)` 以 `续页备份 <本地日期时间>.zip` 放入文件夹，同名时依次尝试 ` (2)`、` (3)`……，从不替换已有文件。
   - **导出到所选位置**：沿用保存面板的原子替换：有 security scope 时经 `NSFileCoordinator`，否则绑定父目录 descriptor 用 `renameat`；目标在资料库内、不是 `.zip`、是 symlink 或父目录在发布前被替换时拒绝。
7. 发布后尽力同步父目录；保存面板只授予文件、或卷不支持目录同步时不算失败，真正的 I/O 错误报告“发布状态不确定”。

[写入器测试](../Tests/KinloguePlatformTests/BackupArchiveWriterTests.swift) 覆盖条目顺序与压缩方式、索引与数据流摘要、文件权限、文件夹内不覆盖并取下一个名字、拒绝库内与非 zip 与 symlink 目标、发布前父目录被换成指向资料库的 symlink、读回时发现损坏、读取不足、取消、目录访问的开始与结束成对、拒绝访问、父目录同步失败与可接受的同步错误，以及空资料库也能写出可恢复的备份。

## 文件夹、自动备份与保留

- 文件夹由 [`BackupFolderAuthority`](../Sources/KinlogueApp/Backup/BackupFolderAuthority.swift) 记录：拒绝资料库所在或其上层目录、symlink、文件系统根、iCloud 目录和只读目录，保存 security-scoped bookmark 与目录 inode。每次使用都重新解析 bookmark、在整个写入/列举/删除期间保持访问，并核对 inode；只比较 inode，卷被重新编号后仍认得同一个文件夹。bookmark 失效、文件夹被替换时需要重新选择；磁盘未连接或共享离线时记为“暂时不可用”。
- 设置与账本由 [`BackupSettingsStore`](../Sources/KinloguePlatform/Backup/BackupSettingsStore.swift) 保存在 App 私有的 `Application Support/Kinlogue/Backup/settings.json`（目录 0700、文件 0600），每次修改在进程锁和 `flock` 下读改写并原子替换。内容是文件夹 bookmark 与身份、自动备份开关、保留份数、调度时间与最近失败、以及**账本**：本机写入文件夹的每份备份的文件名、inode、大小、修改时间、单调序号、backupID 与对应的资料库提交。更换文件夹会清空账本；旧文件夹里的备份从此不归续页管理。
- 保留由 [`BackupFolderRetention`](../Sources/KinloguePlatform/Backup/BackupFolderRetention.swift) 和 Core 的 [`BackupRetention`](../Sources/KinlogueCore/Backup/BackupRetention.swift) 执行：新备份发布后才开始；账本条目对应的文件必须仍是同名、同 inode、同大小、同修改时间、单硬链接的普通文件，否则从账本移除而**不删除**；在仍对得上的条目中按序号保留最新 N 份（1–30，默认 5），其余删除前再核对一次身份。新备份本身对不上时一个也不删；文件夹打不开或检查出错时保留账本、标记延后。手动和自动备份共用这一池；“导出备份到…”不进账本。
- 自动备份由 [`BackupScheduler`](../Sources/KinlogueApp/Backup/BackupScheduler.swift) 安排，只在 App 运行时工作：资料变化后等 5 分钟静默期，距上次备份至少 24 小时，启动、激活、唤醒时补做；文件夹暂时不可用或备份期间资料变化时按 1、5、15 分钟有界重试，之后停止并保留可见失败；需要用户处理的失败（重新选择文件夹、空间不足、资料库读不出、验证失败、发布状态不确定）不自动重试，下一次资料变化会重新安排。时钟回拨时沿用已记录的到期时间，不会因此停用。
- 手动备份、自动备份和导出都经过同一个 [`BackupOperationCoordinator`](../Sources/KinlogueApp/Backup/BackupOperationCoordinator.swift)，同一时间只写一份；它们也计为资料库的活动操作，因此恢复、删除资料库和完整性停机会先取消并等待未发布的备份。

## 恢复

入口在设置页、资料库无法打开时的降级启动页和完整性失败提示中：

1. 选择一个 `.zip`。
2. [`BackupArchiveReader`](../Sources/KinloguePlatform/Backup/BackupArchiveReader.swift) 把整个文件当作不可信输入：no-follow 打开普通文件，读中央目录并拒绝重名条目和超量条目；在根目录或**唯一一个**顶层文件夹下找到索引（兼容解压后用访达重新压缩）；严格解码索引，核对它点名的每个条目都存在、是普通文件且大小一致。索引没有点名的条目（自己加的文件、`__MACOSX/`、路径穿越的名字）一律不读。包内名字从不用来在磁盘上建文件。
3. [`BackupRestoreVerifier`](../Sources/KinloguePlatform/Backup/BackupArchiveRestore.swift) 做容量预检、写 preflight 收据、在 App 私有同卷 staging 中把数据流写入 spool、把每个原件写到 `originals/<uuid>.data`；解出时边读边计数，超过声明大小立即中止，读完核对 CRC-32 与 SHA-256；读完再核对源文件未被替换或改写。
4. [`SQLiteLogicalRestore`](../Sources/KinloguePlatform/Backup/SQLiteLogicalRestore.swift) 只把有界逻辑值写入新建数据库：资料库标识必须与索引一致，原件集合与每个原件的长度、摘要、类型必须与索引一一对应；随后做完整严格验证，成员、记录与手机上传计数也要与索引一致。
5. 界面显示备份时间、写出它的版本、成员、记录、手机上传项、原件数和资料大小，不显示健康内容。
6. 用户确认后，[`BackupRestoreTransaction`](../Sources/KinloguePlatform/Backup/BackupRestoreTransaction.swift) 做 whole-root 切换：收据先于切换持久化，激活后严格验证，失败回滚；中断由下一次启动收敛到完整旧根、无根或完整新根。切换过程中关闭自动备份（保留文件夹与账本，避免恢复到旧状态后自动备份把恢复前更新的备份轮换掉）；设置记录读不出时直接移除它，不挡住恢复。
7. 成功后只能退出并重新打开；按钮先解除窗口对退出的拦截再终止，终止被拒时直接结束进程（[`RestartRequiredQuit`](../Sources/KinlogueApp/App/RestartRequiredQuit.swift)）。

确认前的任何失败（不是续页备份、格式更新、空间不足、内容或索引不一致、文件被改动）都不会替换当前资料库，可以重新选择。[恢复测试](../Tests/KinloguePlatformTests/BackupArchiveRestoreTests.swift) 构造了加入额外条目、访达式顶层文件夹与全部 deflate、不是 ZIP、没有索引、两个索引、原件翻转一个字节、缺条目、重名条目、数据流损坏、索引声明更短、计数或资料库标识不符、要求更新版本、声明加密，以及真实膨胀超过 ZIP 头所声明大小的条目；[激活测试](../Tests/KinloguePlatformTests/BackupArchiveActivationTests.swift) 覆盖已有资料库的整根替换、旧根移走后中断的回滚、新根就位后中断的提交（含卷重新编号）、截断的事务收据失败关闭和只清理有收据的废弃预检；[逻辑备份测试](../Tests/KinloguePlatformTests/SQLiteLogicalBackupTests.swift) 用真实仓库、LAN 上传和 DICOM 建库，经 ZIP 恢复后逐项核对并可再次备份；[进程测试](../Tests/KinlogueStorageProcessTests/SQLiteLogicalRestoreProcessTests.swift) 在每个 durable phase 让真实子进程 `SIGKILL` 后由新进程收敛。

## 旧版本留下的东西

- 早期写入的加密 `.kinloguebackup` 恢复点不能被当前版本读取；需要时使用旧版本 App。
- 用户文件夹里的隐藏 `.kinlogue-backup-v1` 目录不会被续页改动。
- 旧版本在 `Application Support/Kinlogue/BackupIdentity/` 保存的设备签名私钥、恢复公钥和验证记录，会在启动时由 [`LegacyBackupIdentityCleanup`](../Sources/KinloguePlatform/Backup/BackupSettingsStore.swift) 移除：只删除那几个已知文件名的本人普通文件，目录里有其他内容时目录保留。

## 安全边界

- 备份不加密。拿到文件的人能读取全部成员、报告、OCR 转录和原件；网盘同步目录意味着服务商和能登录该账号的人都能读取。设置页、导出面板、说明文件和 [`../PRIVACY.md`](../PRIVACY.md) 都写明这一点。
- SHA-256 与 CRC-32 只发现意外损坏，不防篡改：同时改了内容和索引的包会被当作有效备份。恢复只在用户亲自选择并确认时发生，所有记录仍按资源上限和完整图严格校验，内容不会被执行。
- 活动资料库本来就是明文；“没有账号、云同步、遥测”的边界不变，续页不调用任何网盘 API。
- 早期加密设计的威胁模型与实现记录保留在 [加密目录备份计划](plans/2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md)，只用于解释决策来源。

## 当前验证边界

上述测试与 App 层的 [备份服务测试](../Tests/KinlogueAppTests/LiveBackupServiceTests.swift)、[调度测试](../Tests/KinlogueAppTests/BackupSchedulerTests.swift)、[文件夹授权测试](../Tests/KinlogueAppTests/BackupFolderAuthorityTests.swift)、[设置模型](../Tests/KinlogueAppTests/BackupModelTests.swift)、[导出模型](../Tests/KinlogueAppTests/BackupExportModelTests.swift) 与 [恢复模型](../Tests/KinlogueAppTests/RestoreModelTests.swift) 测试都只在当前 Mac 的开发构建上运行。尚未执行：安装后的 App 上实际选择文件夹、立即备份、轮换与恢复；接近上限（ZIP64、约 25,000 个原件）的写入与恢复耗时；阿里云盘、百度网盘客户端对文件夹中文件的处理（是否替换文件导致账本对不上、是否上传工作文件）；外置盘、NAS 与沙盒中 item-replacement 目录的行为；Windows 和访达对包内中文路径的解压；macOS 26/27 独立机器、键盘与 VoiceOver。准确状态见 [`acceptance/current-release.md`](acceptance/current-release.md)。
