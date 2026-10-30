import 'dart:convert';

/// Edits JSON that may contain comments and trailing commas, changing only
/// the member at a path: comments, ordering and formatting elsewhere survive.
abstract final class JsonEdit {
  /// Decodes [text]; a missing or blank document is an empty object.
  static Object? decode(String? text) => text == null || text.trim().isEmpty
      ? <String, Object?>{}
      : _parse(text).value;

  /// Returns [text] with the member at [path] set to [value], creating
  /// missing parent objects.
  static String set(String? text, List<String> path, Object? value) {
    final String nl = _newline(text);
    if (text == null || text.trim().isEmpty) {
      return '${_render(_nest(path, value), '', '  ', nl)}$nl';
    }
    final String unit = _indentUnit(text);
    final _Node root = _parse(text);
    _Node node = root;
    for (int depth = 0; depth < path.length; depth++) {
      final List<_Member>? members = node.members;
      if (members == null) {
        throw const FormatException('Expected a JSON object.');
      }
      final _Member? member = members
          .where((m) => m.key == path[depth])
          .lastOrNull;
      if (member == null) {
        return _insert(
          text,
          node,
          path[depth],
          _nest(path.sublist(depth + 1), value),
          unit,
          nl,
        );
      }
      final bool last = depth == path.length - 1;
      if (last || member.node.members == null) {
        final String indent = _lineIndent(text, member.keyStart);
        return text.replaceRange(
          member.node.start,
          member.node.end,
          _render(
            last ? value : _nest(path.sublist(depth + 1), value),
            indent,
            unit,
            nl,
          ),
        );
      }
      node = member.node;
    }
    throw ArgumentError('An empty path cannot be set.');
  }

  /// Returns [text] without the member at [path]; unchanged when absent.
  static String? remove(String? text, List<String> path) {
    if (text == null || text.trim().isEmpty) return text;
    _Node node = _parse(text);
    for (int depth = 0; depth < path.length; depth++) {
      final List<_Member>? members = node.members;
      if (members == null) return text;
      final int index = members.lastIndexWhere((m) => m.key == path[depth]);
      if (index < 0) return text;
      final _Member member = members[index];
      if (depth < path.length - 1) {
        node = member.node;
        continue;
      }
      if (members.length == 1) {
        return text.replaceRange(node.start + 1, node.end - 1, '');
      }
      if (index < members.length - 1) {
        return text.replaceRange(
          member.keyStart,
          members[index + 1].keyStart,
          '',
        );
      }
      // The last member: take the separator before it, or with a trailing
      // comma the span between the two commas, so the style is kept.
      final _Member previous = members[index - 1];
      return member.commaEnd != null && previous.commaEnd != null
          ? text.replaceRange(previous.commaEnd!, member.commaEnd!, '')
          : text.replaceRange(previous.node.end, member.node.end, '');
    }
    return text;
  }

  static String _insert(
    String text,
    _Node object,
    String key,
    Object? value,
    String unit,
    String nl,
  ) {
    final List<_Member> members = object.members!;
    if (members.isEmpty) {
      final String outer = _lineIndent(text, object.start);
      final String indent = outer + unit;
      return text.replaceRange(
        object.start + 1,
        object.end - 1,
        '$nl$indent${jsonEncode(key)}: ${_render(value, indent, unit, nl)}$nl$outer',
      );
    }
    final _Member last = members.last;
    final String indent = _lineIndent(text, last.keyStart);
    final String entry =
        '$nl$indent${jsonEncode(key)}: ${_render(value, indent, unit, nl)}';
    return last.commaEnd == null
        ? text.replaceRange(last.node.end, last.node.end, ',$entry')
        : text.replaceRange(last.commaEnd!, last.commaEnd!, '$entry,');
  }

  static Object? _nest(List<String> path, Object? value) {
    Object? result = value;
    for (final String key in path.reversed) {
      result = <String, Object?>{key: result};
    }
    return result;
  }

  static String _render(Object? value, String indent, String unit, String nl) =>
      JsonEncoder.withIndent(
        unit,
      ).convert(value).replaceAll('\n', '$nl$indent');

  static String _lineIndent(String text, int offset) {
    final int start = offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
    int end = start;
    while (end < offset && (text[end] == ' ' || text[end] == '\t')) {
      end++;
    }
    return text.substring(start, end);
  }

  static String _indentUnit(String text) =>
      RegExp(r'^([ \t]+)["}\]]', multiLine: true).firstMatch(text)?.group(1) ??
      '  ';

  static String _newline(String? text) =>
      text != null && text.contains('\r\n') ? '\r\n' : '\n';

  static _Node _parse(String text) => _Parser(text).document();
}

final class _Node {
  _Node(this.start, this.end, this.value, [this.members]);
  final int start;
  final int end;
  final Object? value;

  /// Members in source order, for objects only.
  final List<_Member>? members;
}

final class _Member {
  _Member(this.key, this.keyStart, this.node, this.commaEnd);
  final String key;
  final int keyStart;
  final _Node node;

  /// The offset just after a comma that follows the value, if any.
  final int? commaEnd;
}

final class _Parser {
  _Parser(this.s);
  final String s;
  int i = 0;

  _Node document() {
    _skip();
    final _Node node = _value();
    _skip();
    if (i != s.length) _fail();
    return node;
  }

  void _skip() {
    while (i < s.length) {
      final String c = s[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '﻿') {
        i++;
      } else if (s.startsWith('//', i)) {
        final int end = s.indexOf('\n', i);
        i = end < 0 ? s.length : end;
      } else if (s.startsWith('/*', i)) {
        final int end = s.indexOf('*/', i + 2);
        if (end < 0) _fail();
        i = end + 2;
      } else {
        return;
      }
    }
  }

  _Node _value() {
    if (i >= s.length) _fail();
    final String c = s[i];
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (c == '"') return _string();
    for (final (String word, Object? value) in <(String, Object?)>[
      ('true', true),
      ('false', false),
      ('null', null),
    ]) {
      if (s.startsWith(word, i)) {
        final int start = i;
        i += word.length;
        return _Node(start, i, value);
      }
    }
    final Match? number = _number.matchAsPrefix(s, i);
    if (number == null) _fail();
    i = number.end;
    return _Node(number.start, i, num.parse(number.group(0)!));
  }

  _Node _object() {
    final int start = i++;
    final Map<String, Object?> value = <String, Object?>{};
    final List<_Member> members = <_Member>[];
    _skip();
    while (true) {
      if (i < s.length && s[i] == '}') break;
      if (i >= s.length || s[i] != '"') _fail();
      final int keyStart = i;
      final String key = _string().value! as String;
      _skip();
      if (i >= s.length || s[i] != ':') _fail();
      i++;
      _skip();
      final _Node node = _value();
      _skip();
      int? commaEnd;
      if (i < s.length && s[i] == ',') commaEnd = ++i;
      members.add(_Member(key, keyStart, node, commaEnd));
      value[key] = node.value;
      _skip();
      if (commaEnd == null) {
        if (i >= s.length || s[i] != '}') _fail();
        break;
      }
    }
    i++;
    return _Node(start, i, value, members);
  }

  _Node _array() {
    final int start = i++;
    final List<Object?> value = <Object?>[];
    _skip();
    while (true) {
      if (i < s.length && s[i] == ']') break;
      value.add(_value().value);
      _skip();
      if (i < s.length && s[i] == ',') {
        i++;
        _skip();
        continue;
      }
      if (i >= s.length || s[i] != ']') _fail();
      break;
    }
    i++;
    return _Node(start, i, value);
  }

  _Node _string() {
    final int start = i++;
    while (i < s.length && s[i] != '"') {
      if (s[i] == '\\') i++;
      i++;
    }
    if (i >= s.length) _fail();
    i++;
    try {
      return _Node(start, i, jsonDecode(s.substring(start, i)));
    } on FormatException {
      _fail();
    }
  }

  Never _fail() => throw FormatException('Invalid JSON.', s, i);

  static final RegExp _number = RegExp(
    r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
  );
}
