/// Input checks for local services, mirroring the backend's Pydantic schemas
/// (same rules, same messages) so the app behaves the same in both modes.
library;

import '../services/errors.dart';

/// Reads a required or optional string.
String? readString(Map<String, dynamic> input, String field, {bool required = false}) {
  if (!input.containsKey(field) || input[field] == null) {
    if (required) throw ValidationException(field, 'Field required');
    return null;
  }
  final value = input[field];
  if (value is! String) throw ValidationException(field, 'Input should be a valid string');
  return value;
}

/// Reads a number, enforcing optional `gt` / `ge` / `le` bounds like Pydantic's Field().
double? readNumber(Map<String, dynamic> input, String field, {bool required = false, num? gt, num? ge, num? le}) {
  if (!input.containsKey(field) || input[field] == null) {
    if (required) throw ValidationException(field, 'Field required');
    return null;
  }
  final raw = input[field];
  final value = raw is num ? raw.toDouble() : (raw is String ? double.tryParse(raw.trim()) : null);
  if (value == null || value.isNaN) throw ValidationException(field, 'Input should be a valid number');
  _checkBounds(field, value, gt: gt, ge: ge, le: le);
  return value;
}

/// Reads a whole number with optional bounds.
int? readInt(Map<String, dynamic> input, String field, {bool required = false, num? gt, num? ge, num? le}) {
  if (!input.containsKey(field) || input[field] == null) {
    if (required) throw ValidationException(field, 'Field required');
    return null;
  }
  final raw = input[field];
  final int? value = switch (raw) {
    int v => v,
    double v when v == v.roundToDouble() => v.toInt(),
    String v => int.tryParse(v.trim()),
    _ => null,
  };
  if (value == null) throw ValidationException(field, 'Input should be a valid integer');
  _checkBounds(field, value, gt: gt, ge: ge, le: le);
  return value;
}

bool? readBool(Map<String, dynamic> input, String field) {
  if (!input.containsKey(field) || input[field] == null) return null;
  final value = input[field];
  if (value is bool) return value;
  throw ValidationException(field, 'Input should be a valid boolean');
}

/// Reads a 'YYYY-MM-DD' date and returns it in that form.
String? readDate(Map<String, dynamic> input, String field, {bool required = false}) {
  if (!input.containsKey(field) || input[field] == null) {
    if (required) throw ValidationException(field, 'Field required');
    return null;
  }
  final raw = input[field];
  final parsed = raw is DateTime ? raw : (raw is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw) ? DateTime.tryParse(raw) : null);
  if (parsed == null || (raw is String && dateOnly(parsed) != raw)) {
    throw ValidationException(field, 'Input should be a valid date');
  }
  return dateOnly(parsed);
}

/// Reads an id (the backend accepts any UUID or string here).
String? readId(Map<String, dynamic> input, String field, {bool required = false}) {
  if (!input.containsKey(field) || input[field] == null || input[field] == '') {
    if (required) throw ValidationException(field, 'Field required');
    return null;
  }
  return input[field].toString();
}

/// 'YYYY-MM-DD' for a date (local calendar date).
String dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void _checkBounds(String field, num value, {num? gt, num? ge, num? le}) {
  if (gt != null && !(value > gt)) throw ValidationException(field, 'Input should be greater than ${_n(gt)}');
  if (ge != null && !(value >= ge)) throw ValidationException(field, 'Input should be greater than or equal to ${_n(ge)}');
  if (le != null && !(value <= le)) throw ValidationException(field, 'Input should be less than or equal to ${_n(le)}');
}

String _n(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
