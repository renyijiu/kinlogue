---
title: 本机 Codex CLI 与 Claude Code CLI 的非交互调用选项
author: OpenAI（Codex CLI）、Anthropic（Claude Code）；本机安装版本的 --help 输出
source_url: 本机 `codex --help`、`codex exec --help`、`codex login --help`、`codex features list`、`claude --help`、`claude auth --help`
captured: 2026-10-15
kind: external-spec
---

# 本机 Codex CLI 与 Claude Code CLI 的非交互调用选项

本页只记录 2026-10-15 在开发机上从帮助文本读到的选项，用于[成员对话计划](../plans/2026-10-15-feat-member-cli-chat-plan.md)。没有发起任何模型请求，也没有在 App Sandbox 或 XPC 中运行这两个 CLI；下文“未核实”一节的内容都要由计划的 U0 探针实测。

## 版本与位置

| CLI | 版本 | 安装位置 |
| --- | --- | --- |
| Codex | `codex-cli 0.162.0` | `/opt/homebrew/bin/codex`（Homebrew） |
| Claude Code | `2.1.296 (Claude Code)` | `~/.local/bin/claude`（原生安装） |

两个 CLI 都频繁发布新版本；以下选项名只对上述版本成立。

## Codex 0.162.0

- `codex exec [PROMPT]`：非交互运行；不给 PROMPT 或给 `-` 时从 stdin 读取指令。
- `--json`：把事件按 JSONL 打印到 stdout。`-o/--output-last-message <FILE>` 与 `--output-schema <FILE>` 需要文件路径。
- `--ephemeral`：不把会话文件写到磁盘。
- `--ignore-user-config`：不加载 `$CODEX_HOME/config.toml`，帮助文本注明“认证仍使用 `CODEX_HOME`”。`--ignore-rules`：不加载用户或项目的 execpolicy `.rules`。
- `-s/--sandbox read-only|workspace-write|danger-full-access`、`-C/--cd <DIR>`、`--skip-git-repo-check`、`-m/--model`、`-c key=value`（按 TOML 覆盖配置）、`--enable/--disable <FEATURE>`。
- `--oss` 与 `--local-provider lmstudio|ollama`：改用本机模型服务。
- `codex login status`：显示登录状态。`codex app-server` 标为 experimental。
- `codex features list` 显示本版本默认开启了 `apps`、`browser_use`、`browser_use_external`、`computer_use`、`code_mode_host`、`daemon_auto_start`、`goals` 等功能；列表中也有大量标为 `removed` 或 `under development` 的条目，说明功能名在版本之间变化。

未合入的 `codex/agentrunkit-probe` 分支曾用同一版本（0.162.0）的配置 schema 核对过一组关闭 shell、浏览器、插件、hooks、记忆、技能发现、遥测和历史的配置键（该分支的 `packaging/codex-config.toml`）。那组配置是给内置 Codex 加独立 `CODEX_HOME` 用的，本次没有在用户自己的安装上复验。

## Claude Code 2.1.296

- `-p/--print`：打印回答后退出。帮助文本提醒：非交互模式跳过工作区信任对话框，并且会静默忽略校验失败的设置文件。
- `--output-format text|json|stream-json`；`--include-partial-messages` 只在 `--print` 加 `stream-json` 时有效；`--input-format text|stream-json`。
- `--system-prompt <prompt>` 替换默认系统提示词；`--append-system-prompt` 是追加。
- `--tools <tools...>`：指定可用的内置工具，传 `""` 时关闭全部内置工具。
- `--strict-mcp-config`：只使用 `--mcp-config` 给出的 MCP 服务器，忽略其他 MCP 配置。
- `--safe-mode`：关闭 CLAUDE.md、skills、已安装插件、hooks、MCP 服务器、自定义命令与 agent、输出样式等定制；帮助文本说认证、模型选择、内置工具和插件以及权限照常工作。
- `--restricted`：去掉运行命令或代码的内置工具和 WebFetch，忽略 user、project、local 设置文件。
- `--no-session-persistence`：不把会话写到磁盘（只在 `--print` 下有效）。
- `--permission-prompts host|none`：`none` 时任何需要询问的操作都自动拒绝。
- `--bare`：只认 `ANTHROPIC_API_KEY` 或 `--settings` 里的 `apiKeyHelper`，不读取 OAuth 登录；因此不适用于“复用用户已登录的订阅”。
- `--max-budget-usd` 只对 API 调用有效。
- `claude auth status`：显示认证状态。

## 本项目采用的部分

- 两个 CLI 都能从 stdin 接收提示词、以 JSON 事件流输出、关闭会话落盘，这是计划中“每轮一个新进程、健康资料只走 stdin”的依据。
- Claude Code 可以用 `--tools ""`、`--safe-mode`、`--strict-mcp-config` 组合关闭工具和用户定制；Codex 可以用 `--ignore-user-config` 在保留登录的同时忽略用户配置，再用 `-c` 覆盖关闭默认开启的功能。
- 帮助文本没有提供“锁定版本”的机制，计划因此采用“每次按帮助文本和功能列表检查所需选项，缺失就拒绝”的方式，而不是锁定某一版本。

## 未核实（需要 U0 实测）

- 关闭工具后，实际发给模型的请求里是否确实没有任何工具；Codex 在 `-c features.*=false` 覆盖后是否还有默认工具。
- 两个 CLI 的流式事件格式；Codex `exec --json` 是否给出逐字增量；`stream-json` 是否要求同时传 `--verbose`。
- 带上述选项运行时是否仍在 `~/.claude`、`~/.codex` 下写入会话、历史、日志或遥测文件；关闭遥测需要哪些环境变量。
- 在 App Sandbox 或独立 XPC 服务中运行时，能否读到各自的登录凭据（Codex 的 `CODEX_HOME`，Claude Code 的钥匙串项）并在刷新后写回。
- 从 GUI 进程启动时缺少登录 shell 的 `PATH` 和代理变量，对两个 CLI 的影响。

## 转引但本次未重新核对的来源

`codex/agentrunkit-probe` 分支的调研文档转引了 Anthropic 的 Agent SDK 文档（<https://code.claude.com/docs/en/agent-sdk/overview>）：未经批准，第三方产品不能提供 claude.ai 登录或额度。这与用户在自己的终端里使用 Claude Code 是不同的边界。本次没有重新阅读该页，计划把它列为需要用户确认的问题。
