import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../util/log.dart' as logutil;
import 'auth.dart';

const _kAndroidChannelId = 'familygram_posts';
const _kAndroidChannelName = 'New posts';
const _kAndroidChannelDesc = 'Notifications when family members upload new photos';

// Top-level entry point required by firebase_messaging. Runs in its own
// isolate when the app is fully terminated and a notification arrives — we
// don't do anything custom (the OS already displays the system banner from
// the `notification` field), but Firebase requires us to register it.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {}

// Holds the GoRouter instance so tap handlers can deep-link without needing
// a BuildContext. main.dart sets this once GoRouter is constructed.
final routerProvider = StateProvider<GoRouter?>((_) => null);

final pushControllerProvider = Provider<PushController>((ref) => PushController(ref));

class PushController {
  final Ref _ref;
  final FlutterLocalNotificationsPlugin _local = FlutterLocalNotificationsPlugin();
  String? _registeredToken;
  bool _initialized = false;
  StreamSubscription<String>? _refreshSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<RemoteMessage>? _openedSub;

  PushController(this._ref);

  // Call once auth has succeeded. Idempotent: setup runs once, token
  // registration re-runs each call so post-logout-login on the same device
  // re-binds the FCM token to the new user_id server-side.
  Future<void> onAuthenticated() async {
    try {
      await _initializeOnce();
      await _registerToken();
    } catch (e, st) {
      await _diag({'stage': 'onAuthenticated.error', 'error': e.toString(), 'stack': st.toString().substring(0, 200)});
    }
  }

  Future<void> unregisterCurrent() async {
    final token = _registeredToken;
    _registeredToken = null;
    if (token == null) return;
    try {
      await _ref.read(apiClientProvider).unregisterDeviceToken(token);
    } catch (e) {
      // Logout proceeds regardless; orphan tokens get pruned on next failed send.
      logutil.flog('push: unregister failed (ignored): $e');
    }
  }

  Future<void> _initializeOnce() async {
    if (_initialized) return;
    _initialized = true;

    final messaging = FirebaseMessaging.instance;
    await _diag({'stage': 'initOnce.start'});
    final settings = await messaging.requestPermission(alert: true, badge: true, sound: true);
    await _diag({'stage': 'requestPermission', 'status': settings.authorizationStatus.name});
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      logutil.flog('push: permission denied; skipping registration');
      _initialized = false;
      return;
    }

    // iOS: ask the system to display banners while the app is foregrounded.
    // Android: ignored — we display via flutter_local_notifications instead.
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true, badge: true, sound: true,
    );
    await _diag({'stage': 'foregroundOptionsSet'});

    if (Platform.isAndroid) {
      await _local.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (resp) {
          final postId = resp.payload;
          if (postId != null && postId.isNotEmpty) _navigateToPost(postId);
        },
      );
      final androidImpl = _local
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.createNotificationChannel(const AndroidNotificationChannel(
        _kAndroidChannelId,
        _kAndroidChannelName,
        description: _kAndroidChannelDesc,
        importance: Importance.high,
      ));
    }

    _foregroundSub = FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);
    _refreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((_) => _registerToken());
    await _diag({'stage': 'listenersAttached'});

    // Cold-start launched via notification tap. Fire-and-forget — on iOS,
    // getInitialMessage() can hang until APNs registration completes; we
    // don't want that to block token registration.
    unawaited(messaging.getInitialMessage().then((initial) {
      if (initial != null) _handleTap(initial);
    }));
    await _diag({'stage': 'initOnce.done'});
  }

  Future<void> _registerToken() async {
    await _diag({'stage': 'registerToken.start'});
    try {
      String? apnsToken;
      if (Platform.isIOS) {
        // iOS: getToken() throws if the APNs token hasn't been received yet.
        // Poll up to 15s — first-launch APNs registration can be slow.
        for (int i = 0; i < 30; i++) {
          apnsToken = await FirebaseMessaging.instance.getAPNSToken();
          if (apnsToken != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        await _diag({
          'stage': 'apnsToken',
          'present': apnsToken != null,
          'len': apnsToken?.length ?? 0,
        });
      }
      final token = await FirebaseMessaging.instance.getToken();
      await _diag({
        'stage': 'fcmToken',
        'present': token != null && token.isNotEmpty,
        'len': token?.length ?? 0,
      });
      if (token == null || token.isEmpty) return;
      if (token == _registeredToken) return;

      final platform = Platform.isIOS ? 'ios' : 'android';
      await _ref.read(apiClientProvider).registerDeviceToken(token, platform);
      _registeredToken = token;
      await _diag({'stage': 'registered', 'platform': platform});
    } catch (e) {
      await _diag({'stage': 'error', 'error': e.toString()});
      logutil.flog('push: register token failed: $e');
    }
  }

  Future<void> _diag(Map<String, Object?> info) async {
    // Both client-side print (Console.app visible) and server-side POST
    // (wrangler tail visible) are gated by the same flag.
    if (!logutil.debugLogging) return;
    logutil.flog('push-diag $info');
    try {
      await _ref.read(apiClientProvider).pushDiagnostic(info);
    } catch (_) {/* swallow */}
  }

  void _handleForegroundMessage(RemoteMessage message) {
    // iOS shows the system banner via setForegroundNotificationPresentationOptions.
    // Android suppresses by default, so we render via flutter_local_notifications.
    if (!Platform.isAndroid) return;
    final notification = message.notification;
    if (notification == null) return;
    final postId = message.data['post_id']?.toString();
    _local.show(
      DateTime.now().millisecondsSinceEpoch.remainder(1 << 31),
      notification.title,
      notification.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _kAndroidChannelId,
          _kAndroidChannelName,
          channelDescription: _kAndroidChannelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      payload: postId,
    );
  }

  void _handleTap(RemoteMessage message) {
    final postId = message.data['post_id']?.toString();
    if (postId != null && postId.isNotEmpty) _navigateToPost(postId);
  }

  void _navigateToPost(String postId) {
    final router = _ref.read(routerProvider);
    if (router == null) {
      logutil.flog('push: router not ready, dropping deep-link to /post/$postId');
      return;
    }
    router.push('/post/$postId');
  }

  void dispose() {
    _foregroundSub?.cancel();
    _openedSub?.cancel();
    _refreshSub?.cancel();
  }
}
