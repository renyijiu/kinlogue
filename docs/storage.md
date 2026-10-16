# 存储格式与持久化不变量

> **当前状态**：资料库只有一种格式：SQLite 数据库加原件目录，细节见 [SQLite 存储专题](sqlite-storage.md)。早先的 JSON 清单实现（`PlaintextVault`、独立的 LAN inbox 清单及其写锁）已于 2026-10-13 从本分支删除，代码里不再有能创建、读取或写入那种资料库的路径；遇到这样的目录时原样保留并拒绝打开。本页只保留跨专题的持久化不变量：根目录在哪里、目录里有什么、怎样删除、有哪些上限。

## 资料库根目录

生产运行时由 `AppRuntimeIdentity` 固定到：

```text
~/Library/Application Support/Kinlogue/Vault/
```

验收运行使用带随机 run ID 的隔离目录：

```text
~/Library/Application Support/Kinlogue/Acceptance/<runID>/SourceVault/
```

路径由系统 Application Support、签名 bundle identity 和验收配置推导；生产 App 不接受环境变量或任意用户路径作为资料库根目录。

## 根目录布局

```text
Vault/
├── library.sqlite          # 成员、报告、草稿、OCR、LAN 队列、DICOM 层级与全部引用关系
├── originals/              # 原件，每个一个文件：<uuid>.data
├── dicom-import-journals/  # 导入期间的归属收据，导入结束即清空
└── dicom-import-staging/   # 导入期间的同卷只读副本，导入结束即清空
```

数据库事务是唯一的逻辑提交点。原件是不可变的普通文件，名字只由服务端生成的 UUID 构成；展示名、URL、用户输入和手机文件名都不进入路径。原件按 staged → live → deleting 三个状态登记在数据库里：先登记归属并写入、哈希、同步，再在发布领域引用的同一事务里变为 live；最后一条引用被移除的事务把它标为 deleting，文件在没有读取者之后才回收。中断后重新打开时，公开状态只能是完整的旧提交或完整的新提交。连接配置、schema、行摘要、原件生命周期、巡检和各领域的事务见 [SQLite 存储专题](sqlite-storage.md)。

OCR 文档、LAN 预处理结果和 DICOM 的 study/series/instance 都是数据库行，不再有单独的 OCR 文件、派生文件或 study index 文件。切片像素不写入资料库。

DICOM 导入开始前先在 `dicom-import-journals/` 原子写入归属收据，再创建并绑定本次操作的暂存目录的 device/inode；回收只通过 descriptor 相对的 no-follow 操作处理身份匹配的文件，遇到符号链接、未知条目或目录被替换时拒绝删除并保留收据。导入流程、XPC、切片服务和 Viewer 见 [`dicom.md`](dicom.md)。

## 其他格式的目录

[SQLiteLibraryStore](../Sources/KinloguePlatform/Storage/SQLiteLibraryStore.swift) 在打开已有文件前只读核对 SQLite header、`application_id`、`user_version` 和日志模式。唯一的例外是 schema 版本 1：它在通过版本 1 的全部校验后迁移为版本 2，只新增成员对话的三张表（见 [`sqlite-storage.md`](sqlite-storage.md) 与 [`decisions.md`](decisions.md) 2026-10-16）。根目录里出现它不认识的内容时返回“格式不受支持”，不迁移、不改写、不删除：早先版本留下的 `library.json` 资料库、未知 schema 和其他非空目录都按此处理，[回归](../Tests/KinloguePlatformTests/SQLiteLibraryStoreTests.swift) 核对目录内容和字节保持不变。启动页说明格式不受支持，只提供从恢复点恢复的入口。在这样的目录上确认恢复，会用恢复点的内容整根替换它，下一次启动打开恢复后的资料库；被替换的旧目录先移到资料库旁，由下一次启动收敛时删除，之后不再保留（[回归](../Tests/KinlogueAppTests/SQLiteAppStartupTests.swift)）。把已有 JSON 资料迁入需要另行验证的离线转换，本分支没有提供；这部分代码已经删除，需要它的人只能从 Git 历史取回，转换结果只能以恢复点的形式经上述恢复入口装入。早先版本写出的文件树格式恢复点同样被拒绝，见 [`backup-and-restore.md`](backup-and-restore.md)。

## 文件系统安全与删除

- 资料库根目录、原件目录和事务收据必须归当前用户所有；管理目录使用私有权限（通常 `0700`），收据使用 `0600`。
- 文件打开和目录访问使用 `O_NOFOLLOW` 与 descriptor 身份检查，避免路径被换成符号链接后写到别处。
- 一个资料库同一时间只有一个 owner。[SQLiteLibraryOwner](../Sources/KinloguePlatform/Storage/SQLiteLibraryOwner.swift) 在打开数据库之前对根目录旁的锁文件取 `flock`，第二个进程或同进程的第二次打开立即得到“被占用”；进程退出时内核释放锁。锁文件名由根目录解析后的身份推导，经符号链接父目录或大小写不同的别名到达同一个库时争用同一把锁；锁路径被换成符号链接或非普通文件时拒绝使用。
- 删除先写一个绑定规范根路径和 device/inode 的收据，再把当前目录移入确定的隔离位置。清理先打开并绑定隔离目录的 descriptor，只通过 `openat` / `fstatat` / `unlinkat` 和 no-follow 规则递归处理原目录内容；即使隔离目录的名字随后被替换，也不会进入替换目录，名字与已绑定身份不一致时保留收据并失败关闭。
- 启动在取得 owner 之后、打开数据库之前收敛这笔已授权的删除；因此一份有效的删除收据可以删掉随后被判定为不受支持或已损坏的原目录。没有收据时，不受支持的格式、未知布局和损坏内容都保持不变并失败关闭。
- 删除不承诺抹除 Finder 里的原始文件、Time Machine、APFS snapshot、系统备份或其他副本；它只管理 App 自己的当前资料库。

## 存储资源上限

这些是安全和解码上限，不是对用户磁盘总量的承诺：

| 对象 | 上限 |
| --- | ---: |
| 单个导入文件（图片或 PDF） | 100 MiB、PDF 200 页 |
| 报告数、草稿数 | 各 20,000 |
| 报告与 DICOM 引用的原件总数 | 20,000 |
| 单个成员、单份草稿、同一 owner 的来源集合 | 16 MiB canonical JSON |
| 报告的 OCR 文档 / LAN 来源的 OCR 文档 | 16 MiB / 32 MiB |

DICOM 另有以下门禁：

| DICOM | 上限 |
| --- | ---: |
| 单 study 保留对象 | 2,000 |
| 资料库 study 数 | 256 |
| 资料库 DICOM 原件数 | 10,000 |
| 资料库累计 Series | 4,096 |
| 单 study 的逻辑编码 | 16 MiB |

单次 DICOM 文件夹导入固定为遍历深度 16、10,000 个目录项、2,000 个 DICOM 对象、2 GiB 唯一来源字节、每个对象 100 MiB、两个 worker 和八个导入持有的来源/暂存 descriptor。扫描器使用迭代的目录身份工作表，从持有的根逐段 `openat` / `O_NOFOLLOW` 重新打开深层目录并立即关闭上一段。摘要和长度都相同的重复对象在每两项一批之后按 descriptor 和身份删除，所以对象和字节上限只计唯一原件。设本次唯一原件总量为 `S`、检查时已进入同卷暂存的字节为 `A`，容量门禁要求当前可用空间至少为 `2S - A + 256 MiB`；这是保守的峰值预算，不是资料库配额，算术溢出或容量查询失败都失败关闭。

上限在构造或解码时、提交前和持有提交权的最终检查中重新核对；超限的提交在写入之前被拒绝。LAN inbox 另有待确认项、传输回执、并发和内存上限，见 [`lan-upload.md`](lan-upload.md)。产品决策明确不设固定的存储字节配额；文件系统写入失败时当前文件不会发布为可处理项，并提供清理或重试的路径。

## 已确认原始文件导出

[SQLiteOriginalArchiveSource](../Sources/KinloguePlatform/Export/SQLiteOriginalArchiveSource.swift) 在一次受协调的读取里取得导出清单，并 pin 住清单里的原件。清单只包含 `.confirmed` 报告的每一条来源行和 `.confirmed` DICOM study 的原件；同一原件被两条来源行引用时仍按两行输出。条目总数上限为 30,000，超过已完成 writer characterization 的边界时在读取原件之前失败关闭。草稿、待确认的 DICOM、OCR 文档、LAN inbox 和没有引用的原件都不可达。只查询来源的元数据，不加载 OCR 或报告详情。

pin 记下原件的元数据并阻止文件被回收，所以准备之后发生的合法编辑或删除不改变这次导出的内容；写每个 ZIP 条目时才打开该原件的只读 descriptor，逐块读取并核对长度、SHA-256 和读取前后的文件身份，发布前再整体核对一次 pin。一次准备只能用于一次导出，导出结束时归还 pin。

`OriginalArchiveExporter` 使用 ZIPFoundation `0.9.20` 的 stored entry 和 64 KiB provider 逐块 `pread`。work archive 位于目标同卷的私有 item-replacement directory，名称不带 `.zip`；新目标由该 API 生成的零字节 placeholder 会在写入前移除。写入后同步文件、重新打开并逐 entry 解压复核路径、数量、长度和摘要。只有这些步骤全部成功才原子 move/replace 用户目标：普通文件 authority 路径绑定目标和 work 父目录 descriptor 并以 `renameat` 发布，目录替换时按已捕获 inode 清除 placeholder/work；`NSSavePanel` security scope 路径使用 `NSFileCoordinator` 提供的协调 URL 与 Foundation replace/move，不额外要求未获授权的父目录访问。提交阶段不再接受取消；发布后还会尽力同步父目录，但 `NSSavePanel` 只授予目标文件而未授予父目录时的 `EACCES` / `EPERM`，以及文件系统明确不支持目录同步的错误，不会把已完整校验和原子发布的 ZIP 误报为失败；真正的目录 I/O 错误仍报告“发布状态不确定”。目标在资料库内、非 `.zip`、symlink 或非 regular replacement 均被拒绝。

输出目录和文件名只由用户可见的成员名、确认日期、稳定序号、清洗后的报告显示名和类型扩展构成；DICOM 使用通用的 `.dcm` 名称。内部 UUID、原件或 study ID、摘要、原始路径和 DICOM UID 不进入 ZIP。该 ZIP 不含恢复所需的清单，不能当作资料库备份。

## 版本、备份与未来路线

- 数据库 schema 尚未随正式版本发布，开发期间仍可调整；不提供旧 JSON 资料库或更早实验数据库的自动迁移。DICOM 只接受 ordering policy v2，其他 policy version 失败关闭。
- 空目录可以初始化为当前格式；未知的非空目录、损坏的数据库或不受支持的版本都不会被当成新资料库覆盖。
- 当前版本提供用户选择目录的加密 `.kinloguebackup` 恢复点与整库替换恢复，但不提供云同步、网盘 API、iCloud 或 CloudKit。恢复点覆盖已提交的完整领域图和原件；显式的原始文件 ZIP 只是不可恢复的明文交接副本。
- 备份的本机配置和恢复事务收据位于资料库之外、同一可信 Application Support 目录下，避免整根替换复制旧设备身份或移走自己的恢复记录。恢复的暂存和回滚目录只存在于同一个 app 私有父目录，不写入用户选择的同步目录。
- 恢复点使用独立的密码学认证；活动资料库仍是明文，SHA-256 只用来发现意外损坏和本机去重。将来若加入活动资料库加密或云同步，仍必须提供显式迁移、密钥生命周期和失败恢复协议，不能把当前的 SHA-256 改称认证。

完整格式、自动化、保留和恢复顺序见 [`backup-and-restore.md`](backup-and-restore.md)。
