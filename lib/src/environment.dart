import 'dart:io';

import 'errors.dart';

/// The user's home, configuration roots and PATH, injectable for tests.
final class InstallEnvironment {
  InstallEnvironment({
    Map<String, String>? environment,
    String? operatingSystem,
  }) : env = environment ?? Platform.environment,
       os = operatingSystem ?? Platform.operatingSystem;

  final Map<String, String> env;
  final String os;

  bool get windows => os == 'windows';
  String get separator => windows ? r'\' : '/';

  String get home {
    final String? value = env[windows ? 'USERPROFILE' : 'HOME'];
    if (value == null || value.isEmpty) {
      throw const AgentInstallException(
        'unsupported_platform',
        'The home directory is unknown.',
      );
    }
    return _trimEnd(value);
  }

  /// `$XDG_CONFIG_HOME` when absolute, else `~/.config` (also on Windows,
  /// where OpenCode and similar tools keep their configuration).
  String get configHome {
    final String? xdg = env['XDG_CONFIG_HOME'];
    return !windows && xdg != null && xdg.startsWith('/')
        ? _trimEnd(xdg)
        : '$home$separator.config';
  }

  /// Per-user application data: `~/Library/Application Support` on macOS,
  /// `%APPDATA%` on Windows and the configuration home on Linux.
  String? get appData => switch (os) {
    'macos' => '$home/Library/Application Support',
    'windows' => _nonEmpty(env['APPDATA']),
    _ => configHome,
  };

  /// The first executable named [command] on PATH.
  String? which(String command) {
    final List<String> extensions = windows
        ? <String>[
            '',
            ...(env['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
                .split(';')
                .where((e) => e.isNotEmpty)
                .map((e) => e.toLowerCase()),
          ]
        : const <String>[''];
    for (final String directory in (env['PATH'] ?? env['Path'] ?? '').split(
      windows ? ';' : ':',
    )) {
      if (directory.isEmpty) continue;
      for (final String extension in extensions) {
        final String candidate =
            '${_trimEnd(directory)}$separator$command$extension';
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }

  /// Expands a validated path template. [clientHome] fills `{home}`.
  String resolve(String template, {String? clientHome}) {
    final String root;
    final String rest;
    if (template == '~' || template.startsWith('~/')) {
      root = home;
      rest = template.substring(1);
    } else {
      final RegExpMatch m = _templateRoot.firstMatch(template)!;
      root = switch (m.group(1)) {
        'home' => clientHome ?? home,
        'configHome' => configHome,
        _ =>
          appData ??
              (throw const AgentInstallException(
                'unsupported_platform',
                'This platform has no application data directory.',
              )),
      };
      rest = template.substring(m.end);
    }
    return root + (windows ? rest.replaceAll('/', r'\') : rest);
  }

  /// Turns a client-documented override such as `CODEX_HOME` into an absolute
  /// directory, or null when it is unset or not absolute.
  String? overrideDirectory(String name) {
    final String? value = _nonEmpty(env[name]);
    if (value == null) return null;
    if (value == '~' || value.startsWith('~/') || value.startsWith(r'~\')) {
      return home + value.substring(1);
    }
    final bool absolute = windows
        ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)
        : value.startsWith('/');
    return absolute ? _trimEnd(value) : null;
  }

  /// Shows [path] relative to the home directory, as `~/...`.
  String display(String path) {
    final String home = this.home;
    return path == home || path.startsWith('$home$separator')
        ? '~${path.substring(home.length).replaceAll(r'\', '/')}'
        : path;
  }
}

/// A path template starts at a user-scoped root and never climbs out of it.
bool isPathTemplate(String value) {
  if (value.length > 512 || value.contains(r'\')) return false;
  final String rest;
  if (value == '~' || value.startsWith('~/')) {
    rest = value.substring(1);
  } else {
    final RegExpMatch? m = _templateRoot.firstMatch(value);
    if (m == null) return false;
    rest = value.substring(m.end);
  }
  if (rest.isNotEmpty && !rest.startsWith('/')) return false;
  return rest
      .split('/')
      .skip(1)
      .every(
        (s) => s.isNotEmpty && s != '.' && s != '..' && _segment.hasMatch(s),
      );
}

final RegExp _templateRoot = RegExp(r'^\{(home|configHome|appData)\}');
final RegExp _segment = RegExp(r'^[A-Za-z0-9._ +@()-]{1,255}$');

String _trimEnd(String path) =>
    path.length > 1 ? path.replaceAll(RegExp(r'[\\/]+$'), '') : path;

String? _nonEmpty(String? value) =>
    value == null || value.trim().isEmpty ? null : value;
