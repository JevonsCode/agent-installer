import 'dart:convert';
import 'dart:io';
import 'package:agent_installer/agent_installer.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('chengxiaobang-'));
  tearDown(() => home.deleteSync(recursive: true));
  File file(String name) => File('${home.path}/client/$name');
  AgentInstaller installer([String version = '1']) => AgentInstaller(
    environment: InstallEnvironment(
      environment: {
        'HOME': home.path,
        'PATH': '',
        'CHENGXIAOBANG_HOME': '${home.path}/client',
      },
      operatingSystem: 'macos',
    ),
    product: ProductManifest.fromJson({
      'schemaVersion': 1,
      'product': 'acme',
      'name': 'Acme',
      'version': version,
      'mcp': {
        'name': 'acme',
          'markers': ['/acme/server.js'],
        'command': '/node $version',
        'args': ['/acme/server.js'],
      },
      'hooks': {
        'markers': ['/acme/hook.js'],
        'events': {
          'userPromptSubmit': {
            'command': ['/node $version', '/acme/hook.js'],
            'timeoutSec': 20,
          },
          'stop': {
            'command': ['/node $version', '/acme/hook.js'],
            'timeoutSec': 20,
          },
        },
      },
    }),
  );
  Map<String, dynamic> hooks() =>
      jsonDecode(file('hooks.json').readAsStringSync());

  test(
    'detect, install, repeat, refresh and remove preserve foreign configuration',
    () {
      file('mcp.json').parent.createSync(recursive: true);
      file(
        'mcp.json',
      ).writeAsStringSync('{"mcpServers":{"other":{"command":"other"}}}');
      final foreign = {
        'id': 'dingdong',
        'event': 'Stop',
        'command': 'dingdong notify',
        'enabled': true,
      };
      file('hooks.json').writeAsStringSync(
        jsonEncode({
          'enabled': true,
          'custom': 1,
          'hooks': [foreign],
        }),
      );
      final i = installer();
      expect(
        i.scan().firstWhere((s) => s.id == 'chengxiaobang').detected,
        isTrue,
      );
      i.apply(['chengxiaobang']);
      expect(hooks()['hooks'].length, 3);
      expect(hooks()['hooks'][0], foreign);
      expect(hooks()['hooks'][1]['event'], 'UserPromptSubmit');
      expect(hooks()['hooks'][1]['timeoutSeconds'], 20);
      final before = file('hooks.json').readAsStringSync();
      i.apply(['chengxiaobang']);
      expect(file('hooks.json').readAsStringSync(), before);
      installer('2').apply(['chengxiaobang']);
      expect(hooks()['hooks'].length, 3);
      expect(hooks()['hooks'][1]['command'], contains('/node 2'));
      installer('2').remove(['chengxiaobang']);
      expect(hooks(), {
        'enabled': true,
        'custom': 1,
        'hooks': [foreign],
      });
      expect(jsonDecode(file('mcp.json').readAsStringSync())['mcpServers'], {
        'other': {'command': 'other'},
      });
    },
  );

  test('new hooks file is enabled; disabled global hooks stay disabled', () {
    file('mcp.json').parent.createSync(recursive: true);
    installer().apply(['chengxiaobang']);
    expect(hooks()['enabled'], true);
    file('hooks.json').writeAsStringSync('{"enabled":false,"hooks":[]}');
    installer().apply(['chengxiaobang']);
    expect(hooks(), {'enabled': false, 'hooks': []});
    expect(
      installer().status(['chengxiaobang']).single.state,
      isNot('connected'),
    );
  });

  test('foreign ID collision and malformed JSON are not overwritten', () {
    file('mcp.json').parent.createSync(recursive: true);
    for (final text in [
      '{broken',
      jsonEncode({
        'enabled': true,
        'hooks': [
          {
            'id': 'acme-Stop',
            'event': 'Stop',
            'command': 'foreign',
            'enabled': true,
          },
        ],
      }),
    ]) {
      file('hooks.json').writeAsStringSync(text);
      installer().apply(['chengxiaobang']);
      expect(file('hooks.json').readAsStringSync(), text);
    }
  });
}
