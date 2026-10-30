import 'dart:convert';

import 'extensions.dart';
import 'environment.dart';
import 'errors.dart';

/// The standard hook events a product may ask for. Each target maps them to
/// its own event names and omits the ones it does not support.
/// `agentResponse` fires with the final reply text, where a client has it.
const List<String> hookEvents = <String>[
  'sessionStart',
  'userPromptSubmit',
  'stop',
  'agentResponse',
  'preCompact',
];

const Map<String, String> _claudeEvents = <String, String>{
  'sessionStart': 'SessionStart',
  'userPromptSubmit': 'UserPromptSubmit',
  'stop': 'Stop',
  'preCompact': 'PreCompact',
};

/// Built-in install targets, in the shape of an extension file's `install`
/// section. Verify upstream paths and formats when a client changes.
const Map<String, Map<String, Object?>>
builtinInstallTargets = <String, Map<String, Object?>>{
  'claude-code': <String, Object?>{
    'name': 'Claude Code',
    'detect': <Object?>[
      <String, Object?>{'command': 'claude'},
      <String, Object?>{'path': '~/.claude.json'},
      <String, Object?>{'path': '~/.claude'},
    ],
    'mcp': <String, Object?>{'file': '~/.claude.json', 'format': 'claude-json'},
    'hooks': <String, Object?>{
      'file': '~/.claude/settings.json',
      'format': 'claude-hooks',
      'events': _claudeEvents,
    },
    'permissions': <String, Object?>{'file': '~/.claude/settings.json'},
    'instructions': <String, Object?>{'file': '~/.claude/CLAUDE.md'},
    'skills': <String, Object?>{'dir': '~/.claude/skills'},
    'afterInstall': <String>[
      'Start a new Claude Code session to load the change.',
    ],
  },
  'claude-desktop': <String, Object?>{
    'name': 'Claude Desktop',
    'os': <String>['macos', 'windows'],
    'detect': <Object?>[
      <String, Object?>{'path': '{appData}/Claude'},
    ],
    'mcp': <String, Object?>{
      'file': '{appData}/Claude/claude_desktop_config.json',
      'format': 'mcp-servers-json',
    },
    'afterInstall': <String>['Restart Claude Desktop to load the change.'],
  },
  'codex': <String, Object?>{
    'name': 'Codex',
    'home': <String, Object?>{'env': 'CODEX_HOME', 'default': '~/.codex'},
    'detect': <Object?>[
      <String, Object?>{'command': 'codex'},
      <String, Object?>{'path': '{home}/config.toml'},
    ],
    'mcp': <String, Object?>{
      'file': '{home}/config.toml',
      'format': 'codex-toml',
    },
    'hooks': <String, Object?>{
      'file': '{home}/hooks.json',
      'tomlFile': '{home}/config.toml',
      'format': 'codex-hooks',
      'events': _claudeEvents,
    },
    'instructions': <String, Object?>{
      'file': '{home}/AGENTS.md',
      'overrideFile': '{home}/AGENTS.override.md',
    },
    'skills': <String, Object?>{'dir': '~/.agents/skills'},
    'afterInstall': <String>['Start a new Codex session to load the change.'],
  },
  'cursor': <String, Object?>{
    'name': 'Cursor',
    'detect': <Object?>[
      <String, Object?>{'command': 'cursor'},
      <String, Object?>{'path': '~/.cursor'},
    ],
    'mcp': <String, Object?>{
      'file': '~/.cursor/mcp.json',
      'format': 'mcp-servers-json',
    },
    'hooks': <String, Object?>{
      'file': '~/.cursor/hooks.json',
      'format': 'cursor-hooks',
      'events': <String, String>{
        'sessionStart': 'sessionStart',
        'userPromptSubmit': 'beforeSubmitPrompt',
        'stop': 'stop',
        'agentResponse': 'afterAgentResponse',
      },
    },
    'skills': <String, Object?>{'dir': '~/.cursor/skills'},
    'afterInstall': <String>['Reload Cursor to load the change.'],
  },
  'gemini-cli': <String, Object?>{
    'name': 'Gemini CLI',
    'home': <String, Object?>{'env': 'GEMINI_CLI_HOME', 'default': '~'},
    'detect': <Object?>[
      <String, Object?>{'command': 'gemini'},
      <String, Object?>{'path': '{home}/.gemini/settings.json'},
    ],
    'mcp': <String, Object?>{
      'file': '{home}/.gemini/settings.json',
      'format': 'mcp-servers-json',
    },
  },
  'kiro': <String, Object?>{
    'name': 'Kiro',
    'home': <String, Object?>{'env': 'KIRO_HOME', 'default': '~/.kiro'},
    'detect': <Object?>[
      <String, Object?>{'command': 'kiro'},
      <String, Object?>{'command': 'kiro-cli'},
      <String, Object?>{'path': '{home}/settings/mcp.json'},
    ],
    'mcp': <String, Object?>{
      'file': '{home}/settings/mcp.json',
      'format': 'kiro-json',
    },
  },
  'qwen-code': <String, Object?>{
    'name': 'Qwen Code',
    'home': <String, Object?>{'env': 'QWEN_HOME', 'default': '~/.qwen'},
    'detect': <Object?>[
      <String, Object?>{'command': 'qwen'},
      <String, Object?>{'path': '{home}/settings.json'},
    ],
    'mcp': <String, Object?>{
      'file': '{home}/settings.json',
      'format': 'mcp-servers-json',
    },
  },
  'opencode': <String, Object?>{
    'name': 'OpenCode',
    'detect': <Object?>[
      <String, Object?>{'command': 'opencode'},
      <String, Object?>{'path': '{configHome}/opencode/opencode.json'},
      <String, Object?>{'path': '{configHome}/opencode/opencode.jsonc'},
    ],
    'manualWhenEnv': <String>[
      'OPENCODE_CONFIG',
      'OPENCODE_CONFIG_CONTENT',
      'OPENCODE_CONFIG_DIR',
    ],
    'mcp': <String, Object?>{
      'file': <String>[
        '{configHome}/opencode/opencode.jsonc',
        '{configHome}/opencode/opencode.json',
      ],
      'format': 'opencode-json',
    },
    'skills': <String, Object?>{'dir': '{configHome}/opencode/skills'},
    'plugins': <String, Object?>{'dir': '{configHome}/opencode/plugins'},
    'afterInstall': <String>['Restart OpenCode to load the change.'],
  },
};

const Set<String> mcpFormats = <String>{
  'claude-json',
  'mcp-servers-json',
  'kiro-json',
  'opencode-json',
  'codex-toml',
};
const Set<String> hookFormats = <String>{
  'claude-hooks',
  'codex-hooks',
  'cursor-hooks',
};

/// One file a component edits, with its format.
typedef TargetFile = ({List<String> files, String format});

/// Where and how one agent client accepts a product's integration.
final class InstallTarget {
  InstallTarget._({
    required this.id,
    required this.name,
    required this.builtin,
    required this.detect,
    this.os,
    this.homeEnv,
    this.homeDefault,
    this.manualWhenEnv = const <String>[],
    this.mcp,
    this.hooks,
    this.hooksTomlFile,
    this.hookEvents = const <String, String>{},
    this.permissionsFile,
    this.instructionsFile,
    this.instructionsOverrideFile,
    this.skillsDir,
    this.pluginsDir,
    this.afterInstall = const <String>[],
    this.extensionFile,
  });

  /// Parses an `install` section; [path] prefixes error locations.
  factory InstallTarget.fromJson(
    String id,
    Object? raw,
    String path, {
    required String name,
    bool builtin = false,
    String? extensionFile,
  }) {
    final Map<String, Object?> json = _object(raw, path);
    _keys(json, const <String>{
      'name',
      'os',
      'home',
      'detect',
      'manualWhenEnv',
      'mcp',
      'hooks',
      'permissions',
      'instructions',
      'skills',
      'plugins',
      'afterInstall',
    }, path);
    List<String>? os;
    if (json.containsKey('os')) {
      os = _strings(json['os'], '$path.os');
      if (os.any(
        (o) => !const <String>{'macos', 'windows', 'linux'}.contains(o),
      )) {
        invalidTarget('$path.os', 'use macos, windows or linux.');
      }
    }
    String? homeEnv;
    String? homeDefault;
    if (json.containsKey('home')) {
      final Map<String, Object?> home = _object(json['home'], '$path.home');
      _keys(home, const <String>{'env', 'default'}, '$path.home');
      if (home.containsKey('env')) {
        homeEnv = _envName(home['env'], '$path.home.env');
      }
      homeDefault = _template(
        home['default'],
        '$path.home.default',
        home: false,
      );
    }
    final Object? detectRaw = json['detect'];
    if (detectRaw is! List || detectRaw.isEmpty || detectRaw.length > 16) {
      invalidTarget('$path.detect', 'must list 1 to 16 conditions.');
    }
    final List<DetectRule> detect = <DetectRule>[
      for (final (int i, Object? rule) in detectRaw.indexed)
        DetectRule._parse(rule, '$path.detect[$i]'),
    ];
    TargetFile? mcp;
    if (json.containsKey('mcp')) {
      mcp = _file(json['mcp'], '$path.mcp', mcpFormats, allowList: true);
    }
    TargetFile? hooks;
    String? tomlFile;
    Map<String, String> events = const <String, String>{};
    if (json.containsKey('hooks')) {
      final Map<String, Object?> h = _object(json['hooks'], '$path.hooks');
      _keys(h, const <String>{
        'file',
        'format',
        'events',
        'tomlFile',
      }, '$path.hooks');
      hooks = _file(
        <String, Object?>{'file': h['file'], 'format': h['format']},
        '$path.hooks',
        hookFormats,
      );
      if (h.containsKey('tomlFile')) {
        if (hooks.format != 'codex-hooks') {
          invalidTarget('$path.hooks.tomlFile', 'applies only to codex-hooks.');
        }
        tomlFile = _template(h['tomlFile'], '$path.hooks.tomlFile');
      }
      final Map<String, Object?> e = _object(h['events'], '$path.hooks.events');
      events = <String, String>{
        for (final MapEntry<String, Object?> entry in e.entries)
          _event(entry.key, '$path.hooks.events'): _native(
            entry.value,
            '$path.hooks.events.${entry.key}',
          ),
      };
      if (events.isEmpty) invalidTarget('$path.hooks.events', 'is empty.');
    }
    String? permissions;
    if (json.containsKey('permissions')) {
      final Map<String, Object?> p = _object(
        json['permissions'],
        '$path.permissions',
      );
      _keys(p, const <String>{'file'}, '$path.permissions');
      permissions = _template(p['file'], '$path.permissions.file');
    }
    String? instructions;
    String? instructionsOverride;
    if (json.containsKey('instructions')) {
      final Map<String, Object?> i = _object(
        json['instructions'],
        '$path.instructions',
      );
      _keys(i, const <String>{'file', 'overrideFile'}, '$path.instructions');
      instructions = _template(i['file'], '$path.instructions.file');
      if (i.containsKey('overrideFile')) {
        instructionsOverride = _template(
          i['overrideFile'],
          '$path.instructions.overrideFile',
        );
      }
    }
    String? dir(String key) {
      if (!json.containsKey(key)) return null;
      final Map<String, Object?> d = _object(json[key], '$path.$key');
      _keys(d, const <String>{'dir'}, '$path.$key');
      return _template(d['dir'], '$path.$key.dir');
    }

    final InstallTarget target = InstallTarget._(
      id: id,
      name: json.containsKey('name')
          ? _text(json['name'], '$path.name', 64)
          : name,
      builtin: builtin,
      os: os,
      homeEnv: homeEnv,
      homeDefault: homeDefault,
      detect: detect,
      manualWhenEnv: json.containsKey('manualWhenEnv')
          ? <String>[
              for (final String n in _strings(
                json['manualWhenEnv'],
                '$path.manualWhenEnv',
              ))
                _envName(n, '$path.manualWhenEnv'),
            ]
          : const <String>[],
      mcp: mcp,
      hooks: hooks,
      hooksTomlFile: tomlFile,
      hookEvents: events,
      permissionsFile: permissions,
      instructionsFile: instructions,
      instructionsOverrideFile: instructionsOverride,
      skillsDir: dir('skills'),
      pluginsDir: dir('plugins'),
      afterInstall: json.containsKey('afterInstall')
          ? <String>[
              for (final String s in _strings(
                json['afterInstall'],
                '$path.afterInstall',
              ))
                _text(s, '$path.afterInstall', 200),
            ]
          : const <String>[],
      extensionFile: extensionFile,
    );
    if (target.components.isEmpty) {
      invalidTarget(path, 'declares nothing to install.');
    }
    return target;
  }

  final String id;
  final String name;
  final bool builtin;

  /// Platforms the client exists on; null for all.
  final List<String>? os;
  final String? homeEnv;
  final String? homeDefault;
  final List<DetectRule> detect;

  /// Environment variables that make the client read a different file, so a
  /// change here could be shadowed; the client is then configured by hand.
  final List<String> manualWhenEnv;
  final TargetFile? mcp;
  final TargetFile? hooks;
  final String? hooksTomlFile;

  /// Standard event name to the client's own name.
  final Map<String, String> hookEvents;
  final String? permissionsFile;
  final String? instructionsFile;
  final String? instructionsOverrideFile;
  final String? skillsDir;
  final String? pluginsDir;
  final List<String> afterInstall;

  /// The user extension file that defines or customizes this target.
  final String? extensionFile;

  /// The kinds of integration this client accepts.
  List<String> get components => <String>[
    if (mcp != null) 'mcp',
    if (hooks != null) 'hooks',
    if (permissionsFile != null) 'permissions',
    if (instructionsFile != null) 'instructions',
    if (skillsDir != null) 'skills',
    if (pluginsDir != null) 'plugin',
  ];

  /// The resolved `{home}` directory.
  String clientHome(InstallEnvironment environment) =>
      (homeEnv == null ? null : environment.overrideDirectory(homeEnv!)) ??
      environment.resolve(homeDefault ?? '~');

  String resolve(InstallEnvironment environment, String template) =>
      environment.resolve(template, clientHome: clientHome(environment));
}

/// One condition that shows a client is installed.
final class DetectRule {
  const DetectRule._(this.command, this.path);

  factory DetectRule._parse(Object? raw, String path) {
    final Map<String, Object?> json = _object(raw, path);
    if (json.length != 1)
      invalidTarget(path, 'use exactly one of command or path.');
    if (json.containsKey('command')) {
      final String command = _text(json['command'], '$path.command', 64);
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(command)) {
        invalidTarget('$path.command', 'must be a program name.');
      }
      return DetectRule._(command, null);
    }
    if (json.containsKey('path')) {
      return DetectRule._(null, _template(json['path'], '$path.path'));
    }
    invalidTarget(path, 'use exactly one of command or path.');
  }

  /// A program name looked up on PATH.
  final String? command;

  /// A file or directory template.
  final String? path;
}

/// Built-in targets merged with the `install` sections of extension files.
final class InstallTargets {
  InstallTargets._(this.targets, this.problems);

  /// Built-in targets only.
  static final InstallTargets defaults = InstallTargets.fromExtensions(
    const <ExtensionFile>[],
  );

  /// Reads [extensionsDirectory] (usually [defaultExtensionsDirectory]).
  factory InstallTargets.load({String? extensionsDirectory}) =>
      InstallTargets.fromExtensions(
        extensionsDirectory == null
            ? const <ExtensionFile>[]
            : readExtensionDirectory(extensionsDirectory),
      );

  /// An extension file's `install` section replaces a built-in target's
  /// listed keys or defines a new target. A bad section skips only its file.
  factory InstallTargets.fromExtensions(List<ExtensionFile> extensions) {
    final Map<String, InstallTarget> targets = <String, InstallTarget>{
      for (final MapEntry<String, Map<String, Object?>> e
          in builtinInstallTargets.entries)
        e.key: InstallTarget.fromJson(
          e.key,
          e.value,
          'builtin.${e.key}',
          name: e.key,
          builtin: true,
        ),
    };
    final List<ExtensionProblem> problems = <ExtensionProblem>[];
    for (final ExtensionFile file in extensions) {
      if (file.text == null) continue;
      final String name = file.name!;
      try {
        final Object? json;
        try {
          json = jsonDecode(file.text!);
        } on FormatException {
          continue;
        }
        if (json is! Map<String, Object?> || !json.containsKey('install')) {
          continue;
        }
        final String id = name.endsWith('.json')
            ? name.substring(0, name.length - 5)
            : '';
        if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(id)) {
          invalidTarget(
            r'$',
            'the file name must be a client ID followed by .json.',
          );
        }
        if (json['schemaVersion'] != 1)
          invalidTarget(r'$.schemaVersion', 'must be 1.');
        final Map<String, Object?> install = _object(
          json['install'],
          r'$.install',
        );
        final Map<String, Object?>? base = builtinInstallTargets[id];
        targets[id] = InstallTarget.fromJson(
          id,
          <String, Object?>{...?base, ...install},
          r'$.install',
          name: json['name'] is String ? json['name']! as String : id,
          builtin: base != null,
          extensionFile: name,
        );
      } on AgentInstallException catch (error) {
        problems.add(ExtensionProblem(name, error.message));
      }
    }
    return InstallTargets._(
      Map<String, InstallTarget>.unmodifiable(targets),
      List<ExtensionProblem>.unmodifiable(problems),
    );
  }

  final Map<String, InstallTarget> targets;

  /// Extension files whose `install` section was skipped.
  final List<ExtensionProblem> problems;
}

TargetFile _file(
  Object? raw,
  String path,
  Set<String> formats, {
  bool allowList = false,
}) {
  final Map<String, Object?> json = _object(raw, path);
  _keys(json, const <String>{'file', 'format'}, path);
  final Object? file = json['file'];
  final List<String> files = allowList && file is List
      ? <String>[for (final Object? f in file) _template(f, '$path.file')]
      : <String>[_template(file, '$path.file')];
  if (files.isEmpty || files.length > 4) {
    invalidTarget('$path.file', 'must name 1 to 4 candidate files.');
  }
  final Object? format = json['format'];
  if (format is! String || !formats.contains(format)) {
    invalidTarget('$path.format', 'must be one of ${formats.join(', ')}.');
  }
  return (files: files, format: format);
}

String _template(Object? value, String path, {bool home = true}) {
  if (value is! String ||
      !isPathTemplate(value) ||
      (!home && value.startsWith('{home}'))) {
    invalidTarget(
      path,
      'must start with ~/, {home}, {configHome} or {appData} and use plain '
      'path segments.',
    );
  }
  return value;
}

String _event(String value, String path) {
  if (!hookEvents.contains(value)) {
    invalidTarget(path, '"$value" is not one of ${hookEvents.join(', ')}.');
  }
  return value;
}

String _native(Object? value, String path) {
  final String text = _text(value, path, 64);
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_.]*$').hasMatch(text)) {
    invalidTarget(path, 'must be a plain event name.');
  }
  return text;
}

String _envName(Object? value, String path) {
  final String text = _text(value, path, 64);
  if (!RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(text)) {
    invalidTarget(path, 'must be an environment variable name.');
  }
  return text;
}

Map<String, Object?> _object(Object? value, String path) {
  if (value is! Map<String, Object?>) invalidTarget(path, 'must be an object.');
  return value;
}

List<String> _strings(Object? value, String path) {
  if (value is! List || value.length > 32 || value.any((v) => v is! String)) {
    invalidTarget(path, 'must be a list of text.');
  }
  return value.cast<String>();
}

String _text(Object? value, String path, int maxLength) {
  if (value is! String || value.isEmpty || value.length > maxLength) {
    invalidTarget(
      path,
      'must be non-empty text of at most $maxLength characters.',
    );
  }
  return value;
}

void _keys(Map<String, Object?> json, Set<String> allowed, String path) {
  for (final String key in json.keys) {
    if (!allowed.contains(key))
      invalidTarget(path, 'unsupported field "$key".');
  }
}
