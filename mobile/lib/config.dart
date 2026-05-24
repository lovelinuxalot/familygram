// Build-time configuration. Override via --dart-define when running flutter:
//   flutter run --dart-define=API_BASE=https://your-worker.workers.dev \
//               --dart-define=ORY_BASE=https://your-slug.projects.oryapis.com
class AppConfig {
  static const apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://localhost:8787',
  );
  static const oryBase = String.fromEnvironment(
    'ORY_BASE',
    defaultValue: 'https://REPLACE-ME.projects.oryapis.com',
  );
}
