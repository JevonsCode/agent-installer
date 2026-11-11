// The built-in DeepSeek Harness target: the product's plugin directory is
// copied to {DSH_HOME}/plugins/<product> and registered in every profile
// under {DSH_HOME}/profiles as `dsh plugin --profile <name> add link:<dir>`
// would. Synthetic only: a temporary home, plugin bundle and profiles.
import 'dart:convert';
import 'dart:io';

import 'package:agent_installer/agent_installer.dart';
import 'package:test/test.dart';

late Directory home;
late String bundle;

String get dshHome => '${home.path}${Platform.pathSeparator}.dsh';
String sep = Platform.pathSeparator;

InstallEnvironment env([
  Map<String, String> extra = const <String, String>{},
]) => InstallEnvironment(
  environment: <String, String>{
    'HOME': home.path,
    'USERPROFILE': home.path,
    'PATH': '${home.path}${sep}bin',
    ...extra,
  },
  operatingSystem: Platform.isWindows ? 'windows' : 'linux',
);

AgentInstaller installer({
  String package = 'fuli-dsh',
  Map<String, String> extra = const <String, String>{},
}) {
  File('$bundle${sep}package.json').writeAsStringSync(
    jsonEncode(<String, Object?>{
      'name': package,
      'version': '1.0.0',
      'dsh': <String, Object?>{
        'bundle': <String, Object?>{'patch': './cordis.patch.yml'},
      },
    }),
  );
  return AgentInstaller(
    product: ProductManifest.fromJson(<String, Object?>{
      'schemaVersion': 1,
      'product': 'acme',
      'name': 'Acme',
      'version': '1.0.0',
      'skills': <Object?>[
        <String, Object?>{
          'name': 'acme-helper',
          'source': '${Directory.current.path}/example/acme/skills/acme-helper',
        },
      ],
      'plugin': <String, Object?>{'name': 'acme', 'source': bundle},
    }),
    environment: env(extra),
  );
}

String profileDir(String name) => '$dshHome${sep}profiles$sep$name';

void profile(String name, {List<String>? bundles, Map<String, String>? deps}) {
  final Directory dir = Directory(profileDir(name))
    ..createSync(recursive: true);
  File('${dir.path}${sep}package.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'name': 'dsh-profile-$name',
      'private': true,
      'dependencies': ?deps,
      if (bundles != null)
        'dsh': <String, Object?>{
          'profile': <String, Object?>{'bundles': bundles},
        },
    }),
  );
}

Map<String, Object?> manifestOf(String name) =>
    jsonDecode(File('${profileDir(name)}${sep}package.json').readAsStringSync())
        as Map<String, Object?>;

String installedPlugin() => '$dshHome${sep}plugins${sep}acme';
String spec() => 'link:${installedPlugin().replaceAll(r'\', '/')}';
String linkPath(String name, [String package = 'fuli-dsh']) =>
    <String>[profileDir(name), 'node_modules', ...package.split('/')].join(sep);

ClientStatus status(AgentInstaller i) => i.status(<String>['dsh']).single;
Map<String, String> states(ClientStatus s) => <String, String>{
  for (final ComponentStatus c in s.components) c.component: c.state,
};

void main() {
  setUp(() async {
    home = await Directory.systemTemp.createTemp('agent-installer-dsh-');
    bundle = '${home.path}${sep}bundle';
    Directory(bundle).createSync();
    File(
      '$bundle${sep}index.js',
    ).writeAsStringSync('export const name = "acme";\n');
    File('$bundle${sep}cordis.patch.yml').writeAsStringSync('- insert: []\n');
  });
  tearDown(() => home.delete(recursive: true));

  test('DSH is detected by its profiles folder or the dsh command', () {
    TargetScan scan() =>
        installer().scan().firstWhere((TargetScan s) => s.id == 'dsh');
    expect(scan().detected, isFalse);
    profile('desktop', bundles: <String>['@deepseek-ai/dsh-base']);
    expect(scan().detected, isTrue);
    expect(scan().components, <String>['skills', 'plugin']);
  });

  test(
    'apply copies the plugin and registers it in every profile; status, re-apply and remove',
    () {
      profile('desktop', bundles: <String>['@deepseek-ai/dsh-base']);
      profile(
        'web',
        bundles: <String>['@deepseek-ai/dsh-base', 'other-bundle'],
        deps: <String, String>{'other-bundle': '1.0.0'},
      );
      Directory('$dshHome${sep}profiles${sep}not-a-profile').createSync();
      final AgentInstaller i = installer();
      expect(status(i).state, 'not_connected');

      final ClientResult applied = i.apply(<String>['dsh']).single;
      expect(applied.problems, isEmpty);
      expect(applied.state, 'connected');
      expect(applied.actions, <String>[
        'Restart DeepSeek Harness to load the change.',
      ]);
      expect(File('${installedPlugin()}${sep}index.js').existsSync(), isTrue);
      expect(
        File(
          '$dshHome${sep}skills${sep}acme-helper${sep}SKILL.md',
        ).existsSync(),
        isTrue,
      );
      for (final String name in <String>['desktop', 'web']) {
        final Map<String, Object?> manifest = manifestOf(name);
        expect((manifest['dependencies']! as Map)['fuli-dsh'], spec());
        expect(
          ((manifest['dsh']! as Map)['profile']! as Map)['bundles'],
          contains('fuli-dsh'),
        );
        expect(
          FileSystemEntity.typeSync(linkPath(name), followLinks: false),
          FileSystemEntityType.link,
        );
        expect(File('${linkPath(name)}${sep}index.js').existsSync(), isTrue);
      }
      expect(
        ((manifestOf('web')['dsh']! as Map)['profile']! as Map)['bundles'],
        <String>['@deepseek-ai/dsh-base', 'other-bundle', 'fuli-dsh'],
      );
      expect(states(status(i))['plugin'], 'current');

      final ClientResult again = i.apply(<String>['dsh']).single;
      expect(again.changes, isEmpty, reason: 'idempotent');

      // A link pointing elsewhere is outdated and repaired.
      Link(linkPath('desktop')).deleteSync();
      if (Platform.isWindows) {
        Process.runSync('cmd', <String>[
          '/c',
          'mklink',
          '/J',
          linkPath('desktop'),
          bundle,
        ]);
      } else {
        Link(linkPath('desktop')).createSync(bundle);
      }
      expect(states(status(i))['plugin'], 'outdated');
      i.apply(<String>['dsh']);
      expect(states(status(i))['plugin'], 'current');

      final ClientResult removed = i.remove(<String>['dsh']).single;
      expect(removed.problems, isEmpty);
      expect(Directory(installedPlugin()).existsSync(), isFalse);
      for (final String name in <String>['desktop', 'web']) {
        expect(
          FileSystemEntity.typeSync(linkPath(name), followLinks: false),
          FileSystemEntityType.notFound,
        );
        expect((manifestOf(name)['dependencies'] as Map?)?['fuli-dsh'], isNull);
      }
      expect(
        (manifestOf('web')['dependencies']! as Map)['other-bundle'],
        '1.0.0',
      );
      expect(
        ((manifestOf('web')['dsh']! as Map)['profile']! as Map)['bundles'],
        <String>['@deepseek-ai/dsh-base', 'other-bundle'],
      );
      expect(status(i).state, 'not_connected');
    },
  );

  test(
    'a profile that depends on the name otherwise, or has no bundle list, is left as it is',
    () {
      profile(
        'desktop',
        bundles: <String>['@deepseek-ai/dsh-base'],
        deps: <String, String>{'fuli-dsh': '2.0.0'},
      );
      profile('fresh');
      final AgentInstaller i = installer();
      final String before = File(
        '${profileDir('desktop')}${sep}package.json',
      ).readAsStringSync();
      final ClientResult result = i.apply(<String>['dsh']).single;
      expect(
        result.problems.join('\n'),
        contains('already depends on fuli-dsh (2.0.0)'),
      );
      expect(
        result.problems.join('\n'),
        contains('no dsh.profile.bundles list'),
      );
      expect(
        File('${profileDir('desktop')}${sep}package.json').readAsStringSync(),
        before,
      );
      expect(status(i).state, 'conflict');
      // Removing never touches the person's own dependency.
      i.remove(<String>['dsh']);
      expect(
        (manifestOf('desktop')['dependencies']! as Map)['fuli-dsh'],
        '2.0.0',
      );
    },
  );

  test('a real directory at the link path is the person\'s', () {
    profile('desktop', bundles: <String>['@deepseek-ai/dsh-base']);
    Directory(linkPath('desktop')).createSync(recursive: true);
    final AgentInstaller i = installer();
    final ClientResult result = i.apply(<String>['dsh']).single;
    expect(result.problems.join('\n'), contains('is not a link made by Acme'));
    expect(states(status(i))['plugin'], 'conflict');
    i.remove(<String>['dsh']);
    expect(Directory(linkPath('desktop')).existsSync(), isTrue);
  });

  test(
    'DSH_HOME moves the home, forward slashes included; a scoped package name links under its scope',
    () {
      final String other = '${home.path}${sep}custom-dsh';
      final AgentInstaller i = installer(
        package: '@acme/dsh-plugin',
        // As a shell on Windows often sets it: C:/Users/…
        extra: <String, String>{'DSH_HOME': other.replaceAll(r'\', '/')},
      );
      Directory(
        '$other${sep}profiles${sep}desktop',
      ).createSync(recursive: true);
      File(
        '$other${sep}profiles${sep}desktop${sep}package.json',
      ).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'dsh': <String, Object?>{
            'profile': <String, Object?>{'bundles': <String>[]},
          },
        }),
      );
      expect(i.apply(<String>['dsh']).single.problems, isEmpty);
      expect(
        FileSystemEntity.typeSync(
          <String>[
            other,
            'profiles',
            'desktop',
            'node_modules',
            '@acme',
            'dsh-plugin',
          ].join(sep),
          followLinks: false,
        ),
        FileSystemEntityType.link,
      );
    },
  );

  test('a plugin source without a package name is reported, not guessed', () {
    profile('desktop', bundles: <String>[]);
    final AgentInstaller i = installer(package: 'Not A Name');
    expect(
      status(i).components.where((c) => c.component == 'plugin').single.state,
      'conflict',
    );
  });
}
