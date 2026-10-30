import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Runs the installer with a temporary home so no real client is touched.
Future<(int, String)> run(Directory home, List<String> arguments) async {
  final Map<String, String> parent = Platform.environment;
  final ProcessResult result = await Process.run(
    Platform.resolvedExecutable,
    <String>['run', 'bin/agent_installer.dart', ...arguments],
    environment: <String, String>{
      'HOME': home.path,
      'USERPROFILE': home.path,
      'APPDATA': '${home.path}${Platform.pathSeparator}AppData',
      'XDG_CONFIG_HOME': '${home.path}/.config',
      'CODEX_HOME': '',
      'OPENCODE_CONFIG': '',
      if (!Platform.isWindows)
        'PUB_CACHE': parent['PUB_CACHE'] ?? '${parent['HOME']}/.pub-cache',
    },
  );
  return (result.exitCode, result.stdout as String);
}

void main() {
  late Directory home;
  late List<String> product;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('agent-installer-cli-');
    final String bundle = '${Directory.current.path}/example/acme';
    product = <String>[
      '--product',
      '$bundle/acme.manifest.json',
      '--var',
      'acmeMcp=/opt/acme/bin/acme_mcp',
      '--var',
      'bundle=$bundle',
      '--extensions',
      '${home.path}/ext',
      '--backups',
      '${home.path}/backups',
    ];
  });
  tearDown(() => home.delete(recursive: true));

  test('scan, plan, apply, status and remove speak JSON', () async {
    File('${home.path}/.cursor/mcp.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{}\n');
    final (int scanCode, String scanOut) = await run(home, <String>[
      'scan',
      '--extensions',
      '${home.path}/ext',
      '--json',
    ]);
    expect(scanCode, 0);
    final Map<String, Object?> scan =
        jsonDecode(scanOut) as Map<String, Object?>;
    final Map<String, Object?> cursor = (scan['clients']! as List)
        .cast<Map<String, Object?>>()
        .firstWhere((c) => c['id'] == 'cursor');
    expect(cursor['detected'], isTrue);
    expect(cursor['evidence'], contains('~/.cursor'));

    final (int planCode, String planOut) = await run(home, <String>[
      'plan',
      '--clients',
      'cursor',
      ...product,
      '--json',
    ]);
    expect(planCode, 0);
    final Map<String, Object?> plan =
        ((jsonDecode(planOut) as Map)['clients'] as List).single
            as Map<String, Object?>;
    expect(plan['state'], 'not_connected');
    expect(
      (plan['changes']! as List).map((c) => (c as Map)['path']),
      contains('~/.cursor/mcp.json'),
    );
    expect(File('${home.path}/.cursor/mcp.json').readAsStringSync(), '{}\n');

    final (int applyCode, String applyOut) = await run(home, <String>[
      'apply',
      '--clients',
      'cursor',
      ...product,
    ]);
    expect(applyCode, 0);
    expect(applyOut, contains('cursor (Cursor): connected'));
    expect(applyOut, contains('→ Reload Cursor'));

    final (_, String statusOut) = await run(home, <String>[
      'status',
      '--clients',
      'cursor',
      ...product,
      '--json',
    ]);
    expect(
      (((jsonDecode(statusOut) as Map)['clients'] as List).single
          as Map)['state'],
      'connected',
    );

    final (int removeCode, _) = await run(home, <String>[
      'remove',
      '--clients',
      'cursor',
      ...product,
    ]);
    expect(removeCode, 0);
    expect(File('${home.path}/.cursor/mcp.json').existsSync(), isFalse);
  });

  test('errors are structured and nothing is written', () async {
    final File bad = File('${home.path}/bad.json')
      ..writeAsStringSync(
        '{"schemaVersion":1,"product":"x","name":"X","version":"1","mcp":{"name":"x","command":"{nope}"}}',
      );
    final (int code, String out) = await run(home, <String>[
      'apply',
      '--clients',
      'cursor',
      '--product',
      bad.path,
      '--json',
    ]);
    expect(code, 1);
    expect((jsonDecode(out) as Map)['error'], <String, Object?>{
      'code': 'invalid_manifest',
      'message': r'$.mcp.command: unknown placeholder {nope}.',
    });
    final (int missing, String missingOut) = await run(home, <String>[
      'apply',
      ...product,
      '--json',
    ]);
    expect(missing, 1);
    expect(
      ((jsonDecode(missingOut) as Map)['error'] as Map)['code'],
      'invalid_arguments',
    );
    final (int unknown, String unknownOut) = await run(home, <String>[
      'plan',
      '--clients',
      'nope',
      ...product,
      '--json',
    ]);
    expect(unknown, 1);
    expect(
      ((jsonDecode(unknownOut) as Map)['error'] as Map)['code'],
      'unknown_client',
    );
    expect(Directory('${home.path}/.cursor').existsSync(), isFalse);
  });
}
