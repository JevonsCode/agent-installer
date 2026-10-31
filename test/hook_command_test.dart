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

  test('literal command equivalence is conservative', () {
    bool equal(String a, String b, {bool windows = false, bool ps = false}) =>
        hookCommandsEqual(a, b, windows: windows, powerShell: ps);
    expect(
      equal(
        "& 'node.exe' '--flag' 'it''s'",
        "& 'node.exe' --flag 'it''s'",
        windows: true,
        ps: true,
      ),
      isTrue,
    );
    expect(
      equal(
        r'"C:\node.exe" "--flag" "Stop"',
        r'"C:\node.exe" --flag Stop',
        windows: true,
      ),
      isTrue,
    );
    expect(
      equal(r"/opt/node 'it'\''s' '--flag'", r"/opt/node 'it'\''s' --flag"),
      isTrue,
    );
    expect(equal("node '--flag' ''", "node --flag ''"), isTrue);
    expect(equal("node '--flag' x", "node --flag y"), isFalse);
    expect(equal(r'node "$HOME"', r"node '$HOME'"), isFalse);
    expect(equal("node '--flag", "node --flag"), isFalse);
    expect(
      equal(r'"C:\node.exe" "%PATH%"', r'"C:\node.exe" %PATH%', windows: true),
      isFalse,
    );
    expect(
      equal("& 'node.exe' --", "& 'node.exe' '--'", windows: true, ps: true),
      isFalse,
    );
  });
}
