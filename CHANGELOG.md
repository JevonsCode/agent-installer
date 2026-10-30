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
