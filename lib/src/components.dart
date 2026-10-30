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
  DirectoryPart(this.component, this.source, this.target);
  final String component;
  final String source;
  final String target;
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
        work.text.add(
          _mcpPart(
            present.isEmpty ? candidates.first : present.single,
            file.format,
            mcp,
          ),
        );
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
        ),
      );
    }
  }

  directories('skills', target.skillsDir, product.skills);
  directories('plugin', target.pluginsDir, <DirectorySpec>[?product.plugin]);
  return work;
}

TextPart _mcpPart(String file, String format, McpSpec mcp) {
  if (format == 'codex-toml') {
    final Map<String, Object?> entry = <String, Object?>{
      'command': mcp.command,
      'args': mcp.args,
      if (mcp.env.isNotEmpty) 'env': mcp.env,
      ...mcp.extra,
    };
    return TextPart(
      'mcp',
      file,
      (t) => CodexToml.setServer(t, mcp.name, entry),
      (t) => CodexToml.removeServer(t, mcp.name),
      (t) => CodexToml.hasServer(t, mcp.name),
    );
  }
  final List<String> key = <String>[
    format == 'opencode-json' ? 'mcp' : 'mcpServers',
    mcp.name,
  ];
  final Map<String, Object?> ours = switch (format) {
    'opencode-json' => <String, Object?>{
      'type': 'local',
      'command': <String>[mcp.command, ...mcp.args],
      'enabled': true,
      if (mcp.env.isNotEmpty) 'environment': mcp.env,
    },
    'claude-json' => <String, Object?>{
      'type': 'stdio',
      'command': mcp.command,
      'args': mcp.args,
      if (mcp.env.isNotEmpty) 'env': mcp.env,
    },
    'kiro-json' => <String, Object?>{
      'command': mcp.command,
      'args': mcp.args,
      if (mcp.env.isNotEmpty) 'env': mcp.env,
      'disabled': false,
    },
    _ => <String, Object?>{
      'command': mcp.command,
      'args': mcp.args,
      if (mcp.env.isNotEmpty) 'env': mcp.env,
    },
  }..addAll(mcp.extra);
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
        ...ours,
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
  Map<String, Object?> handler(HookSpec h) => <String, Object?>{
    if (!cursor) 'type': 'command',
    'command': shellCommand(h.command, windows: env.windows),
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
      // The person keeps hooks in config.toml, so FULI's rule applies: write
      // there and only clean hooks.json, unless both hold unrelated hooks.
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
            (t) => CodexToml.setHooks(t, groups, product.isOurHook),
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
      (t) => _jsonHooks(t, desired, product, cursor: cursor),
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
    if (deepEquals(groups, next)) continue;
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
