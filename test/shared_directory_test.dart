import 'dart:io';

import 'package:agent_installer/agent_installer.dart';
import 'package:test/test.dart';

// The shared root, its layout and the 0.1 fallback are a convention with
// agent-session-launcher; its tests guard the same paths.
void main() {
  test('the shared root and its layout follow each platform convention', () {
    expect(
      defaultSharedDirectory(
        environment: const <String, String>{'HOME': '/Users/me'},
        operatingSystem: 'macos',
      ),
      '/Users/me/.config/agent-clients',
    );
    expect(
      defaultExtensionsDirectory(
        environment: const <String, String>{
          'HOME': '/home/me',
          'XDG_CONFIG_HOME': '/cfg',
        },
        operatingSystem: 'linux',
      ),
      '/cfg/agent-clients/extensions',
    );
    expect(
      defaultExtensionsDirectory(
        environment: const <String, String>{
          'HOME': '/home/me',
          'XDG_CONFIG_HOME': 'relative',
        },
        operatingSystem: 'linux',
      ),
      '/home/me/.config/agent-clients/extensions',
    );
    expect(
      defaultExtensionsDirectory(
        environment: const <String, String>{
          'APPDATA': r'C:\Users\me\AppData\Roaming',
        },
        operatingSystem: 'windows',
      ),
      r'C:\Users\me\AppData\Roaming\agent-clients\extensions',
    );
    expect(
      defaultBackupsDirectory(
        'acme',
        environment: const <String, String>{
          'APPDATA': r'C:\Users\me\AppData\Roaming',
        },
        operatingSystem: 'windows',
      ),
      r'C:\Users\me\AppData\Roaming\agent-clients\backups\acme',
    );
    expect(
      defaultBackupsDirectory(
        'acme',
        environment: const <String, String>{'HOME': '/home/me'},
        operatingSystem: 'linux',
      ),
      '/home/me/.config/agent-clients/backups/acme',
    );
    expect(
      defaultExtensionsDirectory(
        environment: const <String, String>{},
        operatingSystem: 'windows',
      ),
      isNull,
    );
    expect(
      defaultBackupsDirectory(
        'acme',
        environment: const <String, String>{},
        operatingSystem: 'linux',
      ),
      isNull,
    );
  });

  test('the old directory is read until the new one exists', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'agent-installer-shared-',
    );
    addTearDown(() => root.delete(recursive: true));
    final String os = Platform.isWindows ? 'windows' : 'linux';
    final String sep = Platform.pathSeparator;
    final Map<String, String> env = <String, String>{
      'APPDATA': root.path,
      'XDG_CONFIG_HOME': root.path,
    };
    String? resolve() =>
        defaultExtensionsDirectory(environment: env, operatingSystem: os);
    final String current = '${root.path}${sep}agent-clients${sep}extensions';
    final String legacy =
        '${root.path}${sep}agent-session-launcher${sep}clients';

    expect(resolve(), current);
    Directory(legacy).createSync(recursive: true);
    expect(resolve(), legacy);
    Directory(current).createSync(recursive: true);
    expect(resolve(), current);
    expect(Directory(legacy).existsSync(), isTrue, reason: 'never moved');
    expect(
      defaultBackupsDirectory('acme', environment: env, operatingSystem: os),
      '${root.path}${sep}agent-clients${sep}backups${sep}acme',
      reason: 'backups always use the new root',
    );
  });
}
