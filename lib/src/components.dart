import 'dart:convert';
import 'dart:io';

import 'environment.dart';
import 'json_edit.dart';
import 'manifest.dart';
import 'targets.dart';
import 'text_edit.dart';

/// An edit of one text file for one component. [install] and [uninstall]
/// return the new text, or null to delete the file; they throw
/// [FormatException] when the file cannot be safely edited.
final class TextPart {
  TextPart(
    this.component,
    this.path,
    this.install,
    this.uninstall,
    this.present,
  );
  final String component;
  final String path;
  final String? Function(String? text) install;
  final String? Function(String? text) uninstall;

  /// Whether the file already holds this product's entry.
  final bool Function(String? text) present;
}

/// A directory the product owns, such as a skill.
final class DirectoryPart {
  DirectoryPart(this.component, this.source, this.target, [this.adopt]);
  final String component;
  final String source;
  final String target;
  final AdoptMarker? adopt;
}

/// Everything one client needs for one product.
final class ClientWork {
  final List<TextPart> text = <TextPart>[];
  final List<DirectoryPart> directories = <DirectoryPart>[];

  /// Components the client cannot accept, with the reason.
  final Map<String, String> blocked = <String, String>{};

  /// Components the product wants but the client does not offer.
  final Set<String> unsupported = <String>{};
}

/// Plans the parts for [product] in [target]; reads files only to choose
/// between alternative locations.
ClientWork buildWork(
  InstallTarget target,
  ResolvedProduct product,
  InstallEnvironment env,
) {
  final ClientWork work = ClientWork();
  String path(String template) => target.resolve(env, template);
  bool exists(String p) =>
      FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound;

  final McpSpec? mcp = product.mcp;
  if (mcp != null) {
    final TargetFile? file = target.mcp;
    if (file == null) {
      work.unsupported.add('mcp');
    } else {
      final List<String> candidates = file.files.map(path).toList();
      final List<String> present = candidates.where(exists).toList();
      if (present.length > 1) {
        work.blocked['mcp'] =
            'Both ${present.map(env.display).join(' and ')} exist; configure '
            '${target.name} by hand.';
      } else {
        final String chosen = present.isEmpty
            ? candidates.first
            : present.single;
        final String? existing = _existingMcp(chosen, file.format, mcp.name);
        if (existing != null && !mcp.isOurs(existing)) {
          // Same name, someone else's server: never replace or remove it.
          work.blocked['mcp'] =
              'Another MCP server is already named "${mcp.name}" in '
              '${env.display(chosen)}; rename or remove it first.';
        } else {
          work.text.add(_mcpPart(chosen, file.format, mcp));
        }
      }
    }
  }

  if (product.hooks.isNotEmpty) {
    final TargetFile? hooks = target.hooks;
    final List<HookSpec> supported = product.hooks
        .where((h) => target.hookEvents.containsKey(h.event))
        .toList();
    if (hooks == null || supported.isEmpty) {
      work.unsupported.add('hooks');
    } else if (env.windows &&
        supported.any((h) => h.command.any((a) => a.contains('"')))) {
      work.blocked['hooks'] = 'A hook argument contains a double quote.';
    } else {
      _hookParts(
        work,
        target,
        product,
        supported,
        hooks,
        path(hooks.files.single),
        env,
      );
    }
  }

  if (product.permissions.isNotEmpty) {
    if (target.permissionsFile == null) {
      work.unsupported.add('permissions');
    } else {
      work.text.add(
        _permissionsPart(path(target.permissionsFile!), product.permissions),
      );
    }
  }

  final String? markdown = product.instructions;
  if (markdown != null) {
    if (target.instructionsFile == null) {
      work.unsupported.add('instructions');
    } else {
      final String main = path(target.instructionsFile!);
      final String? override = target.instructionsOverrideFile == null
          ? null
          : path(target.instructionsOverrideFile!);
      // Codex reads AGENTS.override.md instead of AGENTS.md when it has text.
      final bool useOverride =
          override != null &&
          File(override).existsSync() &&
          File(override).readAsStringSync().trim().isNotEmpty;
      final String active = useOverride ? override : main;
      final String begin = product.instructionsBegin;
      final String end = product.instructionsEnd;
      work.text.add(
        TextPart(
          'instructions',
          active,
          (t) => MarkdownBlock.set(t, begin, end, markdown),
          (t) => MarkdownBlock.remove(t, begin, end),
          (t) => MarkdownBlock.has(t, begin, end),
        ),
      );
      final String? inactive = useOverride ? main : override;
      if (inactive != null) {
        String? clean(String? t) => MarkdownBlock.remove(t, begin, end);
        work.text.add(
          TextPart('instructions', inactive, clean, clean, (t) => false),
        );
      }
    }
  }

  void directories(String component, String? dir, List<DirectorySpec> specs) {
    if (specs.isEmpty) return;
    if (dir == null) {
      work.unsupported.add(component);
      return;
    }
    for (final DirectorySpec spec in specs) {
      work.directories.add(
        DirectoryPart(
          component,
          spec.source,
          '${path(dir)}${env.separator}${spec.name}',
          spec.adopt,
        ),
      );
    }
  }

  directories('skills', target.skillsDir, product.skills);
  directories('plugin', target.pluginsDir, <DirectorySpec>[?product.plugin]);
  return work;
}

/// The existing entry named [name] as text, or null when there is none or
/// the file cannot be read; the text part reports unreadable files.
String? _existingMcp(String path, String format, String name) {
  final File file = File(path);
  if (!file.existsSync()) return null;
  try {
    final String text = file.readAsStringSync();
    if (format == 'codex-toml') return CodexToml.serverText(text, name);
    final Object? servers = _root(
      text,
    )[format == 'opencode-json' ? 'mcp' : 'mcpServers'];
    final Object? entry = servers is Map ? servers[name] : null;
    return entry == null ? null : jsonEncode(entry);
  } on Object {
    return null;
  }
}

TextPart _mcpPart(String file, String format, McpSpec mcp) {
  // The person's value of a preserved option survives an update.
  List<String> args(List<String>? existing) =>
      keepOptions(mcp.args, existing, mcp.preserveArgs);
  if (format == 'codex-toml') {
    Map<String, Object?> entry(String? t) => <String, Object?>{
      'command': mcp.command,
      'args': args(CodexToml.serverArgs(t, mcp.name)),
      if (mcp.env.isNotEmpty) 'env': mcp.env,
      ...mcp.extra,
    };
    return TextPart(
      'mcp',
      file,
      (t) => CodexToml.setServer(t, mcp.name, entry(t)),
      (t) => CodexToml.removeServer(t, mcp.name),
      (t) => CodexToml.hasServer(t, mcp.name),
    );
  }
  final List<String> key = <String>[
    format == 'opencode-json' ? 'mcp' : 'mcpServers',
    mcp.name,
  ];
  Map<String, Object?> ours(Object? existing) {
    List<String>? strings(Object? value) =>
        value is List && value.every((v) => v is String)
        ? value.cast<String>()
        : null;
    final Map<Object?, Object?>? old = existing is Map ? existing : null;
    if (format == 'opencode-json') {
      final List<String>? command = strings(old?['command']);
      return <String, Object?>{
        'type': 'local',
        'command': <String>[
          mcp.command,
          ...args(
            command == null || command.isEmpty
                ? null
                : command.skip(1).toList(),
          ),
        ],
        'enabled': true,
        if (mcp.env.isNotEmpty) 'environment': mcp.env,
        ...mcp.extra,
      };
    }
    final List<String> merged = args(strings(old?['args']));
    return <String, Object?>{
      if (format == 'claude-json') 'type': 'stdio',
      'command': mcp.command,
      'args': merged,
      if (mcp.env.isNotEmpty) 'env': mcp.env,
      if (format == 'kiro-json') 'disabled': false,
      ...mcp.extra,
    };
  }

  Object? current(String? t) {
    final Object? servers = _root(t)[key.first];
    if (servers != null && servers is! Map) {
      throw FormatException('"${key.first}" must be an object.');
    }
    return (servers as Map?)?[mcp.name];
  }

  return TextPart(
    'mcp',
    file,
    (t) {
      final Object? existing = current(t);
      // Keep fields the person added, minus transport fields that conflict.
      final Map<String, Object?> desired = <String, Object?>{
        if (existing is Map<String, Object?>)
          for (final MapEntry<String, Object?> e in existing.entries)
            if (!_transportKeys.contains(e.key)) e.key: e.value,
        ...ours(existing),
      };
      return deepEquals(existing, desired) ? t : JsonEdit.set(t, key, desired);
    },
    (t) {
      if (current(t) == null) return t;
      final String? without = JsonEdit.remove(t, key);
      // Drop a server map left empty, so a file created by install goes too.
      final Object? servers = _root(without)[key.first];
      return servers is Map && servers.isEmpty
          ? JsonEdit.remove(without, <String>[key.first])
          : without;
    },
    (t) => current(t) != null,
  );
}

/// [desired] with the value [existing] gives each option in [names], as
/// `--name value` or `--name=value`: replaced where [desired] has the option,
/// appended where it does not. A value starting with `-` is not taken.
List<String> keepOptions(
  List<String> desired,
  List<String>? existing,
  List<String> names,
) {
  if (existing == null || names.isEmpty) return desired;
  final List<String> result = <String>[...desired];
  for (final String name in names) {
    final (int, int)? theirs = _optionAt(existing, name);
    if (theirs == null) continue;
    final List<String> kept = existing.sublist(
      theirs.$1,
      theirs.$1 + theirs.$2,
    );
    final (int, int)? mine = _optionAt(result, name);
    if (mine == null) {
      result.addAll(kept);
    } else {
      result.replaceRange(mine.$1, mine.$1 + mine.$2, kept);
    }
  }
  return result;
}

/// Where option [name] starts in [args] and how many arguments it spans.
(int, int)? _optionAt(List<String> args, String name) {
  for (int i = 0; i < args.length; i++) {
    if (args[i].startsWith('$name=')) return (i, 1);
    if (args[i] == name) {
      return (i, i + 1 < args.length && !args[i + 1].startsWith('-') ? 2 : 1);
    }
  }
  return null;
}

const Set<String> _transportKeys = <String>{
  'url',
  'httpUrl',
  'headers',
  'oauth',
  'type',
};

void _hookParts(
  ClientWork work,
  InstallTarget target,
  ResolvedProduct product,
  List<HookSpec> hooks,
  TargetFile file,
  String jsonPath,
  InstallEnvironment env,
) {
  final bool cursor = file.format == 'cursor-hooks';
  // Codex runs hook commands with PowerShell on Windows.
  final bool powerShell = env.windows && file.format == 'codex-hooks';
  Map<String, Object?> handler(HookSpec h) => <String, Object?>{
    if (!cursor) 'type': 'command',
    'command': powerShell
        ? powerShellCommand(h.command)
        : shellCommand(h.command, windows: env.windows),
    if (h.timeoutSec != null) 'timeout': h.timeoutSec,
    if (h.statusMessage != null && file.format == 'claude-hooks')
      'statusMessage': h.statusMessage,
    ...h.extra,
  };
  final Map<String, List<Object?>> desired = <String, List<Object?>>{};
  for (final HookSpec h in hooks) {
    (desired[target.hookEvents[h.event]!] ??= <Object?>[]).add(
      cursor
          ? handler(h)
          : <String, Object?>{
              if (h.matcher != null) 'matcher': h.matcher,
              'hooks': <Object?>[handler(h)],
            },
    );
  }

  if (file.format == 'codex-hooks' && target.hooksTomlFile != null) {
    final String toml = target.resolve(env, target.hooksTomlFile!);
    final File tomlFile = File(toml);
    final String? tomlText = tomlFile.existsSync()
        ? tomlFile.readAsStringSync()
        : null;
    if (CodexToml.hasHookTables(tomlText)) {
      // The person keeps hooks in config.toml: write there and only clean
      // hooks.json, unless both files hold unrelated hooks.
      final File json = File(jsonPath);
      if (json.existsSync() &&
          _hasForeignJsonHooks(json.readAsStringSync(), product)) {
        work.blocked['hooks'] =
            'Codex has hooks in both config.toml and hooks.json; move them '
            'into one file first.';
        return;
      }
      final List<TomlHookGroup> groups = <TomlHookGroup>[
        for (final HookSpec h in hooks)
          (
            event: target.hookEvents[h.event]!,
            matcher: h.matcher,
            handler: handler(h),
          ),
      ];
      work.text
        ..add(
          TextPart(
            'hooks',
            toml,
            (t) => CodexToml.setHooks(
              t,
              groups,
              product.isOurHook,
              commandsEqual: (a, b) => hookCommandsEqual(
                a,
                b,
                windows: env.windows,
                powerShell: powerShell,
              ),
            ),
            (t) => CodexToml.setHooks(
              t,
              const <TomlHookGroup>[],
              product.isOurHook,
            ),
            (t) => CodexToml.hasHooks(t, product.isOurHook),
          ),
        )
        ..add(
          TextPart(
            'hooks',
            jsonPath,
            (t) => _jsonHooks(
              t,
              const <String, List<Object?>>{},
              product,
              cursor: false,
            ),
            (t) => _jsonHooks(
              t,
              const <String, List<Object?>>{},
              product,
              cursor: false,
            ),
            (t) => _hasJsonHooks(t, product, cursor: false),
          ),
        );
      return;
    }
  }
  work.text.add(
    TextPart(
      'hooks',
      jsonPath,
      (t) => _jsonHooks(
        t,
        desired,
        product,
        cursor: cursor,
        windows: env.windows,
        powerShell: powerShell,
      ),
      (t) => _jsonHooks(
        t,
        const <String, List<Object?>>{},
        product,
        cursor: cursor,
      ),
      (t) => _hasJsonHooks(t, product, cursor: cursor),
    ),
  );
}

/// Removes the product's handlers from every event and places [desired]
/// where the product's first handler of that event was.
String? _jsonHooks(
  String? text,
  Map<String, List<Object?>> desired,
  ResolvedProduct product, {
  required bool cursor,
  bool windows = false,
  bool powerShell = false,
}) {
  final Map<String, Object?> root = _root(text);
  if (cursor && root['version'] != null && root['version'] != 1) {
    throw const FormatException('Unsupported Cursor hooks version.');
  }
  final Map<String, Object?> hooks = _map(root['hooks'], '"hooks"');
  String? result = text;
  bool changed = false;
  for (final String event in <String>{...hooks.keys, ...desired.keys}) {
    final List<Object?> groups = _list(hooks[event], '"hooks.$event"');
    final List<Object?> kept = <Object?>[];
    int? at;
    for (final Object? group in groups) {
      final List<Object?> handlers = cursor
          ? <Object?>[group]
          : _list(_map(group, 'a hook group')['hooks'], 'a hook group');
      final List<Object?> others = handlers
          .where((h) => !_isOurs(h, product))
          .toList();
      if (others.length == handlers.length) {
        kept.add(group);
        continue;
      }
      at ??= kept.length;
      if (!cursor && others.isNotEmpty) {
        kept.add(<String, Object?>{
          ...group! as Map<String, Object?>,
          'hooks': others,
        });
      }
    }
    final List<Object?> next = <Object?>[...kept]
      ..insertAll(at ?? kept.length, desired[event] ?? const <Object?>[]);
    _preserveHookCommands(
      groups,
      next,
      product,
      cursor: cursor,
      windows: windows,
      powerShell: powerShell,
    );
    if (_hookGroupsEqual(
      groups,
      next,
      cursor: cursor,
      windows: windows,
      powerShell: powerShell,
    )) {
      continue;
    }
    changed = true;
    result = next.isEmpty
        ? JsonEdit.remove(result, <String>['hooks', event])
        : JsonEdit.set(result, <String>['hooks', event], next);
  }
  if (!changed) return text;
  final Map<String, Object?> after = _root(result);
  if (after['hooks'] is Map && (after['hooks']! as Map).isEmpty) {
    result = JsonEdit.remove(result, const <String>['hooks']);
    // A Cursor file that held only these hooks keeps no stray version.
    if (cursor && after.length == 2 && after['version'] == 1) {
      result = JsonEdit.remove(result, const <String>['version']);
    }
  } else if (cursor && after['version'] == null && desired.isNotEmpty) {
    result = JsonEdit.set(result, const <String>['version'], 1);
  }
  return result;
}

bool _hasJsonHooks(
  String? text,
  ResolvedProduct product, {
  required bool cursor,
}) {
  final Map<String, Object?> hooks = _map(_root(text)['hooks'], '"hooks"');
  return hooks.values.any(
    (groups) => _list(groups, 'hooks').any(
      (g) => cursor
          ? _isOurs(g, product)
          : _list(
              _map(g, 'a hook group')['hooks'],
              'a hook group',
            ).any((h) => _isOurs(h, product)),
    ),
  );
}

bool _hasForeignJsonHooks(String text, ResolvedProduct product) {
  final Map<String, Object?> hooks = _map(_root(text)['hooks'], '"hooks"');
  return hooks.values.any(
    (groups) => _list(groups, 'hooks').any(
      (g) => _list(
        _map(g, 'a hook group')['hooks'],
        'a hook group',
      ).any((h) => !_isOurs(h, product)),
    ),
  );
}

bool _isOurs(Object? handler, ResolvedProduct product) {
  final Object? command = handler is Map ? handler['command'] : null;
  return command is String && product.isOurHook(command);
}

TextPart _permissionsPart(String file, List<String> rules) {
  List<Object?> allow(String? t) {
    final Map<String, Object?> permissions = _map(
      _root(t)['permissions'],
      '"permissions"',
    );
    final List<Object?> list = _list(
      permissions['allow'],
      '"permissions.allow"',
    );
    if (list.any((r) => r is! String)) {
      throw const FormatException('"permissions.allow" must list text.');
    }
    return list;
  }

  return TextPart(
    'permissions',
    file,
    (t) {
      final List<Object?> current = allow(t);
      final List<String> missing = rules
          .where((r) => !current.contains(r))
          .toList();
      return missing.isEmpty
          ? t
          : JsonEdit.set(
              t,
              const <String>['permissions', 'allow'],
              <Object?>[...current, ...missing],
            );
    },
    (t) {
      final List<Object?> current = allow(t);
      final List<Object?> kept = current
          .where((r) => !rules.contains(r))
          .toList();
      if (kept.length == current.length) return t;
      if (kept.isNotEmpty) {
        return JsonEdit.set(t, const <String>['permissions', 'allow'], kept);
      }
      final String? without = JsonEdit.remove(t, const <String>[
        'permissions',
        'allow',
      ]);
      return _map(_root(without)['permissions'], '"permissions"').isEmpty
          ? JsonEdit.remove(without, const <String>['permissions'])
          : without;
    },
    (t) => allow(t).any(rules.contains),
  );
}

/// Compares literal commands only. Shell expressions fall back to text equality.
bool hookCommandsEqual(
  String a,
  String b, {
  required bool windows,
  required bool powerShell,
}) {
  if (a == b) return true;
  final List<String>? left = _parseCommand(a, windows, powerShell);
  final List<String>? right = _parseCommand(b, windows, powerShell);
  return left != null && right != null && deepEquals(left, right);
}

List<String>? _parseCommand(String text, bool windows, bool powerShell) {
  int i = 0;
  if (powerShell) {
    if (text.length < 2 ||
        text[0] != '&' ||
        (text[1] != ' ' && text[1] != '\t'))
      return null;
    i = 1;
  }
  final List<String> args = <String>[];
  while (i < text.length) {
    while (i < text.length && (text[i] == ' ' || text[i] == '\t')) {
      i++;
    }
    if (i == text.length) break;
    final StringBuffer arg = StringBuffer();
    bool started = false;
    bool quoted = false;
    while (i < text.length && text[i] != ' ' && text[i] != '\t') {
      final String c = text[i];
      if (c == "'" && (!windows || powerShell)) {
        if (powerShell && started) return null;
        started = true;
        quoted = true;
        i++;
        bool closed = false;
        while (i < text.length) {
          if (text[i] == "'") {
            if (powerShell && i + 1 < text.length && text[i + 1] == "'") {
              arg.write("'");
              i += 2;
            } else {
              i++;
              closed = true;
              break;
            }
          } else {
            if (text[i] == '\n' || text[i] == '\r') return null;
            arg.write(text[i++]);
          }
        }
        if (!closed) return null;
      } else if (c == '"' && windows && !powerShell) {
        if (started) return null;
        started = true;
        quoted = true;
        i++;
        while (i < text.length && text[i] != '"') {
          if ('%!\r\n'.contains(text[i])) return null;
          arg.write(text[i++]);
        }
        if (i == text.length || (i > 0 && text[i - 1] == r'\')) return null;
        i++;
      } else if (c == r'\' && !windows && !powerShell) {
        started = true;
        i++;
        if (i == text.length || text[i] == '\n' || text[i] == '\r') {
          return null;
        }
        arg.write(text[i++]);
      } else {
        if (quoted && (windows || powerShell)) return null;
        final RegExp safe = powerShell ? _powerShellPlain : _plain;
        if (!safe.hasMatch(c) || (windows && c == '%')) return null;
        started = true;
        arg.write(c);
        i++;
      }
    }
    final String value = arg.toString();
    if (powerShell && ((!quoted && value == '--') || (args.isEmpty && !quoted)))
      return null;
    args.add(value);
  }
  return args.isEmpty ? null : args;
}

bool _hookGroupsEqual(
  List<Object?> a,
  List<Object?> b, {
  required bool cursor,
  required bool windows,
  required bool powerShell,
}) {
  bool handlerEquals(Object? x, Object? y) {
    if (x is! Map || y is! Map || x.length != y.length) {
      return deepEquals(x, y);
    }
    return x.keys.every((key) {
      if (!y.containsKey(key)) return false;
      if (key == 'command' && x[key] is String && y[key] is String) {
        return hookCommandsEqual(
          x[key] as String,
          y[key] as String,
          windows: windows,
          powerShell: powerShell,
        );
      }
      return deepEquals(x[key], y[key]);
    });
  }

  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (cursor) {
      if (!handlerEquals(a[i], b[i])) return false;
    } else {
      final Object? x = a[i];
      final Object? y = b[i];
      if (x is! Map || y is! Map || x.length != y.length) return false;
      for (final Object? key in x.keys) {
        if (!y.containsKey(key)) return false;
        if (key == 'hooks' && x[key] is List && y[key] is List) {
          final List left = x[key] as List;
          final List right = y[key] as List;
          if (left.length != right.length) return false;
          for (int j = 0; j < left.length; j++) {
            if (!handlerEquals(left[j], right[j])) return false;
          }
        } else if (!deepEquals(x[key], y[key])) {
          return false;
        }
      }
    }
  }
  return true;
}

void _preserveHookCommands(
  List<Object?> old,
  List<Object?> next,
  ResolvedProduct product, {
  required bool cursor,
  required bool windows,
  required bool powerShell,
}) {
  Object? preserve(Object? a, Object? b) {
    if (a is! Map || b is! Map || !_isOurs(a, product)) return b;
    final Object? previous = a['command'];
    final Object? desired = b['command'];
    if (previous is! String ||
        desired is! String ||
        !hookCommandsEqual(
          previous,
          desired,
          windows: windows,
          powerShell: powerShell,
        ))
      return b;
    return <String, Object?>{...b.cast<String, Object?>(), 'command': previous};
  }

  for (int i = 0; i < old.length && i < next.length; i++) {
    if (cursor) {
      next[i] = preserve(old[i], next[i]);
    } else {
      final Object? a = old[i];
      final Object? b = next[i];
      if (a is! Map ||
          b is! Map ||
          a['hooks'] is! List ||
          b['hooks'] is! List) {
        continue;
      }
      final List before = a['hooks'] as List;
      final List after = b['hooks'] as List;
      final List<Object?> copy = <Object?>[...after];
      for (int j = 0; j < before.length && j < copy.length; j++) {
        copy[j] = preserve(before[j], copy[j]);
      }
      next[i] = <String, Object?>{...b.cast<String, Object?>(), 'hooks': copy};
    }
  }
}

/// Joins a command for a shell, quoting arguments that need it.
String shellCommand(List<String> argv, {required bool windows}) => argv
    .map(
      (a) => _plain.hasMatch(a)
          ? a
          : windows
          ? '"$a"'
          : "'${a.replaceAll("'", r"'\''")}'",
    )
    .join(' ');

final RegExp _plain = RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$');

/// Joins a command for PowerShell: the program is invoked with `&`, and every
/// argument that is not plain becomes a single-quoted literal, in which
/// nothing is expanded.
String powerShellCommand(List<String> argv) => <String>[
  '&',
  _powerShellQuote(argv.first),
  for (final String a in argv.skip(1))
    a != '--' && _powerShellPlain.hasMatch(a) ? a : _powerShellQuote(a),
].join(' ');

String _powerShellQuote(String value) => "'${value.replaceAll("'", "''")}'";

// No @, %, +, = or comma: PowerShell gives them a meaning in arguments.
final RegExp _powerShellPlain = RegExp(r'^[A-Za-z0-9_:./\\-]+$');

Map<String, Object?> _root(String? text) {
  final Object? value = JsonEdit.decode(text);
  if (value is! Map<String, Object?>) {
    throw const FormatException('The file must hold a JSON object.');
  }
  return value;
}

Map<String, Object?> _map(Object? value, String what) {
  if (value == null) return const <String, Object?>{};
  if (value is! Map<String, Object?>)
    throw FormatException('$what must be an object.');
  return value;
}

List<Object?> _list(Object? value, String what) {
  if (value == null) return const <Object?>[];
  if (value is! List<Object?>) throw FormatException('$what must be a list.');
  return value;
}

/// Structural equality that ignores key order.
bool deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && deepEquals(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
