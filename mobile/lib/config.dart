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

  /// Network timeout for API calls. The live backend can take a few
  /// seconds to wake up after being idle (Cloud Run cold start).
  static const Duration requestTimeout = Duration(seconds: 45);
}
