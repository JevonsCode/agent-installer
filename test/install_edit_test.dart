import 'package:agent_installer/agent_installer.dart';
import 'package:agent_installer/src/text_edit.dart';
import 'package:test/test.dart';

void main() {
  group('JsonEdit', () {
    const String jsonc = '''
{
  // keep me
  "a": 1,
  "nested": {
    "x": true, /* inline */
  },
}
''';

    test('decodes comments and trailing commas', () {
      expect(JsonEdit.decode(jsonc), <String, Object?>{
        'a': 1,
        'nested': <String, Object?>{'x': true},
      });
      expect(JsonEdit.decode(null), <String, Object?>{});
      expect(() => JsonEdit.decode('{"a":}'), throwsFormatException);
    });

    test('sets a member in place and keeps comments', () {
      final String edited = JsonEdit.set(jsonc, <String>['a'], 2);
      expect(edited, jsonc.replaceFirst('"a": 1', '"a": 2'));
      final String added = JsonEdit.set(jsonc, <String>['nested', 'y'], 'z');
      expect(added, contains('// keep me'));
      expect(added, contains('/* inline */'));
      expect(JsonEdit.decode(added), <String, Object?>{
        'a': 1,
        'nested': <String, Object?>{'x': true, 'y': 'z'},
      });
    });

    test('insert then remove restores the original text', () {
      for (final String original in <String>[
        '{\n  "a": 1\n}\n',
        '{}\n',
        '{\n  "a": 1,\n  "b": {\n    "c": 2\n  }\n}\n',
        jsonc,
      ]) {
        for (final List<String> path in <List<String>>[
          <String>['new'],
          <String>['deep', 'er'],
        ]) {
          final String added = JsonEdit.set(original, path, <String, Object?>{
            'k': <Object?>[1, 'v'],
          });
          expect(
            JsonEdit.remove(added, <String>[path.first]),
            original,
            reason: '$original + $path',
          );
        }
      }
    });

    test('removes first, middle and only members', () {
      const String text = '{\n  "a": 1,\n  "b": 2,\n  "c": 3\n}\n';
      expect(
        JsonEdit.remove(text, <String>['a']),
        '{\n  "b": 2,\n  "c": 3\n}\n',
      );
      expect(
        JsonEdit.remove(text, <String>['b']),
        '{\n  "a": 1,\n  "c": 3\n}\n',
      );
      expect(JsonEdit.remove('{"only": 1}', <String>['only']), '{}');
      expect(JsonEdit.remove(text, <String>['missing']), text);
    });

    test('creates a document and follows tab indentation', () {
      expect(
        JsonEdit.set(null, <String>['a', 'b'], 1),
        '{\n  "a": {\n    "b": 1\n  }\n}\n',
      );
      expect(
        JsonEdit.set('{\n\t"x": 1\n}', <String>['y'], 2),
        '{\n\t"x": 1,\n\t"y": 2\n}',
      );
    });
  });

  group('CodexToml', () {
    const String config = '''
# top comment
model = "gpt-5"

[mcp_servers.other]
command = "x" # keep

[mcp_servers.acme]
command = "old"
enabled = true # mine
env = [
  "A",
]

[mcp_servers.acme.tools.ping]
approval_mode = "approve"
''';

    test('replaces our keys and keeps foreign keys and sub-tables', () {
      final String edited = CodexToml.setServer(
        config,
        'acme',
        <String, Object?>{
          'command': '/bin/acme',
          'args': <String>['--x'],
        },
      );
      expect(
        edited,
        contains(
          '[mcp_servers.acme]\ncommand = "/bin/acme"\nargs = ["--x"]\nenabled = true # mine\nenv = [\n  "A",\n]\n',
        ),
      );
      expect(edited, contains('[mcp_servers.acme.tools.ping]'));
      expect(edited, startsWith('# top comment\nmodel = "gpt-5"\n'));
      expect(
        CodexToml.setServer(edited, 'acme', <String, Object?>{
          'command': '/bin/acme',
          'args': <String>['--x'],
        }),
        edited,
      );
      final String removed = CodexToml.removeServer(edited, 'acme')!;
      expect(removed, isNot(contains('acme')));
      expect(removed, contains('[mcp_servers.other]\ncommand = "x" # keep'));
    });

    test('appends a new server and removes it again', () {
      const String base = 'model = "gpt-5"\n';
      final String added = CodexToml.setServer(base, 'a b', <String, Object?>{
        'command': 'c',
        'env': <String, Object?>{'K': 'v'},
      });
      expect(
        added,
        'model = "gpt-5"\n\n[mcp_servers."a b"]\ncommand = "c"\nenv = { K = "v" }\n',
      );
      expect(CodexToml.removeServer(added, 'a b'), base);
    });

    test('reads the args of a server, or null when they are not text', () {
      const String toml = '''
[mcp_servers.a]
command = "x"
args = [ # mine
  "--p", 'C:\\literal',
  "q\\"uote\\u00e9",
]

[mcp_servers.b]
args = [1, 2]

[mcp_servers.c]
command = "y"
''';
      expect(CodexToml.serverArgs(toml, 'a'), <String>[
        '--p',
        r'C:\literal',
        'q"uote\u00e9',
      ]);
      expect(CodexToml.serverArgs(toml, 'b'), isNull);
      expect(CodexToml.serverArgs(toml, 'c'), isNull);
      expect(CodexToml.serverArgs(toml, 'missing'), isNull);
    });

    test('hooks are replaced where they were and foreign hooks stay', () {
      const String hooks = '''
[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "other-tool --stop"

[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "'/x/acme_mcp' --old"

[hooks.state.abc]
trusted_hash = "h"
''';
      bool ours(String command) => command.contains('acme_mcp');
      final List<TomlHookGroup> groups = <TomlHookGroup>[
        (
          event: 'Stop',
          matcher: null,
          handler: <String, Object?>{
            'type': 'command',
            'command': '/x/acme_mcp --new',
            'timeout': 10,
          },
        ),
        (
          event: 'SessionStart',
          matcher: '^(startup|resume)\$',
          handler: <String, Object?>{
            'type': 'command',
            'command': '/x/acme_mcp --start',
          },
        ),
      ];
      final String edited = CodexToml.setHooks(hooks, groups, ours);
      expect(edited, contains('command = "other-tool --stop"'));
      expect(edited, isNot(contains('--old')));
      expect(
        edited.indexOf('/x/acme_mcp --new'),
        lessThan(edited.indexOf('[hooks.state.abc]')),
        reason: 'replaced in place',
      );
      expect(
        edited,
        endsWith(
          '[[hooks.SessionStart]]\nmatcher = "^(startup|resume)\$"\n\n[[hooks.SessionStart.hooks]]\ntype = "command"\ncommand = "/x/acme_mcp --start"\n',
        ),
      );
      expect(CodexToml.setHooks(edited, groups, ours), edited);
      expect(CodexToml.hasHooks(edited, ours), isTrue);
      final String removed = CodexToml.setHooks(
        edited,
        const <TomlHookGroup>[],
        ours,
      );
      expect(CodexToml.hasHooks(removed, ours), isFalse);
      expect(removed, contains('other-tool --stop'));
      expect(removed, contains('[hooks.state.abc]'));
    });
  });

  group('MarkdownBlock', () {
    const String begin = '<!-- BEGIN X -->';
    const String end = '<!-- END X -->';

    test('appends, replaces in place and removes cleanly', () {
      const String original = '# Notes\n\nKeep this.\n';
      final String added = MarkdownBlock.set(original, begin, end, 'v1');
      expect(added, '# Notes\n\nKeep this.\n\n$begin\nv1\n$end\n');
      final String withTail = '${added}After.\n';
      final String replaced = MarkdownBlock.set(withTail, begin, end, 'v2');
      expect(replaced, '# Notes\n\nKeep this.\n\n$begin\nv2\n$end\nAfter.\n');
      expect(MarkdownBlock.remove(added, begin, end), original);
      expect(
        MarkdownBlock.remove(
          MarkdownBlock.set(null, begin, end, 'x'),
          begin,
          end,
        ),
        isNull,
      );
    });
  });
}
