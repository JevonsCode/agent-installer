# Agent Installer

English | [简体中文](README.zh.md)

Detects the AI agent clients on this machine and installs a product's
integration (MCP server, hooks, instructions, skills, permissions) into the
clients a person selects, with a dry-run preview, status and removal.

A product (the host) describes what to install; the installer writes it
into MCP configs, lifecycle hooks, managed sections in instruction
files, skill and plugin directories, and permission allowlists. Every step can
be previewed first, and afterward you can check status, update, or uninstall.

It shares client IDs and the [local extensions](https://github.com/JevonsCode/agent-session-launcher/blob/main/docs/extensions.md)
directory with the session launcher component. A product only describes
"what to install" ([Product manifest](#product-manifest)); "where to install
it and in what format" for each client is described by the built-in catalog
and extension files ([Install targets](#install-targets)); the actual writing
is done by a fixed set of code — neither the manifest nor the extension files
can execute code. [Integrating a host](docs/integrating-a-host.md) walks a
host application through the whole flow.

## Download

Each release on [Releases](https://github.com/JevonsCode/agent-installer/releases) provides a compiled executable; Dart does not need to be installed:

| Platform | File |
| --- | --- |
| macOS (Apple silicon) | `agent-installer-macos-arm64` |
| macOS (Intel) | `agent-installer-macos-x64` |
| Linux x64 / arm64 | `agent-installer-linux-x64`, `agent-installer-linux-arm64` |
| Windows x64 | `agent-installer-windows-x64.exe` |

Verify with the `SHA256SUMS` file in the same directory. On macOS, a file
downloaded through a browser needs `xattr -d com.apple.quarantine <file>`
followed by `chmod +x`; a file downloaded with `curl` only needs `chmod +x`.
A Node host just needs to pass the downloaded file's path as `executable` to
the binding.

## Build and dependencies

Requires Dart SDK 3.10 or later. A Node host compiles a native executable for
each platform:

```sh
dart pub get
mkdir -p build
dart compile exe bin/agent_installer.dart -o build/agent-installer
```

A Dart/Flutter host calls it in-process via a Git dependency (not yet
published to pub.dev):

```yaml
dependencies:
  agent_installer:
    git:
      url: https://github.com/JevonsCode/agent-installer.git
      ref: <commit-or-tag>
```

This repository shares the local extensions directory and client IDs with
[agent-session-launcher](https://github.com/JevonsCode/agent-session-launcher):
in the same `<client-id>.json`, this component only reads `install`, while
the session launcher component reads the other fields and ignores `install`.
The two have no code dependency; each side's tests guard this convention.

## Shared directory

Both components use one per-user root, `agent-clients`:

| Platform | Root |
| --- | --- |
| Windows | `%APPDATA%\agent-clients` |
| macOS / Linux | `$XDG_CONFIG_HOME/agent-clients` when `XDG_CONFIG_HOME` is absolute, else `~/.config/agent-clients` |

- `extensions/` holds the hand-written `<client-id>.json` files
  (`defaultExtensionsDirectory()`).
- `backups/<product>/<client-id>/` holds the originals this component copied
  before changing a file or replacing a directory
  (`defaultBackupsDirectory(product)`).

Before 0.2 the extensions lived in `agent-session-launcher/clients` and the
backups in `agent-session-launcher/backups` under the same base. While
`agent-clients/extensions` does not exist, the old extensions directory is
still read; nothing is moved automatically. To move, create
`agent-clients/extensions` and move your `.json` files into it; old backups
can be deleted once you no longer need them.

## Verification

```sh
dart test
dart analyze
AGENT_INSTALLER_BIN="$PWD/build/agent-installer" node --test test/node_binding_test.mjs
```

All tests run in a temporary directory and never touch the machine's real
client configuration.

## CLI

```sh
agent-installer scan --json
agent-installer status  --product acme.manifest.json --var acmeMcp=/opt/acme/bin/acme_mcp --json
agent-installer plan    --clients claude-code,codex --product … --var …
agent-installer apply   --clients claude-code,codex --product … --var …
agent-installer remove  --clients cursor --product … --var …
```

- `plan` only previews: it returns the changes and diff for each file without
  writing anything.
- `apply` and `remove` must list clients explicitly; they never default to
  all clients.
- `--extensions` defaults to the shared local extensions directory;
  `--backups` defaults to `agent-clients/backups/<product>` (see
  [Shared directory](#shared-directory)), keeping the 5 most recent originals
  per file or directory.
- `--json` prints `{ "version": 1, "ok": true, … }`; on failure, `ok: false`
  with `error.code` and exit code 1. When it finishes but some components
  were skipped, the exit code is 2, with the reasons under each client's
  `problems`.

The Node host uses `bindings/node/index.mjs` (types in `index.d.ts`); a Dart
host uses `package:agent_installer/agent_installer.dart` directly:

```dart
final installer = AgentInstaller(
  product: ProductManifest.decode(manifestText, variables: {'appMcp': mcpPath}),
  targets: InstallTargets.load(extensionsDirectory: defaultExtensionsDirectory()),
  backupDirectory: backupsPath,
);
final scans = installer.scan();               // settings page list
final plan = installer.plan(['claude-code']); // preview
installer.apply(['claude-code']);             // after user confirmation
```

## Status

Each client's `state`:

| Value | Meaning |
| --- | --- |
| `connected` | All components are up to date |
| `update_available` | Some components are missing or outdated |
| `not_connected` | No component has been installed yet |
| `conflict` | Some component cannot be modified safely; see `componentStates[].message` |
| `manual` | An environment variable makes the client read a different file; manual configuration is needed |
| `unsupported` | This client is not present on the current system, or it accepts none of the product's components |

Each component is `current`, `outdated`, `missing`, `conflict`, or
`unsupported` (the product wants to install it, but the client doesn't
support it). `detected` and `evidence` only state what was found; they don't
affect whether installation is possible: a user can pre-install for a client
that has never been run.

## Built-in clients

| ID | MCP | Hook | Instructions | Skills | Other |
| --- | --- | --- | --- | --- | --- |
| `claude-code` | `~/.claude.json` | `~/.claude/settings.json` | `~/.claude/CLAUDE.md` | `~/.claude/skills` | permission allowlist |
| `codex` | `{CODEX_HOME}/config.toml` | `hooks.json`, or written into the existing hook table in `config.toml` if there is one | `AGENTS.md` (`AGENTS.override.md` if it has content) | `~/.agents/skills` | |
| `cursor` | `~/.cursor/mcp.json` | `~/.cursor/hooks.json` | | `~/.cursor/skills` | |
| `opencode` | `opencode.jsonc` or `opencode.json` | | | `skills` | `plugins/<product>` |
| `claude-desktop` | `claude_desktop_config.json` (macOS, Windows) | | | | |
| `gemini-cli`, `kiro`, `qwen-code` | each client's own `settings.json` / `mcp.json` | | | | |

Hooks for Gemini CLI and Kiro, and deciding whether to install the OpenCode
plugin based on its version, are not built in for the first release; they can
be added through an extension file and promoted to the built-in catalog once
verified.

## Product manifest

[JSON Schema](docs/manifest.schema.json), example at
[`example/acme/acme.manifest.json`](example/acme/acme.manifest.json).

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

- **Placeholders**: `{name}` is a plain substitution, never evaluated; its
  value comes from the host via `--var` or `variables`. There are also
  `{clientId}` and `{clientName}`. `${…}` is kept as-is for the client to
  expand. An unknown placeholder is an error.
- **MCP**: `extra` writes additional fields, e.g. Codex's
  `startup_timeout_sec`. Fields a user added to an existing entry are kept;
  transport fields such as `url`, `headers`, `type` are replaced. An entry
  with the same name is only treated as belonging to this product if its
  command, args, or URL contain one of the strings in `markers`; otherwise it
  is reported as a conflict, and neither install nor remove touches it.
  `markers` defaults to the hook's markers, or to the command itself if there
  is no hook. No extra identifying field is written into the entry, because
  some clients drop unrecognized fields when they rewrite the config.
  `preserveArgs` (e.g. `["--tool-profile"]`) names options whose value the
  person chose in the product's existing entry: on update that `--name value`
  or `--name=value` replaces the manifest's value, or is appended when the
  manifest has none.
- **Hook**: event names are unified as `sessionStart`, `userPromptSubmit`,
  `stop`, `agentResponse` (carries the final reply text; currently only
  Cursor's `afterAgentResponse`), and `preCompact`; the client maps them to
  its own names, and events a client doesn't support are skipped. The command
  is an array of arguments, quoted per platform and joined into one command
  line: POSIX shell quoting on macOS and Linux, double quotes on Windows,
  except Codex on Windows, which runs hooks in PowerShell and gets
  `& 'C:\path\program.exe' 'an argument' --flag` (single-quoted literals,
  `''` for a quote inside). Each command must contain one of the strings in
  `markers`, which the component uses to recognize, update, and remove this
  product's hook — so an old entry installed manually or by an AI can also be
  taken over.
- **Instructions**: the default marker is
  `<!-- BEGIN <PRODUCT> MANAGED INSTRUCTIONS -->`; `begin` and `end` can be
  set to reuse a product's existing markers.
- **Skills / plugins**: the whole directory is copied, and a receipt file
  `.agent-installer.json` is written into the target directory. A
  same-named directory that doesn't belong to this product is never
  overwritten; a directory the user has modified is kept as-is and reported.
  A directory without a receipt is adopted (only the receipt is written; the
  change's action is `adopt`) when its files already equal the product's.
  With `"adopt": { "file": "SKILL.md", "contains": "name: acme-helper" }` a
  directory holding that marker is taken over and replaced as well. A
  directory with another product's receipt is never adopted.
- **Per-client overrides**: `clients.<id>` is merged recursively with the
  components above; `null` means this client does not get that component.

## Install targets

A local private Agent can be plugged in just by adding an `install` section
to its extension file; see the fields in
[extension.schema.json](https://github.com/JevonsCode/agent-session-launcher/blob/main/docs/extension.schema.json):

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

- A path can only start with `~/`, `{home}` (the environment variable named
  by `home.env`, or `home.default`), `{configHome}`, or `{appData}`, and must
  not contain `..`.
- The write format must be one of the built-in formats: for MCP,
  `claude-json`, `mcp-servers-json`, `kiro-json`, `opencode-json`,
  `codex-toml`; for hooks, `claude-hooks`, `codex-hooks`, `cursor-hooks`.
- When the file name uses a built-in ID (e.g. `cursor.json`), the keys listed
  under `install` replace the built-in values; the rest are kept.
- A file whose only field is `install` never becomes a client of the session
  launcher component. An extension file with an error only skips itself; the
  reason is in `extensionErrors`.

## Write safety

- Only this product's own entries are modified: MCP by name, hooks by
  marker, instructions by begin/end marker, directories by receipt; other
  content, order, and comments are left unchanged (JSON supports comments and
  trailing commas; TOML is edited table by table).
- A file is not written if it is already up to date; an update replaces the
  entry in place rather than moving it to the end of the file.
- Writes are atomic: a temp file is written in the same directory and then
  swapped in, the original file's permissions are kept, and a new file is
  created with mode 0600; a symlink stays a symlink, and the write goes to
  the file it points to.
- If the client changes the file between the read and the write (Claude Code
  frequently rewrites `~/.claude.json`), the component re-applies its edit
  against the new content, retrying up to 3 times, and never overwrites the
  client's own change.
- After removal, a file that is left with only `{}` is deleted; the same
  applies to an instructions file that removal created.
- The client's trust store is never modified. After Codex gets a new or
  changed hook, the user must confirm trust in Codex with `/hooks`.

## Installing via AI

An AI can use the CLI directly: run `scan --json` and `status --json` first
to see the current state, then `plan` for the clients the user picked, show
the user the diff for confirmation, and then `apply`. For an Agent it
doesn't recognize, the AI writes an `install` section in an extension file
from that Agent's own documentation, then runs `plan` to check it. An install
done this way can still be queried for status, updated, and removed.
