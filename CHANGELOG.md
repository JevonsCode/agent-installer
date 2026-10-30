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
