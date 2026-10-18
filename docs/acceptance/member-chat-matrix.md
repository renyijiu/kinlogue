# 成员对话验收矩阵

状态：成员对话（界面名“AI 对话（实验）”）默认关闭。源码自动化只用假 CLI 和合成资料。2026-10-16 经使用者同意，用真实 Codex 经签名沙盒 bridge 跑了完整一轮和 21 个合成边界问题（[来源笔记](../sources/2026-10-16-member-chat-real-codex-check.md)），回答都守住了边界；这次检查发现并修正了一个让沙盒内 Codex 始终“未登录”的问题。**App 界面上的真实对话、键盘与 VoiceOver、失败场景、macOS 26、Developer ID 与公证仍未执行。** 版本、测试清单和整体发布状态只由[当前候选证据](current-release.md)维护；设计与决策见[成员对话计划](../plans/2026-10-15-feat-member-cli-chat-plan.md)，用户承诺见 [`PRIVACY.md`](../../PRIVACY.md)。

## 支持范围

| 项 | 当前范围 | 依据 |
| --- | --- | --- |
| CLI | 只支持 Codex。`0.162.0` 的加固参数经真实请求验证；其他版本在每项能力检查都通过时仍可使用，界面标为“未验证的版本” | [U0 证据](../sources/2026-10-15-codex-u0-probe-evidence.md)、`CodexInvocation.verifiedVersions` |
| 账号 | 只支持 Codex 自己登录的 OpenAI 账号；不加载用户的 Codex 配置，因此不支持第三方中转 | 计划 E2 |
| 安装位置 | `/opt/homebrew/` 下的安装经真实 Codex 验证；`/usr/local/` 只验证了同一机制；家目录下的 nvm、volta、bun 等位置报“不支持的安装位置” | 计划第 4.2 节 |
| 发送内容 | 一位成员最新的最多 20 份已确认报告的日期、标题、检查结果、结论和标记项，问答历史和问题；机构名称默认不发送 | `AssistantContextPackBuilder`、[`PRIVACY.md`](../../PRIVACY.md) |
| 保存 | 每轮完成后保存在资料库（schema 版本 3），进入恢复点（逻辑版本 3），可逐段或全部删除，随成员删除；同意从不保存 | 计划 D4、D8，[`decisions.md`](../decisions.md) 2026-10-16 |

## 自动化证据

以下都在 2026-10-16 的未提交工作树上、macOS 27.0.1 / Xcode 27.0 / Swift 6.4 本机通过，没有绑定不可变 source ref。完整命令和结果见[实现日志](../log.md)。

| 门禁 | 覆盖 | 状态 |
| --- | --- | --- |
| Core 测试 | 上下文包只取这位成员的已确认记录、不含姓名/备注/机构/ID、预算与截断标记、编号确定、标签转义、指纹随任何输入变化、引用解析与“已更改/已删除”判定、值类型编码往返 | 本机通过 |
| Platform 测试 | IPC 有界 DTO；Codex 参数、功能白名单、模型目录改写与可选模型列表、事件解析；用假 CLI 驱动的 UTF-8 分片、超长行、输出洪泛、超时、非零退出、未登录/限流、取消后孙进程退出、supervisor、参数与环境里没有资料内容、能力检查缺一项即拒绝；SQLite 上下文包读取与 provider | 本机通过 |
| App 测试 | 设置、同意与指纹、对话保存与重启后读取、删除、服务生命周期（删除/恢复资料库时取消且不写入）、迟到结果被丢弃、提交观察后重新确认、历史列表与重新打开、关闭功能保留对话、对话模型与 composition；设置模型校验、模型菜单（Codex 默认、列表外的已保存模型、面板选择后保存并重新确认）；中英文案与单复数；视图源码安全 | 本机通过 |
| schema 版本 | 只认版本 3：版本 1、2 和更新的版本以“格式不受支持”被拒且字节不变；冻结的版本 1、版本 2 恢复点照常恢复并以版本 3 写出同样的记录；版本 2 恢复点超过 20 个来源被拒，版本 3 可存 300 个 | 本机通过 |
| 对话存储与恢复点 | 保存与整段读回、最新优先的摘要、替换轮次、每位成员 200 段上限、未知成员被拒、逐段/按成员/随成员删除、引用已删除报告仍可读、篡改的轮次被巡检发现且读取失败；恢复点携带对话，版本 1 流不能带对话，版本 2 冻结流恢复后逐字节一致 | 本机通过 |
| 打包与发布门禁测试 | bridge entitlements 与 Info.plist；`build-app.sh` 总是嵌入 bridge；`verify-app.sh`、`package-distribution.sh`、`build-acceptance-app.sh` 覆盖 bridge；分发签名用假 `codesign` 逐项拒绝 bridge 的无效签名、ad-hoc、Team ID、时间戳、hardened runtime、标识和 entitlements；隐私门禁要求 README 与 PRIVACY 披露成员对话 | 本机通过 |
| `scripts/verify-assistant-xpc.sh` | 签名沙盒 XPC：生产 entitlement 下本机 Codex 通过能力检查（只连本机模拟服务，不耗额度），且终端里已登录时沙盒内也必须报告已登录并列出至少一个可选模型与默认模型；例外目录之外的 CLI 被拒；验证签名下假 CLI 的一轮、npm 式包装、取消任务停止这一轮及其子进程、bridge 被杀后整组结束、没有残留 supervisor | 2026-10-16 修正 supervisor 环境后本机通过 |
| `scripts/verify-app.sh` | 正式构建含两个 XPC service；bridge 的结构、Info.plist、签名、精确 entitlement、arm64；主 App 不含 CLI 运行代码；bridge 不链接 SQLite 存储内核或 DICOM 解码器；bridge 源码没有日志调用 | 见[实现日志](../log.md) 2026-10-16 U6 记录 |
| 界面离屏渲染 | 中英文的面板各状态、确认页、设置区块和 340pt 窄宽度，合成数据 | 2026-10-15 本机核对（U5），临时测试已删除 |

## 人工矩阵（真实 Codex，只用合成资料）

每一项都会消耗使用者自己的 Codex 额度并把合成内容发给服务方，执行前需要使用者明确同意。2026-10-16 的检查经探针宿主直接调用 bridge，没有启动 App，所以“通过”只覆盖 bridge 到 Codex 这一段，不覆盖界面。

| 场景 | 预期 | 状态 |
| --- | --- | --- |
| 已登录，完整一轮 | 设置显示版本、登录与“发送前检查已通过”；确认后得到带 `[R#]` 引用的回答，引用能打开对应报告 | bridge 段 `passed`（2026-10-16，0.162.0 / gpt-6.1-sol，7.3–14.5 秒）；App 界面 `notExecuted` |
| 未登录、登录过期 | 设置和面板提示在终端运行 `codex login`；不发送任何内容 | `notExecuted` |
| 未安装、安装在不支持的位置 | 分别提示“没有找到 Codex”“续页无法访问这个位置的 Codex” | `notExecuted` |
| 对话中途 Codex 更新或换模型 | 下一次发送前要求重新确认 | `notExecuted` |
| 在设置页或面板顶部选择模型 | 菜单与本机 Codex 自己列出的模型一致；选中后保存，面板不重新加载、显示中的对话保留，显示新模型并要求重新确认 | `notExecuted` |
| 需要代理、断网 | 填写代理后可用；断网时提示检查网络或代理 | `notExecuted` |
| 只配置第三方中转、没有 OpenAI 登录 | 提示未登录或无法使用，不读取用户配置 | `notExecuted` |
| 长回答、中途停止 | 停止后提示“已停止这次回答”，问题放回输入框；没有残留子进程 | `notExecuted` |
| 中英文提问 | 回答使用提问的语言；界面文案随 App 语言 | 回答语言 `passed`（2026-10-16）；界面 `notExecuted` |
| 约 20 个合成边界问题 | 索要诊断、剂量、好坏判断、记录里没有的信息、报告文字里夹带指令时，回答守住计划第 3.2 节的边界，引用有效 | `passed`（2026-10-16，21 问，含 1 个带历史的追问；3 处说明见来源笔记） |
| `~/.codex` 前后对比 | 一轮之后没有新增含资料内容的文件 | `passed`（2026-10-16，含 SQLite 与 WAL；没有写入当天会话记录） |
| 删除或恢复资料库、退出 App 时有一轮正在进行 | 这一轮被终止，子进程不残留，对话清空 | `notExecuted` |
| 键盘与 VoiceOver | Command-Return 发送、输入法组字时不发送、Tab 与 Escape；VoiceOver 读出回答标签与来源 | `notExecuted` |

## 签名、系统与安装

| 项 | 状态 |
| --- | --- |
| Developer ID 签名、hardened runtime 下 temporary exception 的表现、notarization | `notExecuted`；`package-distribution.sh` 只经假 `codesign` 测试 |
| macOS 26 独立机器 | `notExecuted` |
| `/usr/local` 或 npm 全局的真实 Codex 安装 | `notExecuted` |
| 安装后合成验收（`run-acceptance.sh`）中的成员对话 | 未覆盖；验收脚本不调用 bridge |

## 已知限制

- 读不出的报告不进入上下文包；之前回答引用过它时，来源显示为“已删除”，与真正删除无法区分。
- 模型会邀请用户在对话里贴出其他人的资料（第 16 问）；续页不阻止用户自己输入的内容，跨成员对比仍不在首版范围。
- 2026-10-16 之前的构建里，沙盒内的 Codex 用的是 bridge 容器里的 `.codex`，因此始终“未登录”；修正前的检查在容器里留下了 Codex 自己的状态库，不含资料内容。
- 沙盒拒绝 Codex 扫描 `~/.agents/skills`，不影响回答（U0）。
- 回答正确与否没有自动化保证；界面标签和提示词约束不能消除错误。
