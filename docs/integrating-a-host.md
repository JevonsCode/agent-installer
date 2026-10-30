# Integrating a host

A host is any application that wants its integration (an MCP server, hooks,
instructions, skills, a plugin, permissions) in the Agent clients a person
uses. It does four things:

1. **Describe the product**: ship a [product manifest](manifest.schema.json)
   with the application and pass the values it cannot know in advance (the
   path of its own MCP executable, the bundle directory) as variables.
2. **Show the clients**: call `scan` and `status` for a settings screen. Use
   `detected` and `evidence` only as hints; a person may set up a client they
   have not run yet.
3. **Preview, then write**: call `plan` for the clients the person picked,
   show the diffs, and call `apply` (or `remove`) only after they confirm.
4. **Tell the person what is left**: show each client's `actions` (for
   example "restart the client") and `problems` (components that were left
   alone, with the reason).

The host stays responsible for asking the person, for any account or trust
step inside a client, and for deciding when to offer an update; the
installer never edits a client's trust store.

## Dart / Flutter host

In-process, no native executable needed. Pin the dependency to a commit or tag:

```yaml
dependencies:
  agent_installer:
    git:
      url: https://github.com/JevonsCode/agent-installer.git
      ref: <commit-or-tag>
```

```dart
import 'package:agent_installer/agent_installer.dart';

final AgentInstaller installer = AgentInstaller(
  product: ProductManifest.decode(
    manifestText,
    variables: <String, String>{'exampleMcp': mcpPath, 'bundle': bundlePath},
  ),
  targets: InstallTargets.load(
    extensionsDirectory: defaultExtensionsDirectory(),
  ),
  backupDirectory: defaultBackupsDirectory('example'),
);
final List<ClientStatus> states = installer.status();
final List<ClientResult> preview = installer.plan(<String>['claude-code']);
// After the person confirms:
final List<ClientResult> results = installer.apply(<String>['claude-code']);
```

## Node.js host

The binding is a dependency-free ES module (not yet on npm): copy
`bindings/node/` or add the repository as a submodule. Ship a native
executable built for each OS and CPU (see the README's download table).

```javascript
import { createInstaller, defaultExtensionsDirectory } from './vendor/agent-installer/index.mjs';

const installer = createInstaller({
  executable: '/absolute/path/to/agent-installer',
  manifestPath: '/absolute/path/to/example.manifest.json',
  variables: { exampleMcp: '/absolute/path/to/example-mcp', bundle: '/absolute/path/to/bundle' },
  extensionsDir: defaultExtensionsDirectory(), // optional; this is the default
});

const { clients } = await installer.status();
const preview = await installer.plan(['claude-code']);
const result = await installer.apply(['claude-code']); // after the person confirms
```

Every failure rejects with an `Error` whose `code` is the installer or
binding error code.

## Taking over an earlier setup

A host that already wrote its integration by hand, or with its own script,
can let the installer take that setup over instead of reporting a conflict:

- **MCP**: give `mcp.markers` text that appears in the old entry's command or
  arguments (for example the executable's name). A same-name entry with a
  marker is updated in place; one without is never touched.
- **Hooks**: `hooks.markers` works the same way for hook commands.
- **Instructions**: set `instructions.begin` and `instructions.end` to the
  markers the old block used.

Map the host's own client names to the installer's IDs once (for example a
host's `claude` setting becomes `claude-code`, `claude-desktop`, or both).

## Acceptance

Verify each host separately: `plan` shows the diff you expect for every
client you support, `apply` followed by `status` reports `connected`, and the
client really loads the MCP server, hooks and skills after the actions shown.
`remove` must leave the person's own entries as they were.
