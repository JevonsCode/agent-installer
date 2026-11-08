# Changelog

## 0.4.1 (2026-11-08)

### Changed

- A person's prompt file with the name of one of the product's prompts (on
  a case-insensitive disk, also one differing only in case) no longer makes
  the whole `prompts` component a conflict: that one prompt is skipped and
  the file kept, and the others are written. A roster of names can meet a
  person's own prompt; one clash must not stop the client's status,
  install or repair.

## 0.4.0 (2026-11-08)

### Added

- `prompts` component: a product lists prompt files (`name`, `description`,
  `body`), written as `<name>.md` with a front matter that names the
  product (`installed-by`). Apply removes the product's files it no longer
  lists and leaves them alone when the manifest has no `prompts`; remove
  deletes all of the product's and nothing else; a person's file of the same name
  is a conflict and stays. Built-in `codex` keeps them in
  `{CODEX_HOME}/prompts`, which the Codex app lists in its / menu as
  `prompts:<name>`. Extension targets name the folder with
  `"prompts": { "dir": … }`.

## 0.3.1 (2026-11-02)

### Fixed

- Blank lines or spaces at the end of a file are no change: `status` reads
  such a file as current, and `plan` and `apply` leave it alone. A Codex
  `config.toml` that ended with a blank line after the product's tables read
  as `outdated` for MCP and hooks forever, because every write ends the file
  with exactly one newline.

## 0.3.0 (2026-11-01)

### Added

- Built-in `antigravity` client (Google Antigravity and its `agy` CLI): MCP
  in `~/.gemini/config/mcp_config.json`, detected by `agy` on PATH, that file,
  `~/.gemini/antigravity` or `~/.gemini/antigravity-cli`.
- `status` lists each component's `paths` (relative to home), so a host can
  show where to make a change by hand, for built-in and extension clients.

### Changed

- A command MCP entry that carries `"type": "stdio"` (the generic snippet
  many products hand out) keeps it and reads as current instead of outdated.

## 0.2.1 (2026-11-01)

### Changed

- A hook command that parses to the same arguments as the desired one is
  current and keeps its existing text, whatever its quoting (PowerShell call
  operator for Codex on Windows, cmd double quotes for the other clients on
  Windows, POSIX literals elsewhere); `apply` no longer rewrites it, so a
  client that asks the person to re-trust changed hooks is not asked again for
  a quoting difference. Commands that cannot be parsed with confidence still
  compare as text.
- Managed instruction blocks follow the existing file's line endings and
  compare equally across LF and CRLF.

## 0.2.0 (2026-10-30)

### Breaking

- The shared extensions directory and the default backups moved to the
  neutral `agent-clients` root that agent-session-launcher also uses:
  `%APPDATA%\agent-clients` on Windows, `$XDG_CONFIG_HOME/agent-clients` when
  that is an absolute path, else `~/.config/agent-clients` (macOS included,
  as before). Extensions are read from `extensions/`, and the CLI's default
  `--backups` is `backups/<product>` there (it used to be
  `agent-session-launcher/backups/<product>`).
  - While `agent-clients/extensions` does not exist,
    `defaultExtensionsDirectory()` returns the 0.1 directory
    `agent-session-launcher/clients` under the same base, so existing files
    keep working.
  - Files are never moved automatically. To move, create
    `agent-clients/extensions` and move your `.json` files into it; once it
    exists the old directory is no longer read. Old backups can be deleted
    by hand.
  - New: `defaultSharedDirectory()` and `defaultBackupsDirectory(product)`.

### Changed

- Code and the README no longer describe rules of particular host products.
  A short, neutral [Integrating a host](docs/integrating-a-host.md) guide
  covers the host flow with generic examples.
- Codex on Windows runs lifecycle hooks in PowerShell, so its hook commands
  are now written in PowerShell syntax there:
  `& 'C:\path\node.exe' 'C:\path with spaces\hook.js' --flag`, with every
  argument that is not plain written as a single-quoted literal (`''` for a
  quote inside). Other clients and platforms are unchanged. An existing
  Codex hook carrying the product's marker is rewritten on the next `apply`.
- New manifest field `mcp.preserveArgs`: options such as `--tool-profile`
  whose value the person chose in the product's existing entry are kept on
  update (Codex TOML, JSON `args` and OpenCode `command` alike), replacing
  the manifest's value or appended when the manifest has none.
- Skill and plugin directories without an `.agent-installer.json` receipt
  are adopted instead of reported as `conflict` when their files already
  equal the product's (the plan shows the new change action `adopt`, and
  only the receipt is written), or when the manifest's new
  `adopt: { file, contains? }` marker is found in them (then they are
  replaced). A directory carrying another product's receipt is never
  adopted; anything else stays a `conflict`.
- Skill and plugin directories are now backed up before they are replaced
  or removed, as `<backups>/<client-id>/<name>.<UTC time>.bak/`, with the
  same retention as file backups (the 5 most recent per name). Retention now
  matches only the installer's own `<name>.<time>.bak` entries.
- Windows: when a skill or plugin directory cannot be renamed because the
  client holds it open (sharing, lock or access violation), its files are
  updated in place, the receipt last, and the change reports it in the new
  `note` field. Other failures leave the directory as it was and are
  reported under `problems` instead of aborting the run.
- Each client result has `actionCodes`, one stable code per entry of
  `actions` (`restart_client`, `new_session`, `reload_config`,
  `trust_hooks`, `other`), so hosts can localize. The CLI output is
  described in the new `docs/result.schema.json`. An extension file's
  `afterInstall` accepts `{ "code", "message" }` objects besides plain text
  (code `other`); `InstallTarget.afterInstall` is now a list of
  `AfterInstallAction` records.
- Node binding: the spawn, timeout and parse logic is one `runNative`
  helper shaped like the one in agent-session-launcher's binding.
  - Breaking: `plan`, `apply` and `remove` resolve with
    `{ clients, partial, problems, extensionErrors }` instead of the bare
    client list. `partial: true` marks a run that finished with exit code 2;
    `problems` lists `{ client, message }`.
  - Every failure now rejects asynchronously with an `Error` carrying
    `code`; `createInstaller` no longer throws for a relative path.
  - `timeoutMs` (default 60000, at most 600000) is validated
    (`invalid_timeout`); `unknown_outcome` is never retried automatically.
  - New exports: `defaultExtensionsDirectory()` and
    `defaultBackupsDirectory(product)`.
