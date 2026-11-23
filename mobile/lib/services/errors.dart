/// Errors raised by the on-phone (local) services.
///
/// Messages are written for the user and match what the backend returned for
/// the same problem, so screens can show `error.toString()` unchanged.
library;

class ServiceException implements Exception {
  const ServiceException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Invalid input. Formatted like the backend's validation errors after the
/// API client tidied them: `Amount: Input should be greater than 0`.
class ValidationException extends ServiceException {
  ValidationException(this.field, String problem) : super('${prettyField(field)}: $problem');
  final String field;
}

/// The record doesn't exist (for example it was deleted on another screen).
class NotFoundException extends ServiceException {
  const NotFoundException(super.message);
}

/// The area hasn't been moved to the phone yet (local mode only).
class NotAvailableYetException extends ServiceException {
  const NotAvailableYetException(String area)
      : super('$area is not in the offline version yet. It is coming in a later update.');
}

/// `monthly_limit` -> `Monthly limit` (same as the API client's formatting).
String prettyField(String field) {
  final words = field.replaceAll('_', ' ');
  return words.isEmpty ? field : words[0].toUpperCase() + words.substring(1);
}
