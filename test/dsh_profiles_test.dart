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

/// A directory link as pnpm makes it: a junction on Windows.
void directoryLink(String path, String target) {
  Directory(path).parent.createSync(recursive: true);
  if (Platform.isWindows) {
    Process.runSync('cmd', <String>['/c', 'mklink', '/J', path, target]);
  } else {
    Link(path).createSync(target);
  }
}

String linkTarget(String path) => Link(path).targetSync();
String text(String path) => File(path).readAsStringSync();

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
    'another version of the name, with the link pnpm made to it, is left whole on apply and remove',
    () {
      // A profile where the person installed fuli-dsh 2.0.0 (say, the public
      // connector's package of that name) before connecting the product.
      final String store = '${home.path}${sep}pnpm-store${sep}fuli-dsh@2.0.0';
      Directory(store).createSync(recursive: true);
      File(
        '$store${sep}index.js',
      ).writeAsStringSync('export const name = "theirs";\n');
      profile(
        'desktop',
        bundles: <String>['@deepseek-ai/dsh-base', 'fuli-dsh'],
        deps: <String, String>{'fuli-dsh': '2.0.0'},
      );
      directoryLink(linkPath('desktop'), store);
      profile('web', bundles: <String>['@deepseek-ai/dsh-base']);
      final String manifest = '${profileDir('desktop')}${sep}package.json';
      final String before = text(manifest);
      final String linkBefore = linkTarget(linkPath('desktop'));
      final AgentInstaller i = installer();

      // Removing before any connection touches nothing of theirs either.
      expect(i.remove(<String>['dsh']).single.changes, isEmpty);
      expect(linkTarget(linkPath('desktop')), linkBefore);

      final ClientResult applied = i.apply(<String>['dsh']).single;
      expect(
        applied.problems.join('\n'),
        allOf(
          contains('desktop'),
          contains('already depends on fuli-dsh (2.0.0)'),
        ),
      );
      expect(text(manifest), before);
      expect(linkTarget(linkPath('desktop')), linkBefore);
      expect(File('$store${sep}index.js').existsSync(), isTrue);
      // The other profile is the product's, and connected.
      expect((manifestOf('web')['dependencies']! as Map)['fuli-dsh'], spec());
      expect(linkTarget(linkPath('web')), isNotEmpty);
      expect(status(i).state, 'conflict');

      i.remove(<String>['dsh']);
      expect(text(manifest), before);
      expect(linkTarget(linkPath('desktop')), linkBefore);
      expect(File('$store${sep}index.js').existsSync(), isTrue);
      expect(
        FileSystemEntity.typeSync(linkPath('web'), followLinks: false),
        FileSystemEntityType.notFound,
      );
    },
  );

  test(
    'a link elsewhere with no dependency, or a real directory there, is the person\'s',
    () {
      final String elsewhere = '${home.path}${sep}elsewhere';
      Directory(elsewhere).createSync();
      profile('desktop', bundles: <String>['@deepseek-ai/dsh-base']);
      directoryLink(linkPath('desktop'), elsewhere);
      profile('web', bundles: <String>['@deepseek-ai/dsh-base']);
      Directory(linkPath('web')).createSync(recursive: true);
      final String desktopBefore = text(
        '${profileDir('desktop')}${sep}package.json',
      );
      final String webBefore = text('${profileDir('web')}${sep}package.json');
      final AgentInstaller i = installer();
      final String problems = i
          .apply(<String>['dsh'])
          .single
          .problems
          .join('\n');
      expect(problems, contains('node_modules/fuli-dsh links to'));
      expect(
        problems,
        contains('node_modules/fuli-dsh exists and is not a link'),
      );
      expect(states(status(i))['plugin'], 'conflict');
      i.remove(<String>['dsh']);
      expect(linkTarget(linkPath('desktop')), contains('elsewhere'));
      expect(Directory(linkPath('web')).existsSync(), isTrue);
      expect(text('${profileDir('desktop')}${sep}package.json'), desktopBefore);
      expect(text('${profileDir('web')}${sep}package.json'), webBefore);
    },
  );

  test(
    'a profile whose node_modules is a link is left alone, so nothing is written outside it',
    () {
      final String outside = '${home.path}${sep}outside-modules';
      Directory(outside).createSync();
      profile('desktop', bundles: <String>['@deepseek-ai/dsh-base']);
      directoryLink('${profileDir('desktop')}${sep}node_modules', outside);
      final String before = text('${profileDir('desktop')}${sep}package.json');
      final AgentInstaller i = installer();
      expect(
        i.apply(<String>['dsh']).single.problems.join('\n'),
        contains('node_modules is not a plain directory'),
      );
      expect(Directory(outside).listSync(), isEmpty);
      expect(text('${profileDir('desktop')}${sep}package.json'), before);
    },
  );

  test(
    'a profile changed by hand after connecting is left as it is by remove',
    () {
      final String elsewhere = '${home.path}${sep}elsewhere';
      Directory(elsewhere).createSync();
      profile('desktop', bundles: <String>['@deepseek-ai/dsh-base']);
      final AgentInstaller i = installer();
      expect(i.apply(<String>['dsh']).single.problems, isEmpty);
      // The person points the package somewhere else themselves.
      Link(linkPath('desktop')).deleteSync();
      directoryLink(linkPath('desktop'), elsewhere);
      final String before = text('${profileDir('desktop')}${sep}package.json');
      i.remove(<String>['dsh']);
      expect(linkTarget(linkPath('desktop')), contains('elsewhere'));
      expect(text('${profileDir('desktop')}${sep}package.json'), before);
    },
  );

  test('a profile without a bundle list is reported and left as it is', () {
    profile('fresh');
    final String before = text('${profileDir('fresh')}${sep}package.json');
    final AgentInstaller i = installer();
    expect(
      i.apply(<String>['dsh']).single.problems.join('\n'),
      contains('no dsh.profile.bundles list'),
    );
    expect(text('${profileDir('fresh')}${sep}package.json'), before);
    expect(
      FileSystemEntity.typeSync(linkPath('fresh'), followLinks: false),
      FileSystemEntityType.notFound,
    );
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
