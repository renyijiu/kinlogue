# 成员对话验收矩阵

状态：成员对话（界面名“AI 对话（实验）”）默认关闭。源码自动化只用假 CLI 和合成资料；签名沙盒 XPC 在本机用真实 Codex 做过不耗额度的能力检查。**经真实 Codex 的完整一轮问答、回答边界的人工检查、macOS 26、Developer ID 与公证都还没有执行。** 版本、测试清单和整体发布状态只由[当前候选证据](current-release.md)维护；设计与决策见[成员对话计划](../plans/2026-10-15-feat-member-cli-chat-plan.md)，用户承诺见 [`PRIVACY.md`](../../PRIVACY.md)。

## 支持范围

| 项 | 当前范围 | 依据 |
| --- | --- | --- |
| CLI | 只支持 Codex。`0.162.0` 的加固参数经真实请求验证；其他版本在每项能力检查都通过时仍可使用，界面标为“未验证的版本” | [U0 证据](../sources/2026-10-15-codex-u0-probe-evidence.md)、`CodexInvocation.verifiedVersions` |
| 账号 | 只支持 Codex 自己登录的 OpenAI 账号；不加载用户的 Codex 配置，因此不支持第三方中转 | 计划 E2 |
| 安装位置 | `/opt/homebrew/` 下的安装经真实 Codex 验证；`/usr/local/` 只验证了同一机制；家目录下的 nvm、volta、bun 等位置报“不支持的安装位置” | 计划第 4.2 节 |
| 发送内容 | 一位成员最新的最多 20 份已确认报告的日期、标题、检查结果、结论和标记项，问答历史和问题；机构名称默认不发送 | `AssistantContextPackBuilder`、[`PRIVACY.md`](../../PRIVACY.md) |
| 保存 | 只在内存；保存对话属于 U7，尚未开始 | 计划 D4、D8 |

## 自动化证据

以下都在 2026-10-16 的未提交工作树上、macOS 27.0.1 / Xcode 27.0 / Swift 6.4 本机通过，没有绑定不可变 source ref。完整命令和结果见[实现日志](../log.md)。

| 门禁 | 覆盖 | 状态 |
| --- | --- | --- |
| Core 测试 | 上下文包只取这位成员的已确认记录、不含姓名/备注/机构/ID、预算与截断标记、编号确定、标签转义、指纹随任何输入变化、引用解析与“已更改/已删除”判定、值类型编码往返 | 本机通过 |
| Platform 测试 | IPC 有界 DTO；Codex 参数、功能白名单、模型目录改写、事件解析；用假 CLI 驱动的 UTF-8 分片、超长行、输出洪泛、超时、非零退出、未登录/限流、取消后孙进程退出、supervisor、参数与环境里没有资料内容、能力检查缺一项即拒绝；SQLite 上下文包读取与 provider | 本机通过 |
| App 测试 | 设置、同意与指纹、内存对话存储、服务生命周期（删除/恢复资料库时取消并清空）、迟到结果被丢弃、提交观察后重新确认、对话模型与 composition；设置模型校验；中英文案与单复数；视图源码安全 | 本机通过 |
| 打包与发布门禁测试 | bridge entitlements 与 Info.plist；`build-app.sh` 总是嵌入 bridge；`verify-app.sh`、`package-distribution.sh`、`build-acceptance-app.sh` 覆盖 bridge；分发签名用假 `codesign` 逐项拒绝 bridge 的无效签名、ad-hoc、Team ID、时间戳、hardened runtime、标识和 entitlements；隐私门禁要求 README 与 PRIVACY 披露成员对话 | 本机通过 |
| `scripts/verify-assistant-xpc.sh` | 签名沙盒 XPC：生产 entitlement 下本机 Codex 通过能力检查（只连本机模拟服务，不耗额度），例外目录之外的 CLI 被拒；验证签名下假 CLI 的一轮、npm 式包装、取消任务停止这一轮及其子进程、bridge 被杀后整组结束、没有残留 supervisor | 2026-10-15 本机通过（U2b、U3） |
| `scripts/verify-app.sh` | 正式构建含两个 XPC service；bridge 的结构、Info.plist、签名、精确 entitlement、arm64；主 App 不含 CLI 运行代码；bridge 不链接 SQLite 存储内核或 DICOM 解码器；bridge 源码没有日志调用 | 见[实现日志](../log.md) 2026-10-16 U6 记录 |
| 界面离屏渲染 | 中英文的面板各状态、确认页、设置区块和 340pt 窄宽度，合成数据 | 2026-10-15 本机核对（U5），临时测试已删除 |

## 人工矩阵（真实 Codex，只用合成资料）

每一项都会消耗使用者自己的 Codex 额度并把合成内容发给服务方，执行前需要使用者明确同意。

| 场景 | 预期 | 状态 |
| --- | --- | --- |
| 已登录，完整一轮 | 设置显示版本、登录与“发送前检查已通过”；确认后得到带 `[R#]` 引用的回答，引用能打开对应报告 | `notExecuted` |
| 未登录、登录过期 | 设置和面板提示在终端运行 `codex login`；不发送任何内容 | `notExecuted` |
| 未安装、安装在不支持的位置 | 分别提示“没有找到 Codex”“续页无法访问这个位置的 Codex” | `notExecuted` |
| 对话中途 Codex 更新或换模型 | 下一次发送前要求重新确认 | `notExecuted` |
| 需要代理、断网 | 填写代理后可用；断网时提示检查网络或代理 | `notExecuted` |
| 只配置第三方中转、没有 OpenAI 登录 | 提示未登录或无法使用，不读取用户配置 | `notExecuted` |
| 长回答、中途停止 | 停止后提示“已停止这次回答”，问题放回输入框；没有残留子进程 | `notExecuted` |
| 中英文提问 | 回答使用提问的语言；界面文案随 App 语言 | `notExecuted` |
| 约 20 个合成边界问题 | 索要诊断、剂量、好坏判断、记录里没有的信息、报告文字里夹带指令时，回答守住计划第 3.2 节的边界，引用有效 | `notExecuted` |
| `~/.codex` 前后对比 | 一轮之后没有新增含资料内容的文件（U0 在 0.162.0 上核对过，经 bridge 的一轮尚未核对） | `notExecuted` |
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
- 沙盒拒绝 Codex 扫描 `~/.agents/skills`，不影响回答（U0）。
- 回答正确与否没有自动化保证；界面标签和提示词约束不能消除错误。
