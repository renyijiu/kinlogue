---
title: Plain ZIP Backup and Export - Plan
type: feat
date: 2026-10-19
topic: plain-zip-backup-export
execution: code
planning_depth: deep
status: implemented-pending-release-evidence
supersedes:
  - 2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md
  - 2026-08-10-001-feat-export-all-original-files-plan.md
---

# 明文 ZIP 备份与导出合并 - 计划

> **状态：已实施，待发布证据。** 用户 2026-10-19 接受明文备份的代价，下方 4 个决定都按推荐执行；U1–U6 已在本分支完成。本页保留设计和权衡，当前能力以 [`../backup-and-restore.md`](../backup-and-restore.md)、[`../storage.md`](../storage.md#备份与导出) 和代码为准，执行记录与未执行门禁见 [`../log.md`](../log.md)。本计划取代 [加密目录备份计划](2026-08-19-1418-feat-encrypted-folder-backup-restore-plan.md) 与 [原件导出计划](2026-08-10-001-feat-export-all-original-files-plan.md)。
>
> **与设计稿的差异**：设置页没有实现“文件夹中另有 X 份备份不由本机管理”的计数，只显示保留份数和最近一次备份时间；其余流程、格式和保留规则按本页实施。

## 目标

用户 2026-10-19 提出：把“加密备份与恢复”和“导出原始文件”合并成一个功能，暂时去掉加密，备份就是一个压缩包，数据的管理权交还给用户；用户设定保留几份；恢复时直接选一个压缩包导回来。

合并后只有**一种文件**：`.zip` 备份包。它同时满足三件事：

1. **能看**：解压后按家庭成员、日期排好的原件，可以直接打开、打印、挑出某位成员的文件夹发给医生。
2. **能恢复**：包内有索引文件和完整的逻辑数据，续页可以从它整库恢复。
3. **能管理**：文件就放在用户选择的文件夹里，用户可以复制、改名、移走、删除；续页只按保留数量清理**自己写入且未被改动**的那几份。

## 用户流程

### 设置页：“数据备份与导出”（合并原“数据备份”和“数据管理”两个分区）

```text
备份文件夹    ~/百度网盘/续页备份            [更改…] [在访达中显示]
自动备份      [开关]  资料变化后，每天最多一次
保留          最近 [ 5 ] 份（续页只删除自己写入、未被改名或移动的备份）
              [立即备份]        最近一次：2026-10-19 15:30（已验证）
一次性导出    [导出备份到…]     存到任意位置，不计入保留数量
恢复          [从备份恢复…]
⚠ 备份文件不加密，包含全部健康资料。放在网盘同步目录里，网盘服务商和能登录该账号的人都能读取。
```

- **立即备份 / 自动备份**：写入备份文件夹，计入保留数量。
- **导出备份到…**：用系统保存面板选位置和文件名，格式与自动备份完全相同，也能用来恢复；不记入保留，续页之后不再管理它。
- 没有恢复码、没有首次设置向导、没有“未完成的设置”状态。

### 恢复

1. 在设置页、资料库打不开时的降级启动页、完整性失败提示中，选择“从备份恢复…”，选一个 `.zip`。
2. 续页在 App 私有的 staging 中逐项校验并重建资料库（见下文“读取规则”）。
3. 界面显示备份时间、写出它的续页版本、成员数、记录数、待确认数、原件数与总大小，不显示健康内容。
4. 用户确认后整库替换（沿用现有 whole-root 事务），然后退出并重新打开 App。
5. 恢复后**关闭自动备份**，保留备份文件夹设置，由用户确认后再打开：避免恢复到旧状态后，自动备份把恢复前更新的备份轮换掉。

## 备份包格式 v1

### 目录结构

文件名：`续页备份 2026-10-19 153012.zip`（英文界面为 `Kinlogue Backup 2026-10-19 153012.zip`），同名时追加 ` (2)`。

```text
续页备份 2026-10-19 153012.zip
├── kinlogue-backup.json        # 索引：格式版本、资料库标识、计数、每个文件的路径/长度/SHA-256
├── 说明.txt                     # 给人看的说明（中英双语）；恢复时忽略
├── data/
│   └── library.klog            # logical-v1 数据流：成员、报告、OCR 复核、草稿、LAN 队列与回执、DICOM 图
└── files/                      # 每个原件恰好一份
    ├── 张三/
    │   ├── 2026-03-02 - Report 0001 - Source 0001 - 血常规.pdf
    │   ├── 未注明日期 - Report 0002 - Source 0001 - 门诊病历.jpg
    │   └── 2026-05-10 - DICOM 0001/
    │       ├── 0001.dcm
    │       └── 0002.dcm
    ├── 李四/
    ├── _待确认/
    │   ├── 草稿 0001/来源 0001 - 体检报告.pdf
    │   └── DICOM 0001/0001.dcm
    ├── _手机待整理/
    │   └── 0001 - IMG_2041.jpg
    └── _其他/                   # 只被历史回执等引用、无法归入上面任何一类的原件
        └── 0001.data
```

- `files/<成员>/` 下沿用现有 `OriginalArchivePlan` 的命名：清洗后的成员名、确认日期、稳定序号、清洗后的来源名和类型扩展名。已归档成员照样列出。
- 草稿、待确认 DICOM、手机待整理的原件放在 `_` 开头的目录，排在成员目录之后；目录名按写出时的界面语言本地化，恢复只认索引里的路径，不依赖这些名字。
- 同一原件被多条来源引用时只存一份，放在规划顺序中第一次出现的位置；索引里该原件只有一条路径。
- 内部 UUID 只出现在索引和 `library.klog` 里，不进入 `files/` 下的路径。

### 索引文件 `kinlogue-backup.json`

```json
{
  "format": "kinlogue-backup",
  "formatVersion": 1,
  "minimumReaderVersion": 1,
  "encryption": "none",
  "createdAt": "2026-10-19T07:30:12Z",
  "creator": { "app": "Kinlogue", "version": "0.x.y", "build": "nnn" },
  "library": { "libraryID": "…", "generation": 42, "commitID": "…" },
  "counts": { "members": 3, "records": 120, "drafts": 4, "inboxItems": 2, "dicomStudies": 2, "originals": 380 },
  "data": { "path": "data/library.klog", "encoding": "logical-v1", "byteCount": 1048576, "sha256": "…" },
  "originals": [
    { "id": "…", "path": "files/张三/2026-03-02 - Report 0001 - Source 0001 - 血常规.pdf",
      "byteCount": 482113, "sha256": "…", "contentType": "com.adobe.pdf" }
  ]
}
```

- `library` 与 `library.klog` 头部的 `libraryID / generation / commitID` 必须一致；`originals` 与数据流里的 `.original` 记录必须一一对应（id、长度、SHA-256、类型）。
- `encryption` 字段为将来可选的加密层保留；v1 只接受 `"none"`。
- `formatVersion` 可以增长；reader 只看 `minimumReaderVersion` 是否不高于自己支持的版本，未知字段忽略。
- 上限：索引解压后不超过 16 MiB；原件条目沿用 logical-v1 的 25,000 个上限；单个条目、总大小沿用现有资源预算。

为什么数据部分沿用 logical-v1 而不是改成可读的 JSON：它已经有冻结夹具、严格的长度/计数/摘要校验和一条经过 SIGKILL 矩阵验证的恢复路径；换格式等于重做一遍。逐条记录本身就是规范 JSON，格式说明会写进 `说明.txt` 和文档。给人看的目录（例如 `目录.csv`）可以以后再加，不影响恢复。

### 压缩方式

- `files/` 下的原件用 **stored**（不压缩）：PDF、JPEG、HEIC 本身已压缩，stored 写读快，容量预估精确，沿用现有导出写入器。
- 索引、说明和 `library.klog` 用 **deflate**：以文本和 JSON 为主，压缩收益明显。
- 超过 4 GiB 或 65,535 个条目时使用 ZIP64。已核对锁定的 ZIPFoundation `0.9.20`（revision `22787ff`）包含 `Archive+ZIP64.swift` 与 `Entry+ZIP64.swift`；大包的写入和读取仍需实测。

## 写入流程

1. **捕获**：沿用 [`SQLiteLogicalBackupSource.prepare()`](../../Sources/KinloguePlatform/Backup/SQLiteLogicalBackupSource.swift)：一次 admission 内固定 revision、pin 住全部可达原件、生成逻辑数据 spool。
2. **规划路径**：从同一份 spool 中读出成员、报告来源、草稿、DICOM、LAN 记录，为每个原件分配 `files/` 下唯一的路径。路径与数据来自同一次捕获，不会出现两者对应不同提交的情况。
3. **容量预检**：原件总字节 + 逻辑数据字节 + 索引上限 + 256 MiB 余量，在目标所在卷上检查。
4. **写 ZIP**：在目标同卷的私有 item-replacement 目录里写临时文件（不带 `.zip`，网盘客户端看不到），顺序为索引、说明、数据、原件；原件逐块读取并核对长度、SHA-256 和文件身份。沿用 `OriginalArchiveExporter` 的流式写入、取消和失败注入。
5. **回读验证**：同步文件后重新打开，按索引逐项解出并核对路径、长度和 SHA-256。
6. **发布**：
   - 备份文件夹：以**排他重命名**放进文件夹（同名不覆盖，换一个 ` (2)` 名字重试），然后记入账本并执行保留清理。
   - 一次性导出：沿用现有保存面板的原子替换发布。
7. 归还 pin，删除临时文件。

## 保留规则

App 私有目录里保存一份很小的**备份账本**：续页写入备份文件夹的每份备份记一条（文件名、inode、字节数、修改时间、单调递增序号、资料库 revision）。

1. 新备份发布并通过回读验证之后才开始清理；新备份失败时一个旧文件也不删。
2. 只看账本里的条目：按文件名 no-follow 打开，必须仍是普通文件、单硬链接、inode / 大小 / 修改时间与记录一致。对不上的（被改名、移走、替换、网盘客户端重新下载过）从账本里移除，**永不删除**。
3. 对得上的按序号从新到旧排列，保留最近 N 份，其余在删除前再核对一次身份后删除。按序号而不按时钟排序，系统时间回拨不影响。
4. 文件夹里其他文件（用户放进来的、其他 Mac 写入的、改过名的备份）不计数、不删除。设置页显示“文件夹中另有 X 份备份不由本机管理”。
5. 保留范围 1–30，默认 5。保留数量只描述这个本地文件夹，不代表网盘远端保留几份。

两台 Mac 指向同一个同步文件夹时各自记账、各自清理自己写入的文件，不会互删。

## 自动备份

沿用现有 [`BackupScheduler`](../../Sources/KinlogueApp/Backup/BackupScheduler.swift) 的行为：只在 App 运行时工作；资料变化后等待 5 分钟静默期；两次成功备份至少间隔 24 小时；启动、激活、唤醒时补做到期的备份；文件夹暂时不可用时按 1、5、15 分钟有界重试。“当前提交是否已有备份”改为比较账本里最近一份的 revision，不再依赖 witness。

## 读取与恢复

### 读取规则（备份包一律视为不可信输入）

1. no-follow 打开所选文件，必须是普通文件；记下 inode、大小、修改时间，读完后再核对一次，变化即失败。
2. 读中央目录：拒绝重名条目、加密条目、stored/deflate 以外的压缩方式；条目数有上限。
3. 定位索引：根目录下的 `kinlogue-backup.json`，或者**唯一一个**顶层目录下的 `<目录>/kinlogue-backup.json`（兼容“解压后又用访达重新压缩”的情况），其余路径都相对于这个位置解析。
4. 索引严格解码：`format`、版本、`encryption == "none"`、各项上限；每条路径必须以 `data/` 或 `files/` 开头，不含 `..`、绝对路径、反斜杠、NUL，彼此不重复，并对应包内恰好一个普通文件条目，解压后大小与索引一致。
5. 包内没被索引引用的条目（用户自己加的文件、`__MACOSX/`、`.DS_Store`）一律忽略、从不解出。
6. **从不用包内路径在磁盘上建文件**：原件写入 staging 时只用索引里的 UUID 生成 `originals/<uuid>.data`。
7. 解出时边读边计数，超过索引声明的大小立即中止（防止压缩炸弹）；读完核对 SHA-256，ZIPFoundation 同时核对 CRC32。

### 恢复流程

与现有 `BackupRestoreVerifier.prepare` 相比，只把“解密容器”这一步换成“按索引读 ZIP”：

1. 读索引 → 容量预检 → 写 preflight 收据 → 建私有 staging。
2. 把 `library.klog` 流入 `SQLiteLogicalSpool`、把原件流入 staging，每项核对长度和 SHA-256。
3. [`SQLiteLogicalRestore.restore`](../../Sources/KinloguePlatform/Backup/SQLiteLogicalRestore.swift) 改为接收“索引给出的原件表 + 资料库标识”，不再接收加密容器的 `BackupManifest`；其余严格校验不变。
4. 用户确认后由 [`BackupRestoreTransaction`](../../Sources/KinloguePlatform/Backup/BackupRestoreTransaction.swift) 整库切换；启动时的收敛、回滚、`LibraryLifecycleCoordinator` 的任务排空全部不变。

## 隐私与安全边界的变化（需要明确接受的代价）

- **备份包是明文**。任何拿到文件的人都能读取全部成员、报告、OCR 转录和原件：网盘服务商、能登录网盘账号的人、捡到外置盘的人。现在的加密恢复点正是为“放在网盘里也不泄露”设计的，去掉加密就放弃了这一点。
- SHA-256 只用于发现意外损坏，不防篡改：有人改了包里的数据并同步改了索引，续页无法察觉。恢复只在用户亲自选择并确认时发生，且所有记录仍按资源上限和完整图严格校验，不会执行任何内容。
- 建议用户把备份文件夹放在开了 FileVault 的磁盘、加密的外置盘或加密磁盘映像上；界面和文档会明说网盘同步目录意味着服务商可读。
- 以后若要恢复加密，可以在整个 ZIP 外再包一层（索引的 `encryption` 字段已预留），不需要改动内部结构。
- 活动资料库本来就是明文，这部分不变；“没有账号、云同步、遥测”的边界不变；续页仍不调用任何网盘 API。

## 删除、保留与新增的代码

| 处理 | 内容 |
| --- | --- |
| 删除 | 恢复码、密钥层级、HPKE/AES-GCM 容器与 reader、设备签名身份与信任记录、writer epoch、序号、witness、publication lease、隐藏的 `.kinlogue-backup-v1` repository、`.kinloguebackup` 写入与读取、首次设置与 pending enrollment 流程；只含已确认原件、不可恢复的旧导出。涉及 `BackupCrypto`、`BackupKeyHierarchy`、`BackupTrustRecords`、`BackupTrustVerifier`、`EncryptedBackupContainer`、`BackupContainerReader`、`EncryptedCheckpointWriter`、`BackupCheckpoint`、`BackupManifest`、`BackupCheckpointPublisher`、`BackupRepository`、`BackupSetupService`，约 4,500 行源码及对应测试；另有 `BackupLocalConfigurationStore`、`BackupRetentionPolicy`、`BackupRetentionExecutor` 约 1,900 行改写为小得多的版本。 |
| 保留 | logical-v1 及其冻结夹具、`SQLiteLogicalBackupSource` / `SQLiteLogicalCaptureDatabase` / `SQLiteLogicalRestore`、`BackupRestoreTransaction` 与 SIGKILL 进程矩阵、preflight 收据与 staging、生命周期排空、目录 bookmark 授权、调度器、ZIP 流式写入/回读/原子发布、命名清洗。 |
| 新增 / 改写 | Core：`BackupArchiveIndex`（索引编解码与校验）、`BackupArchivePlan`（全部原件的路径规划）、保留策略（纯函数）。Platform：`BackupArchiveWriter`（由 `OriginalArchiveExporter` 改造，增加排他发布）、`BackupArchiveReader`、账本与设置存储（替代 1,359 行的 `BackupLocalConfigurationStore`）。App：合并后的备份/恢复/导出 service、ViewModel 与设置分区，中英文案。预计 1,500–2,000 行。 |

## 旧数据怎么办

- **已有的 `.kinloguebackup` 恢复点**：新版本不再读取（推荐，见下方决定 1）。升级后第一件事是做一份新的 ZIP 备份；需要读旧恢复点时用旧版本 App。
- **用户文件夹里隐藏的 `.kinlogue-backup-v1` 目录**：续页不碰，由用户自己删除；文档写明位置。
- **App 私有目录里的旧备份配置**（设备签名私钥、恢复公钥、witness）：新版本启动时按现有 `removeForDestructiveReset` 的方式移除，只核对是当前用户私有的普通文件，不读取内容。
- **资料库本身**不变，没有 schema 迁移。

## 需要用户决定

1. **旧加密恢复点**：直接放弃读取（推荐，项目尚未发布，只影响自用）；或保留一条只读的旧格式恢复路径（要留下约 3,000 行密码学和容器代码）。
2. **给医生的导出**：取消单独的“仅已确认原件”导出，解压备份后把某位成员的文件夹发出去即可（推荐）；或在同一写入器上保留一个“只导出某位成员的原件、不可恢复”的模式。注意整份备份包含全家所有人的资料和转录，不应直接交给医生。
3. **写入位置**：直接写进用户选的文件夹（推荐，用户可以在选择面板里自己新建子文件夹）；或在其中固定建一个可见的“续页备份”子文件夹。
4. **清理方式**：超出保留数量的旧备份直接删除（推荐，这正是用户设定的保留规则，网盘客户端通常有自己的回收站）；或移到废纸篓（外置盘和网络卷上未必可用，且不释放空间）。

## 实施单元

| 单元 | 内容 | 主要测试 |
| --- | --- | --- |
| U1 Core | 索引类型与校验、路径规划（复用命名清洗）、保留策略 | 索引往返与拒绝（版本、加密字段、路径穿越、重复、超限）；规划覆盖全部原件且无重名；共享原件只出现一次；保留按序号、只动账本条目 |
| U2 Platform 写入 | 由导出器改造的写入器、排他发布、账本 | 真实资料库写出后逐项回读；同名重试；取消与失败注入不留文件；容量不足在写入前失败 |
| U3 Platform 读取与恢复 | ZIP reader、`prepare` 换源、`SQLiteLogicalRestore` 改接口 | 真实资料库 → ZIP → 恢复 → 逐项比对；冻结 logical-v1 夹具仍通过；改一个字节、删条目、重名条目、声明大小小于实际（压缩炸弹）、未被引用的多余条目、访达重新压缩（顶层目录 + deflate）；现有 SIGKILL 进程矩阵不改动重跑 |
| U4 App | service、调度器、合并 ViewModel 与设置分区、恢复后关闭自动备份、启动时移除旧配置、中英文案 | 调度与重试、保留只删本机写入的文件、改名文件保留、新备份失败不删旧文件、恢复入口三处、本地化门禁 |
| U5 删除 | 密码学、信任、repository、旧导出及其测试、探针与脚本中的相应段落 | `scripts/test.sh`、`scripts/verify-app.sh` 的源码与包内容门禁 |
| U6 文档 | `README.md`、`PRIVACY.md`、`project-overview.md`、`backup-and-restore.md`（重写）、`storage.md`、`sqlite-storage.md`、`privacy-and-security.md`、`decisions.md`（新增“去掉备份加密”决策）、`index.md`、`plans/README.md`（两份旧计划标为 superseded）、验收账本、`log.md` | `scripts/verify-docs.sh`、`scripts/privacy-guard.sh` |

顺序：U1 → U2/U3 → U4 → U5 → U6。U5 放在新路径通过测试之后，保证任何时刻都有一条能用的备份与恢复路径。

## 仍需实测的门禁

- 超过 4 GiB、接近 25,000 个原件的 ZIP64 写入与恢复耗时（参照 [规模闭环](../storage-refactor-measurement-2026-10-11.md#sqlite-完整规模闭环)）。
- 写进阿里云盘、百度网盘同步目录后客户端的行为（是否替换文件导致账本对不上、是否上传临时文件）。
- 访达“压缩”与 macOS 自带解压对包内中文路径的兼容；Windows 解压中文文件名。
- 安装后的 App 上手动恢复一次真实备份；键盘与 VoiceOver 走完备份和恢复流程。
