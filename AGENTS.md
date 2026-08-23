# Kinlogue Agent Contract

本文件是 Kinlogue 的 Agent schema：它规定 Agent 进入仓库后如何读取事实、如何维护项目知识、如何修改代码和文档，以及哪些边界不可突破。它不是业务实现的替代品；当它与当前代码或测试冲突时，应先标记冲突，再以代码、测试和可复现验收结果为准修正文档。

## 1. 进入仓库后的固定顺序

先读以下内容，再开始有范围的修改：

1. [`docs/index.md`](docs/index.md)：项目知识库目录、当前状态和导航。
2. [`docs/project-overview.md`](docs/project-overview.md)：产品边界、用户流程和当前版本姿态。
3. 与任务直接相关的专题页：架构、数据模型、存储、LAN、OCR、隐私或验收文档。
4. [`README.md`](README.md) 和 [`PRIVACY.md`](PRIVACY.md)：面向用户的承诺，不能被实现细节悄悄推翻。
5. 真实代码、测试、脚本和 `Package.swift`：最终的可执行事实来源。

使用 `rg` 定位符号和现有约定；先读命中的上下文，再写新代码或新文档。不要凭文件名推断行为。

## 2. 项目知识库的三层模型

Kinlogue 借鉴 LLM Wiki 的“原始资料 → 编译后的 Wiki → schema”结构，但把它适配为代码仓库：

| 层 | 仓库位置 | 规则 |
| --- | --- | --- |
| 原始事实 | `Sources/`、`Tests/`、`Package.swift`、`packaging/`、`scripts/`，以及 `docs/sources/` | 代码、测试和锁定的外部资料是输入。`docs/sources/` 中的来源笔记追加保存，不把总结冒充原文。 |
| 编译后的 Wiki | `docs/*.md`、`docs/acceptance/`、`docs/plans/`、`docs/index.md`、`docs/log.md` | Agent 负责把事实组织成可导航、互相链接、可复核的专题页；每次影响范围变化都同步索引和日志。 |
| Schema | `AGENTS.md` | 规定读取顺序、事实优先级、安全边界、验证和维护流程。 |

日常工作按以下循环进行：

- **Ingest**：一次处理一个外部来源或一次重大实现变化，先记录来源/事实，再更新受影响专题页。
- **Query**：回答项目问题时先读 `docs/index.md`，再沿链接读取 3–5 个最相关页面，最后回到代码或测试核实关键断言。
- **Lint**：定期检查孤儿页、断链、互相矛盾的状态、过时的版本/命令，以及“代码已经改变但文档没有改变”的漂移。
- **Log**：在 [`docs/log.md`](docs/log.md) 追加发生了什么、依据是什么、哪些门禁仍未执行。

### 事实优先级

当不同资料出现差异时，按以下顺序判断；不要静默选择一个看起来更方便的说法：

1. 当前分支的代码、测试、`Package.swift`、`packaging/` 和脚本。
2. 当前用户可见的 `README.md`、`PRIVACY.md`。
3. 与当前版本明确绑定的验收报告和验收矩阵。
4. 当前仍有效的实施计划，例如明文 MVP 和 LAN upload 计划。
5. 已标记 `supersedes` 的历史计划只用于解释决策来源，不用于描述当前能力。

如果无法仅凭仓库事实解决矛盾，写成“待核实”并指出冲突位置；不要用猜测填平空白。

## 3. 不可突破的产品与安全边界

- Kinlogue 是单机、单用户操作模型；当前版本没有账号、云同步、iCloud、CloudKit、HealthKit、遥测、广告或第三方崩溃 SDK。
- 当前资料库是 App Sandbox 内的明文资料库。没有应用层加密，也不使用 Keychain；SHA-256 只用于发现意外损坏和本机去重，不提供保密、认证、防篡改或防回滚。
- 局域网接收只在用户明确开启临时会话后工作，使用普通 HTTP，只能向用户说明为可信任私人网络能力。不能把它描述成 TLS 或端到端加密。
- 手机端只看到当前会话的文件、进度和结果；不能浏览成员、历史记录、OCR 或时间线。
- 只有用户确认的来源转录才进入时间线、搜索和比较。Agent 不得把 OCR 或规则抽取结果写成诊断、趋势、治疗建议或新的医学结论。
- 原件、真实姓名、真实病历、完整地址、验证码、token、私有路径和可逆身份信息不得进入 Git、测试夹具、日志、截图、构建产物、验收报告或文档。
- 所有导入文件和 LAN 文件都必须被当作不可信的惰性附件；不执行、不主动渲染不支持的内容，不把展示名拼成路径。
- 不得为了“让测试通过”引入通配监听、私有 macOS API、未经锁定的依赖版本、破坏性迁移、自动恢复 LAN 接收或绕过现有隐私门禁。

## 4. 代码边界与主要入口

| 区域 | 责任 | 修改时必须检查 |
| --- | --- | --- |
| `Sources/KinlogueCore/` | Foundation-only 领域模型、状态机、导入用例、协议和跨平台规则 | 不引入 AppKit、PDFKit、Vision、SwiftNIO 或文件系统实现。 |
| `Sources/KinloguePlatform/` | 明文 Vault、文件原子提交、OCR、PDF/Image 处理、LAN receiver/inbox、平台资源 | 资源上限、路径防护、并发/重启恢复、无内容日志和对应集成测试。 |
| `Sources/KinlogueApp/` | SwiftUI/AppKit composition root、App service、ViewModel、界面和验收入口 | UI 状态、主线程边界、生命周期通知、真实 service 链路。 |
| `Sources/KinlogueStorageProcessFixture/` | 跨进程存储协调测试的 fixture | 只用于测试，不把测试入口接进生产 bundle。 |
| `Tests/` | 按 target 镜像的单元、集成、并发、脚本安全和安装验收测试 | 任何行为改动先找到现有覆盖，再补最小缺口。 |
| `scripts/` | 构建、隐私扫描、安装验收、回滚归档和包安全门禁 | 不把一次本机通过写成跨系统或正式分发通过。 |

正式运行时从 [`AppRuntimeIdentity`](Sources/KinlogueApp/App/AppRuntimeIdentity.swift) 取得可信的 Application Support 路径，由 [`AppComposition`](Sources/KinlogueApp/App/AppComposition.swift) 组装 `PlaintextVault`、本机 OCR、导入 workflow 和 LAN inbox service。不要在 View 中直接创建存储、网络或 OCR 实例。

## 5. 修改工作流

### 开始前

- 运行 `git status --short`，保留用户已有改动；不要使用 `git reset --hard`、宽范围删除或覆盖用户文件。
- 明确任务属于代码、用户文档、架构知识还是验收记录，并列出将要改变的文件。
- 对代码改动先做 Test Discovery：搜索对应 target 的已有测试和跨层调用方。
- 对文档改动先确认事实来源，尤其是版本号、命令、存储格式、网络边界和“已通过/未验证”措辞。

### 代码改动

- 先写或强化能证明行为的测试；如果是纯配置、纯文档或手工验收面，记录为什么不适合单元测试以及替代验证。
- 保持 `Core → Platform → App` 依赖方向；不要为了方便把平台实现塞进 `KinlogueCore`。
- 涉及持久化、回调、HTTP middleware、重试或生命周期时，至少核对一次真实跨层链路，不要只用全 mock 的测试。
- 新增、重命名或替换 `Sources/KinlogueApp` 的 View/ViewModel 时，按 [`docs/localization.md`](docs/localization.md) 重新扫描用户可见文案；错误、空状态、确认框和无障碍文案同样必须进入中英资源，并通过本地化硬编码门禁。
- ViewModel 中跨界面重绘保留的用户可见错误或状态必须保存语义 case/key，不保存已经按旧语言解析的字符串；复数文案使用 String Catalog variation，并测试单数与复数。
- 行为变化完成后，同步最相关的专题文档、`docs/index.md` 和 `docs/log.md`。计划文件是决策记录，不用在其中伪造执行进度。

### 文档改动

- 文档只写仓库可证明的事实；推断使用“推断”或“待验证”标签。
- 新增页面必须从 `docs/index.md` 可达，并链接到代码、测试、计划或验收证据。
- 变更现有承诺时同时检查 `README.md`、`PRIVACY.md`、`docs/privacy-and-security.md` 和相关验收脚本；不能只改其中一处。
- `docs/sources/` 中的来源笔记不改写成项目结论；如来源修订，新增修订笔记并在 Wiki 页更新链接。

## 6. 常用验证命令

在 macOS 14+、Swift 6 / Xcode 或 Command Line Tools 环境中，按改动范围选择：

```sh
swift build --disable-sandbox
scripts/test.sh
scripts/privacy-guard.sh
scripts/verify-package-graph.sh <swift-package-dump-package.json>
scripts/verify-app.sh
scripts/build-acceptance-app.sh
scripts/run-acceptance.sh
```

其中 `verify-app.sh`、安装验收和回滚归档要求完整 Xcode，且会生成/更新 `dist/` 下的本机产物；`dist/` 和 `.build/` 被 `.gitignore` 忽略，不能把它们当作提交内容。完整命令、前置条件和当前未执行门禁见 [`docs/testing-and-release.md`](docs/testing-and-release.md)。

验证结果必须区分：

- 当前 Mac 自动化通过；
- 安装后合成数据通过；
- 公开发布兼容性或真实手机矩阵未执行；
- 人工 OCR、键盘/VoiceOver 或其他手工检查未执行。

不能用低层单元测试或当前机器结果替代未执行的系统版本/真实设备门禁。

## 7. Git 与交付纪律

- 默认不提交、不 push、不创建 PR；只有用户明确要求时才执行这些外部状态变化。
- 提交时只 stage 本次逻辑单元的文件，不使用无范围的 `git add .`。
- 不把真实资料、`dist/`、`.build/`、临时文件或本机验收报告加入提交。
- 删除资料库、回滚包或用户文件前先解析精确目标和所有权；优先使用可恢复方式，发现目标不明确就停下。
- 最终说明列出实际变更文件、验证命令/结果、仍待人工完成的门禁和任何文档事实冲突。

## 8. 完成检查清单

- [ ] 已读取 `docs/index.md` 和相关专题页。
- [ ] 已保留并检查工作树中原有改动。
- [ ] 行为改动有对应测试，或有明确的替代验证理由。
- [ ] 没有真实病历、凭据、完整地址或内容日志进入仓库/产物。
- [ ] 文档中的当前能力、版本、命令和验收状态与代码/脚本一致。
- [ ] 新旧页面通过 `docs/index.md` 和局部链接互相可达。
- [ ] `docs/log.md` 已追加本次可复核的变化。
- [ ] 最终交付明确区分已验证与未验证，不把未来路线写成当前功能。
