/// Helpers for Python -> Dart parity tests.
///
/// Fixtures in `test/parity/fixtures/` are produced by
/// `tools/parity/generate_fixtures.py`, which runs the real backend code.
/// A local Dart implementation passes when it returns the same JSON for
/// every saved input.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Loads `test/parity/fixtures/<name>` (tests run from the package root).
Map<String, dynamic> loadFixture(String name) {
  final file = File('test/parity/fixtures/$name');
  if (!file.existsSync()) {
    throw StateError('Missing fixture ${file.path}. Run: python tools/parity/generate_fixtures.py');
  }
  return Map<String, dynamic>.from(jsonDecode(file.readAsStringSync()) as Map);
}

/// Lists every difference between [expected] (from Python) and [actual]
/// (from Dart), as `path: expected X, got Y`. Empty when they match.
///
/// Numbers match when they differ by at most [tolerance] (plus a tiny
/// relative margin for floating-point noise); `12` and `12.0` are equal.
List<String> diffJson(Object? expected, Object? actual, {double tolerance = 0, String path = r'$', int limit = 25}) {
  final out = <String>[];
  void walk(Object? e, Object? a, String p) {
    if (out.length >= limit) return;
    if (e is num && a is num) {
      final margin = tolerance + 1e-9 * (e.abs() > 1 ? e.abs() : 1);
      if ((e - a).abs() > margin) out.add('$p: expected $e, got $a');
    } else if (e is Map && a is Map) {
      for (final key in e.keys) {
        if (!a.containsKey(key)) {
          out.add('$p.$key: missing (expected ${_short(e[key])})');
        } else {
          walk(e[key], a[key], '$p.$key');
        }
      }
      for (final key in a.keys) {
        if (!e.containsKey(key)) out.add('$p.$key: unexpected extra key (${_short(a[key])})');
      }
    } else if (e is List && a is List) {
      if (e.length != a.length) out.add('$p: expected ${e.length} items, got ${a.length}');
      for (var i = 0; i < e.length && i < a.length; i++) {
        walk(e[i], a[i], '$p[$i]');
      }
    } else if (e != a) {
      out.add('$p: expected ${_short(e)}, got ${_short(a)}');
    }
  }

  walk(expected, actual, path);
  return out;
}

/// Fails the test with a readable report if [actual] differs from [expected].
void expectMatchesPython(Object? actual, Object? expected, {double tolerance = 0, String? reason}) {
  final diffs = diffJson(expected, actual, tolerance: tolerance);
  if (diffs.isNotEmpty) {
    fail([?reason, 'Dart result differs from Python:', ...diffs.map((d) => '  $d')].join('\n'));
  }
}

String _short(Object? value) {
  final text = value is String ? '"$value"' : jsonEncode(value);
  return text.length > 80 ? '${text.substring(0, 77)}...' : text;
}
