import 'dart:convert';
import 'json_edit.dart';

/// Chengxiaobang uses a flat hooks array with stable IDs and an enabled switch.
/// Ownership remains command-marker based, as for the other hook formats.
abstract final class ChengxiaobangHooks {
  static Map<String, Object?> _root(String? text) {
    final value = JsonEdit.decode(text);
    if (value is! Map<String, Object?> ||
        (value['enabled'] != null && value['enabled'] is! bool) ||
        (value['hooks'] != null && value['hooks'] is! List)) {
      throw const FormatException('Invalid Chengxiaobang hooks configuration.');
    }
    return value;
  }

  static List<Map<String, Object?>> _entries(Map<String, Object?> root) {
    final result = <Map<String, Object?>>[];
    final ids = <String>{};
    for (final value in (root['hooks'] as List? ?? const [])) {
      if (value is! Map<String, Object?> ||
          value['id'] is! String ||
          value['command'] is! String ||
          value['event'] is! String ||
          value['enabled'] is! bool ||
          !ids.add(value['id'] as String)) {
        throw const FormatException(
          'Invalid or duplicate Chengxiaobang hook entry.',
        );
      }
      result.add(value);
    }
    return result;
  }

  static bool has(String? text, bool Function(String) owns) =>
      _entries(_root(text)).any((entry) => owns(entry['command'] as String));

  static String? set(
    String? text,
    List<Map<String, Object?>> desired,
    bool Function(String) owns,
  ) {
    final before = _root(text);
    final old = _entries(before);
    if (desired.isNotEmpty && before['enabled'] == false) {
      throw const FormatException(
        'Global Chengxiaobang hooks are disabled; enable them in the client before connecting hooks.',
      );
    }
    final kept = old
        .where((entry) => !owns(entry['command'] as String))
        .toList();
    final ids = kept.map((entry) => entry['id']).toSet();
    if (desired.any((entry) => ids.contains(entry['id']))) {
      throw const FormatException(
        'A Chengxiaobang hook ID belongs to another command.',
      );
    }
    final next = [...kept, ...desired];
    if (jsonEncode(old) == jsonEncode(next) &&
        (desired.isEmpty || before['enabled'] == true))
      return text;
    // Removing absent hooks is a no-op; unrelated root fields and hooks survive.
    if (desired.isEmpty && old.length == kept.length) return text;
    var result = JsonEdit.set(text, const ['hooks'], next);
    if (desired.isNotEmpty && before['enabled'] == null) {
      result = JsonEdit.set(result, const ['enabled'], true);
    }
    return result;
  }
}
