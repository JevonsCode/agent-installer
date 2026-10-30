import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'components.dart';
import 'environment.dart';
import 'errors.dart';
import 'manifest.dart';
import 'targets.dart';

/// Whether a client is present, independent of any product.
final class TargetScan {
  const TargetScan({
    required this.id,
    required this.name,
    required this.detected,
    required this.evidence,
    required this.components,
    required this.builtin,
    this.platformSupported = true,
    this.manual,
    this.extensionFile,
  });

  final String id;
  final String name;
  final bool detected;

  /// What showed the client is installed, e.g. `~/.codex/config.toml`.
  final List<String> evidence;
  final List<String> components;
  final bool builtin;
  final bool platformSupported;

  /// Why the client must be configured by hand, if it must.
  final String? manual;
  final String? extensionFile;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'detected': detected,
    'evidence': evidence,
    'components': components,
    'builtin': builtin,
    'platformSupported': platformSupported,
    'manual': ?manual,
    'extensionFile': ?extensionFile,
  };
}

/// One component's state in one client.
final class ComponentStatus {
  const ComponentStatus(this.component, this.state, [this.message]);
  final String component;

  /// `current`, `outdated`, `missing`, `conflict` or `unsupported`.
  final String state;
  final String? message;

  Map<String, Object?> toJson() => <String, Object?>{
    'component': component,
    'state': state,
    'message': ?message,
  };
}

/// A product's state in one client.
final class ClientStatus {
  const ClientStatus(this.scan, this.state, this.components);
  final TargetScan scan;

  /// `connected`, `update_available`, `not_connected`, `conflict`, `manual`
  /// or `unsupported`.
  final String state;
  final List<ComponentStatus> components;

  Map<String, Object?> toJson() => <String, Object?>{
    ...scan.toJson(),
    'state': state,
    'componentStates': <Object?>[for (final c in components) c.toJson()],
  };
}

/// One file or directory a plan would change.
final class PlannedChange {
  const PlannedChange(this.path, this.components, this.action, [this.diff]);
  final String path;
  final List<String> components;

  /// `create`, `update`, `delete`, or `adopt` when an existing directory
  /// that already holds the product's files only gets its receipt.
  final String action;
  final String? diff;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'components': components,
    'action': action,
    'diff': ?diff,
  };
}

/// The outcome, or the dry run, of installing into or removing from a client.
final class ClientResult {
  const ClientResult(
    this.id,
    this.name,
    this.state,
    this.changes,
    this.problems,
    this.actions,
  );
  final String id;
  final String name;

  /// The client's state afterwards; for a plan, its current state.
  final String state;
  final List<PlannedChange> changes;
  final List<String> problems;

  /// What the person still has to do, e.g. restart the client.
  final List<String> actions;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'state': state,
    'changes': <Object?>[for (final c in changes) c.toJson()],
    'problems': problems,
    'actions': actions,
  };
}

/// Detects agent clients and installs one product's integration into the
/// clients a person selects. It edits only entries the product owns,
/// identified by its MCP name, hook markers, instruction markers and
/// directory receipts, so installs by hand are recognized too.
final class AgentInstaller {
  AgentInstaller({
    required this.product,
    InstallTargets? targets,
    InstallEnvironment? environment,
    this.backupDirectory,
  }) : targets = targets ?? InstallTargets.defaults,
       env = environment ?? InstallEnvironment();

  final ProductManifest product;
  final InstallTargets targets;
  final InstallEnvironment env;

  /// Where originals are copied before a change; null keeps no backups.
  final String? backupDirectory;

  List<TargetScan> scan() => scanTargets(targets, env);

  List<ClientStatus> status([List<String>? clients]) => <ClientStatus>[
    for (final InstallTarget t in _select(
      clients ?? targets.targets.keys.toList(),
    ))
      _status(t),
  ];

  List<ClientResult> plan(List<String> clients) => <ClientResult>[
    for (final t in _select(clients)) _run(t, install: true, write: false),
  ];

  List<ClientResult> apply(List<String> clients) => <ClientResult>[
    for (final t in _select(clients)) _run(t, install: true, write: true),
  ];

  List<ClientResult> remove(List<String> clients) => <ClientResult>[
    for (final t in _select(clients)) _run(t, install: false, write: true),
  ];

  List<InstallTarget> _select(List<String> ids) => <InstallTarget>[
    for (final String id in ids)
      targets.targets[id] ??
          (throw AgentInstallException(
            'unknown_client',
            'Unknown client "$id".',
          )),
  ];

  ClientStatus _status(InstallTarget target) {
    final TargetScan scan = scanTarget(target, env);
    if (!scan.platformSupported) {
      return ClientStatus(scan, 'unsupported', const <ComponentStatus>[]);
    }
    final ResolvedProduct resolved = product.forTarget(target);
    final ClientWork work = buildWork(target, resolved, env);
    final List<ComponentStatus> states = <ComponentStatus>[];
    final List<String> order = <String>[];
    for (final TextPart p in work.text) {
      if (!order.contains(p.component)) order.add(p.component);
    }
    for (final String component in order) {
      states.add(
        _textState(component, work.text.where((p) => p.component == component)),
      );
    }
    for (final String component in <String>{
      for (final DirectoryPart d in work.directories) d.component,
    }) {
      final List<_DirState> dirs = <_DirState>[
        for (final DirectoryPart d in work.directories)
          if (d.component == component) _dirState(d, resolved),
      ];
      final _DirState? conflict = dirs
          .where((d) => d.state == 'conflict')
          .firstOrNull;
      states.add(
        ComponentStatus(
          component,
          conflict != null
              ? 'conflict'
              : dirs.every((d) => d.state == 'current')
              ? 'current'
              : dirs.every((d) => d.state == 'missing')
              ? 'missing'
              : 'outdated',
          conflict?.message,
        ),
      );
    }
    states
      ..addAll(<ComponentStatus>[
        for (final MapEntry<String, String> e in work.blocked.entries)
          ComponentStatus(e.key, 'conflict', e.value),
      ])
      ..addAll(<ComponentStatus>[
        for (final String c in work.unsupported)
          ComponentStatus(c, 'unsupported'),
      ]);
    final List<String> active = <String>[
      for (final ComponentStatus s in states)
        if (s.state != 'unsupported') s.state,
    ];
    final String state = scan.manual != null
        ? 'manual'
        : active.isEmpty
        ? 'unsupported'
        : active.contains('conflict')
        ? 'conflict'
        : active.every((s) => s == 'current')
        ? 'connected'
        : active.every((s) => s == 'missing')
        ? 'not_connected'
        : 'update_available';
    return ClientStatus(scan, state, states);
  }

  ComponentStatus _textState(String component, Iterable<TextPart> parts) {
    try {
      bool present = false;
      bool current = true;
      for (final TextPart p in parts) {
        final String? text = _read(p.path);
        present = present || p.present(text);
        current = current && p.install(text) == text;
      }
      return ComponentStatus(
        component,
        !present ? 'missing' : (current ? 'current' : 'outdated'),
      );
    } on FormatException catch (error) {
      return ComponentStatus(component, 'conflict', error.message);
    }
  }

  ClientResult _run(
    InstallTarget target, {
    required bool install,
    required bool write,
  }) {
    final TargetScan scan = scanTarget(target, env);
    if (!scan.platformSupported || scan.manual != null) {
      return ClientResult(
        target.id,
        target.name,
        scan.platformSupported ? 'manual' : 'unsupported',
        const <PlannedChange>[],
        <String>[
          scan.manual ?? '${target.name} is not available on this platform.',
        ],
        const <String>[],
      );
    }
    final ResolvedProduct resolved = product.forTarget(target);
    final ClientWork work = buildWork(target, resolved, env);
    final List<String> problems = <String>[
      for (final MapEntry<String, String> e in work.blocked.entries)
        '${e.key}: ${e.value}',
    ];
    final List<PlannedChange> changes = <PlannedChange>[];
    final Map<String, List<TextPart>> byFile = <String, List<TextPart>>{};
    for (final TextPart p in work.text) {
      (byFile[p.path] ??= <TextPart>[]).add(p);
    }
    for (final MapEntry<String, List<TextPart>> file in byFile.entries) {
      final PlannedChange? change = _editFile(
        target,
        file.key,
        file.value,
        install: install,
        write: write,
        problems: problems,
      );
      if (change != null) changes.add(change);
    }
    for (final DirectoryPart d in work.directories) {
      final PlannedChange? change = _editDirectory(
        target.id,
        d,
        resolved,
        install: install,
        write: write,
        problems: problems,
      );
      if (change != null) changes.add(change);
    }
    final bool hooksChanged = changes.any(
      (c) => c.components.contains('hooks'),
    );
    final List<String> actions = changes.isEmpty || !install
        ? const <String>[]
        : <String>[
            ...target.afterInstall,
            if (hooksChanged && target.hooks?.format == 'codex-hooks')
              'Review and trust the new hooks in Codex with /hooks.',
          ];
    return ClientResult(
      target.id,
      target.name,
      _status(target).state,
      changes,
      problems,
      actions,
    );
  }

  PlannedChange? _editFile(
    InstallTarget target,
    String path,
    List<TextPart> parts, {
    required bool install,
    required bool write,
    required List<String> problems,
  }) {
    for (int attempt = 0; attempt < 3; attempt++) {
      final String? before = _read(path);
      String? after = before;
      final List<String> touched = <String>[];
      for (final TextPart p in parts) {
        try {
          final String? next = install ? p.install(after) : p.uninstall(after);
          if (next != after) touched.add(p.component);
          after = next;
        } on FormatException catch (error) {
          problems.add(
            '${p.component}: ${env.display(path)}: ${error.message}',
          );
        }
      }
      // Removing the last entry of a JSON file deletes the file instead of
      // leaving an empty object behind. A file that was already empty is
      // the person's and stays.
      if (!install && after != before && after?.trim() == '{}') after = null;
      if (after == before) return null;
      final String action = before == null
          ? 'create'
          : after == null
          ? 'delete'
          : 'update';
      final PlannedChange change = PlannedChange(
        env.display(path),
        touched.toSet().toList(),
        action,
        _diff(before, after),
      );
      if (!write) return change;
      // The client may rewrite its own file meanwhile (Claude Code does);
      // edit again from the new content rather than overwrite it.
      if (_read(path) != before) continue;
      _backup(target.id, path, before);
      _write(path, after);
      return change;
    }
    problems.add('${env.display(path)} kept changing; try again.');
    return null;
  }

  PlannedChange? _editDirectory(
    String clientId,
    DirectoryPart part,
    ResolvedProduct resolved, {
    required bool install,
    required bool write,
    required List<String> problems,
  }) {
    final _DirState state = _dirState(part, resolved);
    final String shown = env.display(part.target);
    if (state.state == 'conflict') {
      if (install || state.ours)
        problems.add('${part.component}: $shown: ${state.message}');
      return null;
    }
    if (install) {
      if (state.state == 'current') {
        if (!state.adopt) return null;
        // Already the product's files: only the receipt is added.
        if (write) _writeReceipt(part.target, state.source!, resolved);
        return PlannedChange(shown, <String>[part.component], 'adopt');
      }
      final PlannedChange change = PlannedChange(shown, <String>[
        part.component,
      ], state.state == 'missing' ? 'create' : 'update');
      if (write) {
        _backupDirectory(clientId, part.target);
        _copyDirectory(part, state.source!, resolved);
      }
      return change;
    }
    if (state.state == 'missing') return null;
    if (write) {
      _backupDirectory(clientId, part.target);
      Directory(part.target).deleteSync(recursive: true);
    }
    return PlannedChange(shown, <String>[part.component], 'delete');
  }

  _DirState _dirState(DirectoryPart part, ResolvedProduct resolved) {
    final Map<String, String> source;
    try {
      source = _hashTree(part.source);
    } on Object {
      return _DirState(
        'conflict',
        'The product source ${part.source} cannot be read.',
      );
    }
    final Directory target = Directory(part.target);
    if (!target.existsSync()) return _DirState('missing', null, source: source);
    final File receiptFile = File('${part.target}${env.separator}$_receipt');
    Map<String, Object?>? receipt;
    bool foreign = false;
    try {
      final Object? json = jsonDecode(receiptFile.readAsStringSync());
      if (json is Map<String, Object?> && json['product'] == resolved.product) {
        receipt = json;
      } else {
        foreign = json is Map<String, Object?> && json['product'] is String;
      }
    } on Object {
      receipt = null;
    }
    final Map<String, String> actual;
    try {
      actual = _hashTree(part.target)..remove(_receipt);
    } on Object {
      return _DirState('conflict', 'It cannot be read.');
    }
    if (receipt == null || receipt['files'] is! Map) {
      // A directory without the product's receipt is taken over only when it
      // already holds exactly the product's files, or carries the marker the
      // manifest names; another product's receipt is never taken over.
      if (!foreign && deepEquals(actual, source)) {
        return _DirState(
          'current',
          null,
          source: source,
          ours: true,
          adopt: true,
        );
      }
      if (!foreign && _hasAdoptMarker(part)) {
        return _DirState(
          'outdated',
          null,
          source: source,
          ours: true,
          adopt: true,
        );
      }
      return _DirState(
        'conflict',
        'It exists and is not managed by ${product.name}.',
      );
    }
    if (!deepEquals(actual, receipt['files'])) {
      return _DirState(
        'conflict',
        'It was changed by hand, so it is left as it is.',
        ours: true,
      );
    }
    return _DirState(
      deepEquals(actual, source) ? 'current' : 'outdated',
      null,
      source: source,
      ours: true,
    );
  }

  void _copyDirectory(
    DirectoryPart part,
    Map<String, String> files,
    ResolvedProduct resolved,
  ) {
    final Directory target = Directory(part.target);
    final String parent = target.parent.path;
    final String name = target.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final Directory staging = Directory(
      '$parent${env.separator}.$name.agent-installer-new',
    );
    final Directory old = Directory(
      '$parent${env.separator}.$name.agent-installer-old',
    );
    for (final Directory d in <Directory>[staging, old]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    staging.createSync(recursive: true);
    for (final String relative in files.keys) {
      final File to = File(
        '${staging.path}${env.separator}${_native(relative)}',
      );
      to.parent.createSync(recursive: true);
      File(
        '${part.source}${env.separator}${_native(relative)}',
      ).copySync(to.path);
    }
    _writeReceipt(staging.path, files, resolved);
    if (target.existsSync()) target.renameSync(old.path);
    staging.renameSync(target.path);
    if (old.existsSync()) old.deleteSync(recursive: true);
  }

  void _writeReceipt(
    String directory,
    Map<String, String> files,
    ResolvedProduct resolved,
  ) => File('$directory${env.separator}$_receipt').writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'product': resolved.product, 'version': resolved.version, 'files': files})}\n',
  );

  bool _hasAdoptMarker(DirectoryPart part) {
    final AdoptMarker? marker = part.adopt;
    if (marker == null) return false;
    final File file = File(
      '${part.target}${env.separator}${_native(marker.file)}',
    );
    try {
      if (!file.existsSync()) return false;
      return marker.contains == null ||
          file.readAsStringSync().contains(marker.contains!);
    } on Object {
      return false;
    }
  }

  Map<String, String> _hashTree(String root) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) throw FileSystemException('missing', root);
    final Map<String, String> files = <String, String>{};
    int bytes = 0;
    final List<File> entries = dir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
    if (entries.length > 500) throw FileSystemException('too many files', root);
    for (final File file in entries) {
      final List<int> data = file.readAsBytesSync();
      bytes += data.length;
      if (bytes > 20 * 1024 * 1024)
        throw FileSystemException('too large', root);
      final String relative = file.path
          .substring(root.length + 1)
          .replaceAll(r'\', '/');
      files[relative] = _fnv1a(data);
    }
    return Map<String, String>.fromEntries(
      files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  }

  String _native(String relative) =>
      env.windows ? relative.replaceAll('/', r'\') : relative;

  String? _read(String path) {
    final File file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// Atomic replacement that keeps a symlinked file's link and its mode.
  void _write(String path, String? content) {
    final File file = File(path);
    if (content == null) {
      if (file.existsSync()) file.deleteSync();
      return;
    }
    final String real = file.existsSync()
        ? file.resolveSymbolicLinksSync()
        : path;
    final File target = File(real);
    target.parent.createSync(recursive: true);
    final int mode = target.existsSync()
        ? target.statSync().mode & 0x1ff
        : 0x180;
    final String name = target.uri.pathSegments.last;
    final File temp = File(
      '${target.parent.path}${env.separator}.$name.agent-installer.tmp',
    );
    temp.writeAsStringSync(content, flush: true);
    _restrict(temp.path, mode);
    temp.renameSync(real);
  }

  void _backup(String clientId, String path, String? before) {
    final Directory? dir = _backupFolder(clientId);
    if (dir == null || before == null) return;
    final String name = File(path).uri.pathSegments.last;
    final File backup = File(
      '${dir.path}${env.separator}$name.${_stamp()}.bak',
    );
    // Configs can hold tokens: create the copy private before writing to it.
    backup.createSync();
    _restrict(backup.path, 0x180);
    backup.writeAsStringSync(before);
    _prune(dir, name);
  }

  /// Copies a directory the product is about to replace or delete, kept like
  /// file backups: the 5 most recent per name.
  void _backupDirectory(String clientId, String path) {
    final Directory source = Directory(path);
    final Directory? dir = _backupFolder(clientId);
    if (dir == null || !source.existsSync()) return;
    final String name = source.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final Directory backup = Directory(
      '${dir.path}${env.separator}$name.${_stamp()}.bak',
    )..createSync();
    _restrict(backup.path, 0x1c0);
    for (final FileSystemEntity entry in source.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is! File) continue;
      final File to = File(
        '${backup.path}${entry.path.substring(source.path.length)}',
      );
      to.parent.createSync(recursive: true);
      entry.copySync(to.path);
    }
    _prune(dir, name);
  }

  /// The private per-client backup folder, or null when backups are off.
  Directory? _backupFolder(String clientId) {
    final String? root = backupDirectory;
    if (root == null) return null;
    final Directory dir = Directory('$root${env.separator}$clientId')
      ..createSync(recursive: true);
    _restrict(dir.path, 0x1c0);
    return dir;
  }

  String _stamp() => DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[-:]'), '')
      .replaceAll('.', '');

  /// Keeps the 5 most recent backups of [name] in [dir].
  void _prune(Directory dir, String name) {
    final RegExp ours = RegExp(
      '^${RegExp.escape(name)}'
      r'\.\d{8}T\d+Z\.bak$',
    );
    final List<FileSystemEntity> old =
        dir
            .listSync()
            .where(
              (e) => ours.hasMatch(
                e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
              ),
            )
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    for (final FileSystemEntity e in old.skip(5)) {
      e.deleteSync(recursive: true);
    }
  }
}

void _restrict(String path, int mode) {
  if (Platform.isWindows) return;
  Process.runSync('/bin/chmod', <String>[mode.toRadixString(8), path]);
}

/// Detects every target.
List<TargetScan> scanTargets(InstallTargets targets, InstallEnvironment env) =>
    <TargetScan>[for (final t in targets.targets.values) scanTarget(t, env)];

TargetScan scanTarget(InstallTarget target, InstallEnvironment env) {
  // A target whose files live under an unknown directory (no %APPDATA%) is
  // treated like one this platform does not have.
  final bool platform =
      (target.os == null || target.os!.contains(env.os)) &&
      _resolvable(target, env);
  final List<String> evidence = <String>[];
  if (platform) {
    for (final DetectRule rule in target.detect) {
      if (rule.command != null) {
        final String? found = env.which(rule.command!);
        if (found != null) evidence.add('command: ${rule.command}');
      } else {
        final String path;
        try {
          path = target.resolve(env, rule.path!);
        } on AgentInstallException {
          continue;
        }
        if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
          evidence.add(env.display(path));
        }
      }
    }
  }
  final String? manual = target.manualWhenEnv
      .where((n) => (env.env[n] ?? '').isNotEmpty)
      .map(
        (n) =>
            '$n is set, so ${target.name} may read another file; configure it by hand.',
      )
      .firstOrNull;
  return TargetScan(
    id: target.id,
    name: target.name,
    detected: evidence.isNotEmpty,
    evidence: evidence,
    components: target.components,
    builtin: target.builtin,
    platformSupported: platform,
    manual: platform ? manual : null,
    extensionFile: target.extensionFile,
  );
}

final class _DirState {
  _DirState(
    this.state,
    this.message, {
    this.source,
    this.ours = false,
    this.adopt = false,
  });
  final String state;
  final String? message;
  final Map<String, String>? source;
  final bool ours;

  /// The directory has no receipt yet and is taken over on install.
  final bool adopt;
}

const String _receipt = '.agent-installer.json';

/// FNV-1a 64-bit, enough to notice a changed file; not a security check.
String _fnv1a(List<int> data) {
  int hash = 0xcbf29ce484222325;
  for (final int byte in data) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

String? _diff(String? before, String? after) {
  final List<String> a = (before ?? '').split('\n');
  final List<String> b = (after ?? '').split('\n');
  int p = 0;
  while (p < a.length && p < b.length && a[p] == b[p]) {
    p++;
  }
  int s = 0;
  while (s < a.length - p &&
      s < b.length - p &&
      a[a.length - 1 - s] == b[b.length - 1 - s]) {
    s++;
  }
  final int from = math.max(0, p - 3);
  final List<String> lines = <String>[
    '@@ line ${from + 1} @@',
    for (final String l in a.sublist(from, p)) ' $l',
    for (final String l in a.sublist(p, a.length - s)) '-$l',
    for (final String l in b.sublist(p, b.length - s)) '+$l',
    for (final String l in a.sublist(
      a.length - s,
      math.min(a.length, a.length - s + 3),
    ))
      ' $l',
  ];
  return lines.length > 400
      ? '${lines.take(400).join('\n')}\n… ${lines.length - 400} more lines'
      : lines.join('\n');
}

bool _resolvable(InstallTarget target, InstallEnvironment env) {
  try {
    for (final String template in <String?>[
      ...?target.mcp?.files,
      ...?target.hooks?.files,
      target.permissionsFile,
      target.instructionsFile,
      target.skillsDir,
      target.pluginsDir,
    ].nonNulls) {
      target.resolve(env, template);
    }
    return true;
  } on AgentInstallException {
    return false;
  }
}
