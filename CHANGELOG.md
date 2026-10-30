# Changelog

## 0.2.0 (unreleased)

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
