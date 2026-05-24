import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

// Manages the per-launch unlock state for Familygram. If the device has any
// biometric or passcode set up, the app starts in "locked" state and shows
// the BiometricLockScreen until LocalAuthentication.authenticate succeeds.
//
// Fresh sign-ins (Google OAuth) call markUnlocked() so the user isn't faced
// with a Face ID prompt immediately after just authenticating. App lifecycle
// transitions (>60s in background) flip back to locked.

class BiometricState {
  final bool available;     // device hardware/passcode supports auth
  final bool unlocked;
  final bool checking;
  final String? error;
  const BiometricState({this.available = false, this.unlocked = false, this.checking = false, this.error});
  bool get shouldLock => available && !unlocked;
  BiometricState copyWith({bool? available, bool? unlocked, bool? checking, String? error, bool clearError = false}) =>
      BiometricState(
        available: available ?? this.available,
        unlocked: unlocked ?? this.unlocked,
        checking: checking ?? this.checking,
        error: clearError ? null : (error ?? this.error),
      );
}

class BiometricController extends StateNotifier<BiometricState> {
  final _local = LocalAuthentication();
  BiometricController() : super(const BiometricState()) {
    _detect();
  }

  Future<void> _detect() async {
    try {
      // isDeviceSupported returns true if the device has a passcode (or
      // biometrics). canCheckBiometrics is biometric-specific. We want any of
      // the two — passcode fallback is fine.
      final supported = await _local.isDeviceSupported();
      state = state.copyWith(available: supported);
    } catch (_) {
      state = state.copyWith(available: false);
    }
  }

  Future<bool> unlock() async {
    if (state.checking) return false;
    state = state.copyWith(checking: true, clearError: true);
    try {
      final ok = await _local.authenticate(
        localizedReason: 'Unlock Familygram',
        options: const AuthenticationOptions(
          biometricOnly: false,   // allow passcode fallback if Face ID fails
          stickyAuth: true,        // survive app backgrounding mid-prompt
        ),
      );
      state = state.copyWith(unlocked: ok, checking: false);
      return ok;
    } catch (e) {
      state = state.copyWith(checking: false, error: e.toString());
      return false;
    }
  }

  // Used after a fresh Google sign-in — the user just authenticated, don't
  // make them do it again.
  void markUnlocked() => state = state.copyWith(unlocked: true, clearError: true);

  void lock() => state = state.copyWith(unlocked: false);

  // Logout clears everything.
  void reset() => state = const BiometricState();
}

final biometricProvider = StateNotifierProvider<BiometricController, BiometricState>((_) => BiometricController());
