import 'dart:convert';

/// A hook group to write into Codex's `config.toml`.
typedef TomlHookGroup = ({
  String event,
  String? matcher,
  Map<String, Object?> handler,
});

/// Line-based edits of Codex `config.toml`. Only whole tables owned by the
/// caller are replaced; other tables, comments and order are kept.
abstract final class CodexToml {
  static bool hasServer(String? text, String name) =>
      _sections(text).any((s) => !s.array && s.name == 'mcp_servers.$name');

  /// Replaces the body of `[mcp_servers.<name>]`, keeping its sub-tables, or
  /// appends the table.
  static String setServer(
    String? text,
    String name,
    Map<String, Object?> entry,
  ) {
    final List<_Section> sections = _sections(text);
    final List<int> found = <int>[
      for (final (int i, _Section s) in sections.indexed)
        if (!s.array && s.name == 'mcp_servers.$name') i,
    ];
    if (found.length > 1) {
      throw FormatException('[mcp_servers.$name] is defined more than once.');
    }
    final List<String> body = <String>[
      for (final MapEntry<String, Object?> e in entry.entries)
        '${_key(e.key)} = ${_value(e.value)}',
    ];
    if (found.isEmpty) {
      sections.add(
        _Section('mcp_servers.$name', false, <String>[
          '[mcp_servers.${_key(name)}]',
          ...body,
          '',
        ], generated: true),
      );
    } else {
      final _Section old = sections[found.single];
      final int blanks = old.lines.reversed
          .takeWhile((l) => l.trim().isEmpty)
          .length;
      sections[found.single] = _Section(old.name, false, <String>[
        old.lines.first,
        ...body,
        // Keep fields and comments the person added, as the JSON writers do.
        ..._foreignLines(
          old.lines.sublist(1, old.lines.length - blanks),
          entry.keys.toSet(),
        ),
        for (int i = 0; i < blanks; i++) '',
      ]);
    }
    return _join(sections, text);
  }

  /// Removes `[mcp_servers.<name>]` and its sub-tables.
  static String? removeServer(String? text, String name) {
    if (!hasServer(text, name)) return text;
    final String base = 'mcp_servers.$name';
    return _join(
      _sections(text)
          .where((s) => s.name != base && !(s.name ?? '').startsWith('$base.'))
          .toList(),
      text,
    );
  }

  /// Whether the file defines any hook as a TOML table.
  static bool hasHookTables(String? text) =>
      _sections(text).any((s) => s.array && _groupEvent(s) != null);

  static bool hasHooks(String? text, bool Function(String command) ours) =>
      _hookHandlers(_sections(text)).any((h) => _isOurs(h, ours));

  /// Removes every handler [ours] matches, dropping groups left empty, and
  /// writes [groups] where the first matched handler of their event was, or
  /// at the end of the file.
  static String setHooks(
    String? text,
    List<TomlHookGroup> groups,
    bool Function(String command) ours,
  ) {
    final List<_Section> sections = _sections(text);
    final List<_Section> out = <_Section>[];
    final Map<String, int> insertAt = <String, int>{};
    int k = 0;
    while (k < sections.length) {
      final _Section header = sections[k];
      final String? event = header.array ? _groupEvent(header) : null;
      if (event == null) {
        out.add(header);
        k++;
        continue;
      }
      final String handlerName = 'hooks.$event.hooks';
      final List<_Section> attached = <_Section>[];
      final List<List<_Section>> handlers = <List<_Section>>[];
      for (k++; k < sections.length; k++) {
        final _Section s = sections[k];
        if (s.array && s.name == handlerName) {
          handlers.add(<_Section>[s]);
        } else if ((s.name ?? '').startsWith('$handlerName.')) {
          (handlers.isEmpty ? attached : handlers.last).add(s);
        } else {
          break;
        }
      }
      final List<List<_Section>> kept = handlers
          .where((h) => !_isOurs(h, ours))
          .toList();
      if (kept.isNotEmpty) {
        out
          ..add(header)
          ..addAll(attached)
          ..addAll(kept.expand((h) => h));
      }
      if (kept.length != handlers.length) {
        insertAt.putIfAbsent(event, () => out.length);
      }
    }
    final List<String> events = <String>{
      for (final TomlHookGroup g in groups) g.event,
    }.toList();
    // Events that share a position keep the order of [groups].
    final List<(int, int, String)> placed =
        <(int, int, String)>[
          for (final (int order, String e) in events.indexed)
            if (insertAt.containsKey(e)) (insertAt[e]!, order, e),
        ]..sort(
          (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
        );
    int offset = 0;
    for (final (int index, int _, String event) in placed) {
      final List<_Section> block = _hookSections(groups, event);
      out.insertAll(index + offset, block);
      offset += block.length;
    }
    for (final String event in events.where((e) => !insertAt.containsKey(e))) {
      out.addAll(_hookSections(groups, event));
    }
    return _join(out, text);
  }

  static List<_Section> _hookSections(
    List<TomlHookGroup> groups,
    String event,
  ) => <_Section>[
    for (final TomlHookGroup g in groups.where(
      (g) => g.event == event,
    )) ...<_Section>[
      _Section('hooks.$event', true, <String>[
        '[[hooks.$event]]',
        if (g.matcher != null) 'matcher = ${_value(g.matcher)}',
        '',
      ], generated: true),
      _Section('hooks.$event.hooks', true, <String>[
        '[[hooks.$event.hooks]]',
        for (final MapEntry<String, Object?> e in g.handler.entries)
          '${_key(e.key)} = ${_value(e.value)}',
        '',
      ]),
    ],
  ];

  static Iterable<List<_Section>> _hookHandlers(List<_Section> sections) sync* {
    for (int k = 0; k < sections.length; k++) {
      final String? event = sections[k].array ? _groupEvent(sections[k]) : null;
      if (event == null) continue;
      for (int j = k + 1; j < sections.length; j++) {
        final _Section s = sections[j];
        if (s.array && s.name == 'hooks.$event.hooks') {
          yield <_Section>[s];
        } else if (!(s.name ?? '').startsWith('hooks.$event.hooks.')) {
          break;
        }
      }
    }
  }

  static bool _isOurs(List<_Section> handler, bool Function(String) ours) =>
      handler.first.lines.any((line) {
        final RegExpMatch? m = _command.firstMatch(line);
        return m != null && ours(m.group(1)!);
      });

  static String? _groupEvent(_Section s) =>
      _event.firstMatch(s.name ?? '')?.group(1);

  static final RegExp _event = RegExp(r'^hooks\.([A-Za-z][A-Za-z0-9_]*)$');
  static final RegExp _command = RegExp(r'^\s*command\s*=\s*(.+)$');
}

/// Body lines of a table except the keys in [owned]; a value spanning
/// several lines (an array or inline table) moves with its key.
List<String> _foreignLines(List<String> body, Set<String> owned) {
  final List<String> kept = <String>[];
  bool keep = true;
  int depth = 0;
  for (final String line in body) {
    if (depth == 0) {
      final RegExpMatch? key = _keyLine.firstMatch(line);
      keep = key == null || !owned.contains(_unquote(key.group(1)!));
    }
    depth += _bracketDepth(line);
    if (depth < 0) depth = 0;
    if (keep && line.trim().isNotEmpty) kept.add(line);
  }
  return kept;
}

final RegExp _keyLine = RegExp(r'''^\s*("[^"]*"|'[^']*'|[A-Za-z0-9_-]+)\s*=''');

String _unquote(String key) =>
    key.length > 1 && (key.startsWith('"') || key.startsWith("'"))
    ? key.substring(1, key.length - 1)
    : key;

/// Net open brackets on a line, ignoring quoted text and comments.
int _bracketDepth(String line) {
  int depth = 0;
  String? quote;
  for (int i = 0; i < line.length; i++) {
    final String c = line[i];
    if (quote != null) {
      if (c == '\\' && quote == '"') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
    } else if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '#') {
      break;
    } else if (c == '[' || c == '{') {
      depth++;
    } else if (c == ']' || c == '}') {
      depth--;
    }
  }
  return depth;
}

final class _Section {
  _Section(this.name, this.array, this.lines, {this.generated = false});

  /// Null for the lines before the first table.
  final String? name;
  final bool array;

  /// The header line, the body, and blank lines up to the next header.
  final List<String> lines;
  final bool generated;
}

final RegExp _header = RegExp(r'^\s*(\[\[?)\s*([^\[\]]+?)\s*\]\]?\s*(?:#.*)?$');

List<_Section> _sections(String? text) {
  final List<String> lines = (text ?? '').replaceAll('\r\n', '\n').split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final List<_Section> sections = <_Section>[_Section(null, false, <String>[])];
  for (final String line in lines) {
    final RegExpMatch? m = _header.firstMatch(line);
    if (m == null) {
      sections.last.lines.add(line);
      continue;
    }
    final String name = m
        .group(2)!
        .split('.')
        .map((p) => p.trim().replaceAll(RegExp(r'''^["']|["']$'''), ''))
        .join('.');
    sections.add(_Section(name, m.group(1) == '[[', <String>[line]));
  }
  return sections;
}

String _join(List<_Section> sections, String? original) {
  final List<String> lines = <String>[];
  for (final _Section s in sections) {
    if (s.generated && lines.isNotEmpty && lines.last.trim().isNotEmpty) {
      lines.add('');
    }
    lines.addAll(s.lines);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  final String nl = (original ?? '').contains('\r\n') ? '\r\n' : '\n';
  return lines.isEmpty ? '' : '${lines.join(nl)}$nl';
}

String _key(String key) =>
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key) ? key : jsonEncode(key);

String _value(Object? value) => switch (value) {
  String() => jsonEncode(value),
  bool() || int() || double() => '$value',
  List<Object?>() => '[${value.map(_value).join(', ')}]',
  Map<String, Object?>() =>
    value.isEmpty
        ? '{}'
        : '{ ${value.entries.map((e) => '${_key(e.key)} = ${_value(e.value)}').join(', ')} }',
  _ => throw FormatException('Unsupported TOML value: $value'),
};

/// A managed Markdown block delimited by two marker lines.
abstract final class MarkdownBlock {
  static bool has(String? text, String begin, String end) =>
      _range(text, begin, end) != null;

  /// Replaces the block in place, or appends it after a blank line.
  static String set(String? text, String begin, String end, String body) {
    final String nl = (text ?? '').contains('\r\n') ? '\r\n' : '\n';
    final String block = '$begin\n${body.trim()}\n$end'.replaceAll('\n', nl);
    final (int, int)? range = _range(text, begin, end);
    if (range != null) return text!.replaceRange(range.$1, range.$2, block);
    final String base = (text ?? '').trimRight();
    return base.isEmpty ? '$block$nl' : '$base$nl$nl$block$nl';
  }

  /// Removes the block; null when nothing else is left in the file.
  static String? remove(String? text, String begin, String end) {
    final (int, int)? range = _range(text, begin, end);
    if (range == null) return text;
    final String nl = text!.contains('\r\n') ? '\r\n' : '\n';
    final String before = text.substring(0, range.$1).trimRight();
    final String after = text.substring(range.$2).trim();
    final String joined = before.isEmpty
        ? after
        : after.isEmpty
        ? before
        : '$before$nl$nl$after';
    return joined.isEmpty ? null : '$joined$nl';
  }

  static (int, int)? _range(String? text, String begin, String end) {
    if (text == null) return null;
    final int start = text.indexOf(begin);
    if (start < 0) return null;
    final int stop = text.indexOf(end, start + begin.length);
    return stop < 0 ? null : (start, stop + end.length);
  }
}
