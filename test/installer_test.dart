import 'dart:convert';
import 'dart:io';

import 'package:agent_installer/agent_installer.dart';
import 'package:test/test.dart';

late Directory home;

String get bundle => '${Directory.current.path}/example/acme';

/// The host's own rules unless [os] simulates another platform.
InstallEnvironment env({
  Map<String, String> extra = const <String, String>{},
  String? os,
}) => InstallEnvironment(
  environment: <String, String>{
    'HOME': home.path,
    'USERPROFILE': home.path,
    'PATH': '${home.path}${Platform.pathSeparator}bin',
    ...extra,
  },
  operatingSystem: os ?? (Platform.isWindows ? 'windows' : 'linux'),
);

ProductManifest acme({Map<String, Object?>? override}) {
  final Map<String, Object?> json =
      jsonDecode(File('$bundle/acme.manifest.json').readAsStringSync())
          as Map<String, Object?>;
  return ProductManifest.fromJson(
    <String, Object?>{...json, ...?override},
    variables: <String, String>{
      'acmeMcp': '/opt/acme/bin/acme_mcp',
      'bundle': bundle,
    },
  );
}

AgentInstaller installer({
  ProductManifest? product,
  InstallEnvironment? environment,
  InstallTargets? targets,
  String? backups,
}) => AgentInstaller(
  product: product ?? acme(),
  environment: environment ?? env(),
  targets: targets,
  backupDirectory: backups,
);

String? read(String path) {
  final File file = File('${home.path}/$path');
  return file.existsSync() ? file.readAsStringSync() : null;
}

void write(String path, String content) => File('${home.path}/$path')
  ..parent.createSync(recursive: true)
  ..writeAsStringSync(content);

Map<String, Object?> json(String path) =>
    jsonDecode(read(path)!) as Map<String, Object?>;

ClientStatus status(AgentInstaller i, String id) =>
    i.status(<String>[id]).single;

Map<String, String> states(ClientStatus s) => <String, String>{
  for (final ComponentStatus c in s.components) c.component: c.state,
};

void main() {
  setUp(() async {
    home = await Directory.systemTemp.createTemp('agent-installer-');
  });
  tearDown(() => home.delete(recursive: true));

  test('scan reports evidence, PATH commands and platform limits', () {
    write('bin/codex', '');
    write('.claude.json', '{}');
    final Map<String, TargetScan> scans = <String, TargetScan>{
      for (final TargetScan s in installer().scan()) s.id: s,
    };
    expect(scans['codex']!.evidence, <String>['command: codex']);
    expect(scans['claude-code']!.evidence, <String>['~/.claude.json']);
    expect(scans['gemini-cli']!.detected, isFalse);
    expect(
      installer(
        environment: env(os: 'linux'),
      ).scan().firstWhere((s) => s.id == 'claude-desktop').platformSupported,
      isFalse,
    );
    Directory(
      '${home.path}/Library/Application Support/Claude',
    ).createSync(recursive: true);
    final TargetScan desktop = installer(
      environment: env(os: 'macos'),
    ).scan().firstWhere((s) => s.id == 'claude-desktop');
    expect(desktop.evidence, <String>['~/Library/Application Support/Claude']);
  });

  test('Claude Code installs, is idempotent and removes cleanly', () {
    const String claudeJson =
        '{\n  "numStartups": 3,\n  "mcpServers": {\n    "other": {\n      "command": "x"\n    }\n  }\n}\n';
    const String settings =
        '{\n  "hooks": {\n    "Stop": [\n      {\n        "hooks": [\n          {\n            "type": "command",\n            "command": "other --stop"\n          }\n        ]\n      }\n    ]\n  },\n  "permissions": {\n    "allow": [\n      "Bash(ls)"\n    ]\n  }\n}\n';
    write('.claude.json', claudeJson);
    write('.claude/settings.json', settings);
    write('.claude/CLAUDE.md', '# Mine\n');
    final AgentInstaller i = installer(backups: '${home.path}/backups');
    expect(status(i, 'claude-code').state, 'not_connected');

    final ClientResult applied = i.apply(<String>['claude-code']).single;
    expect(applied.state, 'connected');
    expect(applied.problems, isEmpty);
    expect(applied.actions, contains(startsWith('Start a new Claude Code')));
    expect(json('.claude.json')['mcpServers'], <String, Object?>{
      'other': <String, Object?>{'command': 'x'},
      'acme': <String, Object?>{
        'type': 'stdio',
        'command': '/opt/acme/bin/acme_mcp',
        'args': <String>['--source', 'Claude Code'],
      },
    });
    final Map<String, Object?> hooks =
        json('.claude/settings.json')['hooks']! as Map<String, Object?>;
    expect((hooks['Stop']! as List).length, 2, reason: 'foreign hook kept');
    expect(
      jsonEncode(hooks['Stop']),
      contains(
        Platform.isWindows
            ? r'--source \"Claude Code\"'
            : "--source 'Claude Code'",
      ),
    );
    expect(
      jsonEncode(hooks['Stop']),
      contains('"statusMessage":"Notifying Acme"'),
    );
    expect(
      jsonEncode(hooks['SessionStart']),
      contains('"matcher":"startup|resume"'),
    );
    expect(
      (json('.claude/settings.json')['permissions']! as Map)['allow'],
      <String>['Bash(ls)', 'mcp__acme__ping'],
    );
    expect(
      read('.claude/CLAUDE.md'),
      contains('<!-- BEGIN ACME MANAGED INSTRUCTIONS -->'),
    );
    expect(read('.claude/skills/acme-helper/SKILL.md'), isNotNull);
    expect(
      Directory('${home.path}/backups/claude-code').listSync(),
      hasLength(3),
    );
    if (!Platform.isWindows) {
      for (final FileSystemEntity f in Directory(
        '${home.path}/backups/claude-code',
      ).listSync()) {
        expect(f.statSync().mode & 0x1ff, 0x180, reason: f.path);
      }
      expect(
        Directory('${home.path}/backups/claude-code').statSync().mode & 0x1ff,
        0x1c0,
      );
    }

    expect(i.apply(<String>['claude-code']).single.changes, isEmpty);
    expect(i.plan(<String>['claude-code']).single.changes, isEmpty);

    final ClientResult removed = i.remove(<String>['claude-code']).single;
    expect(removed.state, 'not_connected');
    expect(read('.claude.json'), claudeJson);
    expect(read('.claude/settings.json'), settings);
    expect(read('.claude/CLAUDE.md'), '# Mine\n');
    expect(
      Directory('${home.path}/.claude/skills/acme-helper').existsSync(),
      isFalse,
    );
  });

  test('a plan never writes', () {
    write('.claude.json', '{}');
    final ClientResult plan = installer().plan(<String>['claude-code']).single;
    expect(
      plan.changes.map((c) => c.path),
      containsAll(<String>[
        '~/.claude.json',
        '~/.claude/settings.json',
        '~/.claude/skills/acme-helper',
      ]),
    );
    expect(plan.changes.first.diff, contains('+    "acme": {'));
    expect(read('.claude.json'), '{}');
    expect(read('.claude/settings.json'), isNull);
  });

  test('Codex keeps hooks in config.toml when the person does', () {
    const String toml =
        'model = "gpt-5"\n\n[[hooks.Stop]]\n\n[[hooks.Stop.hooks]]\ntype = "command"\ncommand = "other --stop"\n';
    write('.codex/config.toml', toml);
    final AgentInstaller i = installer();
    final ClientResult applied = i.apply(<String>['codex']).single;
    expect(applied.problems, isEmpty);
    expect(applied.actions, contains(contains('/hooks')));
    final String config = read('.codex/config.toml')!;
    expect(
      config,
      contains(
        '[mcp_servers.acme]\ncommand = "/opt/acme/bin/acme_mcp"\nargs = ["--source", "Codex"]\nstartup_timeout_sec = 20\n',
      ),
    );
    expect(
      config,
      contains(
        Platform.isWindows
            ? "command = \"& '/opt/acme/bin/acme_mcp' --notify-stop --source Codex\""
            : 'command = "/opt/acme/bin/acme_mcp --notify-stop --source Codex"',
      ),
    );
    expect(config, contains('matcher = "^(startup|resume)\$"'));
    expect(config, contains('command = "other --stop"'));
    expect(read('.codex/hooks.json'), isNull);
    expect(read('.codex/AGENTS.md'), contains('Acme is available'));
    expect(read('.agents/skills/acme-helper/SKILL.md'), isNotNull);
    expect(status(i, 'codex').state, 'connected');
    i.remove(<String>['codex']);
    expect(read('.codex/config.toml'), toml);
  });

  test('Codex hook commands use PowerShell syntax on Windows only', () {
    final AgentInstaller i = installer(
      product: acme(
        override: <String, Object?>{
          'hooks': <String, Object?>{
            'markers': <String>['acme_mcp'],
            'events': <String, Object?>{
              'stop': <String, Object?>{
                'command': <String>['{acmeMcp}', "it's here", '--flag'],
              },
            },
          },
          'clients': <String, Object?>{},
        },
      ),
    );
    write('.codex/config.toml', '');
    i.apply(<String>['codex', 'claude-code']);
    String stop(String path, String event) {
      final Map<String, Object?> hooks =
          json(path)['hooks']! as Map<String, Object?>;
      final Map<String, Object?> group =
          (hooks[event]! as List).single as Map<String, Object?>;
      return ((group['hooks']! as List).single as Map)['command'] as String;
    }

    expect(
      stop('.codex/hooks.json', 'Stop'),
      Platform.isWindows
          ? "& '/opt/acme/bin/acme_mcp' 'it''s here' --flag"
          : r"/opt/acme/bin/acme_mcp 'it'\''s here' --flag",
    );
    expect(
      stop('.claude/settings.json', 'Stop'),
      Platform.isWindows
          ? '/opt/acme/bin/acme_mcp "it\'s here" --flag'
          : r"/opt/acme/bin/acme_mcp 'it'\''s here' --flag",
    );
    expect(status(i, 'codex').state, 'connected');
  });

  test('an empty file the product never touched survives removal', () {
    const String toml =
        '[[hooks.Stop]]\n\n[[hooks.Stop.hooks]]\ntype = "command"\ncommand = "other --stop"\n';
    write('.codex/config.toml', toml);
    write('.codex/hooks.json', '{}\n');
    final AgentInstaller i = installer();
    expect(i.apply(<String>['codex']).single.problems, isEmpty);
    i.remove(<String>['codex']);
    expect(read('.codex/config.toml'), toml);
    expect(read('.codex/hooks.json'), '{}\n');
  });

  test('Codex uses hooks.json by default and refuses two hook files', () {
    write('.codex/config.toml', 'model = "gpt-5"\n');
    final AgentInstaller i = installer();
    i.apply(<String>['codex']);
    expect(
      jsonEncode(json('.codex/hooks.json')),
      contains('--notify-stop --source Codex'),
    );
    i.remove(<String>['codex']);
    expect(read('.codex/hooks.json'), isNull);

    write(
      '.codex/config.toml',
      '[[hooks.Stop]]\n\n[[hooks.Stop.hooks]]\ncommand = "a"\n',
    );
    write(
      '.codex/hooks.json',
      '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"b"}]}]}}',
    );
    final ClientStatus s = status(i, 'codex');
    expect(s.state, 'conflict');
    expect(
      s.components.firstWhere((c) => c.component == 'hooks').message,
      contains('both'),
    );
    final ClientResult result = i.apply(<String>['codex']).single;
    expect(result.problems, contains(startsWith('hooks:')));
    expect(read('.codex/config.toml'), contains('[mcp_servers.acme]'));
  });

  test('Codex instructions follow a non-empty AGENTS.override.md', () {
    write('.codex/config.toml', '');
    write('.codex/AGENTS.md', '# Base\n');
    write('.codex/AGENTS.override.md', '# Override\n');
    installer().apply(<String>['codex']);
    expect(read('.codex/AGENTS.md'), '# Base\n');
    expect(read('.codex/AGENTS.override.md'), contains('ACME MANAGED'));
  });

  test('CODEX_HOME moves the Codex files', () {
    write('custom/config.toml', '');
    installer(
      environment: env(
        extra: <String, String>{'CODEX_HOME': '${home.path}/custom'},
      ),
    ).apply(<String>['codex']);
    expect(read('custom/config.toml'), contains('[mcp_servers.acme]'));
    expect(read('.codex/config.toml'), isNull);
  });

  test('Cursor hooks use its event names and version', () {
    final AgentInstaller i = installer();
    i.apply(<String>['cursor']);
    final Map<String, Object?> hooks = json('.cursor/hooks.json');
    expect(hooks['version'], 1);
    expect((hooks['hooks']! as Map).keys, <String>['sessionStart', 'stop']);
    expect(
      ((hooks['hooks']! as Map)['stop']! as List).single,
      <String, Object?>{
        'command': '/opt/acme/bin/acme_mcp --notify-stop --source Cursor',
        'timeout': 10,
      },
    );
    i.remove(<String>['cursor']);
    expect(read('.cursor/hooks.json'), isNull);
    expect(read('.cursor/mcp.json'), isNull);
  });

  test('a client can take the final reply instead of stop', () {
    final AgentInstaller i = installer(
      product: acme(
        override: <String, Object?>{
          'clients': <String, Object?>{
            'cursor': <String, Object?>{
              'hooks': <String, Object?>{
                'events': <String, Object?>{
                  'stop': null,
                  'agentResponse': <String, Object?>{
                    'command': <String>['{acmeMcp}', '--notify-stop'],
                  },
                },
              },
            },
          },
        },
      ),
    );
    i.apply(<String>['cursor', 'claude-code']);
    final Map<String, Object?> hooks = json('.cursor/hooks.json');
    expect((hooks['hooks']! as Map).keys, <String>[
      'sessionStart',
      'afterAgentResponse',
    ]);
    expect((json('.claude/settings.json')['hooks']! as Map).keys, <String>[
      'SessionStart',
      'Stop',
    ]);
  });

  test('OpenCode keeps comments, and conflicts become manual work', () {
    write(
      '.config/opencode/opencode.jsonc',
      '{\n  // mine\n  "theme": "x"\n}\n',
    );
    final AgentInstaller i = installer();
    i.apply(<String>['opencode']);
    final String text = read('.config/opencode/opencode.jsonc')!;
    expect(text, contains('// mine'));
    expect((JsonEdit.decode(text)! as Map)['mcp'], <String, Object?>{
      'acme': <String, Object?>{
        'type': 'local',
        'command': <String>['/opt/acme/bin/acme_mcp', '--source', 'OpenCode'],
        'enabled': true,
      },
    });
    write('.config/opencode/opencode.json', '{}');
    expect(states(status(i, 'opencode'))['mcp'], 'conflict');

    final ClientResult manual = installer(
      environment: env(extra: <String, String>{'OPENCODE_CONFIG': '/x.json'}),
    ).apply(<String>['opencode']).single;
    expect(manual.state, 'manual');
    expect(manual.problems.single, contains('OPENCODE_CONFIG'));
  });

  test('MCP-only clients use their own entry shapes', () {
    final AgentInstaller mac = installer(environment: env(os: 'macos'));
    mac.apply(<String>['kiro', 'claude-desktop', 'gemini-cli']);
    expect(
      (json('.kiro/settings/mcp.json')['mcpServers']! as Map)['acme'],
      <String, Object?>{
        'command': '/opt/acme/bin/acme_mcp',
        'args': <String>['--source', 'Kiro'],
        'disabled': false,
      },
    );
    expect(
      ((json(
                'Library/Application Support/Claude/claude_desktop_config.json',
              )['mcpServers']!
              as Map)['acme']!
          as Map)['args'],
      <String>['--profile', 'chat'],
    );
    expect(json('.gemini/settings.json')['mcpServers'], isA<Map>());
    expect(
      states(status(mac, 'claude-desktop')),
      containsPair('hooks', 'unsupported'),
    );
    expect(status(mac, 'claude-desktop').state, 'connected');
  });

  test('existing entries keep added fields and drop transport fields', () {
    write(
      '.cursor/mcp.json',
      '{"mcpServers":{"acme":{"url":"http://localhost/acme_mcp","timeout":5}}}',
    );
    installer().apply(<String>['cursor']);
    expect(
      (json('.cursor/mcp.json')['mcpServers']! as Map)['acme'],
      <String, Object?>{
        'timeout': 5,
        'command': '/opt/acme/bin/acme_mcp',
        'args': <String>['--source', 'Cursor'],
      },
    );
  });

  test('a same-name server without the marker is never taken over', () {
    const String cursor = '{"mcpServers":{"acme":{"command":"other-tool"}}}\n';
    write('.cursor/mcp.json', cursor);
    const String toml = '[mcp_servers.acme]\ncommand = "other-tool"\n';
    write('.codex/config.toml', toml);
    final AgentInstaller i = installer();
    for (final String id in <String>['cursor', 'codex']) {
      expect(states(status(i, id))['mcp'], 'conflict');
      expect(status(i, id).state, 'conflict');
      final ClientResult applied = i.apply(<String>[id]).single;
      expect(applied.problems, contains(contains('already named "acme"')));
      i.remove(<String>[id]);
    }
    expect(read('.cursor/mcp.json'), cursor);
    expect(read('.codex/config.toml'), startsWith(toml));
  });

  test('a hand-made entry with the marker is taken over', () {
    write(
      '.codex/config.toml',
      '[mcp_servers.acme]\ncommand = "/usr/local/bin/acme_mcp"\nenabled = true\n',
    );
    final AgentInstaller i = installer();
    expect(states(status(i, 'codex'))['mcp'], 'outdated');
    i.apply(<String>['codex']);
    expect(
      read('.codex/config.toml'),
      contains('command = "/opt/acme/bin/acme_mcp"'),
    );
    expect(read('.codex/config.toml'), contains('enabled = true'));
    i.remove(<String>['codex']);
    expect(
      read('.codex/config.toml') ?? '',
      isNot(contains('mcp_servers.acme')),
    );
  });

  test('preserved options keep the value the person chose', () {
    final ProductManifest product = acme(
      override: <String, Object?>{
        'mcp': <String, Object?>{
          'name': 'acme',
          'command': '{acmeMcp}',
          'args': <String>[
            '--source',
            '{clientName}',
            '--tool-profile',
            'basic',
          ],
          'preserveArgs': <String>['--tool-profile'],
        },
      },
    );
    write(
      '.codex/config.toml',
      '[mcp_servers.acme]\ncommand = "/usr/local/bin/acme_mcp"\n'
          'args = [\n  "--tool-profile", # chosen by hand\n  "full",\n]\n',
    );
    write(
      '.cursor/mcp.json',
      '{"mcpServers":{"acme":{"command":"acme_mcp","args":["--tool-profile=lite"]}}}',
    );
    write(
      '.config/opencode/opencode.json',
      '{"mcp":{"acme":{"type":"local","command":["acme_mcp","--tool-profile","x"]}}}',
    );
    final AgentInstaller i = installer(product: product);
    i.apply(<String>['codex', 'cursor', 'opencode', 'claude-code']);
    expect(
      read('.codex/config.toml'),
      contains('args = ["--source", "Codex", "--tool-profile", "full"]'),
    );
    expect(
      ((json('.cursor/mcp.json')['mcpServers']! as Map)['acme']!
          as Map)['args'],
      <String>['--source', 'Cursor', '--tool-profile=lite'],
    );
    expect(
      ((json('.config/opencode/opencode.json')['mcp']! as Map)['acme']!
          as Map)['command'],
      <String>[
        '/opt/acme/bin/acme_mcp',
        '--source',
        'OpenCode',
        '--tool-profile',
        'x',
      ],
    );
    expect(
      ((json('.claude.json')['mcpServers']! as Map)['acme']! as Map)['args'],
      <String>['--source', 'Claude Code', '--tool-profile', 'basic'],
      reason: 'a new entry gets the manifest default',
    );
    for (final String id in <String>['codex', 'cursor', 'opencode']) {
      expect(states(status(i, id))['mcp'], 'current', reason: id);
    }
    expect(
      () => acme(
        override: <String, Object?>{
          'mcp': <String, Object?>{
            'name': 'acme',
            'command': '{acmeMcp}',
            'preserveArgs': <String>['tool profile'],
          },
        },
      ),
      throwsA(isA<AgentInstallException>()),
    );
  });

  test('the MCP command must carry a marker', () {
    expect(
      () => acme(
        override: <String, Object?>{
          'mcp': <String, Object?>{
            'name': 'acme',
            'command': 'npx',
            'markers': <String>['acme_mcp'],
          },
        },
      ),
      throwsA(isA<AgentInstallException>()),
    );
  });

  test('skills are never overwritten when changed or foreign', () {
    final AgentInstaller i = installer();
    write('.cursor/skills/acme-helper/SKILL.md', 'someone else');
    expect(states(status(i, 'cursor'))['skills'], 'conflict');
    expect(
      i.apply(<String>['cursor']).single.problems,
      contains(contains('not managed by Acme')),
    );
    expect(read('.cursor/skills/acme-helper/SKILL.md'), 'someone else');

    i.apply(<String>['claude-code']);
    write('.claude/skills/acme-helper/SKILL.md', 'edited by hand');
    expect(states(status(i, 'claude-code'))['skills'], 'conflict');
    final ClientResult removed = i.remove(<String>['claude-code']).single;
    expect(removed.problems, contains(contains('changed by hand')));
    expect(read('.claude/skills/acme-helper/SKILL.md'), 'edited by hand');
  });

  test('outdated skills are replaced', () {
    final AgentInstaller i = installer();
    i.apply(<String>['claude-code']);
    // Simulate an install of an older version: its receipt matches its files.
    final File receipt = File(
      '${home.path}/.claude/skills/acme-helper/.agent-installer.json',
    );
    final Map<String, Object?> data =
        jsonDecode(receipt.readAsStringSync()) as Map<String, Object?>;
    write('.claude/skills/acme-helper/OLD.md', 'old');
    (data['files']! as Map<String, Object?>)['OLD.md'] = fnv1a(
      utf8.encode('old'),
    );
    receipt.writeAsStringSync(jsonEncode(data));
    expect(states(status(i, 'claude-code'))['skills'], 'outdated');
    i.apply(<String>['claude-code']);
    expect(read('.claude/skills/acme-helper/OLD.md'), isNull);
    expect(states(status(i, 'claude-code'))['skills'], 'current');
  });

  test('a symlinked config stays a link', () {
    write('dotfiles/mcp.json', '{}');
    Directory('${home.path}/.cursor').createSync();
    Link(
      '${home.path}/.cursor/mcp.json',
    ).createSync('${home.path}/dotfiles/mcp.json');
    installer().apply(<String>['cursor']);
    expect(
      FileSystemEntity.isLinkSync('${home.path}/.cursor/mcp.json'),
      isTrue,
    );
    expect(read('dotfiles/mcp.json'), contains('acme'));
  }, skip: Platform.isWindows ? 'POSIX links only.' : false);

  test('an extension file adds or customizes install targets', () {
    write(
      'ext/acme-agent.json',
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'name': 'Acme Agent',
        'install': <String, Object?>{
          'detect': <Object?>[
            <String, Object?>{'path': '~/.acme-agent'},
          ],
          'mcp': <String, Object?>{
            'file': '~/.acme-agent/mcp.json',
            'format': 'mcp-servers-json',
          },
          'instructions': <String, Object?>{'file': '~/.acme-agent/AGENTS.md'},
        },
      }),
    );
    write(
      'ext/cursor.json',
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'install': <String, Object?>{
          'skills': <String, Object?>{'dir': '~/.cursor/my-skills'},
        },
      }),
    );
    write(
      'ext/broken.json',
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'install': <String, Object?>{
          'detect': <Object?>[],
          'mcp': <String, Object?>{},
        },
      }),
    );
    write(
      'ext/escape.json',
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'install': <String, Object?>{
          'detect': <Object?>[
            <String, Object?>{'path': '~/../etc'},
          ],
          'mcp': <String, Object?>{
            'file': '/etc/mcp.json',
            'format': 'mcp-servers-json',
          },
        },
      }),
    );
    final InstallTargets targets = InstallTargets.load(
      extensionsDirectory: '${home.path}/ext',
    );
    expect(targets.targets['acme-agent']!.name, 'Acme Agent');
    expect(targets.targets['cursor']!.skillsDir, '~/.cursor/my-skills');
    expect(
      targets.targets['cursor']!.hooks,
      isNotNull,
      reason: 'other keys kept',
    );
    expect(
      <String?>[for (final p in targets.problems) p.file],
      <String>['broken.json', 'escape.json'],
    );

    final AgentInstaller i = installer(targets: targets);
    i.apply(<String>['acme-agent', 'cursor']);
    expect(read('.acme-agent/AGENTS.md'), contains('ACME MANAGED'));
    expect(read('.cursor/my-skills/acme-helper/SKILL.md'), isNotNull);
  });

  test('manifests are validated up front', () {
    Matcher fails(String text) => throwsA(
      isA<AgentInstallException>()
          .having((e) => e.code, 'code', 'invalid_manifest')
          .having((e) => e.message, 'message', contains(text)),
    );
    expect(
      () => ProductManifest.fromJson(<String, Object?>{
        'schemaVersion': 1,
        'product': 'x',
        'name': 'X',
        'version': '1',
        'mcp': <String, Object?>{'name': 'x', 'command': '{missing}'},
      }),
      fails('unknown placeholder {missing}'),
    );
    expect(
      () => acme(
        override: <String, Object?>{
          'hooks': <String, Object?>{
            'markers': <String>['acme_mcp'],
            'events': <String, Object?>{
              'stop': <String, Object?>{
                'command': <String>['other-tool'],
              },
            },
          },
        },
      ),
      fails('must contain one of the hook markers'),
    );
    expect(
      () => acme(
        override: <String, Object?>{
          'clients': <String, Object?>{
            'codex': <String, Object?>{
              'hooks': <String, Object?>{
                'events': <String, Object?>{
                  'afterEverything': <String, Object?>{},
                },
              },
            },
          },
        },
      ),
      fails(r'$.clients.codex.hooks.events.afterEverything'),
    );
    final ProductManifest noHooks = acme(
      override: <String, Object?>{
        'clients': <String, Object?>{
          'cursor': <String, Object?>{'hooks': null},
        },
      },
    );
    expect(
      states(status(installer(product: noHooks), 'cursor')).keys,
      isNot(contains('hooks')),
    );
    expect(
      ProductManifest.fromJson(<String, Object?>{
        'schemaVersion': 1,
        'product': 'x',
        'name': 'X',
        'version': '1',
        'mcp': <String, Object?>{
          'name': 'x',
          'command': 'run',
          'args': <String>[r'${session_id}'],
        },
      }),
      isA<ProductManifest>(),
      reason: r'${...} is left for the client',
    );
  });

  test('unknown clients and backups', () {
    expect(
      () => installer().apply(<String>['nope']),
      throwsA(
        isA<AgentInstallException>().having(
          (e) => e.code,
          'code',
          'unknown_client',
        ),
      ),
    );
    write('.cursor/mcp.json', '{}');
    final AgentInstaller i = installer(backups: '${home.path}/b');
    for (int n = 0; n < 7; n++) {
      i.apply(<String>['cursor']);
      i.remove(<String>['cursor']);
      write('.cursor/mcp.json', '{"n": $n}');
    }
    expect(
      Directory(
        '${home.path}/b/cursor',
      ).listSync().where((f) => f.path.contains('mcp.json.')),
      hasLength(5),
    );
  });
}

String fnv1a(List<int> data) {
  int hash = 0xcbf29ce484222325;
  for (final int byte in data) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}
