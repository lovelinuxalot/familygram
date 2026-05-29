// Runtime-toggleable verbose logging. Mirrored from the server's
// DEBUG_LOGGING flag (fetched at app startup via /config) so a single
// switch on the Worker controls both server tail output AND client
// device console output — no rebuild, no redeploy.
//
// Uses print() (not debugPrint) so the lines survive release builds and
// show up in Console.app on macOS when an iPhone is plugged in. When the
// flag is off, every call is a cheap no-op.

// Mutable global. main.dart sets it after the /config fetch, and the
// push controller checks it before sending diagnostic POSTs.
bool _debugLogging = false;

bool get debugLogging => _debugLogging;
set debugLogging(bool v) => _debugLogging = v;

void flog(String message) {
  if (!_debugLogging) return;
  // ignore: avoid_print
  print('[familygram] $message');
}
