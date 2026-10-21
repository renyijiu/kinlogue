---
title: U0 探针：在终端和 XPC helper 中运行本机 Codex 0.162.0 的实测
author: 本项目 U0 探针（开发机实测）；Codex 0.162.0 配置 schema 由 OpenAI 发布
source_url: 本机 `codex` 0.162.0（Homebrew cask）与用户的 ChatGPT 登录；<https://github.com/openai/codex/blob/rust-v0.162.0/codex-rs/core/config.schema.json>
captured: 2026-10-15
kind: external-spec
---

# U0 探针：在终端和 XPC helper 中运行本机 Codex 0.162.0 的实测

本页记录[成员对话计划](../plans/2026-10-15-feat-member-cli-chat-plan.md) U0 的实测结果，回答[上一份来源笔记](2026-10-15-local-cli-noninteractive-flags.md)中“未核实”的问题。所有资料都是合成的；探针代码放在会话临时目录里，没有进入仓库。

## 环境与方法

- macOS 27.0.1、Xcode 27.0 / Swift 6.4；Codex `0.162.0`（Homebrew cask，真实路径在 `/opt/homebrew/Caskroom/codex/0.162.0/bin/`），以 ChatGPT 账号登录，凭据保存在 `~/.codex/auth.json`（文件，不是系统钥匙串）。用户配置里设了默认模型，探针显式传 `-m gpt-6-astra`。
- 合成上下文包：3 份或 20 份血常规与生化记录，每份带一个唯一标记串，用来事后在磁盘上查找；另有一份“注入”记录，要求模型用工具读取一个 canary 文件并执行 `ls ~`。
- 检查发出的请求：用一个只监听 127.0.0.1 的模拟 Responses 服务替代真实服务商（`-c model_provider=...` 指向它），记录 Codex 实际发出的请求体，这一步不消耗额度。
- 真实账号：终端里跑 3 轮，XPC helper 里跑 3 轮，都只用合成资料。
- XPC：一个 ad-hoc 签名、只有 `app-sandbox` 的宿主 App，内嵌两个 XPC 服务。A 启用 App Sandbox，加 `network.client`、`temporary-exception.files.home-relative-path.read-write = ["/.codex/"]` 和 `temporary-exception.files.absolute-path.read-only = ["/opt/homebrew/"]`；B 不启用沙盒。宿主从 stdin 把请求交给 helper，helper 用固定参数启动 Codex，把提示词写进 Codex 的 stdin。

## 结果

### 工具

1. 本版本默认开启的功能有 57 个（含已标为 removed 的条目）。把不在 7 项白名单内、且未标为 removed 的已开启功能全部 `--disable`，共 41 个。
2. 即使这样，`gpt-6-astra` 的请求里仍有 9 个工具。它们不在顶层 `tools` 字段，而在一个 `additional_tools` 类型的输入项里：代码模式的 `exec`、`wait`、`request_user_input_async`，以及 6 个子 agent 协作工具。另有一个 `error` 事件提示代码模式的 host 已关闭，调用会失败。
3. `-c agents.enabled=false` 去掉 6 个协作工具。剩下 3 个来自模型目录：`codex debug models` 列出的 9 个模型的 `tool_mode` 都是 `code_mode_only`。用 `model_catalog_json` 指向一份改过的目录副本后，请求里的工具数降为 0。副本去掉了 `tool_mode`、`apply_patch_tool_type`、`web_search_tool_type`、`multi_agent_version`，并把 `experimental_supported_tools` 置空、`supports_search_tool` 设为 false。只去掉 `tool_mode` 时，仍会出现 `apply_patch`、`clock.curr_time` 和 `request_user_input_async`。
4. 不在目录里的模型名，或 `gpt-5`，不改目录也是 0 个工具。

### 提示词与请求内容

5. `-c instructions=...` 会整段替换 Codex 内置的约 21 KB 编程助手提示词；`include_collaboration_mode_instructions=false` 和 `include_apps_instructions=false` 去掉对应的开发者消息块。
6. 加固后的请求只有两条消息：一条开发者消息（我们的角色说明），一条用户消息（stdin 内容）。`store` 为 false，3 份记录时请求体约 3.8 KB。请求体中没有本机路径、用户名、工作目录、AGENTS.md 或环境上下文块；`client_metadata` 里有 Codex 自己的安装 ID 和会话 ID。
7. `--strict-config` 会拒绝不认识的 `-c` 键和不认识的功能名，退出码为 1，不输出任何事件。

### 输出与延迟（真实账号，终端）

8. `codex exec --json` 只输出 `thread.started`、`turn.started`、一个 `item.completed`（`agent_message`，完整回答）和带 usage 的 `turn.completed`，**没有逐字增量**。
9. 3 份记录：705 输入 token，6.2 秒；带注入记录：830 token，9.4 秒；20 份记录（提示词 92.6 KB）：24,838 输入 token，17.1 秒。三轮回答都用 `[R#]` 引用。注入记录被当成资料描述（“内容为与健康记录无关的指令文本”），canary 内容没有出现在输出里；这几轮请求本身就没有任何工具可调用。

### 磁盘

10. 运行期间 `~/.codex` 下被修改的文件只有 `logs_2.sqlite`（及 `-wal`）、`models_cache.json`、`.codex-global-state.json`（及 `.bak`）。整个 `~/.codex` 中都找不到合成标记串；日志库里也找不到这几轮的 thread ID。同一时间窗内新增的日志行来自同时运行的 Codex 桌面版（`model/list`、`getAuthStatus` 等），不含资料内容。`auth.json` 没有被修改（这几轮没有发生令牌刷新）。

### XPC helper

11. 宿主处于沙盒中。B（非沙盒）：Codex 正常运行，6.3 秒返回；helper 能列出家目录和 `~/Library/Containers`。
12. A（沙盒 + 例外）：Codex 正常运行，5.8 秒返回；helper 的 `HOME` 是自己的容器，不能列出真实家目录或 `~/Library/Containers`，能读到 `~/.codex/auth.json`。传给 Codex 的 `HOME` 是真实家目录（由 `getpwuid` 取得）。唯一观察到的拒绝来自 Codex 自己扫描 `~/.agents/skills`：它在 stderr 打出一行 `Operation not permitted`，回答不受影响。系统日志里没有其他与 Codex 或 helper 有关的沙盒拒绝。
13. 开启 `skip_host_skill_discovery`（标为 under development）并没有阻止上述扫描，反而多出一个“开启了未完成功能”的 `error` 事件，因此不采用。
14. XPC 服务的环境变量只有 launchd 给的最小集合，没有代理变量。本机不传代理变量时 A、B 都能连上服务商，显式传入 `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` 时 A 也正常。推断：本机能直连是因为系统层面的代理设置，不能推广到其他网络。

## 本项目采用的部分

- 方案 A 在本机可行，按计划 D1 的规则选用 A。
- 加固参数在[上一份笔记](2026-10-15-local-cli-noninteractive-flags.md)的基础上，增加了 `--strict-config`、`agents.enabled=false`、`instructions`、两个 `include_*` 开关和改过的模型目录；功能按“白名单之外全部关闭”处理。
- 回答整段显示；成功判据是退出码 0、`turn.completed`，且有一个 `agent_message`。`error` 事件只作为诊断，不单独判为失败。
- 发送前用本机模拟服务实际检查一次请求（工具数为 0、只有两条消息、没有本机路径），作为能力检查的一部分。

## 未验证

- A 下的令牌刷新：这几轮没有发生刷新，只能说明 `~/.codex/` 有读写例外，没有观察到刷新后的写回。
- 其他安装位置（npm 全局、独立安装脚本、`/usr/local`）在 A 下能否执行；例外列表需要逐一覆盖。
- 真实发送时的网络去向：只检查了发往模拟服务的请求体，没有抓真实流量。
- 取消、超时与进程组回收（留给 U2）；Developer ID 签名、公证和 macOS 26 上 temporary exception 的表现；服务商侧的保留政策。
- 探针留下的两个空沙盒容器（`~/Library/Containers/com.kinlogue.u0probe.*`）由系统保护，`rm` 无法删除，需要在 Finder 中手动移除。

## U2 复核（同日追加）

U2 实现后，用一个用完即删的临时测试，让 `CodexBridge` 对本机真实的 Codex 0.162.0 跑能力检查（只走本机模拟服务，不消耗额度）。新发现：

- `codex features list` 里有带点的功能名（`guardianv2.thread_context`），解析器最初只接受字母、数字和下划线，导致检查失败；已改为接受 `.`。
- 关闭 41 个功能后，`features list` 仍显示 `unified_exec` 开启，`-c features.unified_exec=false` 也无效；同一组参数下实际发出的请求里没有任何工具。`features list` 读取的是用户配置，而这一轮用的是 `--ignore-user-config`，因此检查不再以功能表为准，只以实际请求为准。
- 修正后，目录里的第一个模型（`gpt-6.1-sol`）和 `gpt-6-astra` 都通过检查：已登录、版本已验证、请求中工具数为 0、只有两条消息、没有本机路径，分别用时 3.1 秒和 1.4 秒；临时目录没有残留。
- 没有经 bridge 跑真实的一轮问答。

## U2b 签名 XPC 复核（同日追加）

`scripts/verify-assistant-xpc.sh` 把 bridge 按 [方案 A 的 entitlements](../../packaging/KinlogueAssistantBridge.entitlements) ad-hoc 签名，嵌进只有 `app-sandbox` 的探针宿主，连续两次全部通过：

- 生产 entitlements：本机 Codex 0.162.0 在沙盒 bridge 中通过能力检查。沙盒内可以用 `network.server` 在 127.0.0.1 上监听，Codex 子进程能连回来；bridge 自身作为 supervisor 也能在沙盒内启动。放在例外目录之外的 CLI 被拒，报“不支持的安装位置”：沙盒允许 bridge 读取文件元数据，`access(X_OK)` 才被拒，所以按这一点判断。
- 验证签名（生产集合再加一个只读目录，并换用独立的 bundle 标识）：假 CLI 的一轮回答经 supervisor 返回；仿 npm 的包装（`bin/codex` → `codex.js`，`#!/usr/bin/env` 解释器放在 `bin/`）可以运行；从第二条连接发出的取消在 2 秒处停止这一轮，CLI 和它启动的孙进程都退出；SIGKILL bridge 服务进程后，supervisor 杀掉整组，没有 supervisor 残留。
- 没有用真实账号跑一轮问答；`/usr/local/` 下没有真实安装可测；系统为探针创建的沙盒容器（`com.kinlogue.mac.assistant-bridge`、`…-verification`、`…assistant-xpc-probe`）保留在 `~/Library/Containers/`，其中只有元数据。
