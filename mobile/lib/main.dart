import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'api/api_client.dart';
import 'models/models.dart';
import 'state/auth.dart';
import 'state/biometric.dart';
import 'state/push.dart';
import 'theme.dart';
import 'util/log.dart' as flog;
import 'screens/admin_panel.dart';
import 'screens/biometric_lock.dart';
import 'screens/feed.dart';
import 'screens/image_viewer.dart';
import 'screens/login.dart';
import 'screens/not_allowed.dart';
import 'screens/post_detail.dart';
import 'screens/profile.dart';
import 'screens/upload.dart';
import 'screens/user_profile.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase reads GoogleService-Info.plist / google-services.json at boot.
  // If those aren't in place yet (fresh clone before push setup), log and
  // keep going so the rest of the app still works.
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
  } catch (e) {
    debugPrint('Firebase init failed; push notifications disabled: $e');
  }
  // Fetch the server config so the debug-logging flag is set before any
  // diagnostic code starts. Don't block app startup on failure — default
  // to "debug off" which means quietest behavior.
  try {
    final cfg = await ApiClient().fetchConfig();
    flog.debugLogging = cfg.debug;
  } catch (_) {/* keep default off */}
  runApp(const ProviderScope(child: FamilygramApp()));
}

class FamilygramApp extends ConsumerStatefulWidget {
  const FamilygramApp({super.key});
  @override
  ConsumerState<FamilygramApp> createState() => _FamilygramAppState();
}

class _FamilygramAppState extends ConsumerState<FamilygramApp> with WidgetsBindingObserver {
  late final _AuthListenable _authListenable;
  late final GoRouter _router;
  bool _booted = false;
  DateTime? _backgroundedAt;
  // Re-lock the app if it was backgrounded for at least this long.
  static const _relockAfter = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authListenable = _AuthListenable();
    ref.listenManual(authProvider, (_, __) => _authListenable.ping());
    _router = GoRouter(
      refreshListenable: _authListenable,
      redirect: (ctx, state) {
        final auth = ref.read(authProvider);
        final loc = state.matchedLocation;
        final atLogin = loc == '/login';
        final atNotAllowed = loc == '/not-allowed';
        if (!auth.isAuthed) return atLogin ? null : '/login';
        if (auth.notAllowed) return atNotAllowed ? null : '/not-allowed';
        if (auth.isOnboarded && (atLogin || atNotAllowed)) return '/';
        return null;
      },
      routes: [
        GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
        GoRoute(path: '/not-allowed', builder: (_, __) => const NotAllowedScreen()),
        GoRoute(path: '/', builder: (_, __) => const FeedScreen()),
        GoRoute(path: '/upload', builder: (_, __) => const UploadScreen()),
        GoRoute(path: '/me', builder: (_, __) => const ProfileScreen()),
        GoRoute(path: '/user/:id', builder: (_, s) => UserProfileScreen(userId: s.pathParameters['id']!)),
        GoRoute(path: '/admin', builder: (_, __) => const AdminPanelScreen()),
        GoRoute(path: '/post/:id', builder: (_, s) => PostDetailScreen(postId: s.pathParameters['id']!)),
        GoRoute(
          path: '/view',
          builder: (_, s) {
            final extra = (s.extra as Map<String, dynamic>?) ?? const {};
            final urls = (extra['urls'] as List?)?.cast<String>();
            if (urls != null && urls.isNotEmpty) {
              final keys = ((extra['cacheKeys'] as List?)?.cast<String?>()) ??
                  List<String?>.filled(urls.length, null);
              final initial = (extra['initialIndex'] as int?) ?? 0;
              final post = extra['post'] as Post?;
              return ImageViewerScreen(urls: urls, cacheKeys: keys, initialIndex: initial, post: post);
            }
            // Single-photo legacy shape: {url, cacheKey}.
            return ImageViewerScreen.single(
              url: (extra['url'] as String?) ?? '',
              cacheKey: extra['cacheKey'] as String?,
            );
          },
        ),
      ],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Make the router reachable from push tap handlers before bootstrap, so
      // a cold-start notification can still deep-link the moment auth resolves.
      ref.read(routerProvider.notifier).state = _router;
      await ref.read(authProvider.notifier).bootstrap();
      if (mounted) setState(() => _booted = true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      if (since != null && DateTime.now().difference(since) >= _relockAfter) {
        ref.read(biometricProvider.notifier).lock();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_booted) {
      return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
    }
    return MaterialApp.router(
      title: 'Familygram',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.system,
      routerConfig: _router,
      // Overlay the biometric lock screen over whatever route is current so
      // the user can resume right where they were after unlocking.
      builder: (context, child) {
        final auth = ref.watch(authProvider);
        final bio = ref.watch(biometricProvider);
        final showLock = auth.isAuthed && auth.isOnboarded && bio.shouldLock;
        return Stack(children: [
          child ?? const SizedBox.shrink(),
          if (showLock) const BiometricLockScreen(),
        ]);
      },
    );
  }
}

class _AuthListenable extends ChangeNotifier {
  void ping() => notifyListeners();
}
