/// App-wide configuration.
///
/// The API base URL defaults to the live deployed Finverse backend.
/// To point the app at a different backend (for example a local copy
/// running on your laptop), pass it at build/run time:
///
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000/api
class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://finverse-api-1079638201272.asia-south1.run.app/api',
  );

  static const String appName = 'Finverse';

  /// Where data lives:
  ///  * `cloud` (default): the live backend, with sign-in. Unchanged app.
  ///  * `local`: everything on the phone in an encrypted SQLite database,
  ///    no sign-in and no server. Areas not yet moved to the phone show a
  ///    "coming soon" message.
  ///
  ///   flutter run --dart-define=FINVERSE_MODE=local
  static const String dataMode = String.fromEnvironment('FINVERSE_MODE', defaultValue: 'cloud');
  static bool get isLocal => dataMode == 'local';

  /// Network timeout for API calls. The live backend can take a few
  /// seconds to wake up after being idle (Cloud Run cold start).
  static const Duration requestTimeout = Duration(seconds: 45);
}
