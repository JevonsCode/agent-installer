import 'package:agent_installer/src/components.dart';
import 'package:test/test.dart';

void main() {
  test('PowerShell commands quote spaces and single quotes literally', () {
    expect(
      powerShellCommand(<String>[
        r'C:\Program Files\nodejs\node.exe',
        r'C:\Users\me\My Tools\hook.js',
        '--flag',
      ]),
      r"& 'C:\Program Files\nodejs\node.exe' 'C:\Users\me\My Tools\hook.js' --flag",
    );
    expect(
      powerShellCommand(<String>[r"C:\O'Neil\node.exe", "it's", 'plain']),
      r"& 'C:\O''Neil\node.exe' 'it''s' plain",
    );
    expect(
      powerShellCommand(<String>[
        'node.exe',
        r'$env:HOME',
        'a,b',
        '@args',
        '--',
        '',
      ]),
      r"& 'node.exe' '$env:HOME' 'a,b' '@args' '--' ''",
      reason: 'PowerShell syntax in an argument is never evaluated',
    );
  });

  test('POSIX and cmd quoting are unchanged', () {
    expect(
      shellCommand(<String>['/opt/x', "it's", 'a b'], windows: false),
      r"/opt/x 'it'\''s' 'a b'",
    );
    expect(
      shellCommand(<String>[r'C:\x y\a.exe', '--flag'], windows: true),
      r'"C:\x y\a.exe" --flag',
    );
  });
}
