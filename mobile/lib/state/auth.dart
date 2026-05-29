import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../api/api_client.dart';
import '../api/ory_client.dart';
import '../models/models.dart';
import 'biometric.dart';
import 'push.dart';

const _kSessionKey = 'ory_session_token';

final secureStorageProvider = Provider<FlutterSecureStorage>((_) => const FlutterSecureStorage());
final oryClientProvider = Provider<OryClient>((_) => OryClient());
final apiClientProvider = Provider<ApiClient>((_) => ApiClient());

class AuthState {
  final String? sessionToken;
  final Me? me;
  final bool notAllowed;     // signed in via Ory but email not on allowlist
  final String? notAllowedEmail;
  const AuthState({this.sessionToken, this.me, this.notAllowed = false, this.notAllowedEmail});
  bool get isAuthed => sessionToken != null;
  bool get isOnboarded => me != null;
  AuthState copyWith({
    String? sessionToken,
    Me? me,
    bool? notAllowed,
    String? notAllowedEmail,
    bool clearSession = false,
    bool clearMe = false,
    bool clearNotAllowed = false,
  }) => AuthState(
        sessionToken: clearSession ? null : (sessionToken ?? this.sessionToken),
        me: clearMe ? null : (me ?? this.me),
        notAllowed: clearNotAllowed ? false : (notAllowed ?? this.notAllowed),
        notAllowedEmail: clearNotAllowed ? null : (notAllowedEmail ?? this.notAllowedEmail),
      );
}

class AuthController extends StateNotifier<AuthState> {
  final Ref _ref;
  AuthController(this._ref) : super(const AuthState());

  Future<void> bootstrap() async {
    final storage = _ref.read(secureStorageProvider);
    final token = await storage.read(key: _kSessionKey);
    if (token == null) return;
    _ref.read(apiClientProvider).setToken(token);
    state = state.copyWith(sessionToken: token);
    await _resolveUser();
  }

  Future<void> signInWithGoogle() async {
    final ory = _ref.read(oryClientProvider);
    final token = await ory.signInWithGoogle();
    await _persist(token);
    await _resolveUser();
    // Fresh authentication implies the user is present — skip the biometric
    // prompt for this session.
    _ref.read(biometricProvider.notifier).markUnlocked();
  }

  Future<void> signInWithApple() async {
    final ory = _ref.read(oryClientProvider);
    final token = await ory.signInWithApple();
    await _persist(token);
    await _resolveUser();
    _ref.read(biometricProvider.notifier).markUnlocked();
  }

  // Demo login — only meaningful when the backend reports demo_mode=true.
  // The Worker's /auth/demo endpoint validates the credentials against its
  // DEMO_USERS env var; we just hand the token back to _persist / _resolveUser
  // so the rest of the app sees no difference from an Ory login.
  Future<void> signInWithDemo(String email, String password) async {
    final api = _ref.read(apiClientProvider);
    final token = await api.demoSignIn(email, password);
    await _persist(token);
    await _resolveUser();
    _ref.read(biometricProvider.notifier).markUnlocked();
  }

  Future<void> logout() async {
    // Unregister BEFORE clearing the session token; the DELETE call needs auth.
    await _ref.read(pushControllerProvider).unregisterCurrent();
    await _ref.read(secureStorageProvider).delete(key: _kSessionKey);
    _ref.read(apiClientProvider).setToken(null);
    _ref.read(biometricProvider.notifier).reset();
    state = const AuthState();
  }

  void setMe(Me me) {
    state = state.copyWith(me: me);
  }

  Future<void> _persist(String token) async {
    await _ref.read(secureStorageProvider).write(key: _kSessionKey, value: token);
    _ref.read(apiClientProvider).setToken(token);
    state = state.copyWith(sessionToken: token, clearNotAllowed: true);
  }

  // After authentication: try /me. If the user row doesn't exist yet,
  // automatically call /me/finalize. If finalize is rejected (email not on
  // allowlist), surface notAllowed so the router shows the explanation screen.
  Future<void> _resolveUser() async {
    final api = _ref.read(apiClientProvider);
    try {
      final me = await api.me();
      state = state.copyWith(me: me, clearNotAllowed: true);
      _kickPushRegistration();
      return;
    } on ApiException catch (e) {
      if (e.status == 401) { await logout(); return; }
      if (!(e.status == 409 && e.code == 'needs_finalize')) rethrow;
      // fall through to finalize
    }
    try {
      final me = await api.finalize();
      state = state.copyWith(me: me, clearNotAllowed: true);
      _kickPushRegistration();
    } on ApiException catch (e) {
      if (e.status == 403 && e.code == 'not_allowed') {
        state = state.copyWith(notAllowed: true, notAllowedEmail: e.message, clearMe: true);
      } else if (e.status == 401) {
        await logout();
      } else {
        rethrow;
      }
    }
  }

  // Fire-and-forget: requesting permission + waiting for the APNs token can
  // take seconds, so we don't block sign-in on it.
  void _kickPushRegistration() {
    unawaited(_ref.read(pushControllerProvider).onAuthenticated());
  }
}

final authProvider = StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref));
