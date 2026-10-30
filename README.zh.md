# Agent Installer

[English](README.md) | 简体中文

Detects the AI agent clients on this machine and installs a product's
integration (MCP server, hooks, instructions, skills, permissions) into the
clients a person selects, with a dry-run preview, status and removal.

扫描本机装了哪些 Agent 客户端，再把一个产品（DingDong、FULI……）的接入装进用户勾选
的那几个：MCP 服务、生命周期 Hook、说明文件中的托管段落、Skills、插件目录和权限
白名单。每一步都可以先预览，之后可以查看状态、更新和卸载。

它与会话打开组件共用客户端 ID 和 [本机扩展](https://github.com/JevonsCode/agent-session-launcher/blob/main/docs/extensions.md) 目录。产品只描述“装
什么”（[产品清单](#产品清单)），客户端“装在哪、什么格式”由内置目录和扩展文件描述
（[安装目标](#安装目标)），写入由一组固定代码完成，清单和扩展文件都不能执行代码。

## 下载

每个版本在 [Releases](https://github.com/JevonsCode/agent-installer/releases) 提供编译好的可执行文件，不需要安装 Dart：

| 平台 | 文件 |
| --- | --- |
| macOS（Apple 芯片） | `agent-installer-macos-arm64` |
| macOS（Intel） | `agent-installer-macos-x64` |
| Linux x64 / arm64 | `agent-installer-linux-x64`、`agent-installer-linux-arm64` |
| Windows x64 | `agent-installer-windows-x64.exe` |

用同目录的 `SHA256SUMS` 校验。macOS 上通过浏览器下载的文件需要先执行
`xattr -d com.apple.quarantine <文件>` 并 `chmod +x`；用 `curl` 下载的只需 `chmod +x`。
Node 宿主把下载的文件路径作为 `executable` 传给绑定即可。

## 构建与依赖

需要 Dart SDK 3.10 或更高版本。Node 宿主为每个平台编译原生可执行文件：

```sh
dart pub get
mkdir -p build
dart compile exe bin/agent_installer.dart -o build/agent-installer
```

Dart / Flutter 宿主用 Git 依赖进程内调用（尚未发布到 pub.dev）：

```yaml
dependencies:
  agent_installer:
    git:
      url: https://github.com/JevonsCode/agent-installer.git
      ref: <commit-or-tag>
```

本仓库与 [agent-session-launcher](https://github.com/JevonsCode/agent-session-launcher)
共用本机扩展目录和客户端 ID：同一个 `<client-id>.json` 里，本组件只读 `install`，
会话打开组件读其余字段并忽略 `install`。两边没有代码依赖，这个约定由各自的测试
守住。

## 共享目录

两个组件共用一个按用户的根目录 `agent-clients`：

| 平台 | 根目录 |
| --- | --- |
| Windows | `%APPDATA%\agent-clients` |
| macOS / Linux | `XDG_CONFIG_HOME` 为绝对路径时是 `$XDG_CONFIG_HOME/agent-clients`，否则 `~/.config/agent-clients` |

- `extensions/` 放手写的 `<client-id>.json`（`defaultExtensionsDirectory()`）。
- `backups/<product>/<client-id>/` 放本组件修改文件或替换目录前复制的原件
  （`defaultBackupsDirectory(product)`）。

0.2 之前扩展放在同一基础目录下的 `agent-session-launcher/clients`，备份放在
`agent-session-launcher/backups`。只要 `agent-clients/extensions` 还不存在，就继续
读取旧的扩展目录；不会自动移动任何文件。迁移时新建 `agent-clients/extensions`，
把 `.json` 文件移进去即可；旧备份不再需要时可以自行删除。

## 验证

```sh
dart test
dart analyze
AGENT_INSTALLER_BIN="$PWD/build/agent-installer" node --test test/node_binding_test.mjs
```

测试都在临时目录中运行，不会改动本机真实的客户端配置。

## 命令行

```sh
agent-installer scan --json
agent-installer status  --product acme.manifest.json --var acmeMcp=/opt/acme/bin/acme_mcp --json
agent-installer plan    --clients claude-code,codex --product … --var …
agent-installer apply   --clients claude-code,codex --product … --var …
agent-installer remove  --clients cursor --product … --var …
```

- `plan` 只预览，返回每个文件的变更与 diff，不写任何东西。
- `apply`、`remove` 必须明确列出客户端，不会默认全选。
- `--extensions` 默认是共享的本机扩展目录；`--backups` 默认是
  `agent-clients/backups/<product>`（见[共享目录](#共享目录)），每个文件或目录
  保留最近 5 份原件。
- `--json` 输出 `{ "version": 1, "ok": true, … }`；失败时 `ok: false` 并带 `error.code`，
  退出码 1。完成但有组件被跳过时退出码 2，原因在每个客户端的 `problems` 里。

Node 宿主使用 `bindings/node/index.mjs`（类型见 `index.d.ts`）；Dart 宿主直接
使用 `package:agent_installer/agent_installer.dart`：

```dart
final installer = AgentInstaller(
  product: ProductManifest.decode(manifestText, variables: {'appMcp': mcpPath}),
  targets: InstallTargets.load(extensionsDirectory: defaultExtensionsDirectory()),
  backupDirectory: backupsPath,
);
final scans = installer.scan();               // 设置页列表
final plan = installer.plan(['claude-code']); // 预览
installer.apply(['claude-code']);             // 用户确认后
```

## 状态

每个客户端的 `state`：

| 值 | 含义 |
| --- | --- |
| `connected` | 所有组件都是最新 |
| `update_available` | 部分组件缺失或过期 |
| `not_connected` | 还没有安装任何组件 |
| `conflict` | 有组件不能安全修改，见 `componentStates[].message` |
| `manual` | 环境变量让客户端读取别的文件，需要手动配置 |
| `unsupported` | 当前系统没有这个客户端，或它不接受该产品的任何组件 |

每个组件为 `current`、`outdated`、`missing`、`conflict` 或 `unsupported`（产品要装、
客户端不支持）。`detected` 与 `evidence` 只说明找到了什么，不影响能否安装：用户可以
给还没运行过的客户端预先安装。

## 内置客户端

| ID | MCP | Hook | 说明文件 | Skills | 其他 |
| --- | --- | --- | --- | --- | --- |
| `claude-code` | `~/.claude.json` | `~/.claude/settings.json` | `~/.claude/CLAUDE.md` | `~/.claude/skills` | 权限白名单 |
| `codex` | `{CODEX_HOME}/config.toml` | `hooks.json`，或 `config.toml` 中已有 Hook 表时写在那里 | `AGENTS.md`（`AGENTS.override.md` 有内容时写它） | `~/.agents/skills` | |
| `cursor` | `~/.cursor/mcp.json` | `~/.cursor/hooks.json` | | `~/.cursor/skills` | |
| `opencode` | `opencode.jsonc` 或 `opencode.json` | | | `skills` | `plugins/<产品>` |
| `claude-desktop` | `claude_desktop_config.json`（macOS、Windows） | | | | |
| `gemini-cli`、`kiro`、`qwen-code` | 各自的 `settings.json` / `mcp.json` | | | | |

Gemini CLI、Kiro 的 Hook，以及按 OpenCode 版本决定是否安装插件，第一期没有内置；
可以用扩展文件补充，验证后再加入内置目录。

## 产品清单

[JSON Schema](docs/manifest.schema.json)，示例见
[`example/acme/acme.manifest.json`](example/acme/acme.manifest.json)。

```json
{
  "schemaVersion": 1,
  "product": "acme",
  "name": "Acme",
  "version": "1.0.0",
  "mcp": { "name": "acme", "command": "{acmeMcp}", "args": ["--source", "{clientName}"] },
  "hooks": {
    "markers": ["acme_mcp"],
    "events": {
      "stop": { "command": ["{acmeMcp}", "--notify-stop", "--source", "{clientName}"], "timeoutSec": 10 }
    }
  },
  "instructions": { "markdown": "Acme is available through the `acme` MCP server." },
  "skills": [{ "name": "acme-helper", "source": "{bundle}/skills/acme-helper" }],
  "permissions": { "allow": ["mcp__acme__ping"] },
  "clients": {
    "claude-desktop": { "mcp": { "args": ["--profile", "chat"] } },
    "cursor": { "hooks": null }
  }
}
```

- **占位符**：`{name}` 只做替换、从不求值，值由宿主用 `--var` 或 `variables` 传入；
  另有 `{clientId}`、`{clientName}`。`${…}` 原样保留给客户端展开。未知占位符会报错。
- **MCP**：`extra` 写入额外字段，例如 Codex 的 `startup_timeout_sec`。已有条目中用户
  添加的字段会保留，`url`、`headers`、`type` 等传输字段会被替换。
  同名条目只有在命令、参数或 URL 中含有 `markers` 里的某段文字时才算本产品的；
  否则报冲突，安装和卸载都不会动它。`markers` 默认沿用 Hook 的标记，没有 Hook 时用
  命令本身。条目里不写额外的标识字段，因为部分客户端重写配置时会丢掉不认识的字段。
- **Hook**：事件名统一为 `sessionStart`、`userPromptSubmit`、`stop`、`agentResponse`
  （带最终回复文字，目前只有 Cursor 的 `afterAgentResponse`）、`preCompact`，
  由客户端映射到自己的名称；客户端不支持的事件会跳过。命令是参数数组，按平台引用
  后写成一条命令。每条命令必须包含 `markers` 中的某段文字，组件靠它识别、更新和
  卸载本产品的 Hook，所以手动或 AI 装过的旧条目也能被接管。
- **说明**：默认标记为 `<!-- BEGIN <PRODUCT> MANAGED INSTRUCTIONS -->`，可用
  `begin`、`end` 沿用产品已有的标记。
- **Skills / 插件**：整目录复制，目标目录内写回执 `.agent-installer.json`。不覆盖不属于
  本产品的同名目录；用户改过的目录会被保留并报告。
- **按客户端覆盖**：`clients.<id>` 与上面的组件递归合并，`null` 表示这个客户端不装该
  组件。

## 安装目标

本机私有 Agent 在扩展文件里写 `install` 段即可接入，字段见
[extension.schema.json](https://github.com/JevonsCode/agent-session-launcher/blob/main/docs/extension.schema.json)：

```json
{
  "schemaVersion": 1,
  "name": "Acme Agent",
  "launch": { "command": ["~/bin/acme-agent", "resume", "{id}"] },
  "install": {
    "detect": [{ "command": "acme-agent" }, { "path": "~/.acme" }],
    "mcp": { "file": "~/.acme/mcp.json", "format": "mcp-servers-json" },
    "hooks": {
      "file": "~/.acme/hooks.json",
      "format": "claude-hooks",
      "events": { "sessionStart": "SessionStart", "stop": "Stop" }
    },
    "instructions": { "file": "~/.acme/AGENTS.md" },
    "skills": { "dir": "~/.acme/skills" }
  }
}
```

- 路径只能从 `~/`、`{home}`（`home.env` 指定的环境变量或 `home.default`）、
  `{configHome}`、`{appData}` 开始，不能包含 `..`。
- 写入格式只能从内置格式中选：MCP 为 `claude-json`、`mcp-servers-json`、`kiro-json`、
  `opencode-json`、`codex-toml`，Hook 为 `claude-hooks`、`codex-hooks`、`cursor-hooks`。
- 文件名用内置 ID（如 `cursor.json`）时，`install` 中列出的键替换内置值，其余保留。
- 只有 `install` 的文件不会成为会话打开组件的客户端。出错的扩展文件只跳过它自己，
  原因在 `extensionErrors` 中。

## 写入安全

- 只修改本产品的条目：MCP 按名称，Hook 按标记，说明按首尾标记，目录按回执；其他
  内容、顺序和注释保持不变（JSON 支持注释与尾逗号，TOML 按表编辑）。
- 已是最新时不写文件；更新时在原位置替换，不移动到文件末尾。
- 原子写入：先写同目录临时文件再替换，保留原文件权限，新文件为 0600；符号链接
  保持为链接，写入它指向的文件。
- 客户端在读写之间改了文件（Claude Code 会频繁改 `~/.claude.json`），组件会基于新
  内容重新编辑，最多重试 3 次，不覆盖客户端的修改。
- 卸载后文件只剩 `{}` 时删除该文件；卸载创建过的说明文件同理。
- 从不修改客户端的信任存储。Codex 新增或改动 Hook 后，需要用户在 Codex 中用
  `/hooks` 确认信任。

## 让 AI 安装

AI 可以直接使用命令行：先 `scan --json` 和 `status --json` 了解现状，再对用户选择的
客户端 `plan`，把 diff 给用户确认后 `apply`。遇到不认识的 Agent，AI 根据该 Agent 的
官方文档写出扩展文件的 `install` 段，再运行 `plan` 检查。这样安装的结果仍然可以查
状态、更新和卸载。
