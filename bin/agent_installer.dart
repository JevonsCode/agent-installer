import 'dart:convert';
import 'dart:io';

import 'package:agent_installer/agent_installer.dart';

const String _usage = '''
Usage:
  agent-installer scan [--extensions DIR] [--json]
  agent-installer status [--clients ID,...] PRODUCT
  agent-installer plan --clients ID,... PRODUCT
  agent-installer apply --clients ID,... PRODUCT
  agent-installer remove --clients ID,... PRODUCT

PRODUCT: --product FILE [--var NAME=VALUE]... [--extensions DIR]
         [--backups DIR] [--json]

Extensions default to the shared per-user directory; backups default to a
"backups" directory beside it. plan never writes anything.''';

Future<void> main(List<String> arguments) async {
  final bool json = arguments.contains('--json');
  try {
    exitCode = _run(arguments.where((a) => a != '--json').toList(), json);
  } on AgentInstallException catch (error) {
    _fail(json, error.code, error.message);
  } on FormatException catch (error) {
    _fail(json, 'invalid_arguments', '${error.message}\n\n$_usage');
  } on FileSystemException catch (error) {
    _fail(json, 'io_error', error.message);
  }
}

int _run(List<String> arguments, bool json) {
  if (arguments.isEmpty) throw const FormatException('Missing command.');
  final String command = arguments.first;
  final Map<String, String> vars = <String, String>{};
  final Map<String, String> options = <String, String>{};
  for (int i = 1; i < arguments.length; i += 2) {
    final String flag = arguments[i];
    if (i + 1 >= arguments.length || !flag.startsWith('--')) {
      throw FormatException('Unexpected argument "$flag".');
    }
    final String value = arguments[i + 1];
    if (flag == '--var') {
      final int eq = value.indexOf('=');
      if (eq < 1) throw const FormatException('--var needs NAME=VALUE.');
      vars[value.substring(0, eq)] = value.substring(eq + 1);
    } else if (const <String>{
          '--extensions',
          '--product',
          '--clients',
          '--backups',
        }.contains(flag) &&
        !options.containsKey(flag)) {
      options[flag] = value;
    } else {
      throw FormatException('Unexpected argument "$flag".');
    }
  }
  final String? extensions =
      options['--extensions'] ?? defaultExtensionsDirectory();
  final InstallTargets targets = InstallTargets.load(
    extensionsDirectory: extensions,
  );
  final List<Object?> extensionErrors = <Object?>[
    for (final ExtensionProblem p in targets.problems) p.toJson(),
  ];

  if (command == 'scan') {
    if (options.keys.any((k) => k != '--extensions') || vars.isNotEmpty) {
      throw const FormatException('scan takes only --extensions.');
    }
    final List<TargetScan> scans = scanTargets(targets, InstallEnvironment());
    if (json) {
      _print(<String, Object?>{
        'clients': <Object?>[for (final s in scans) s.toJson()],
        'extensionErrors': extensionErrors,
      });
    } else {
      for (final TargetScan s in scans) {
        stdout.writeln(
          '${s.detected ? '✓' : '·'} ${s.id.padRight(16)} ${s.name.padRight(16)} '
          '${!s.platformSupported
              ? 'not available on this platform'
              : s.detected
              ? s.evidence.join(', ')
              : 'not detected'}',
        );
      }
      _printProblems(targets.problems);
    }
    return 0;
  }

  const Set<String> productCommands = <String>{
    'status',
    'plan',
    'apply',
    'remove',
  };
  if (!productCommands.contains(command)) {
    throw FormatException('Unknown command "$command".');
  }
  final String? productPath = options['--product'];
  if (productPath == null)
    throw const FormatException('--product is required.');
  final List<String>? clients = options['--clients']
      ?.split(',')
      .map((c) => c.trim())
      .where((c) => c.isNotEmpty)
      .toList();
  if (command != 'status' && (clients == null || clients.isEmpty)) {
    throw FormatException('$command needs --clients.');
  }
  final ProductManifest product = ProductManifest.decode(
    File(productPath).readAsStringSync(),
    variables: vars,
  );
  final String? backups =
      options['--backups'] ??
      (extensions == null
          ? null
          : '${File(extensions).parent.path}${Platform.pathSeparator}backups'
                '${Platform.pathSeparator}${product.product}');
  final AgentInstaller installer = AgentInstaller(
    product: product,
    targets: targets,
    backupDirectory: backups,
  );

  if (command == 'status') {
    final List<ClientStatus> states = installer.status(clients);
    if (json) {
      _print(<String, Object?>{
        'product': product.product,
        'clients': <Object?>[for (final s in states) s.toJson()],
        'extensionErrors': extensionErrors,
      });
    } else {
      for (final ClientStatus s in states) {
        stdout.writeln(
          '${s.scan.id.padRight(16)} ${s.state.padRight(17)} '
          '${s.components.map((c) => '${c.component}=${c.state}').join(' ')}'
          '${s.scan.detected ? '' : '  (not detected)'}',
        );
        for (final ComponentStatus c in s.components) {
          if (c.message != null)
            stdout.writeln('    ! ${c.component}: ${c.message}');
        }
      }
      _printProblems(targets.problems);
    }
    return 0;
  }

  final List<ClientResult> results = switch (command) {
    'plan' => installer.plan(clients!),
    'apply' => installer.apply(clients!),
    _ => installer.remove(clients!),
  };
  if (json) {
    _print(<String, Object?>{
      'product': product.product,
      'clients': <Object?>[for (final r in results) r.toJson()],
      'extensionErrors': extensionErrors,
    });
  } else {
    for (final ClientResult r in results) {
      stdout.writeln('${r.id} (${r.name}): ${r.state}');
      if (r.changes.isEmpty) stdout.writeln('  no changes');
      for (final PlannedChange c in r.changes) {
        stdout.writeln('  ${c.action} ${c.path} [${c.components.join(', ')}]');
        if (command == 'plan' && c.diff != null) {
          for (final String line in c.diff!.split('\n')) {
            stdout.writeln('      $line');
          }
        }
      }
      for (final String p in r.problems) {
        stdout.writeln('  ! $p');
      }
      for (final String a in r.actions) {
        stdout.writeln('  → $a');
      }
    }
    _printProblems(targets.problems);
  }
  return results.any((r) => r.problems.isNotEmpty) ? 2 : 0;
}

void _printProblems(List<ExtensionProblem> problems) {
  for (final ExtensionProblem p in problems) {
    stdout.writeln('! ${p.file}: ${p.message}');
  }
}

void _print(Map<String, Object?> body) => stdout.writeln(
  jsonEncode(<String, Object?>{'version': 1, 'ok': true, ...body}),
);

void _fail(bool json, String code, String message) {
  if (json) {
    stdout.writeln(
      jsonEncode(<String, Object?>{
        'version': 1,
        'ok': false,
        'error': <String, Object?>{'code': code, 'message': message},
      }),
    );
  } else {
    stderr.writeln('$code: $message');
  }
  exitCode = 1;
}
