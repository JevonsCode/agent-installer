import 'dart:convert';

import 'errors.dart';
import 'targets.dart';

/// The MCP server a product registers.
final class McpSpec {
  const McpSpec(this.name, this.command, this.args, this.env, this.extra);
  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;

  /// Additional client-specific fields, e.g. Codex `startup_timeout_sec`.
  final Map<String, Object?> extra;
}

/// One lifecycle hook for a standard event.
final class HookSpec {
  const HookSpec(
    this.event,
    this.command,
    this.timeoutSec,
    this.statusMessage,
    this.matcher,
    this.extra,
  );
  final String event;

  /// Program and arguments; written as one quoted shell command.
  final List<String> command;
  final int? timeoutSec;
  final String? statusMessage;
  final String? matcher;
  final Map<String, Object?> extra;
}

/// A directory the product ships, e.g. a skill.
final class DirectorySpec {
  const DirectorySpec(this.name, this.source);
  final String name;
  final String source;
}

/// What a product installs into one client, after overrides and
/// placeholders are applied.
final class ResolvedProduct {
  const ResolvedProduct({
    required this.product,
    required this.version,
    this.mcp,
    this.hookMarkers = const <String>[],
    this.hooks = const <HookSpec>[],
    this.instructions,
    this.instructionsBegin = '',
    this.instructionsEnd = '',
    this.skills = const <DirectorySpec>[],
    this.plugin,
    this.permissions = const <String>[],
  });

  final String product;
  final String version;
  final McpSpec? mcp;

  /// Text in a hook command that identifies the product's own hooks.
  final List<String> hookMarkers;
  final List<HookSpec> hooks;
  final String? instructions;
  final String instructionsBegin;
  final String instructionsEnd;
  final List<DirectorySpec> skills;
  final DirectorySpec? plugin;
  final List<String> permissions;

  bool isOurHook(String command) => hookMarkers.any(command.contains);
}

/// A product's description of its agent integration, shipped with the
/// product and trusted. Strings in commands, environment values and sources
/// may use `{placeholders}` supplied by the host plus `{clientId}` and
/// `{clientName}`; `${...}` is left alone for the client to expand.
final class ProductManifest {
  ProductManifest._(
    this.product,
    this.name,
    this.version,
    this._base,
    this._clients,
    this._variables,
  );

  factory ProductManifest.decode(
    String text, {
    Map<String, String> variables = const <String, String>{},
  }) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      invalidManifest(r'$', 'the manifest is not valid JSON.');
    }
    return ProductManifest.fromJson(json, variables: variables);
  }

  factory ProductManifest.fromJson(
    Object? json, {
    Map<String, String> variables = const <String, String>{},
  }) {
    final Map<String, Object?> root = _object(json, r'$');
    _keys(root, <String>{
      r'$schema',
      'schemaVersion',
      'product',
      'name',
      'version',
      'clients',
      ..._components,
    }, r'$');
    if (root['schemaVersion'] != 1)
      invalidManifest(r'$.schemaVersion', 'must be 1.');
    final String product = _text(root['product'], r'$.product', 32);
    if (!RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(product)) {
      invalidManifest(
        r'$.product',
        'use lowercase letters, digits and hyphens.',
      );
    }
    final Map<String, Object?> base = <String, Object?>{
      for (final String key in _components)
        if (root.containsKey(key)) key: root[key],
    };
    final Map<String, Map<String, Object?>> clients =
        <String, Map<String, Object?>>{};
    if (root.containsKey('clients')) {
      for (final MapEntry<String, Object?> e in _object(
        root['clients'],
        r'$.clients',
      ).entries) {
        final Map<String, Object?> override = _object(
          e.value,
          '\$.clients.${e.key}',
        );
        _keys(override, _components, '\$.clients.${e.key}');
        clients[e.key] = override;
      }
    }
    final ProductManifest manifest = ProductManifest._(
      product,
      _text(root['name'], r'$.name', 64),
      _text(root['version'], r'$.version', 64),
      base,
      clients,
      variables,
    );
    // Validate every combination up front so a bad override fails early.
    manifest._resolve(null, 'client', 'Client', r'$');
    for (final String id in clients.keys) {
      manifest._resolve(id, id, id, '\$.clients.$id');
    }
    return manifest;
  }

  final String product;
  final String name;
  final String version;
  final Map<String, Object?> _base;
  final Map<String, Map<String, Object?>> _clients;
  final Map<String, String> _variables;

  ResolvedProduct forTarget(InstallTarget target) =>
      _resolve(target.id, target.id, target.name, '\$.clients.${target.id}');

  ResolvedProduct _resolve(
    String? id,
    String clientId,
    String clientName,
    String path,
  ) {
    final Map<String, Object?> json = id == null || !_clients.containsKey(id)
        ? _base
        : _merge(_base, _clients[id]!) as Map<String, Object?>;
    final Map<String, String> vars = <String, String>{
      ..._variables,
      'clientId': clientId,
      'clientName': clientName,
    };
    String sub(Object? value, String at, {int max = 4096}) =>
        _substitute(_text(value, at, max), vars, at);

    McpSpec? mcp;
    if (json['mcp'] != null) {
      final Map<String, Object?> m = _object(json['mcp'], '$path.mcp');
      _keys(m, const <String>{
        'name',
        'command',
        'args',
        'env',
        'extra',
      }, '$path.mcp');
      final String name = _text(m['name'], '$path.mcp.name', 64);
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) {
        invalidManifest('$path.mcp.name', 'use letters, digits, _ and -.');
      }
      mcp = McpSpec(
        name,
        sub(m['command'], '$path.mcp.command'),
        <String>[
          for (final (int i, Object? a) in _list(
            m['args'],
            '$path.mcp.args',
          ).indexed)
            sub(a, '$path.mcp.args[$i]'),
        ],
        <String, String>{
          for (final MapEntry<String, Object?> e
              in (m['env'] == null
                      ? const <String, Object?>{}
                      : _object(m['env'], '$path.mcp.env'))
                  .entries)
            e.key: sub(e.value, '$path.mcp.env.${e.key}'),
        },
        _extra(m['extra'], '$path.mcp.extra', vars),
      );
    }

    List<String> markers = const <String>[];
    final List<HookSpec> hooks = <HookSpec>[];
    if (json['hooks'] != null) {
      final Map<String, Object?> h = _object(json['hooks'], '$path.hooks');
      _keys(h, const <String>{'markers', 'events'}, '$path.hooks');
      markers = <String>[
        for (final (int i, Object? m) in _list(
          h['markers'],
          '$path.hooks.markers',
        ).indexed)
          _text(m, '$path.hooks.markers[$i]', 128),
      ];
      if (markers.isEmpty) {
        invalidManifest('$path.hooks.markers', 'needs at least one marker.');
      }
      for (final MapEntry<String, Object?> e in _object(
        h['events'],
        '$path.hooks.events',
      ).entries) {
        final String at = '$path.hooks.events.${e.key}';
        if (!hookEvents.contains(e.key)) {
          invalidManifest(at, 'use one of ${hookEvents.join(', ')}.');
        }
        if (e.value == null) continue;
        final Map<String, Object?> spec = _object(e.value, at);
        _keys(spec, const <String>{
          'command',
          'timeoutSec',
          'statusMessage',
          'matcher',
          'extra',
        }, at);
        final List<String> command = <String>[
          for (final (int i, Object? a) in _list(
            spec['command'],
            '$at.command',
          ).indexed)
            sub(a, '$at.command[$i]'),
        ];
        if (command.isEmpty) invalidManifest('$at.command', 'is empty.');
        if (!markers.any(command.join(' ').contains)) {
          invalidManifest(
            '$at.command',
            'must contain one of the hook markers.',
          );
        }
        final Object? timeout = spec['timeoutSec'];
        if (timeout != null &&
            (timeout is! int || timeout < 1 || timeout > 3600)) {
          invalidManifest('$at.timeoutSec', 'must be 1 to 3600 seconds.');
        }
        hooks.add(
          HookSpec(
            e.key,
            command,
            timeout as int?,
            spec['statusMessage'] == null
                ? null
                : _text(spec['statusMessage'], '$at.statusMessage', 200),
            spec['matcher'] == null
                ? null
                : _text(spec['matcher'], '$at.matcher', 200),
            _extra(spec['extra'], '$at.extra', vars),
          ),
        );
      }
    }

    String? instructions;
    String begin =
        '<!-- BEGIN ${product.toUpperCase()} MANAGED INSTRUCTIONS -->';
    String end = '<!-- END ${product.toUpperCase()} MANAGED INSTRUCTIONS -->';
    if (json['instructions'] != null) {
      final Map<String, Object?> i = _object(
        json['instructions'],
        '$path.instructions',
      );
      _keys(i, const <String>{
        'markdown',
        'begin',
        'end',
      }, '$path.instructions');
      instructions = _text(i['markdown'], '$path.instructions.markdown', 65536);
      if (i['begin'] != null)
        begin = _text(i['begin'], '$path.instructions.begin', 200);
      if (i['end'] != null)
        end = _text(i['end'], '$path.instructions.end', 200);
      if (begin == end || begin.contains('\n') || end.contains('\n')) {
        invalidManifest(
          '$path.instructions',
          'begin and end must be distinct single lines.',
        );
      }
    }

    DirectorySpec directory(Object? raw, String at) {
      final Map<String, Object?> d = _object(raw, at);
      _keys(d, const <String>{'name', 'source'}, at);
      final String source = sub(d['source'], '$at.source');
      if (!RegExp(r'^(/|[A-Za-z]:[\\/])').hasMatch(source)) {
        invalidManifest('$at.source', 'must be an absolute directory.');
      }
      final String name = d['name'] == null
          ? product
          : _text(d['name'], '$at.name', 64);
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(name)) {
        invalidManifest('$at.name', 'must be a plain directory name.');
      }
      return DirectorySpec(name, source);
    }

    final List<DirectorySpec> skills = json['skills'] == null
        ? const <DirectorySpec>[]
        : <DirectorySpec>[
            for (final (int i, Object? s) in _list(
              json['skills'],
              '$path.skills',
            ).indexed)
              directory(s, '$path.skills[$i]'),
          ];
    if (skills.map((s) => s.name).toSet().length != skills.length) {
      invalidManifest('$path.skills', 'skill names must be unique.');
    }
    final List<String> permissions = json['permissions'] == null
        ? const <String>[]
        : () {
            final Map<String, Object?> p = _object(
              json['permissions'],
              '$path.permissions',
            );
            _keys(p, const <String>{'allow'}, '$path.permissions');
            return <String>[
              for (final (int i, Object? r) in _list(
                p['allow'],
                '$path.permissions.allow',
              ).indexed)
                _text(r, '$path.permissions.allow[$i]', 256),
            ];
          }();

    return ResolvedProduct(
      product: product,
      version: version,
      mcp: mcp,
      hookMarkers: markers,
      hooks: hooks,
      instructions: instructions,
      instructionsBegin: begin,
      instructionsEnd: end,
      skills: skills,
      plugin: json['plugin'] == null
          ? null
          : directory(json['plugin'], '$path.plugin'),
      permissions: permissions,
    );
  }
}

const Set<String> _components = <String>{
  'mcp',
  'hooks',
  'instructions',
  'skills',
  'plugin',
  'permissions',
};

/// Maps merge recursively, null removes a key, anything else replaces.
Object? _merge(Object? base, Object? override) {
  if (base is! Map<String, Object?> || override is! Map<String, Object?>) {
    return override;
  }
  final Map<String, Object?> result = <String, Object?>{...base};
  for (final MapEntry<String, Object?> e in override.entries) {
    if (e.value == null) {
      result[e.key] = null;
    } else {
      result[e.key] = _merge(base[e.key], e.value);
    }
  }
  return result;
}

Map<String, Object?> _extra(
  Object? raw,
  String path,
  Map<String, String> vars,
) {
  if (raw == null) return const <String, Object?>{};
  final Map<String, Object?> json = _object(raw, path);
  Object? value(Object? v, String at) => switch (v) {
    String() => _substitute(v, vars, at),
    bool() || int() => v,
    List<Object?>() when v.every((x) => x is String) => <String>[
      for (final Object? x in v) _substitute(x! as String, vars, at),
    ],
    _ => invalidManifest(
      at,
      'must be text, a boolean, an integer or a list of text.',
    ),
  };
  return <String, Object?>{
    for (final MapEntry<String, Object?> e in json.entries)
      e.key: value(e.value, '$path.${e.key}'),
  };
}

final RegExp _placeholder = RegExp(r'(?<!\$)\{([A-Za-z][A-Za-z0-9]*)\}');

String _substitute(String value, Map<String, String> vars, String path) =>
    value.replaceAllMapped(_placeholder, (m) {
      final String? replacement = vars[m.group(1)];
      if (replacement == null) {
        invalidManifest(path, 'unknown placeholder {${m.group(1)}}.');
      }
      return replacement;
    });

Map<String, Object?> _object(Object? value, String path) {
  if (value is! Map<String, Object?>)
    invalidManifest(path, 'must be an object.');
  return value;
}

List<Object?> _list(Object? value, String path) {
  if (value == null) return const <Object?>[];
  if (value is! List || value.length > 64) {
    invalidManifest(path, 'must be a list of at most 64 items.');
  }
  return value;
}

String _text(Object? value, String path, int maxLength) {
  if (value is! String || value.isEmpty || value.length > maxLength) {
    invalidManifest(
      path,
      'must be non-empty text of at most $maxLength characters.',
    );
  }
  return value;
}

void _keys(Map<String, Object?> json, Set<String> allowed, String path) {
  for (final String key in json.keys) {
    if (!allowed.contains(key))
      invalidManifest(path, 'unsupported field "$key".');
  }
}
