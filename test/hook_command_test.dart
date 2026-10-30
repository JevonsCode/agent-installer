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

  test('kept options replace or extend the desired arguments', () {
    const List<String> desired = <String>['--source', 'X', '--profile', 'a'];
    expect(
      keepOptions(desired, <String>['--profile', 'b'], <String>['--profile']),
      <String>['--source', 'X', '--profile', 'b'],
    );
    expect(
      keepOptions(desired, <String>['--profile=c'], <String>['--profile']),
      <String>['--source', 'X', '--profile=c'],
    );
    expect(
      keepOptions(
        <String>['--source', 'X'],
        <String>['--other', '--level', '2'],
        <String>['--profile', '--level'],
      ),
      <String>['--source', 'X', '--level', '2'],
    );
    expect(
      keepOptions(desired, null, <String>['--profile']),
      desired,
      reason: 'a new entry gets the manifest values',
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
