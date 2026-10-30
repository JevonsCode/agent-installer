// Shared with agent-session-launcher: both read the same per-user directory,
// one `<client-id>.json` per client, with the same limits. This package reads
// only `install`; the launcher reads the other fields and ignores `install`.
// The installer also keeps its backups under `backups/<product>` in the same
// root. Keep the root, the layout and the limits in step with that
// repository; the tests of both repositories guard this convention.

import 'dart:convert';
import 'dart:io';

/// At most this many `.json` files are loaded from one directory.
const int maxExtensionFiles = 64;

/// Each extension file is at most this many bytes.
const int maxExtensionBytes = 16384;

/// The per-user root that agent-clients components share: `agent-clients`
/// under `%APPDATA%` on Windows, and under `$XDG_CONFIG_HOME` (when absolute)
/// or `~/.config` elsewhere. Null when the environment names no such base.
String? defaultSharedDirectory({
  Map<String, String>? environment,
  String? operatingSystem,
}) => _under(environment, operatingSystem, 'agent-clients', null);

/// The per-user directory that every host shares for hand-written client
/// files, `<shared root>/extensions`, or null when the environment does not
/// name a home directory.
///
/// While that directory does not exist, a directory left at the location
/// used before 0.2 (`agent-session-launcher/clients`) is returned instead, so
/// existing files keep working. Files are never moved automatically.
String? defaultExtensionsDirectory({
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  final String? current = _under(
    environment,
    operatingSystem,
    'agent-clients',
    'extensions',
  );
  final String? legacy = _under(
    environment,
    operatingSystem,
    'agent-session-launcher',
    'clients',
  );
  return current != null &&
          !Directory(current).existsSync() &&
          Directory(legacy!).existsSync()
      ? legacy
      : current;
}

/// Where originals are copied before [product] changes a client:
/// `<shared root>/backups/<product>`.
String? defaultBackupsDirectory(
  String product, {
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  final String? root = defaultSharedDirectory(
    environment: environment,
    operatingSystem: operatingSystem,
  );
  if (root == null) return null;
  final String sep = (operatingSystem ?? Platform.operatingSystem) == 'windows'
      ? r'\'
      : '/';
  return '$root${sep}backups$sep$product';
}

String? _under(
  Map<String, String>? environment,
  String? operatingSystem,
  String first,
  String? second,
) {
  final Map<String, String> env = environment ?? Platform.environment;
  final bool windows =
      (operatingSystem ?? Platform.operatingSystem) == 'windows';
  final String? base;
  if (windows) {
    final String? appData = env['APPDATA'];
    base = appData == null || appData.isEmpty ? null : appData;
  } else {
    final String? xdg = env['XDG_CONFIG_HOME'];
    final String? home = env['HOME'];
    base = xdg != null && xdg.startsWith('/')
        ? xdg
        : home == null || home.isEmpty
        ? null
        : '$home/.config';
  }
  if (base == null) return null;
  final String sep = windows ? r'\' : '/';
  return second == null ? '$base$sep$first' : '$base$sep$first$sep$second';
}

/// One user-written client file. Exactly one of [text] and [error] is set.
final class ExtensionFile {
  const ExtensionFile(this.name, String this.text) : error = null;
  const ExtensionFile.unreadable(this.name, String this.error) : text = null;

  /// The file name, e.g. `acme-agent.json`; null for a directory problem.
  final String? name;
  final String? text;
  final String? error;
}

/// Why one extension file was not loaded. Only the file name is reported.
final class ExtensionProblem {
  const ExtensionProblem(this.file, this.message);

  final String? file;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    if (file != null) 'file': file,
    'message': message,
  };
}

/// Reads the `.json` files directly inside [path], sorted by name. A missing
/// directory has no extensions; hidden files and other names are ignored.
List<ExtensionFile> readExtensionDirectory(String path) {
  final Directory directory = Directory(path);
  final List<File> files;
  try {
    if (!directory.existsSync()) return const <ExtensionFile>[];
    if (_writableByOthers(directory.statSync())) {
      return const <ExtensionFile>[
        ExtensionFile.unreadable(
          null,
          'The extensions directory is writable by other users.',
        ),
      ];
    }
    files = directory.listSync(followLinks: true).whereType<File>().where((
      File file,
    ) {
      final String name = _fileName(file.path);
      return name.endsWith('.json') && !name.startsWith('.');
    }).toList()..sort((a, b) => _fileName(a.path).compareTo(_fileName(b.path)));
  } on FileSystemException {
    return const <ExtensionFile>[
      ExtensionFile.unreadable(
        null,
        'The extensions directory could not be read.',
      ),
    ];
  }
  return <ExtensionFile>[
    for (final (int index, File file) in files.indexed)
      index < maxExtensionFiles
          ? readExtensionFile(file.path)
          : ExtensionFile.unreadable(
              _fileName(file.path),
              'Only the first $maxExtensionFiles extension files are loaded.',
            ),
  ];
}

/// Reads one extension file, refusing files other users could change.
ExtensionFile readExtensionFile(String path) {
  final String name = _fileName(path);
  try {
    final File file = File(path);
    final FileStat stat = file.statSync();
    if (stat.type != FileSystemEntityType.file) {
      return ExtensionFile.unreadable(name, 'The file does not exist.');
    }
    if (_writableByOthers(stat)) {
      return ExtensionFile.unreadable(
        name,
        'The file is writable by other users.',
      );
    }
    final List<int> bytes = stat.size > maxExtensionBytes
        ? const <int>[]
        : file.readAsBytesSync();
    if (stat.size > maxExtensionBytes || bytes.length > maxExtensionBytes) {
      return ExtensionFile.unreadable(name, 'The file is larger than 16 KiB.');
    }
    return ExtensionFile(name, utf8.decode(bytes));
  } on Object {
    return ExtensionFile.unreadable(
      name,
      'The file could not be read as UTF-8 text.',
    );
  }
}

bool _writableByOthers(FileStat stat) =>
    !Platform.isWindows && stat.mode & 0x2 != 0;

String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;
